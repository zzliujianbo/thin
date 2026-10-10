//! Bounded UI captions only: never execution parameters, routing or policy.
const std = @import("std");
const text = @import("text.zig");
const activity = @import("activity.zig");
const theme = @import("theme.zig");
const shared = @import("../presentation.zig");
const line_stats = @import("../util/line_stats.zig");

/// One safe physical line, capped by cells/whole clusters. ASCII dots indicate
/// clipped suffixes; LF/TAB are spaces, never extra terminal rows.
pub fn singleLine(a: std.mem.Allocator, bytes: []const u8, columns: usize) ![]const u8 {
    return singleLineImpl(a, bytes, columns, false);
}

fn singleLineImpl(a: std.mem.Allocator, bytes: []const u8, columns: usize, source_clipped: bool) ![]const u8 {
    // sanitize returns an immutable view of a fresh owned allocation.
    const safe = @constCast(try text.sanitize(a, bytes, 512));
    defer a.free(safe);
    for (safe) |*byte| if (byte.* == '\n' or byte.* == '\t') {
        byte.* = ' ';
    };
    const clipped = source_clipped or text.exceedsSanitizedLimit(bytes, 512) or text.width(safe) > columns;
    const room = columns -| @min(columns, @as(usize, if (clipped) 3 else 0));
    var end: usize = 0;
    var cells: usize = 0;
    while (end < safe.len) {
        const cluster = text.nextCluster(safe, end, cells);
        if (cells + cluster.width > room) break;
        cells += cluster.width;
        end = cluster.end;
    }
    return if (clipped) std.fmt.allocPrint(a, "{s}{s}", .{ safe[0..end], "..."[0..@min(columns, 3)] }) else a.dupe(u8, safe[0..end]);
}

pub const Caption = struct {
    kind: activity.Tool,
    label: []const u8,

    pub fn deinit(self: Caption, a: std.mem.Allocator) void {
        a.free(self.label);
    }
};

/// Parse only bounded canonical copies. Incomplete JSON must not guess a shell
/// command; execution and approval keep their original unabridged parameters.
pub fn caption(a: std.mem.Allocator, name: []const u8, arguments: []const u8) !Caption {
    const call = try shared.tools.Call.init(a, name, arguments);
    defer call.deinit(a);
    return fromCall(a, call);
}

/// Terminal widths and labels adapt shared structured data; no JSON parsing here.
pub fn fromCall(a: std.mem.Allocator, call: shared.tools.Call) !Caption {
    const kind = call.kind;
    if (kind != .bash and kind != .read and kind != .write) return .{ .kind = kind, .label = try a.dupe(u8, if (kind == .memory) "memory" else "tool") };
    const unavailable = if (kind == .bash) "(command unavailable)" else if (kind == .read) "read_file (file unavailable)" else "write_file (file unavailable)";
    const detail = call.detail orelse return .{ .kind = kind, .label = try a.dupe(u8, unavailable) };
    if (kind == .bash) return .{ .kind = kind, .label = try singleLineImpl(a, detail, 72, call.truncated) };
    const path = try singleLineImpl(a, detail, 32, call.truncated);
    defer a.free(path);
    return .{ .kind = kind, .label = try std.fmt.allocPrint(a, "{s} {s}", .{ if (kind == .read) "read_file" else "write_file", path }) };
}

/// Numeric observations survive Bridge text clipping. Missing is ?, not zero.
/// This helper is called for successful results only; failures retain the path
/// but must not claim any uncompleted read/write or requested-content line count.
pub fn completed(a: std.mem.Allocator, value: Caption, stats: ?line_stats.File) !Caption {
    const label = switch (value.kind) {
        .read => if (stats != null and stats.?.read != null)
            try std.fmt.allocPrint(a, "{s}  {d} lines{s}", .{ value.label, stats.?.read.?, if (stats.?.partial) " [partial]" else "" })
        else
            try std.fmt.allocPrint(a, "{s}  lines ?", .{value.label}),
        .write => if (stats != null and stats.?.changes != null) blk: {
            const c = stats.?.changes.?;
            break :blk try std.fmt.allocPrint(a, "{s}  ~{d} +{d} -{d} lines", .{ value.label, c.modified, c.added, c.removed });
        } else try std.fmt.allocPrint(a, "{s}  changes ?", .{value.label}),
        else => try a.dupe(u8, value.label),
    };
    return .{ .kind = value.kind, .label = label };
}

pub const Outcome = shared.tools.Outcome;

fn outcomeColor(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .pending => theme.muted,
        .success => theme.success,
        .failed => theme.failure,
        .canceled => theme.caution,
    };
}

pub const CommandSpan = struct { start: usize, end: usize, outcome: Outcome };

pub fn commandText(a: std.mem.Allocator, value: Caption, outcome: Outcome) ![]const u8 {
    return std.fmt.allocPrint(a, "{s} {s}{s}", .{ activity.icon(value.kind), value.label, switch (outcome) {
        .failed => " [error]",
        .canceled => " [canceled]",
        else => "",
    } });
}

