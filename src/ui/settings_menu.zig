//! Local presentation only. The connection owner saves and publishes settings.
const std = @import("std");
const text = @import("text.zig");
const time = @import("settings_time.zig");
const provider = @import("provider_picker.zig");
const cfg = @import("../core/config.zig");
pub const Key = @import("../core/settings.zig").Key;
pub const Menu = provider.Picker;
pub const labels = [_][]const u8{
    "Low-price input", "Decision model", "Auto compaction", "Command timeout",
    "Request timeout", "Image model",    "Auto memory",     "Proxy",
};
/// Bounded endpoint text buffer: host/port, [IPv6]:port or a borrowed address.
pub const endpoint_buffer_bytes = cfg.max_proxy_endpoint_bytes + 8;
pub const count = labels.len;
pub const Snapshot = struct {
    low_price_input_enabled: bool = true,
    decision_enabled: bool = false,
    image_enabled: bool = false,
    memory_auto: bool = true,
    image_model: ?[]const u8 = null,
    /// Borrowed provider/rawID reference; rows copies the displayed bytes.
    decision_model: ?[]const u8 = null,
    /// Owner-published proxy host/port state; never inferred from the model list.
    proxy_configured: bool = false,
    /// Bare host (IPv6 without brackets); null means no proxy endpoint exists.
    proxy_address: ?[]const u8 = null,
    proxy_port: u16 = 0,
    proxy_model_count: usize = 0,
    global_settings_available: bool = true,
    limits: cfg.Limits = .{},
};
pub fn preferenceKey(selected: usize) ?Key {
    return switch (selected) {
        2 => .compaction_enabled,
        3 => .command_timeout_ms,
        4 => .request_timeout_ms,
        6 => .memory_auto,
        else => null,
    };
}
pub fn label(selected: usize) []const u8 {
    return if (selected < labels.len) labels[selected] else "";
}
/// Owner-published endpoint text; IPv6 is bracketed so the port stays unambiguous.
pub fn formatEndpoint(buffer: *[endpoint_buffer_bytes]u8, state: Snapshot) ![]const u8 {
    const address = state.proxy_address orelse return "Not configured";
    if (state.proxy_port == 0) return address;
    if (std.mem.findScalar(u8, address, ':') != null) return std.fmt.bufPrint(buffer, "[{s}]:{d}", .{ address, state.proxy_port });
    return std.fmt.bufPrint(buffer, "{s}:{d}", .{ address, state.proxy_port });
}

/// Borrowed display values; rows renders exact copied numeric values, with units.
pub fn value(state: Snapshot, selected: usize) []const u8 {
    return switch (selected) {
        0 => if (state.low_price_input_enabled) "on" else "off",
        1 => if (!state.decision_enabled) "Off" else state.decision_model orelse "Not set",
        5 => if (!state.image_enabled) "Off" else state.image_model orelse "Not set",
        // rows formats the exact endpoint text; empty means "formatted there".
        7 => if (state.proxy_address == null) "Not configured" else "",
        2 => if (state.limits.compaction_enabled) "on" else "off",
        6 => if (state.memory_auto) "on" else "off",
        3, 4 => "s",
        else => "",
    };
}
pub fn description(selected: usize) []const u8 {
    return switch (selected) {
        0 => "Protect input from price surcharges; unknown pricing pauses. Flat pricing: no L.",
        1 => "Review commands, Memory and compaction. Enter selects Off or a logged-in model.",
        2 => "Automatic compaction only; manual /compact and hard preflight remain available.",
        3 => "Command timeout in s (up to 3 decimals).",
        4 => "All inference requests, including decisions, in s (up to 3 decimals).",
        5 => "Read images through a separate helper returning text. Off unless explicitly selected.",
        6 => "Automatically extract and maintain useful memory. On by default.",
        7 => "Configure the proxy address and exact model routes. A new session applies it.",
        else => "",
    };
}
pub const Rows = struct {
    lines: []const []const u8,
    selected_line: ?usize = null,
    can_confirm: bool = false,
};
fn renderedValue(state: Snapshot, selected: usize, buffer: *[32]u8) ![]const u8 {
    return switch (selected) {
        3 => try time.format(buffer, state.limits.command_timeout_ms),
        4 => try time.format(buffer, state.limits.request_timeout_ms),
        else => value(state, selected),
    };
}
pub fn rows(a: std.mem.Allocator, menu: Menu, state: Snapshot, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(menu.selected, labels.len - 1);
    const visible = @min(max_rows, labels.len);
    const start = @min(selected -| (visible / 2), labels.len - visible);
    var label_width: usize = 0;
    for (labels) |item| label_width = @max(label_width, text.width(item));
    const padding = "                                ";
    var complete = false;
    for (start..start + visible) |index| {
        var buffer: [32]u8 = undefined;
        var endpoint: [endpoint_buffer_bytes]u8 = undefined;
        const v = if (index == 7) try formatEndpoint(&endpoint, state) else try renderedValue(state, index, &buffer);
        const gap = label_width - text.width(label(index));
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}  {s}", .{ if (index == selected) "> " else "  ", label(index), padding[0..gap], v });
        defer a.free(raw);
        // Decision/Image/Proxy only open a read-only submenu; their current
        // value is not being saved. All saving root rows keep the full check.
        if (index == selected) complete = if (index == 1 or index == 5 or index == 7)
            2 + text.width(label(index)) <= columns
        else
            text.width(raw) <= columns;
        try append(a, &out, raw, columns);
    }
    if (max_rows > out.items.len) try append(a, &out, description(selected), columns);
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter change  Left back  Esc close", columns);
    if (!state.global_settings_available and max_rows > out.items.len) try append(a, &out, "Global settings unavailable; changes disabled", columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected - start,
        .can_confirm = state.global_settings_available and !menu.pasted and menu.selected < labels.len and complete,
    };
}
/// Second level: the endpoint editor and the existing model multi-select.
pub const proxy_labels = [_][]const u8{ "Address", "Models" };

