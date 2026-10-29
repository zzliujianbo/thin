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

test "flat row identity becomes authority only after a full acknowledgement" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    try picker.captureChoice(a, .{ .name = "first/model", .context_tokens = 32768 });
    try std.testing.expect(!picker.modelShown("first/model"));
    picker.acknowledgeChoice();
    try picker.captureChoice(a, .{ .name = "replacement/model", .context_tokens = 32768 });
    try std.testing.expect(picker.modelShown("first/model") and !picker.modelShown("replacement/model"));
    picker.acknowledgeChoice();
    try std.testing.expect(!picker.modelShown("first/model") and picker.modelShown("replacement/model"));
}

test "flat model list includes logged aliases only and preserves disabled indexes" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    picker.provider = .opencode_go;
    const providers = [_]Provider{ .{ .name = "work-go" }, .{ .name = "proxy", .allow_custom = true } };
    const profiles = [_]cfg.Model{
        .{ .name = "not-logged/hidden-id", .context_tokens = 1000000 },
        .{ .name = "work-go/model-a", .context_tokens = 1000000 },
        .{ .name = "proxy/org/model", .context_tokens = 0 },
        .{ .name = "proxy-other/hidden", .context_tokens = 1000000 },
    };
    const choices_ = try picker.choicesWithProviders(a, "not-logged/hidden-id", 1000000, &profiles, &.{ false, false, true, false }, &providers);
    defer a.free(choices_);
    try std.testing.expectEqual(@as(usize, 2), choices_.len);
    try std.testing.expectEqualStrings("work-go/model-a", choices_[0].name);
    try std.testing.expect(choices_[0].profile_index == 1);
    try std.testing.expectEqualStrings("proxy/org/model", choices_[1].name);
    try std.testing.expect(choices_[1].disabled and choices_[1].profile_index == 2);
    const rendered = try picker.rowsWithProviders(a, "work-go/model-a", 1000000, &profiles, 100, 10, .{}, &.{ false, false, true, false }, &providers);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(rendered.can_confirm);
    try std.testing.expect(std.mem.find(u8, rendered.lines[0], "work-go/model-a") != null);
    try std.testing.expect(std.mem.find(u8, rendered.lines[1], "proxy/org/model") != null);
    try std.testing.expect(std.mem.find(u8, rendered.lines[1], "opencode-go/proxy") == null);
    const empty = try picker.choicesWithProviders(a, "work-go/model-a", 1000000, &profiles, &.{}, &.{});
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expect(@typeInfo(@TypeOf(Picker.choicesWithProviders)).@"fn".param_types[6].? == []const Provider);
    const empty_rows = try picker.rowsWithProviders(a, "work-go/model-a", 1000000, &profiles, 100, 10, .{}, &.{}, &.{});
    defer a.free(empty_rows.lines);
    try std.testing.expect(empty_rows.lines.len == 0 and !empty_rows.can_confirm and empty_rows.selected_choice == null);
    try std.testing.expect(try picker.insert("proxy/new-model", false));
    const no_custom = try picker.choicesWithProviders(a, "proxy/current", 1000000, &profiles, &.{}, &.{});
    defer a.free(no_custom);
    try std.testing.expectEqual(@as(usize, 0), no_custom.len);
}

test "flat identities preserve slash raw IDs across alias profile order and current selection" {
    const a = std.testing.allocator;
    const names = [_][]const u8{ "opencode-go/proxy/model", "proxy/model" };
    const providers = [_]Provider{ .{ .name = "opencode-go" }, .{ .name = "proxy", .allow_custom = true } };
    for ([_]bool{ false, true }) |reversed| {
        const profiles = [_]cfg.Model{
            .{ .name = names[@intFromBool(reversed)], .context_tokens = if (reversed) 131072 else 65536 },
            .{ .name = names[@intFromBool(!reversed)], .context_tokens = if (reversed) 65536 else 131072 },
        };
        const disabled = [_]bool{ reversed, !reversed };
        const official = [_]bool{ !reversed, reversed };
        for (names) |current| {
            var picker = Picker.init(a);
            defer picker.deinit();
            picker.provider = .opencode_go;
            picker.allow_custom = false;
            const choices_ = try picker.choicesWithProviders(a, current, 32768, &profiles, &disabled, &providers);
            defer a.free(choices_);
            try std.testing.expectEqual(@as(usize, 2), choices_.len);
            try std.testing.expectEqualStrings(current, choices_[0].name);
            for (choices_, 0..) |choice, position| {
                const index: usize = if (std.mem.eql(u8, choice.name, profiles[0].name)) 0 else 1;
                try std.testing.expectEqualStrings(profiles[index].name, choice.name);
                try std.testing.expectEqual(@as(?usize, index), choice.profile_index);
                try std.testing.expect(choice.uses_profile);
                try std.testing.expectEqual(position == 0, choice.current);
                try std.testing.expectEqual(profiles[index].context_tokens, choice.context_tokens);
                try std.testing.expectEqual(disabled[index], choice.disabled);
            }
            const rendered = try picker.rowsWithProviders(a, current, 32768, &profiles, 120, 10, .{ .current = false, .models = &official }, &disabled, &providers);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expectEqual(@as(u16, 1), rendered.checked_mask);
            for (rendered.lines, choices_) |line, choice| {
                const index = choice.profile_index.?;
                try std.testing.expect(std.mem.find(u8, line, choice.name) != null);
                try std.testing.expect(std.mem.find(u8, line, if (official[index]) "; official" else "; default") != null);
            }
            try std.testing.expectEqual(!choices_[0].disabled, rendered.can_confirm);
        }
    }
}

