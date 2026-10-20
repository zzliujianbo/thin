//! Direct, bounded decision choices. No search, custom identities or protocol routing.
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
pub fn count(models: []const cfg.Model, providers: ?[]const Provider) usize {
    var n: usize = 1; // Off is always present, even with no logged-in providers.
    for (models[0..@min(models.len, max_models)]) |model| if (eligible(model, providers)) {
        n += 1;
    };
    return n;
}
pub fn choice(models: []const cfg.Model, providers: ?[]const Provider, index: usize) ?Choice {
    if (index == 0) return .off;
    var n: usize = 1;
    for (models[0..@min(models.len, max_models)]) |model| {
        if (!eligible(model, providers)) continue;
        if (n == index) return .{ .model = model.name };
        n += 1;
    }
    return null;
}
pub fn indexOf(models: []const cfg.Model, providers: ?[]const Provider, current: ?[]const u8) usize {
    const name = current orelse return 0;
    var n: usize = 1;
    for (models[0..@min(models.len, max_models)]) |model| {
        if (!eligible(model, providers)) continue;
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
pub fn rows(a: std.mem.Allocator, menu: Menu, models: []const cfg.Model, providers: ?[]const Provider, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const total = count(models, providers);
    const selected = @min(menu.selected, total - 1);
    // Shared popup paints a u16 check mask; keep the provider-style window
    // bounded even when the catalog or terminal is very large.
    const visible = @min(@min(max_rows, 10), total);
    const start = @min(selected -| (visible / 2), total - visible);
    var complete = false;
    for (start..start + visible) |index| {
        const item = choice(models, providers, index).?;
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
fn freeRows(a: std.mem.Allocator, rendered: Rows) void {
    for (rendered.lines) |line| a.free(line);
    a.free(rendered.lines);
}
const profiles = [_]cfg.Model{
    .{ .name = "login/Family/Judge", .protocol = .chat, .context_tokens = 16384 },
    .{ .name = "second/family/judge", .protocol = .responses, .context_tokens = 16384 },
    .{ .name = "raw-only", .context_tokens = 16384 },
    .{ .name = "login/", .context_tokens = 16384 },
};
const logged = [_]Provider{.{ .name = "login" }};
test "direct choices intersect exact providers preserve raw IDs and never invent current" {
    try std.testing.expectEqual(@as(usize, 2), count(&profiles, &logged));
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, null));
    try std.testing.expect(choice(&profiles, null, 0).? == .off);
    try std.testing.expect(choice(&profiles, null, 1) == null);
    try std.testing.expectEqualStrings("login/Family/Judge", choice(&profiles, &logged, 1).?.model);
    try std.testing.expectEqual(@as(usize, 1), indexOf(&profiles, &logged, "login/Family/Judge"));
    try std.testing.expectEqual(@as(usize, 0), indexOf(&profiles, &logged, "login/ghost"));
    try std.testing.expectEqual(@as(usize, 0), indexOf(&profiles, &logged, "login/family/judge"));
    const before = fingerprint(&profiles, &logged).?;
    var changed = profiles;
    changed[0].protocol = .responses;
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&changed, &logged).?));
    changed = profiles;
    changed[0].name = "login/another";
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&changed, &logged).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, null).?));
}
test "direct decision windows keep selection visible and reject paste or clipping" {
    const a = std.testing.allocator;
    for (0..count(&profiles, &logged)) |selected| for (0..7) |height| for (0..65) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, &profiles, &logged, columns, height);
        defer freeRows(a, rendered);
        const label = if (selected == 0) "Off" else profiles[0].name;
        try std.testing.expect(rendered.lines.len <= height);
        try std.testing.expectEqual(height != 0 and columns >= 2 + label.len, rendered.can_confirm);
        if (rendered.selected_line) |index| {
            try std.testing.expect(index < rendered.lines.len);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[index], label) != null);
        } else try std.testing.expect(height == 0);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
    const pasted = try rows(a, .{ .pasted = true }, &profiles, &logged, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
fn allocationCase(a: std.mem.Allocator) !void {
    const rendered = try rows(a, .{ .selected = 1 }, &profiles, &logged, 40, 7);
    defer freeRows(a, rendered);
}
test "decision rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "native protocol is an ordinary exact model and large windows stay bounded" {
    const a = std.testing.allocator;
    const models: [40]cfg.Model = @splat(.{ .name = "login/Native/Judge", .protocol = .systemone, .context_tokens = 16384 });
    try std.testing.expectEqual(@as(usize, 41), count(&models, &logged));
    try std.testing.expectEqualStrings("login/Native/Judge", choice(&models, &logged, 40).?.model);
    for ([_]usize{ 1, 2, 3, 10, 100 }) |height| {
        const rendered = try rows(a, .{ .selected = 40 }, &models, &logged, 80, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.can_confirm);
        try std.testing.expect(rendered.lines.len <= @min(height, 11));
        try std.testing.expect(rendered.selected_line.? < rendered.lines.len);
        try std.testing.expect(std.mem.find(u8, rendered.lines[rendered.selected_line.?], "login/Native/Judge") != null);
    }
    const too_many: [max_models + 1]cfg.Model = @splat(models[0]);
    try std.testing.expect(fingerprint(&too_many, &logged) == null);
    const long_name: [max_name_bytes + 1]u8 = @splat('a');
    const too_long = [_]cfg.Model{.{ .name = &long_name, .context_tokens = 16384 }};
    try std.testing.expect(fingerprint(&too_long, &logged) == null);
}
