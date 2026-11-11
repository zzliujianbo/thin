//! Local endpoint model metadata only. Search/confirmation sends no requests,
//! checks no credentials and never claims discovered provider capabilities.
const std = @import("std");
const cfg = @import("../core/config.zig");
const input = @import("input.zig");
const presentation = @import("presentation.zig");
const text = @import("text.zig");
const Allocator = std.mem.Allocator;

/// Credential-free registry identity published by the owner. This list contains
/// only locally configured providers, including custom aliases.
pub const Provider = struct {
    name: []const u8,
    allow_custom: bool = false,
};

pub const Choice = struct {
    name: []const u8,
    context_tokens: u32,
    current: bool = false,
    inherited: bool = false,
    profile_index: ?usize = null,
    uses_profile: bool = false,
    disabled: bool = false,
    custom_alias: ?[]const u8 = null,
};
pub const Origins = struct {
    current: bool = false,
    models: []const bool = &.{},
};
pub const Rows = struct {
    checked_mask: u16 = 0,
    lines: []const []const u8,
    selected_line: ?usize = null,
    can_confirm: bool = false,
    selected_choice: ?Choice = null,
};

pub const Picker = struct {
    query: input.Editor,
    selected: usize = 0,
    generation: u64 = 1,
    pasted: bool = false,
    allow_custom: bool = true,
    /// Resolved from the actual endpoint by the owner, never inferred from a name.
    provider: ?cfg.providers.Id = null,
    drawn_model: [1089]u8 = undefined,
    drawn_model_len: ?usize = null,
    pending_model: [1089]u8 = undefined,
    pending_model_len: ?usize = null,

    pub fn init(a: Allocator) Picker {
        return .{ .query = .{ .allocator = a } };
    }
    pub fn deinit(self: *Picker) void {
        self.query.deinit();
    }
    /// Copy the fully qualified displayed selection before its frame is ACKed.
    /// Live credential/catalog changes must never retarget an acknowledged row.
    pub fn captureChoice(self: *Picker, a: Allocator, choice: ?Choice) !void {
        self.pending_model_len = null;
        if (choice) |value| {
            const name = try self.selectionName(a, value);
            defer a.free(name);
            if (name.len <= self.pending_model.len) {
                @memcpy(self.pending_model[0..name.len], name);
                self.pending_model_len = name.len;
            }
        }
    }
    pub fn acknowledgeChoice(self: *Picker) void {
        self.drawn_model_len = self.pending_model_len;
        if (self.pending_model_len) |len| @memcpy(self.drawn_model[0..len], self.pending_model[0..len]);
    }
    pub fn modelShown(self: *const Picker, name: []const u8) bool {
        const len = self.drawn_model_len orelse return false;
        return std.mem.eql(u8, self.drawn_model[0..len], name);
    }
    fn belongsTo(name: []const u8, alias: []const u8) bool {
        return name.len > alias.len and std.mem.startsWith(u8, name, alias) and name[alias.len] == '/';
    }
    fn loggedProvider(providers: []const Provider, name: []const u8) ?Provider {
        for (providers) |item| if (belongsTo(name, item.name)) return item;
        return null;
    }
    pub fn selectionName(_: *const Picker, a: Allocator, choice: Choice) ![]u8 {
        if (choice.custom_alias) |alias| return std.fmt.allocPrint(a, "{s}/{s}", .{ alias, choice.name });
        return a.dupe(u8, choice.name);
    }
    pub fn choicesWithProviders(self: *const Picker, a: Allocator, current: []const u8, limit: u32, profiles: []const cfg.Model, disabled: []const bool, providers: []const Provider) ![]Choice {
        const all = try self.candidates(a, current, limit, profiles, disabled);
        const logged = providers;
        errdefer a.free(all);
        var count: usize = 0;
        for (all) |candidate| {
            var choice = candidate;
            if (choice.inherited) {
                if (loggedProvider(logged, choice.name)) |entry| {
                    if (!entry.allow_custom) continue;
                } else if (loggedProvider(logged, current)) |entry| {
                    // Unqualified raw IDs remain on the current custom endpoint;
                    // an explicit other alias must be logged in on its own.
                    if (!entry.allow_custom or std.mem.findScalar(u8, choice.name, '/') != null) continue;
                    choice.custom_alias = entry.name;
                } else continue;
            } else if (loggedProvider(logged, choice.name) == null) continue;
            all[count] = choice;
            count += 1;
        }
        return a.realloc(all, count);
    }
    pub fn changed(self: *Picker) void {
        self.selected = 0;
        self.generation +%= 1;
    }
    pub fn insert(self: *Picker, bytes: []const u8, pasted: bool) !bool {
        if (bytes.len > 1024 -| self.query.bytes.items.len) return false;
        if (!try self.query.insert(bytes)) return false;
        self.pasted = self.pasted or pasted;
        self.changed();
        return true;
    }
    pub fn clear(self: *Picker) void {
        self.query.clear();
        self.pasted = false;
        self.changed();
    }
    pub fn move(self: *Picker, down: bool, count: usize) void {
        if (count == 0) return;
        self.selected = @min(self.selected, count - 1);
        self.selected = if (down) (self.selected + 1) % count else if (self.selected == 0) count - 1 else self.selected - 1;
        self.generation +%= 1;
    }
    fn candidates(self: *const Picker, a: Allocator, current: []const u8, limit: u32, profiles: []const cfg.Model, disabled: []const bool) ![]Choice {
        var result: std.ArrayList(Choice) = .empty;
        errdefer result.deinit(a);
        const query = std.mem.trim(u8, self.query.bytes.items, " \t\r\n");
        var selected: Choice = .{ .name = current, .context_tokens = limit, .current = true };
        for (profiles, 0..) |profile, index| {
            if (!self.sameModel(profile.name, current)) continue;
            selected.profile_index = index;
            // A registry row is a fresh explicit confirmation, including custom
            // aliases. It describes the candidate, not the frozen Runtime budget.
            selected.uses_profile = true;
            selected.context_tokens = profile.context_tokens;
            selected.disabled = index < disabled.len and disabled[index];
            break;
        }
        if (current.len != 0 and (self.matchesName(current, query) or self.matchesName(selected.name, query))) try result.append(a, selected);
        var exact = std.ascii.eqlIgnoreCase(current, query) or std.ascii.eqlIgnoreCase(self.localName(current), query);
        for (profiles, 0..) |profile, index| {
            if (std.ascii.eqlIgnoreCase(profile.name, query) or std.ascii.eqlIgnoreCase(self.localName(profile.name), query)) exact = true;
            if (self.sameModel(profile.name, current) or !self.matchesName(profile.name, query)) continue;
            var duplicate = false;
            for (profiles[0..index]) |prior| if (self.sameModel(prior.name, profile.name)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            try result.append(a, .{ .name = profile.name, .context_tokens = profile.context_tokens, .profile_index = index, .uses_profile = true, .disabled = index < disabled.len and disabled[index] });
        }
        if (self.allow_custom and query.len != 0 and !exact and manualName(query)) try result.append(a, .{ .name = query, .context_tokens = limit, .inherited = true });
        return result.toOwnedSlice(a);
    }
    fn localName(self: *const Picker, name: []const u8) []const u8 {
        const slug = if (self.provider) |id| id.slug() else return name;
        if (name.len > slug.len + 1 and std.mem.startsWith(u8, name, slug) and name[slug.len] == '/') return name[slug.len + 1 ..];
        return name;
    }
    fn sameModel(self: *const Picker, left: []const u8, right: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, left, right);
    }
    fn matchesName(self: *const Picker, name: []const u8, query: []const u8) bool {
        return matches(name, query) or matches(self.localName(name), query);
    }
    fn displayName(self: *const Picker, a: Allocator, name: []const u8) ![]const u8 {
        if (std.mem.findScalar(u8, name, '/')) |slash| {
            if (cfg.providers.Id.fromSlug(name[0..slash]) != null) return a.dupe(u8, name);
        }
        if (self.provider) |id| return std.fmt.allocPrint(a, "{s}/{s}", .{ id.slug(), name });
        return a.dupe(u8, name); // Custom endpoints have no invented provider ID.
    }
    pub fn rowsWithProviders(self: *const Picker, a: Allocator, current: []const u8, limit: u32, profiles: []const cfg.Model, columns: usize, max_rows: usize, origins: Origins, disabled: []const bool, providers: []const Provider) !Rows {
        const choices_ = try self.choicesWithProviders(a, current, limit, profiles, disabled, providers);
        defer a.free(choices_);
        var lines: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (lines.items) |line| a.free(line);
            lines.deinit(a);
        }
        if (max_rows == 0) return .{ .lines = try lines.toOwnedSlice(a), .can_confirm = false };
        const count = @min(@min(10, max_rows), choices_.len);
        const selected = @min(self.selected, choices_.len -| 1);
        const start = @min(selected -| (count / 2), choices_.len - count);
        var can_confirm = false;
        var checked_mask: u16 = 0;
        for (choices_[start .. start + count], start..) |choice, index| {
            // Sanitize and bound the identifier separately. Clipping metadata
            // must not reserve ellipsis cells at the expense of a complete ID.
            // Provider qualifiers remain visible even for a single-provider
            // list; display formatting never changes the owner's selection key.
            const qualified = loggedProvider(providers, choice.name) != null;
            const display_name = if (choice.custom_alias != null) try self.selectionName(a, choice) else if (qualified) try a.dupe(u8, choice.name) else try self.displayName(a, choice.name);
            defer a.free(display_name);
            const name = try presentation.singleLine(a, display_name, columns -| 4);
            defer a.free(name);
            if (index == selected) can_confirm = !choice.disabled and !self.pasted and columns >= 4 and
                name.len != 0 and std.mem.eql(u8, name, display_name) and text.width(name) <= columns - 4;
            if (choice.current) checked_mask |= @as(u16, 1) << @intCast(index - start);
            var official = choice.current and origins.current;
            if (choice.uses_profile) {
                const profile_index = choice.profile_index.?;
                official = profile_index < origins.models.len and origins.models[profile_index];
            }
            var token_buffer: [24]u8 = undefined;
            const tokens = try compactTokens(&token_buffer, choice.context_tokens);
            const raw = try std.fmt.allocPrint(a, "{s}{s}{s}  ({s} tokens; {s}{s}{s})", .{ if (index == selected) "> " else "  ", if (choice.current) "✓ " else "  ", name, tokens, if (official) "official" else "default", if (choice.inherited) "; inherited budget" else "", if (choice.disabled) "; Protocol unknown" else "" });
            defer a.free(raw);
            const line = try clip(a, raw, columns);
            errdefer a.free(line);
            try lines.append(a, line);
        }
        return .{
            .lines = try lines.toOwnedSlice(a),
            .selected_line = if (count != 0) selected - start else null,
            .can_confirm = can_confirm,
            .selected_choice = if (can_confirm) choices_[selected] else null,
            .checked_mask = checked_mask,
        };
    }
};