pub fn proxyLabel(selected: usize) []const u8 {
    return if (selected < proxy_labels.len) proxy_labels[selected] else "";
}

/// Borrowed display values; the endpoint text itself is formatted by proxyRows.
pub fn proxyValue(state: Snapshot, selected: usize) []const u8 {
    return switch (selected) {
        0 => if (state.proxy_address == null) "Not configured" else "",
        1 => if (state.proxy_model_count == 0) "Off" else "",
        else => "",
    };
}

/// Both rows open a child; a missing endpoint never hides the row that can fix
/// it, and the model row itself reports why saving is disabled.
pub fn proxyRows(a: std.mem.Allocator, menu: Menu, state: Snapshot, columns: usize, max_rows: usize) !Rows {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |line| a.free(line);
        out.deinit(a);
    }
    if (max_rows == 0) return .{ .lines = try out.toOwnedSlice(a) };
    const selected = @min(menu.selected, proxy_labels.len - 1);
    const visible = @min(max_rows, proxy_labels.len);
    const start = @min(selected -| (visible / 2), proxy_labels.len - visible);
    var label_width: usize = 0;
    for (proxy_labels) |item| label_width = @max(label_width, text.width(item));
    const padding = "        ";
    var complete = false;
    for (start..start + visible) |index| {
        var endpoint: [endpoint_buffer_bytes]u8 = undefined;
        var counted: [32]u8 = undefined;
        const v = switch (index) {
            0 => try formatEndpoint(&endpoint, state),
            1 => if (state.proxy_model_count == 0) "Off" else try std.fmt.bufPrint(&counted, "{d} selected", .{state.proxy_model_count}),
            else => proxyValue(state, index),
        };
        const gap = label_width - text.width(proxyLabel(index));
        const raw = try std.fmt.allocPrint(a, "{s}{s}{s}  {s}", .{ if (index == selected) "> " else "  ", proxyLabel(index), padding[0..gap], v });
        defer a.free(raw);
        // Opening a child never requires the (unsaved) value to fit.
        if (index == selected) complete = 2 + text.width(proxyLabel(index)) <= columns;
        try append(a, &out, raw, columns);
    }
    if (max_rows > out.items.len) try append(a, &out, "Up/Down select  Enter open  Left/Esc back", columns);
    return .{
        .lines = try out.toOwnedSlice(a),
        .selected_line = selected - start,
        .can_confirm = state.global_settings_available and !menu.pasted and menu.selected < proxy_labels.len and complete,
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
