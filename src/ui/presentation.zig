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
pub fn commandLine(a: std.mem.Allocator, body: []const u8, spans: []const CommandSpan, columns: usize, active_phase: ?usize) ![]const u8 {
    const safe = try singleLine(a, body, columns);
    defer a.free(safe);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var at: usize = 0;
    for (spans) |span| {
        const begin = @min(@max(at, span.start), safe.len);
        const end = @min(@max(begin, span.end), safe.len);
        try out.writer.writeAll(safe[at..begin]);
        if (span.outcome == .pending and active_phase != null and begin < end) {
            const prefix_end = @min(text.nextCluster(safe, begin, 0).end, end);
            try out.writer.print("{s}{s}{s}{s}{s}", .{ theme.command_pulse[active_phase.? % theme.command_pulse.len], safe[begin..prefix_end], theme.muted, safe[prefix_end..end], theme.reset });
        } else try out.writer.print("{s}{s}{s}", .{ outcomeColor(span.outcome), safe[begin..end], theme.reset });
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

pub const PromptActivity = struct {
    busy: bool = false,
    now_ms: u64 = 0,
    phase: usize = 0,
    rate_band: shared.activity.RateBand = .unknown,
    reasoning_effort: shared.ReasoningEffort = .unspecified,
};

/// Model and percentage share TPS palette/phase. Marker has configured effort
/// color; parentheses/space/editor remain default and every style is reset.
pub fn prompt(a: std.mem.Allocator, model: []const u8, snapshot: ?shared.ContextSnapshot, columns: usize, motion: PromptActivity) !Prompt {
    const percentage = try contextLabel(a, snapshot);
    defer a.free(percentage);
    const marker = if (motion.busy) activity.spinner(motion.now_ms) else ">";
    const reserve: usize = @min(@as(usize, 24), columns / 3);
    const room: usize = columns -| (reserve + 6 + text.width(percentage));
    const label = try singleLine(a, model, if (columns < 12) 0 else room);
    defer a.free(label);
    const percent_only = columns >= 12 and label.len == 0 and text.width(percentage) + 5 + reserve <= columns;
    const plain = if (label.len != 0)
        try std.fmt.allocPrint(a, "({s} {s}) {s} ", .{ label, percentage, marker })
    else if (percent_only)
        try std.fmt.allocPrint(a, "({s}) {s} ", .{ percentage, marker })
    else
        try std.fmt.allocPrint(a, "{s} ", .{marker});
    errdefer a.free(plain);
    const marker_color = theme.effortColor(motion.reasoning_effort);
    if (!motion.busy and std.mem.eql(u8, marker_color, theme.reset)) return .{ .plain = plain, .styled = try a.dupe(u8, plain) };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const palette = theme.modelPalette(motion.rate_band);
    var ordinal: usize = 0;
    if (label.len != 0 or percent_only) {
        try out.writer.writeAll("(");
        if (label.len != 0) {
            if (motion.busy) {
                try flowText(&out.writer, label, palette, motion.phase, &ordinal);
                try out.writer.writeAll(theme.reset);
            } else try out.writer.writeAll(label);
            try out.writer.writeAll(" ");
            ordinal += 1;
        }
        if (motion.busy) {
            try flowText(&out.writer, percentage, palette, motion.phase, &ordinal);
            try out.writer.writeAll(theme.reset);
        } else try out.writer.writeAll(percentage);
        try out.writer.writeAll(") ");
    }
    if (std.mem.eql(u8, marker_color, theme.reset)) {
        try out.writer.print("{s} ", .{marker});
    } else try out.writer.print("{s}{s}{s} ", .{ marker_color, marker, theme.reset });
    return .{ .plain = plain, .styled = try a.dupe(u8, out.written()) };
}

fn flowText(writer: *std.Io.Writer, bytes: []const u8, palette: []const []const u8, phase: usize, ordinal: *usize) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const cluster = text.nextCluster(bytes, at, 0);
        try writer.print("{s}{s}", .{ palette[(phase % palette.len + ordinal.*) % palette.len], bytes[at..cluster.end] });
        at = cluster.end;
        ordinal.* += 1;
    }
}