/// Caption bodies are already sanitized, and spans are renderer-owned offsets.
/// Clip BEFORE SGR so no partial escapes; mixed outcomes keep independent colors.
pub fn commandLine(a: std.mem.Allocator, body: []const u8, spans: []const CommandSpan, columns: usize) ![]const u8 {
    const safe = try singleLine(a, body, columns);
    defer a.free(safe);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var at: usize = 0;
    for (spans) |span| {
        const begin = @min(@max(at, span.start), safe.len);
        const end = @min(@max(begin, span.end), safe.len);
        try out.writer.writeAll(safe[at..begin]);
        try out.writer.print("{s}{s}{s}", .{ outcomeColor(span.outcome), safe[begin..end], theme.reset });
        at = end;
        if (at == safe.len) break;
    }
    try out.writer.writeAll(safe[at..]);
    return a.dupe(u8, out.written());
}

pub const Prompt = struct {
    plain: []const u8,
    styled: []const u8,

    pub fn deinit(self: Prompt, a: std.mem.Allocator) void {
        a.free(self.plain);
        a.free(self.styled);
    }
};

/// Only the model name is decorated. The icon is one cell, and every styled
/// cluster is followed by a reset before parentheses/marker/editor text.
pub fn prompt(a: std.mem.Allocator, model: []const u8, snapshot: ?shared.ContextSnapshot, columns: usize, busy: bool, now_ms: u64, phase: usize) !Prompt {
    const context_label = try contextLabel(a, snapshot, columns);
    defer a.free(context_label);
    const context_gap = if (context_label.len != 0) try std.fmt.allocPrint(a, "{s} ", .{context_label}) else try a.dupe(u8, "");
    defer a.free(context_gap);
    const marker = if (busy) activity.spinner(now_ms) else ">";
    const reserve: usize = @min(@as(usize, 24), columns / @as(usize, if (context_label.len != 0) 3 else 2));
    const room = columns -| (reserve + 5 + text.width(context_gap));
    const label = try singleLine(a, model, if (columns < 12) 0 else room);
    defer a.free(label);
    const plain = if (label.len == 0) try std.fmt.allocPrint(a, "{s}{s} ", .{ context_gap, marker }) else try std.fmt.allocPrint(a, "({s}) {s}{s} ", .{ label, context_gap, marker });
    errdefer a.free(plain);
    if (!busy or label.len == 0) return .{ .plain = plain, .styled = try a.dupe(u8, plain) };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("(");
    var at: usize = 0;
    var ordinal: usize = 0;
    while (at < label.len) {
        const cluster = text.nextCluster(label, at, 0);
        try out.writer.print("{s}{s}", .{ theme.model_flow[(phase % theme.model_flow.len + ordinal) % theme.model_flow.len], label[at..cluster.end] });
        at = cluster.end;
        ordinal += 1;
    }
    try out.writer.print("{s}) {s}{s} ", .{ theme.reset, context_gap, marker });
    return .{ .plain = plain, .styled = try a.dupe(u8, out.written()) };
}

/// Occupancy is the calibrated retained-context estimate, including system and
/// schema, against model capacity. Cached tokens are not subtracted. Small
/// windows use the percentage only; unknown/invalid capacity never divides zero.
fn contextLabel(a: std.mem.Allocator, snapshot: ?shared.ContextSnapshot, columns: usize) ![]const u8 {
    if (snapshot == null or columns < 24) return a.dupe(u8, "");
    const s = snapshot.?;
    if (s.limit == 0) return a.dupe(u8, "[ctx ?]");
    const ratio = shared.state.contextRatio(s).?;
    const full = try std.fmt.allocPrint(a, "[ctx ~{d}/{d} {d}.{d}%]", .{ s.tokens, s.limit, ratio / 10, ratio % 10 });
    const editor_reserve: usize = @min(@as(usize, 24), columns / 3);
    const budget: usize = @min(@as(usize, 36), @max(@as(usize, 8), columns -| (editor_reserve + 13)));
    if (text.width(full) <= budget) return full;
    a.free(full);
    if (ratio > 1000) return a.dupe(u8, if (budget >= 12) "[ctx ~>100%]" else "[~>100%]");
    if (budget >= 12) return std.fmt.allocPrint(a, "[ctx ~{d}.{d}%]", .{ ratio / 10, ratio % 10 });
    return std.fmt.allocPrint(a, "[~{d}.{d}%]", .{ ratio / 10, ratio % 10 });
}

