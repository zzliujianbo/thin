//! Bounded multi-select proxy model candidates. Presentation only: the owner
//! saves every toggle, publishes the resulting list, and no network is touched.
//! Candidates are the full catalog intersected with logged-in provider aliases;
//! full provider/raw-ID text, case and inner slashes are preserved and neither
//! protocol nor context capacity filters a model out.
const std = @import("std");
const cfg = @import("../core/config.zig");
const text = @import("text.zig");
pub const Menu = @import("provider_picker.zig").Picker;
pub const Rows = @import("settings_menu.zig").Rows;
pub const Provider = @import("model_picker.zig").Provider;
pub const max_models = 4096;
pub const max_providers = 256;
pub const max_selected = 4096;
pub const max_name_bytes = 1089;
pub const Fingerprint = [32]u8;

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

/// Exact provider alias prefix, then the untouched raw model ID. Protocol and
/// context capacity are deliberately ignored: every logged-in model is usable.
fn eligible(model: cfg.Model, providers: []const Provider) bool {
    if (!validName(model.name)) return false;
    const slash = std.mem.indexOfScalar(u8, model.name, '/') orelse return false;
    if (slash == 0 or slash + 1 == model.name.len) return false;
    for (providers[0..@min(providers.len, max_providers)]) |entry| {
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

/// No Off row: proxy routing is a per-model list, never a global switch.
pub fn count(models: []const cfg.Model, providers: ?[]const Provider, query: []const u8) usize {
    const entries = providers orelse &.{};
    var n: usize = 0;
    for (models[0..@min(models.len, max_models)]) |model| {
        if (eligible(model, entries) and matches(model.name, query)) n += 1;
    }
    return n;
}

pub fn candidate(models: []const cfg.Model, providers: ?[]const Provider, query: []const u8, index: usize) ?[]const u8 {
    const entries = providers orelse &.{};
    var n: usize = 0;
    for (models[0..@min(models.len, max_models)]) |model| {
        if (!eligible(model, entries) or !matches(model.name, query)) continue;
        if (n == index) return model.name;
        n += 1;
    }
    return null;
}

/// Exact, case-sensitive membership of the owner-published list.
pub fn isSelected(selected_models: []const []const u8, name: []const u8) bool {
    for (selected_models) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    const len = value.len;
    hash.update(std.mem.asBytes(&len));
    hash.update(value);
}

/// Fixed-size identity proof over the candidates, the selected list and the
/// configured host/port state. Work stays bounded; oversized state cannot
/// authorize a save instead of allocating a snapshot.
pub fn fingerprint(models: []const cfg.Model, providers: ?[]const Provider, selected_models: []const []const u8, proxy_configured: bool) ?Fingerprint {
    const entries = providers orelse &.{};
    if (models.len > max_models or entries.len > max_providers or selected_models.len > max_selected) return null;
    var candidates: usize = 0;
    for (models) |model| {
        if (!eligible(model, entries)) continue;
        if (model.name.len > max_name_bytes) return null;
        candidates += 1;
    }
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(std.mem.asBytes(&candidates));
    for (models) |model| {
        if (eligible(model, entries)) hashString(&hash, model.name);
    }
    const flags = [1]u8{@intFromBool(proxy_configured)};
    hash.update(&flags);
    hash.update(std.mem.asBytes(&selected_models.len));
    for (selected_models) |name| {
        if (name.len > max_name_bytes) return null;
        hashString(&hash, name);
    }
    return hash.finalResult();
}

pub fn rows(a: std.mem.Allocator, menu: Menu, models: []const cfg.Model, providers: ?[]const Provider, selected_models: []const []const u8, proxy_configured: bool, query: []const u8, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const total = count(models, providers, query);
    var selected_line: ?usize = null;
    var complete = false;
    if (total == 0) {
        try append(a, &out, "No matching models", columns);
    } else {
        const selected = @min(menu.selected, total - 1);
        // Shared popup paints a bounded window; keep provider-picker geometry.
        const visible = @min(@min(max_rows, 10), total);
        const start = @min(selected -| (visible / 2), total - visible);
        for (start..start + visible) |index| {
            const name = candidate(models, providers, query, index).?;
            const raw = try std.fmt.allocPrint(a, "{s}[{c}] {s}", .{
                if (index == selected) "> " else "  ",
                if (isSelected(selected_models, name)) @as(u8, 'x') else @as(u8, ' '),
                name,
            });
            defer a.free(raw);
            if (index == selected) complete = text.width(raw) <= columns;
            try append(a, &out, raw, columns);
        }
        selected_line = selected - start;
    }
    if (!proxy_configured and max_rows > out.items.len) try append(a, &out, "Proxy host/port not configured; saving is disabled", columns);
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter toggle  Left/Esc back", columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected_line,
        .can_confirm = proxy_configured and !menu.pasted and total != 0 and menu.selected < total and complete and
            fingerprint(models, providers, selected_models, proxy_configured) != null,
    };
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
    .{ .name = "login/Family/Proxy", .protocol = .chat, .context_tokens = 16384 },
    // Native protocol and unknown capacity stay selectable for proxy routing.
    .{ .name = "login/native/Judge", .protocol = .systemone, .context_tokens = 0 },
    .{ .name = "second/family/proxy", .protocol = .responses, .context_tokens = 16384 },
    .{ .name = "unlogged/private-model", .context_tokens = 16384 },
    .{ .name = "raw-only", .context_tokens = 16384 },
    .{ .name = "login/", .context_tokens = 16384 },
};
const logged = [_]Provider{.{ .name = "login" }};

test "proxy candidates use logged aliases preserve raw IDs and never synthesize Off" {
    try std.testing.expectEqual(@as(usize, 2), count(&profiles, &logged, ""));
    try std.testing.expectEqual(@as(usize, 0), count(&profiles, null, ""));
    try std.testing.expectEqual(@as(usize, 3), count(&profiles, &[_]Provider{ .{ .name = "login" }, .{ .name = "second" } }, ""));
    try std.testing.expectEqualStrings("login/Family/Proxy", candidate(&profiles, &logged, "", 0).?);
    try std.testing.expectEqualStrings("login/native/Judge", candidate(&profiles, &logged, "", 1).?);
    try std.testing.expect(candidate(&profiles, &logged, "", 2) == null);
    // AND tokens fold ASCII case; the order is irrelevant, the parts are not.
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, &logged, " JUDGE native "));
    try std.testing.expectEqual(@as(usize, 0), count(&profiles, &logged, "OFF"));
    try std.testing.expectEqual(@as(usize, 1), count(&profiles, &logged, "login/family/proxy"));
    try std.testing.expectEqualStrings("login/Family/Proxy", candidate(&profiles, &logged, "FAMILY", 0).?);
    const chinese = [_]cfg.Model{.{ .name = "login/中文/Proxy", .context_tokens = 0 }};
    try std.testing.expectEqual(@as(usize, 1), count(&chinese, &logged, "中文 proxy"));
    try std.testing.expect(!isSelected(&.{"login/Family/Proxy"}, "login/family/proxy"));
    try std.testing.expect(isSelected(&.{ "other/one", "login/Family/Proxy" }, "login/Family/Proxy"));
}