/// Retained-context estimate displayed as percentage only. Capacity unknown is
/// ?%, not 0%; overflow-safe shared arithmetic never wraps an overfull context.
fn contextLabel(a: std.mem.Allocator, snapshot: ?shared.ContextSnapshot) ![]const u8 {
    const ratio = shared.state.contextRatio(snapshot orelse return a.dupe(u8, "?%")) orelse return a.dupe(u8, "?%");
    if (snapshot.?.tokens > snapshot.?.limit) return a.dupe(u8, ">100%");
    return std.fmt.allocPrint(a, "{d}.{d}%", .{ ratio / 10, ratio % 10 });
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

test "percent prompt has default input colors and real spinner not loading text" {
    const a = std.testing.allocator;
    const idle = try prompt(a, "deepseek-flash", null, 79, .{});
    defer idle.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash ?%) > ", idle.plain);
    try std.testing.expectEqualStrings(idle.plain, idle.styled);
    const active = try prompt(a, "deepseek-flash", null, 79, .{ .busy = true, .now_ms = 80, .phase = 2 });
    defer active.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash ?%) ⠙ ", active.plain);
    try std.testing.expect(std.mem.endsWith(u8, active.styled, theme.reset ++ ") ⠙ "));
    try std.testing.expect(std.mem.find(u8, active.styled, "loading") == null);
    const narrow = try prompt(a, "long model name", null, 7, .{});
    defer narrow.deinit(a);
    try std.testing.expectEqualStrings("> ", narrow.plain);
    const hostile = try prompt(a, "你\x1b[2J\nname", null, 30, .{ .busy = true });
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
    const value = try prompt(a, "fixture", .{ .tokens = 16384, .limit = 32768 }, 79, .{});
    defer value.deinit(a);
    try std.testing.expectEqualStrings("(fixture 50.0%) > ", value.plain);
    try std.testing.expectEqualStrings(value.plain, value.styled);
    for ([_]usize{ 1, 7, 24, 40, 79, 119 }) |width| {
        const small = try prompt(a, "long-model-name", .{ .tokens = std.math.maxInt(u64), .limit = 1 }, width, .{ .busy = true, .now_ms = 80, .phase = 1 });
        defer small.deinit(a);
        try std.testing.expect(text.width(small.plain) <= @max(width, 2));
        try std.testing.expect(std.mem.find(u8, small.styled, "loading") == null);
    }
    const zero = try prompt(a, "fixture", .{ .tokens = 9000, .limit = 0 }, 79, .{});
    defer zero.deinit(a);
    try std.testing.expect(std.mem.find(u8, zero.plain, "?%") != null);
}

test "TPS wave continues into percentage while configured effort alone colors the marker" {
    const a = std.testing.allocator;
    for ([_]shared.activity.RateBand{ .slow, .standard, .fast, .unknown }) |band| {
        const value = try prompt(a, "model", .{ .tokens = 22807, .limit = 1000000 }, 79, .{ .busy = true, .now_ms = 80, .phase = 2, .rate_band = band, .reasoning_effort = .xhigh });
        defer value.deinit(a);
        try std.testing.expectEqualStrings("(model 2.3%) ⠙ ", value.plain);
        const palette = theme.modelPalette(band);
        try std.testing.expect(std.mem.find(u8, value.styled, palette[2]) != null);
        // Five name clusters + one default space: percentage continues phase.
        const styled_percent = try std.fmt.allocPrint(a, "{s}2{s}.{s}3{s}%{s}) ", .{ palette[8], palette[9], palette[10], palette[11], theme.reset });
        defer a.free(styled_percent);
        try std.testing.expect(std.mem.find(u8, value.styled, styled_percent) != null);
        try std.testing.expect(std.mem.endsWith(u8, value.styled, (comptime theme.effortColor(.xhigh)) ++ "⠙" ++ theme.reset ++ " "));
        try std.testing.expect(std.mem.find(u8, value.plain, "ctx") == null and std.mem.find(u8, value.plain, "/") == null);
    }
    for ([_]shared.ReasoningEffort{ .none, .minimal, .low, .medium, .high, .xhigh }) |effort| {
        const idle = try prompt(a, "model", .{ .tokens = 1, .limit = 1000 }, 79, .{ .reasoning_effort = effort });
        defer idle.deinit(a);
        const tail = try std.fmt.allocPrint(a, "{s}>{s} ", .{ theme.effortColor(effort), theme.reset });
        defer a.free(tail);
        try std.testing.expect(std.mem.endsWith(u8, idle.styled, tail));
        try std.testing.expectEqualStrings("(model 0.1%) > ", idle.plain);
    }
}

test "only pending command prefix pulses and completed spans remain static and clipped safely" {
    const a = std.testing.allocator;
    const body = "> sleep 1";
    const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }};
    const first = try commandLine(a, body, spans, 79, shared.activity.commandStep(0));
    defer a.free(first);
    const second = try commandLine(a, body, spans, 79, shared.activity.commandStep(120));
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.find(u8, first, theme.command_pulse[0] ++ ">" ++ theme.muted ++ " sleep 1") != null);
    for ([_]Outcome{ .success, .failed, .canceled }) |outcome| {
        const complete = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }};
        const one = try commandLine(a, body, complete, 79, 0);
        defer a.free(one);
        const two = try commandLine(a, body, complete, 79, 1);
        defer a.free(two);
        try std.testing.expectEqualStrings(one, two);
    }
    const narrow = try commandLine(a, "≡ read_file long-path", &.{CommandSpan{ .start = 0, .end = "≡ read_file long-path".len, .outcome = .pending }}, 4, 1);
    defer a.free(narrow);
    try std.testing.expect(std.unicode.utf8ValidateSlice(narrow));
    try std.testing.expect(std.mem.endsWith(u8, narrow, "..." ++ theme.reset));
}

test "same row command results retain icons and independent success failure colors" {
    const a = std.testing.allocator;
    const body = "> date [error]  ·  > pwd";
    const line = try commandLine(a, body, &.{ .{ .start = 0, .end = 14, .outcome = .failed }, .{ .start = 20, .end = body.len, .outcome = .success } }, 79, null);
    defer a.free(line);
    try std.testing.expect(std.mem.find(u8, line, theme.failure ++ "> date [error]") != null);
    try std.testing.expect(std.mem.find(u8, line, theme.success) != null);
    try std.testing.expect(std.mem.findScalar(u8, line, '\n') == null);
    const clipped = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 10, null);
    defer a.free(clipped);
    try std.testing.expect(std.mem.endsWith(u8, clipped, "..." ++ theme.reset));
}
