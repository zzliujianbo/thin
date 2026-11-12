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
    for (providers) |entry| {
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
    for (models) |model| {
        if (eligible(model, entries) and matches(model.name, query)) n += 1;
    }
    return n;
}

pub fn candidate(models: []const cfg.Model, providers: ?[]const Provider, query: []const u8, index: usize) ?[]const u8 {
    const entries = providers orelse &.{};
    var n: usize = 0;
    for (models) |model| {
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
/// configured host/port state, without allocating a snapshot.
pub fn fingerprint(models: []const cfg.Model, providers: ?[]const Provider, selected_models: []const []const u8, proxy_configured: bool, proxy_address: ?[]const u8, proxy_port: u16) ?Fingerprint {
    const entries = providers orelse &.{};
    const address = proxy_address orelse "";
    if (address.len > cfg.max_proxy_endpoint_bytes) return null;
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
    // The endpoint is part of the identity: a concurrent address change must
    // invalidate the acknowledged model toggle.
    hashString(&hash, address);
    hash.update(std.mem.asBytes(&proxy_port));
    hash.update(std.mem.asBytes(&selected_models.len));
    for (selected_models) |name| {
        if (name.len > max_name_bytes) return null;
        hashString(&hash, name);
    }
    return hash.finalResult();
}

pub fn rows(a: std.mem.Allocator, menu: Menu, models: []const cfg.Model, providers: ?[]const Provider, selected_models: []const []const u8, proxy_configured: bool, proxy_address: ?[]const u8, proxy_port: u16, query: []const u8, columns: usize, max_rows: usize) !Rows {
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
    if (!proxy_configured and max_rows > out.items.len) try append(a, &out, "Proxy host/port not configured; Enter shows what is missing", columns);
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter toggle  Left/Esc back", columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected_line,
        // A missing endpoint still acknowledges the frame so Enter can report
        // the blocker instead of silently doing nothing.
        .can_confirm = !menu.pasted and total != 0 and menu.selected < total and complete and
            fingerprint(models, providers, selected_models, proxy_configured, proxy_address, proxy_port) != null,
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