test "proxy fingerprint binds candidates selection and configured state" {
    const before = fingerprint(&profiles, &logged, &.{"login/Family/Proxy"}, true).?;
    try std.testing.expectEqual(@as(usize, 32), before.len);
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{"login/Family/Proxy"}, false).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{ "login/Family/Proxy", "login/native/Judge" }, true).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &logged, &.{"login/native/Judge"}, true).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, &[_]Provider{ .{ .name = "login" }, .{ .name = "second" } }, &.{"login/Family/Proxy"}, true).?));
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&profiles, null, &.{"login/Family/Proxy"}, true).?));
    var changed = profiles;
    changed[0].protocol = .responses;
    try std.testing.expectEqualSlices(u8, &before, &fingerprint(&changed, &logged, &.{"login/Family/Proxy"}, true).?);
    changed[0].name = "login/Family/Other";
    try std.testing.expect(!std.mem.eql(u8, &before, &fingerprint(&changed, &logged, &.{"login/Family/Proxy"}, true).?));
    const too_many: [max_models + 1]cfg.Model = @splat(profiles[0]);
    try std.testing.expect(fingerprint(&too_many, &logged, &.{}, true) == null);
    const too_many_selected: [max_selected + 1][]const u8 = @splat("login/Family/Proxy");
    try std.testing.expect(fingerprint(&profiles, &logged, &too_many_selected, true) == null);
    const long_name: [max_name_bytes + 1]u8 = @splat('a');
    try std.testing.expect(fingerprint(&profiles, &logged, &.{&long_name}, true) == null);
}