test "flat logged custom aliases respect owner disabling inherited candidates" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    picker.allow_custom = false;
    const providers = [_]Provider{.{ .name = "proxy", .allow_custom = true }};
    const profiles = [_]cfg.Model{.{ .name = "proxy/declared", .context_tokens = 65536 }};
    for ([_][]const u8{ "unknown", "proxy/unknown" }) |query| {
        picker.clear();
        try std.testing.expect(try picker.insert(query, false));
        const choices_ = try picker.choicesWithProviders(a, "proxy/current", 32768, &profiles, &.{false}, &providers);
        defer a.free(choices_);
        try std.testing.expectEqual(@as(usize, 0), choices_.len);
    }
    picker.clear();
    try std.testing.expect(try picker.insert("proxy/declared", false));
    const choices_ = try picker.choicesWithProviders(a, "proxy/current", 32768, &profiles, &.{false}, &providers);
    defer a.free(choices_);
    try std.testing.expectEqual(@as(usize, 1), choices_.len);
    try std.testing.expectEqualStrings("proxy/declared", choices_[0].name);
    try std.testing.expect(!choices_[0].inherited and !choices_[0].disabled);
    const rendered = try picker.rowsWithProviders(a, "proxy/current", 32768, &profiles, 100, 10, .{}, &.{false}, &providers);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(rendered.can_confirm);
    try std.testing.expectEqualStrings("proxy/declared", rendered.selected_choice.?.name);
}

test "flat custom models require a logged alias and cannot select unlogged aliases" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const providers = [_]Provider{ .{ .name = "proxy", .allow_custom = true }, .{ .name = "official" } };
    for ([_][]const u8{ "proxy/org/new", "not-logged/new", "official/new", "new-raw" }, 0..) |query, i| {
        picker.clear();
        try std.testing.expect(try picker.insert(query, false));
        const choices_ = try picker.choicesWithProviders(a, "proxy/current", 65536, &.{}, &.{}, &providers);
        defer a.free(choices_);
        if (i == 1 or i == 2) {
            try std.testing.expectEqual(@as(usize, 0), choices_.len);
        } else {
            try std.testing.expectEqual(@as(usize, 1), choices_.len);
            const name = try picker.selectionName(a, choices_[0]);
            defer a.free(name);
            try std.testing.expectEqualStrings(if (i == 0) "proxy/org/new" else "proxy/new-raw", name);
        }
    }
}

