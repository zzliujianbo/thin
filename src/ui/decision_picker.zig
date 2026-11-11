//! Bounded searchable decision choices. No custom identities or protocol routing.
const std = @import("std");
const cfg = @import("../core/config.zig");
const text = @import("text.zig");
pub const Menu = @import("provider_picker.zig").Picker;
pub const Rows = @import("settings_menu.zig").Rows;
pub const Provider = @import("model_picker.zig").Provider;
pub const Choice = union(enum) { off, model: []const u8 };
pub const max_models = 4096;
pub const max_providers = 256;
pub const max_name_bytes = 1089;
pub const Fingerprint = [32]u8;

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn eligible(model: cfg.Model, providers: ?[]const Provider) bool {
    if (!validName(model.name)) return false;
    const slash = std.mem.indexOfScalar(u8, model.name, '/') orelse return false;
    if (slash == 0 or slash + 1 == model.name.len) return false;
    const entries = providers orelse return false;
    for (entries[0..@min(entries.len, max_providers)]) |entry| {
        if (std.mem.eql(u8, entry.name, model.name[0..slash])) return true;
    }
    return false;
}
fn matches(label: []const u8, query: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n\x0b\x0c");
    while (tokens.next()) |token| {
        if (token.len > label.len) return false;
        var found = false;
        for (0..label.len - token.len + 1) |start| {
            if (std.ascii.eqlIgnoreCase(label[start..][0..token.len], token)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}
pub fn count(models: []const cfg.Model, providers: ?[]const Provider, query: []const u8) usize {
    var n: usize = @intFromBool(matches("Off", query));
    for (models[0..@min(models.len, max_models)]) |model| if (eligible(model, providers) and matches(model.name, query)) {
        n += 1;
    };
    return n;
}
pub fn choice(models: []const cfg.Model, providers: ?[]const Provider, query: []const u8, index: usize) ?Choice {
    const off = matches("Off", query);
    if (off and index == 0) return .off;
    var n: usize = @intFromBool(off);
    for (models[0..@min(models.len, max_models)]) |model| {
        if (!eligible(model, providers) or !matches(model.name, query)) continue;
        if (n == index) return .{ .model = model.name };
        n += 1;
    }
    return null;
}
pub fn indexOf(models: []const cfg.Model, providers: ?[]const Provider, query: []const u8, current: ?[]const u8) usize {
    const name = current orelse return 0;
    var n: usize = @intFromBool(matches("Off", query));
    for (models[0..@min(models.len, max_models)]) |model| {
        if (!eligible(model, providers) or !matches(model.name, query)) continue;
        if (std.mem.eql(u8, model.name, name)) return n;
        n += 1;
    }
    return 0; // Never synthesize a missing current model.
}
fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    const len = value.len;
    hash.update(std.mem.asBytes(&len));
    hash.update(value);
}
/// Fixed-size identity proof; work and bytes are bounded. Oversized catalogs
/// may be previewed but cannot authorize saves. Null providers means empty.
pub fn fingerprint(models: []const cfg.Model, providers: ?[]const Provider) ?Fingerprint {
    const entries = providers orelse &.{};
    if (models.len > max_models or entries.len > max_providers) return null;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(std.mem.asBytes(&models.len));
    for (models) |model| {
        if (model.name.len > max_name_bytes) return null;
        hashString(&hash, model.name);
        hashString(&hash, @tagName(model.protocol));
    }
    hash.update(std.mem.asBytes(&entries.len));
    for (entries) |entry| {
        if (entry.name.len > max_name_bytes) return null;
        hashString(&hash, entry.name);
    }
    return hash.finalResult();
}
pub fn rows(a: std.mem.Allocator, menu: Menu, models: []const cfg.Model, providers: ?[]const Provider, query: []const u8, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const total = count(models, providers, query);
    if (total == 0) {
        try append(a, &out, "No matching models", columns);
        return .{ .lines = try out.toOwnedSlice(a) };
    }
    const selected = @min(menu.selected, total - 1);
    // Shared popup paints a u16 check mask; keep the provider-style window
    // bounded even when the catalog or terminal is very large.
    const visible = @min(@min(max_rows, 10), total);
    const start = @min(selected -| (visible / 2), total - visible);
    var complete = false;
    for (start..start + visible) |index| {
        const item = choice(models, providers, query, index).?;
        const label = switch (item) {
            .off => "Off",
            .model => |name| name,
        };
        const raw = try std.fmt.allocPrint(a, "{s}{s}", .{ if (index == selected) "> " else "  ", label });
        defer a.free(raw);
        if (index == selected) complete = text.width(raw) <= columns;
        try append(a, &out, raw, columns);
    }
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter save  Left/Esc back; chat model unchanged", columns);
    return .{ .lines = try out.toOwnedSlice(a), .selected_line = selected - start, .can_confirm = !menu.pasted and menu.selected < total and complete and fingerprint(models, providers) != null };
}
fn append(a: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8, columns: usize) !void {
    var end: usize = 0;
    var width: usize = 0;
    while (end < raw.len) {
        const cluster = text.nextCluster(raw, end, width);
        if (width + cluster.width > columns) break;
        width += cluster.width;
        end = cluster.end;
    }
    const line = try a.dupe(u8, raw[0..end]);
    errdefer a.free(line);
    try out.append(a, line);
}