test "command captions are bounded single line UTF8 with literal three dots" {
    const a = std.testing.allocator;
    const cmd = try caption(a, "bash", "{\"command\":\"date\\nwhoami\\tmore\"}");
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("date whoami more", cmd.label);
    const long = try singleLine(a, "abcdefghi", 7);
    defer a.free(long);
    try std.testing.expectEqualStrings("abcd...", long);
    const hostile = try singleLine(a, "你你你\x1b[2J\ntrailing", 7);
    defer a.free(hostile);
    try std.testing.expect(std.unicode.utf8ValidateSlice(hostile));
    try std.testing.expect(text.width(hostile) <= 7);
    try std.testing.expect(std.mem.findScalar(u8, hostile, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, hostile, '\n') == null);
    try std.testing.expect(std.mem.endsWith(u8, hostile, "..."));
    const incomplete = try caption(a, "bash", "{\"command\":\"partial");
    defer incomplete.deinit(a);
    try std.testing.expectEqualStrings("(command unavailable)", incomplete.label);
}

test "model only prompt has default input colors and real spinner not loading text" {
    const a = std.testing.allocator;
    const idle = try prompt(a, "deepseek-flash", null, 79, false, 0, 0);
    defer idle.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash) > ", idle.plain);
    try std.testing.expectEqualStrings(idle.plain, idle.styled);
    const active = try prompt(a, "deepseek-flash", null, 79, true, 80, 2);
    defer active.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash) ⠙ ", active.plain);
    try std.testing.expect(std.mem.endsWith(u8, active.styled, theme.reset ++ ") ⠙ "));
    try std.testing.expect(std.mem.find(u8, active.styled, "loading") == null);
    const narrow = try prompt(a, "long model name", null, 7, false, 0, 0);
    defer narrow.deinit(a);
    try std.testing.expectEqualStrings("> ", narrow.plain);
    const hostile = try prompt(a, "你\x1b[2J\nname", null, 30, true, 0, 0);
    defer hostile.deinit(a);
    try std.testing.expect(text.width(hostile.plain) < 30);
    try std.testing.expect(std.mem.find(u8, hostile.styled, "\x1b[2J") == null);
}

test "file captions expose safe paths and measured counts with unknown not guessed" {
    const a = std.testing.allocator;
    const read = try caption(a, "read_file", "{\"path\":\"src/main.zig\",\"offset\":100}");
    defer read.deinit(a);
    const done = try completed(a, read, .{ .read = 12, .partial = true });
    defer done.deinit(a);
    try std.testing.expectEqualStrings("read_file src/main.zig  12 lines [partial]", done.label);
    const write = try caption(a, "write_file", "{\"path\":\"a.zig\",\"content\":\"secret-body-not-a-caption\"}");
    defer write.deinit(a);
    const changed = try completed(a, write, .{ .changes = .{ .modified = 3, .added = 5, .removed = 2 } });
    defer changed.deinit(a);
    try std.testing.expectEqualStrings("write_file a.zig  ~3 +5 -2 lines", changed.label);
    const unknown = try completed(a, write, null);
    defer unknown.deinit(a);
    try std.testing.expectEqualStrings("write_file a.zig  changes ?", unknown.label);
    const bad = try caption(a, "write_file", "{\"path\":\"unfinished");
    defer bad.deinit(a);
    try std.testing.expectEqualStrings("write_file (file unavailable)", bad.label);
}

test "context prompt is retained occupancy not cache billing and remains bounded at small widths" {
    const a = std.testing.allocator;
    const value = try prompt(a, "fixture", .{ .tokens = 16384, .limit = 32768 }, 79, false, 0, 0);
    defer value.deinit(a);
    try std.testing.expectEqualStrings("(fixture) [ctx ~16384/32768 50.0%] > ", value.plain);
    try std.testing.expectEqualStrings(value.plain, value.styled);
    for ([_]usize{ 1, 7, 24, 40, 79, 119 }) |width| {
        const small = try prompt(a, "long-model-name", .{ .tokens = std.math.maxInt(u64), .limit = 1 }, width, true, 80, 1);
        defer small.deinit(a);
        try std.testing.expect(text.width(small.plain) <= @max(width, 2));
        try std.testing.expect(std.mem.find(u8, small.styled, "loading") == null);
    }
    const zero = try prompt(a, "fixture", .{ .tokens = 9000, .limit = 0 }, 79, false, 0, 0);
    defer zero.deinit(a);
    try std.testing.expect(std.mem.find(u8, zero.plain, "[ctx ?]") != null);
}

test "same row command results retain icons and independent success failure colors" {
    const a = std.testing.allocator;
    const body = ">_ date [error]  ·  >_ pwd";
    const line = try commandLine(a, body, &.{ .{ .start = 0, .end = 15, .outcome = .failed }, .{ .start = 21, .end = body.len, .outcome = .success } }, 79);
    defer a.free(line);
    try std.testing.expect(std.mem.find(u8, line, theme.failure ++ ">_ date [error]") != null);
    try std.testing.expect(std.mem.find(u8, line, theme.success) != null);
    try std.testing.expect(std.mem.findScalar(u8, line, '\n') == null);
    const clipped = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 10);
    defer a.free(clipped);
    try std.testing.expect(std.mem.endsWith(u8, clipped, "..." ++ theme.reset));
}