test "unknown protocol flags stay aligned through filtering and explicit auto stays enabled" {
    const a = std.testing.allocator;
    try text.initLocale();
    var picker = Picker.init(a);
    defer picker.deinit();
    picker.allow_custom = false;
    const profiles = [_]cfg.Model{
        .{ .name = "opencode-go/explicit-auto", .context_tokens = 32768, .protocol = .auto },
        .{ .name = "opencode-go/new-unknown", .context_tokens = 32768, .protocol = .auto },
        .{ .name = "opencode-zen/known", .context_tokens = 32768, .protocol = .responses },
    };
    const flags = [_]bool{ false, true, false };
    try std.testing.expect(try picker.insert("new-unknown", false));
    const choices_ = try picker.choicesWithProviders(a, "opencode-go/current", 32768, &profiles, &flags, &.{.{ .name = "opencode-go" }});
    defer a.free(choices_);
    try std.testing.expectEqual(@as(usize, 1), choices_.len);
    try std.testing.expect(choices_[0].disabled);
    try std.testing.expectEqual(@as(?usize, 1), choices_[0].profile_index);
    const rendered = try picker.rowsWithProviders(a, "opencode-go/current", 32768, &profiles, 120, 10, .{}, &flags, &.{.{ .name = "opencode-go" }});
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(!rendered.can_confirm);
    try std.testing.expect(std.mem.find(u8, rendered.lines[0], "Protocol unknown") != null);
    picker.clear();
    try std.testing.expect(try picker.insert("explicit-auto", false));
    const explicit = try picker.choicesWithProviders(a, "opencode-go/current", 32768, &profiles, &flags, &.{.{ .name = "opencode-go" }});
    defer a.free(explicit);
    try std.testing.expectEqual(@as(usize, 1), explicit.len);
    try std.testing.expect(!explicit[0].disabled);
    // A checked qualified row is a fresh candidate, including protocol safety.
    picker.provider = .opencode_go;
    picker.clear();
    const retained = try picker.choicesWithProviders(a, "opencode-go/new-unknown", 65536, &profiles, &flags, &.{.{ .name = "opencode-go" }});
    defer a.free(retained);
    try std.testing.expect(retained[0].current and retained[0].disabled);
    try std.testing.expectEqual(profiles[1].context_tokens, retained[0].context_tokens);
}

test "qualified current IDs show candidate capacity without changing selection key" {
    const a = std.testing.allocator;
    try text.initLocale();
    const profiles = [_]cfg.Model{
        .{ .name = "deepseek/deepseek-flash", .context_tokens = 1048576 },
        .{ .name = "deepseek/deepseek-v4-pro", .context_tokens = 1048576 },
    };
    var picker = Picker.init(a);
    defer picker.deinit();
    picker.provider = .deepseek;
    for ([_][]const u8{"deepseek/deepseek-flash"}) |current| {
        const choices_ = try picker.choicesWithProviders(a, current, 1000000, &profiles, &.{}, &.{.{ .name = "deepseek" }});
        defer a.free(choices_);
        try std.testing.expectEqual(@as(usize, 2), choices_.len);
        try std.testing.expect(choices_[0].current and !choices_[1].current);
        try std.testing.expectEqualStrings("deepseek/deepseek-flash", choices_[0].name);
        try std.testing.expectEqual(@as(u32, 1048576), choices_[0].context_tokens);
        const rendered = try picker.rowsWithProviders(a, current, 1000000, &profiles, 80, 10, .{ .models = &.{ true, true } }, &.{}, &.{.{ .name = "deepseek" }});
        defer {
            for (rendered.lines) |line| a.free(line);
            a.free(rendered.lines);
        }
        try std.testing.expectEqualStrings("> ✓ deepseek/deepseek-flash  (1.048M tokens; official)", rendered.lines[0]);
        try std.testing.expectEqual(@as(u16, 1), rendered.checked_mask);
        try std.testing.expect(rendered.can_confirm);
        // The entire provider/model identifier must fit before confirmation.
        const narrow = try picker.rowsWithProviders(a, current, 1000000, &profiles, 4 + "deepseek/deepseek-flash".len - 1, 1, .{}, &.{}, &.{.{ .name = "deepseek" }});
        defer {
            for (narrow.lines) |line| a.free(line);
            a.free(narrow.lines);
        }
        try std.testing.expect(!narrow.can_confirm);
    }
    try std.testing.expect(try picker.insert("deepseek-flash", false));
    const found = try picker.choicesWithProviders(a, "deepseek/deepseek-flash", 1000000, &profiles, &.{}, &.{.{ .name = "deepseek" }});
    defer a.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(!found[0].inherited);
}

test "known provider stays visible even without a qualified catalog entry" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    picker.provider = .deepseek;
    const rendered = try picker.rowsWithProviders(a, "deepseek/deepseek-flash", 1000000, &.{}, 80, 10, .{}, &.{}, &.{.{ .name = "deepseek" }});
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expectEqualStrings("> ✓ deepseek/deepseek-flash  (1M tokens; default)", rendered.lines[0]);
    const choices_ = try picker.choicesWithProviders(a, "deepseek/deepseek-flash", 1000000, &.{}, &.{}, &.{.{ .name = "deepseek" }});
    defer a.free(choices_);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", choices_[0].name);
}