/// Decimal units, with up to three fractional digits (truncated, not rounded).
/// Integer arithmetic avoids promotion across a unit boundary or float artifacts.
fn compactTokens(buffer: []u8, tokens: u32) ![]const u8 {
    const unit: u32 = if (tokens >= 1_000_000) 1_000_000 else if (tokens >= 1_000) 1_000 else 1;
    if (unit == 1) return std.fmt.bufPrint(buffer, "{d}", .{tokens});
    const suffix: []const u8 = if (unit == 1_000_000) "M" else "K";
    const fraction = (tokens % unit) / (unit / 1_000);
    if (fraction == 0) return std.fmt.bufPrint(buffer, "{d}{s}", .{ tokens / unit, suffix });
    var digits: [3]u8 = undefined;
    const fractional = try std.fmt.bufPrint(&digits, "{d:0>3}", .{fraction});
    return std.fmt.bufPrint(buffer, "{d}.{s}{s}", .{ tokens / unit, std.mem.trimEnd(u8, fractional, "0"), suffix });
}

/// Input is already sanitized; preserve whole display clusters without styling.
fn clip(a: Allocator, value: []const u8, columns: usize) ![]const u8 {
    return a.dupe(u8, value[0..text.fitBytes(value, columns)]);
}

pub fn manualName(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}
fn matches(name: []const u8, query: []const u8) bool {
    var at: usize = 0;
    for (name) |byte| {
        if (at < query.len and std.ascii.toLower(byte) == std.ascii.toLower(query[at])) at += 1;
    }
    return at == query.len;
}