test "proxy rows mark checked models and only confirm complete configured rows" {
    const a = std.testing.allocator;
    const chosen = [_][]const u8{"login/native/Judge"};
    for (0..count(&profiles, &logged, "")) |selected| for (0..7) |height| for (0..70) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, &profiles, &logged, &chosen, true, "", columns, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.lines.len <= height);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
        if (height == 0) {
            try std.testing.expect(rendered.selected_line == null and !rendered.can_confirm);
            continue;
        }
        const name = if (selected == 0) "login/Family/Proxy" else "login/native/Judge";
        const width = 2 + "[ ] ".len + name.len;
        try std.testing.expectEqual(columns >= width, rendered.can_confirm);
        if (rendered.can_confirm) {
            const index = rendered.selected_line.?;
            try std.testing.expect(std.mem.find(u8, rendered.lines[index], name) != null);
            try std.testing.expect(std.mem.startsWith(u8, rendered.lines[index][2..], if (selected == 1) "[x]" else "[ ]"));
        }
    };
    const unconfigured = try rows(a, .{}, &profiles, &logged, &.{}, false, "", 80, 10);
    defer freeRows(a, unconfigured);
    try std.testing.expect(!unconfigured.can_confirm);
    try std.testing.expectEqualStrings("Proxy host/port not configured; saving is disabled", unconfigured.lines[2]);
    const pasted = try rows(a, .{ .pasted = true }, &profiles, &logged, &.{}, true, "", 80, 3);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
    const missing = try rows(a, .{}, &profiles, &logged, &.{}, true, "missing", 80, 3);
    defer freeRows(a, missing);
    try std.testing.expect(!missing.can_confirm and missing.selected_line == null);
    try std.testing.expectEqualStrings("No matching models", missing.lines[0]);
    const clipped = try rows(a, .{}, &profiles, &logged, &.{}, true, "", 6, 1);
    defer freeRows(a, clipped);
    try std.testing.expect(!clipped.can_confirm and text.width(clipped.lines[0]) <= 6);
    const empty = try rows(a, .{}, &profiles, &logged, &.{}, true, "", 80, 0);
    defer a.free(empty.lines);
    try std.testing.expect(empty.lines.len == 0 and empty.selected_line == null and !empty.can_confirm);
}

test "proxy rows keep one bounded window for large catalogs" {
    const a = std.testing.allocator;
    const models: [40]cfg.Model = @splat(.{ .name = "login/Native/Judge", .protocol = .systemone, .context_tokens = 0 });
    try std.testing.expectEqual(@as(usize, 40), count(&models, &logged, ""));
    for ([_]usize{ 1, 2, 3, 10, 100 }) |height| {
        const rendered = try rows(a, .{ .selected = 39 }, &models, &logged, &.{}, true, "", 80, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.can_confirm);
        try std.testing.expect(rendered.lines.len <= @min(height, 11));
        try std.testing.expect(rendered.selected_line.? < rendered.lines.len);
        try std.testing.expect(std.mem.find(u8, rendered.lines[rendered.selected_line.?], "login/Native/Judge") != null);
    }
    var menu: Menu = .{};
    const generation = menu.generation;
    menu.move(false, 0);
    try std.testing.expectEqual(generation, menu.generation);
}

fn allocationCase(a: std.mem.Allocator) !void {
    for ([_][]const u8{ "", "JUDGE", "missing" }) |query| {
        const rendered = try rows(a, .{ .selected = 1 }, &profiles, &logged, &.{"login/Family/Proxy"}, true, query, 40, 7);
        defer freeRows(a, rendered);
    }
}

test "proxy rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