test "model identity keeps logged providers and custom endpoints distinct" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const mixed = [_]cfg.Model{
        .{ .name = "opencode-zen/minimax-m2.7", .context_tokens = 204800 },
        .{ .name = "opencode-go/minimax-m2.7", .context_tokens = 204800 },
    };
    picker.provider = .opencode_zen;
    const choices_ = try picker.choicesWithProviders(a, "opencode-zen/minimax-m2.7", 204800, &mixed, &.{}, &.{ .{ .name = "opencode-zen" }, .{ .name = "opencode-go" } });
    defer a.free(choices_);
    try std.testing.expectEqual(@as(usize, 2), choices_.len);
    try std.testing.expect(choices_[0].current and !choices_[1].current);
    const rendered = try picker.rowsWithProviders(a, "opencode-zen/minimax-m2.7", 204800, &mixed, 80, 10, .{}, &.{}, &.{ .{ .name = "opencode-zen" }, .{ .name = "opencode-go" } });
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(std.mem.find(u8, rendered.lines[0], "opencode-zen/minimax-m2.7") != null);
    try std.testing.expect(std.mem.find(u8, rendered.lines[1], "opencode-go/minimax-m2.7") != null);
    picker.provider = null; // A custom alias with the same raw name is not Zen.
    const custom = try picker.choicesWithProviders(a, "proxy/minimax-m2.7", 32768, &mixed, &.{}, &.{ .{ .name = "proxy", .allow_custom = true }, .{ .name = "opencode-zen" }, .{ .name = "opencode-go" } });
    defer a.free(custom);
    try std.testing.expectEqual(@as(usize, 3), custom.len);
    try std.testing.expectEqualStrings("proxy/minimax-m2.7", custom[0].name);
    picker.provider = .deepseek;
    const explicit = [_]cfg.Model{
        .{ .name = "deepseek-flash", .context_tokens = 262144 },
        .{ .name = "deepseek/deepseek-flash", .context_tokens = 1048576 },
    };
    const local = try picker.choicesWithProviders(a, "deepseek/deepseek-flash", 1000000, &explicit, &.{}, &.{.{ .name = "deepseek" }});
    defer a.free(local);
    try std.testing.expectEqual(@as(usize, 1), local.len);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", local[0].name);
    try std.testing.expect(local[0].uses_profile);
    try std.testing.expectEqual(@as(?usize, 1), local[0].profile_index);
}

test "local picker keeps current first searches metadata and labels inherited names" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const profiles = [_]cfg.Model{
        .{ .name = "proxy/current", .context_tokens = 32768 },
        .{ .name = "proxy/fast-code", .context_tokens = 65536 },
        .{ .name = "proxy/deep-code", .context_tokens = 131072 },
    };
    const all = try picker.choicesWithProviders(a, "proxy/current", 32768, &profiles, &.{}, &.{.{ .name = "proxy", .allow_custom = true }});
    defer a.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expect(all[0].current);
    try std.testing.expectEqualStrings("proxy/fast-code", all[1].name);
    try std.testing.expect(try picker.insert("FSC", false));
    const filtered = try picker.choicesWithProviders(a, "proxy/current", 32768, &profiles, &.{}, &.{.{ .name = "proxy", .allow_custom = true }});
    defer a.free(filtered);
    try std.testing.expectEqualStrings("proxy/fast-code", filtered[0].name);
    try std.testing.expect(filtered[filtered.len - 1].inherited);
    picker.clear();
    try std.testing.expect(try picker.insert("PROXY/FAST-CODE", false));
    const exact = try picker.choicesWithProviders(a, "proxy/current", 32768, &profiles, &.{}, &.{.{ .name = "proxy", .allow_custom = true }});
    defer a.free(exact);
    try std.testing.expectEqual(@as(usize, 1), exact.len);
    picker.move(false, 3);
    try std.testing.expectEqual(@as(usize, 2), picker.selected);
    picker.move(true, 3);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);
}

test "named provider picker does not guess protocols for unknown custom IDs" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    picker.allow_custom = false;
    try std.testing.expect(try picker.insert("claude-unknown", false));
    const found = try picker.choicesWithProviders(a, "opencode-go/minimax-m2.7", 204800, &.{}, &.{}, &.{.{ .name = "opencode-go" }});
    defer a.free(found);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "picker bytes rows and paste confirmation are bounded" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const full: [1024]u8 = @splat('a');
    try std.testing.expect(try picker.insert(&full, true));
    try std.testing.expect(!try picker.insert("b", false));
    const rendered = try picker.rowsWithProviders(a, "proxy/current", 32768, &.{}, 20, 3, .{}, &.{}, &.{.{ .name = "proxy", .allow_custom = true }});
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expect(rendered.lines.len <= 3);
    try std.testing.expect(!rendered.can_confirm);
    for (rendered.lines) |line| try std.testing.expect(@import("text.zig").width(line) <= 20);
    picker.clear();
    try std.testing.expect(!picker.pasted);
    try std.testing.expect(!manualName("space name") and !manualName("\x1b[31m"));
}

test "model candidate window caps at ten and keeps selection visible" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const profiles = [_]cfg.Model{
        .{ .name = "p/m01", .context_tokens = 100 },
        .{ .name = "p/m02", .context_tokens = 100 },
        .{ .name = "p/m03", .context_tokens = 100 },
        .{ .name = "p/m04", .context_tokens = 100 },
        .{ .name = "p/m05", .context_tokens = 100 },
        .{ .name = "p/m06", .context_tokens = 100 },
        .{ .name = "p/m07", .context_tokens = 100 },
        .{ .name = "p/m08", .context_tokens = 100 },
        .{ .name = "p/m09", .context_tokens = 100 },
        .{ .name = "p/m10", .context_tokens = 100 },
        .{ .name = "p/m11", .context_tokens = 100 },
        .{ .name = "p/m12", .context_tokens = 100 },
    };
    const all = try picker.choicesWithProviders(a, "p/m00", 100, &profiles, &.{}, &.{.{ .name = "p" }});
    defer a.free(all);
    for ([_]usize{ 0, 1, 4, 10, 20 }) |height| {
        for (0..all.len) |selected| {
            picker.selected = selected;
            const rendered = try picker.rowsWithProviders(a, "p/m00", 100, &profiles, 9, height, .{}, &.{}, &.{.{ .name = "p" }});
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            const count = @min(height, 10);
            try std.testing.expectEqual(count, rendered.lines.len);
            try std.testing.expectEqual(count != 0, rendered.can_confirm);
            if (count == 0) {
                try std.testing.expect(rendered.selected_line == null);
                continue;
            }
            const start = @min(selected -| (count / 2), all.len - count);
            try std.testing.expectEqual(selected - start, rendered.selected_line.?);
            for (rendered.lines, start..) |line, index| {
                const prefix_bytes: usize = if (all[index].current) 6 else 4;
                try std.testing.expectEqualStrings(all[index].name, line[prefix_bytes..]);
                try std.testing.expectEqualStrings(if (all[index].current) "✓ " else "  ", line[2..prefix_bytes]);
                try std.testing.expectEqual(all[index].current, rendered.checked_mask & (@as(u16, 1) << @intCast(index - start)) != 0);
                try std.testing.expectEqualStrings(if (index == selected) "> " else "  ", line[0..2]);
            }
        }
    }
}

test "model confirmation requires complete display cell identifier not metadata" {
    const a = std.testing.allocator;
    try text.initLocale();
    var picker = Picker.init(a);
    defer picker.deinit();
    for ([_][]const u8{ "p/long-model", "p/模型", "p/e\u{301}" }) |name| {
        const full_width = 4 + text.width(name);
        for (0..full_width + 1) |columns| {
            const rendered = try picker.rowsWithProviders(a, name, 100, &.{}, columns, 1, .{}, &.{}, &.{.{ .name = "p" }});
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expectEqual(columns == full_width, rendered.can_confirm);
            try std.testing.expectEqual(@as(usize, 0), rendered.selected_line.?);
            try std.testing.expect(text.width(rendered.lines[0]) <= columns);
            try std.testing.expectEqual(@as(u16, 1), rendered.checked_mask);
            try std.testing.expect(std.unicode.utf8ValidateSlice(rendered.lines[0]));
            if (rendered.can_confirm) try std.testing.expectEqualStrings(name, rendered.lines[0][6..]);
        }
    }
    const unsafe = try picker.rowsWithProviders(a, "p/bad\n\x1b[31mname", 100, &.{}, 80, 1, .{}, &.{}, &.{.{ .name = "p" }});
    defer {
        for (unsafe.lines) |line| a.free(line);
        a.free(unsafe.lines);
    }
    try std.testing.expect(!unsafe.can_confirm);
    try std.testing.expect(std.mem.findScalar(u8, unsafe.lines[0], '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, unsafe.lines[0], 0x1b) == null);
}

fn rowsAllocationProbe(a: Allocator) !void {
    var picker = Picker.init(a);
    defer picker.deinit();
    const rendered = try picker.rowsWithProviders(a, "p/current", 100, &.{.{ .name = "p/other", .context_tokens = 200 }}, 24, 10, .{}, &.{}, &.{.{ .name = "p" }});
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
}

test "model candidate rows clean up on allocation failure" {
    // Keep growth/shrink paths deterministic across fault-injection replays:
    // the backing allocator may otherwise remap the same size differently.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), rowsAllocationProbe, .{});
}

test "compact token decimal boundaries and trimmed integer fractions" {
    const Case = struct { tokens: u32, expected: []const u8 };
    for ([_]Case{
        .{ .tokens = 0, .expected = "0" },
        .{ .tokens = 999, .expected = "999" },
        .{ .tokens = 1_000, .expected = "1K" },
        .{ .tokens = 1_001, .expected = "1.001K" },
        .{ .tokens = 1_010, .expected = "1.01K" },
        .{ .tokens = 32_768, .expected = "32.768K" },
        .{ .tokens = 128_000, .expected = "128K" },
        .{ .tokens = 204_800, .expected = "204.8K" },
        .{ .tokens = 999_999, .expected = "999.999K" },
        .{ .tokens = 1_000_000, .expected = "1M" },
        .{ .tokens = 1_000_999, .expected = "1M" },
        .{ .tokens = 1_001_000, .expected = "1.001M" },
        .{ .tokens = 1_280_000, .expected = "1.28M" },
        .{ .tokens = std.math.maxInt(u32), .expected = "4294.967M" },
    }) |case| {
        var buffer: [24]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try compactTokens(&buffer, case.tokens));
    }
}

test "model provenance uses current origin and aligned profile names not filtered positions" {
    const a = std.testing.allocator;
    var picker = Picker.init(a);
    defer picker.deinit();
    const profiles = [_]cfg.Model{
        .{ .name = "p/other", .context_tokens = 128_000 },
        .{ .name = "p/current", .context_tokens = 1_000_000 },
        .{ .name = "p/target", .context_tokens = 204_800 },
        .{ .name = "p/missing-origin", .context_tokens = 1_000 },
    };
    const origins: Origins = .{ .current = true, .models = &.{ false, false, true } };
    const rendered = try picker.rowsWithProviders(a, "p/current", 1_000_000, &profiles, 100, 10, origins, &.{}, &.{.{ .name = "p", .allow_custom = true }});
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expectEqual(@as(u16, 1), rendered.checked_mask);
    try std.testing.expectEqualStrings("> ✓ p/current  (1M tokens; default)", rendered.lines[0]);
    try std.testing.expectEqualStrings("    p/other  (128K tokens; default)", rendered.lines[1]);
    try std.testing.expectEqualStrings("    p/target  (204.8K tokens; official)", rendered.lines[2]);
    try std.testing.expectEqualStrings("    p/missing-origin  (1K tokens; default)", rendered.lines[3]);
    try std.testing.expect(try picker.insert("target", false));
    const filtered = try picker.rowsWithProviders(a, "p/current", 1_000_000, &profiles, 100, 10, origins, &.{}, &.{.{ .name = "p", .allow_custom = true }});
    defer {
        for (filtered.lines) |line| a.free(line);
        a.free(filtered.lines);
    }
    try std.testing.expectEqual(@as(u16, 0), filtered.checked_mask);
    try std.testing.expectEqualStrings(">   p/target  (204.8K tokens; official)", filtered.lines[0]);
    picker.clear();
    try std.testing.expect(try picker.insert("custom", false));
    const custom = try picker.rowsWithProviders(a, "p/current", 1_000_000, &profiles, 100, 10, origins, &.{}, &.{.{ .name = "p", .allow_custom = true }});
    defer {
        for (custom.lines) |line| a.free(line);
        a.free(custom.lines);
    }
    try std.testing.expectEqualStrings(">   p/custom  (1M tokens; default; inherited budget)", custom.lines[0]);
    picker.clear();
    const defaults = try picker.rowsWithProviders(a, "p/current", 1_000_000, &profiles, 100, 10, .{}, &.{}, &.{.{ .name = "p" }});
    defer {
        for (defaults.lines) |line| a.free(line);
        a.free(defaults.lines);
    }
    for (defaults.lines) |line| {
        try std.testing.expect(std.mem.find(u8, line, "; default") != null);
        try std.testing.expect(std.mem.findScalar(u8, line, 0x1b) == null);
        try std.testing.expect(std.mem.find(u8, line, "; current") == null);
    }
}
