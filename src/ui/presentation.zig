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
    return boundedLine(a, bytes, columns, source_clipped, 512);
}

fn boundedLine(a: std.mem.Allocator, bytes: []const u8, columns: usize, source_clipped: bool, max_bytes: usize) ![]const u8 {
    const prefix = try @import("../util/display_text.zig").sanitizePrefix(a, bytes, max_bytes);
    defer a.free(prefix.text);
    const safe = prefix.text;
    for (safe) |*byte| if (byte.* == '\n' or byte.* == '\t') {
        byte.* = ' ';
    };
    // A byte-capped safe prefix may end inside the original cluster. Its last
    // cluster must not be advertised as complete; truncation is metadata, not
    // a marker searched/replaced in a potentially legitimate file name.
    var stop = safe.len;
    if (source_clipped or prefix.truncated) {
        stop = 0;
        var at: usize = 0;
        var col: usize = 0;
        while (at < safe.len) {
            const cluster = text.nextCluster(safe, at, col);
            if (cluster.end == safe.len) break;
            stop = cluster.end;
            col += cluster.width;
            at = cluster.end;
        }
    }
    const clipped = source_clipped or prefix.truncated or text.width(safe) > columns;
    const room = columns -| @min(columns, @as(usize, if (clipped) 3 else 0));
    const byte_room = max_bytes -| @as(usize, if (clipped) 3 else 0);
    var end: usize = 0;
    var cells: usize = 0;
    while (end < stop) {
        const cluster = text.nextCluster(safe, end, cells);
        if (cluster.end > byte_room or cells + cluster.width > room) break;
        cells += cluster.width;
        end = cluster.end;
    }
    return if (clipped) std.fmt.allocPrint(a, "{s}{s}", .{ safe[0..end], "..."[0..@min(@min(columns, 3), max_bytes)] }) else a.dupe(u8, safe[0..end]);
}

pub const Range = struct { start: usize, end: usize };
/// Renderer-owned byte ranges, not text patterns extracted from a file path.
pub const WriteMarks = struct {
    added: Range,
    removed: Range,

    pub fn shifted(self: WriteMarks, offset: usize) WriteMarks {
        return .{ .added = .{ .start = self.added.start + offset, .end = self.added.end + offset }, .removed = .{ .start = self.removed.start + offset, .end = self.removed.end + offset } };
    }
};

pub const Caption = struct {
    kind: activity.Tool,
    label: []const u8,
    write_marks: ?WriteMarks = null,
    /// Static, allowlisted diagnostic from shared tools; never a raw result body.
    failure_reason: ?[]const u8 = null,

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
    if (kind == .other) return .{ .kind = kind, .label = try a.dupe(u8, "tool") };
    const unavailable = switch (kind) {
        .bash => "(command unavailable)",
        .read, .write => "(file unavailable)",
        .memory => "(operation unavailable)",
        .other => unreachable,
    };
    const detail = call.detail orelse return .{ .kind = kind, .label = try a.dupe(u8, unavailable) };
    // Preserve bounded detail until frame-time width is known; no old 32/72
    // cell path/command cutoff before applying the actual 80% row limit.
    return .{ .kind = kind, .label = try singleLineImpl(a, detail, 512, call.truncated) };
}

/// Numeric observations survive Bridge text clipping. Missing is ?, not zero.
/// This helper is called for successful results only; failures retain the path
/// but must not claim any uncompleted read/write or requested-content line count.
pub fn completed(a: std.mem.Allocator, value: Caption, stats: ?line_stats.File) !Caption {
    var marks: ?WriteMarks = null;
    const label = switch (value.kind) {
        .read => if (stats != null and stats.?.read != null)
            try std.fmt.allocPrint(a, "{s}  {d} lines{s}", .{ value.label, stats.?.read.?, if (stats.?.partial) " [partial]" else "" })
        else
            try std.fmt.allocPrint(a, "{s}  lines ?", .{value.label}),
        .write => if (stats != null and stats.?.changes != null) blk: {
            const c = stats.?.changes.?;
            const added = value.label.len + "  ~".len + decimalLength(c.modified) + 1;
            const removed = added + 1 + decimalLength(c.added) + 1;
            marks = .{ .added = .{ .start = added, .end = added + 1 + decimalLength(c.added) }, .removed = .{ .start = removed, .end = removed + 1 + decimalLength(c.removed) } };
            break :blk try std.fmt.allocPrint(a, "{s}  ~{d} +{d} -{d} lines", .{ value.label, c.modified, c.added, c.removed });
        } else try std.fmt.allocPrint(a, "{s}  changes ?", .{value.label}),
        else => try a.dupe(u8, value.label),
    };
    return .{ .kind = value.kind, .label = label, .write_marks = marks };
}

fn decimalLength(value: u64) usize {
    var n = value;
    var length: usize = 1;
    while (n >= 10) : (n /= 10) length += 1;
    return length;
}

pub const Outcome = shared.tools.Outcome;

fn outcomeColor(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .pending => theme.muted,
        .success => theme.muted,
        .failed => theme.failure,
        .canceled => theme.caution,
    };
}

fn prefixColor(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .pending => "", // Before execution: neutral; active animation is separate.
        .success => theme.success,
        .failed => theme.failure,
        .canceled => theme.caution,
    };
}

pub const CommandSpan = struct { start: usize, end: usize, outcome: Outcome, write_marks: ?WriteMarks = null };

pub fn commandText(a: std.mem.Allocator, value: Caption, outcome: Outcome) ![]const u8 {
    const reason = if (outcome == .failed) value.failure_reason orelse "" else "";
    return std.fmt.allocPrint(a, "{s} {s}{s}{s}{s}", .{ activity.icon(value.kind), value.label, switch (outcome) {
        .failed => " [error]",
        .canceled => " [canceled]",
        else => "",
    }, if (reason.len != 0) " " else "", reason });
}

/// Caption bodies are already sanitized, and spans are renderer-owned offsets.
/// Clip BEFORE SGR so no partial escapes; mixed outcomes keep independent colors.
pub fn commandColumns(columns: usize) usize {
    // Overflow-safe floor(80%), including very narrow frames.
    return if (columns == 0) 0 else @max(1, columns / 5 * 4 + columns % 5 * 4 / 5);
}

/// `duration_ms` is the measured wall-clock execution time of this row. It is
/// rendered last, in muted color, so it survives label clipping and never
/// competes with the outcome color or diff marks. `active_time_ms` remains the
/// animation clock only; the two are deliberately independent.
pub fn commandLine(a: std.mem.Allocator, body: []const u8, spans: []const CommandSpan, columns: usize, duration_ms: ?u64, active_time_ms: ?u64) ![]const u8 {
    // Detail stays <=512 bytes; allow its prefix and bounded observed counts
    // without sanitizing/truncating the same path a second time at512 bytes.
    // Reserve the suffix inside the existing 80% limit, not after clipping.
    // On tiny terminals omit optional time rather than wrapping the command.
    var duration_buf: [32]u8 = undefined;
    var duration_writer = std.Io.Writer.fixed(&duration_buf);
    if (duration_ms) |ms| {
        try duration_writer.writeAll("  ");
        try shared.activity.formatDuration(&duration_writer, ms);
    }
    const limit = commandColumns(columns);
    const suffix = if (duration_ms != null and limit >= duration_writer.buffered().len + 4) duration_writer.buffered() else "";
    const safe = try boundedLine(a, body, limit - suffix.len, false, 640);
    defer a.free(safe);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var at: usize = 0;
    for (spans) |span| {
        const begin = @min(@max(at, span.start), safe.len);
        const end = @min(@max(begin, span.end), safe.len);
        try out.writer.writeAll(safe[at..begin]);
        const prefix_end = if (begin < end) @min(text.nextCluster(safe, begin, 0).end, end) else begin;
        // Never turn clipped ellipsis bytes into a phantom running tool icon.
        const has_prefix = begin == span.start and begin < body.len and std.mem.eql(u8, safe[begin..prefix_end], body[begin..text.nextCluster(body, begin, 0).end]);
        if (span.outcome == .pending and active_time_ms != null and has_prefix) {
            const now_ms = active_time_ms.?;
            try out.writer.print("{s}{s}{s}{s}{s}", .{ theme.command_pulse[shared.activity.commandStep(now_ms)], activity.spinner(now_ms), theme.muted, safe[prefix_end..end], theme.reset });
        } else {
            if (has_prefix) try out.writer.print("{s}{s}{s}", .{ theme.reset, prefixColor(span.outcome), safe[begin..prefix_end] });
            const summary_start = if (has_prefix) prefix_end else begin;
            const color = outcomeColor(span.outcome);
            try out.writer.writeAll(color);
            var cursor = summary_start;
            if (span.write_marks) |marks| {
                const ranges = [_]Range{ marks.added, marks.removed };
                const colors = [_][]const u8{ theme.diff_added, theme.diff_removed };
                for (ranges, colors) |range, tone| {
                    // Only complete, actually retained numeric tokens get a diff
                    // color. Never color ellipsis or a matching substring in a path.
                    if (range.start < cursor or range.end < range.start or range.end > end or range.end > body.len or !std.mem.eql(u8, safe[range.start..range.end], body[range.start..range.end])) continue;
                    try out.writer.print("{s}{s}{s}{s}", .{ safe[cursor..range.start], tone, safe[range.start..range.end], color });
                    cursor = range.end;
                }
            }
            try out.writer.print("{s}{s}", .{ safe[cursor..end], theme.reset });
        }
        at = end;
        if (at == safe.len) break;
    }
    try out.writer.writeAll(safe[at..]);
    if (suffix.len != 0) try out.writer.print("{s}{s}{s}", .{ theme.muted, suffix, theme.reset });
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
    /// Transient level confirmation: temporarily replaces the context percentage
    /// in the prefix with the chosen level name; the owner expires it.
    effort_flash: ?shared.ReasoningEffort = null,
    /// Owner snapshot of the input policy, independent of latest usage.
    low_price_input: bool = false,
};

/// The model keeps idle effort/busy TPS styling; context occupancy has a static
/// threshold color in both states. A transient effort confirmation retains its
/// previous styling. Parentheses, spaces, marker and editor stay default.
pub fn prompt(a: std.mem.Allocator, model: []const u8, snapshot: ?shared.ContextSnapshot, columns: usize, motion: PromptActivity) !Prompt {
    const value = if (motion.effort_flash) |level|
        try a.dupe(u8, level.name() orelse "?")
    else
        try contextLabel(a, snapshot);
    defer a.free(value);
    const percentage = try std.fmt.allocPrint(a, "{s}{s}", .{ if (motion.low_price_input) "L " else "", value });
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
    const idle_color = theme.effortColor(motion.reasoning_effort);
    const slot_flow = motion.busy and motion.effort_flash != null;
    const context_color = theme.contextColor(if (snapshot) |current| shared.state.contextRatio(current) else null);
    const slot_color = if (motion.effort_flash != null) idle_color else context_color;
    const styled_model = label.len != 0 and (motion.busy or !std.mem.eql(u8, idle_color, theme.reset));
    const styled_slot = slot_flow or !std.mem.eql(u8, slot_color, theme.reset) or (motion.low_price_input and !std.mem.eql(u8, context_color, theme.reset));
    if ((label.len == 0 and !percent_only) or (!styled_model and !styled_slot)) return .{ .plain = plain, .styled = try a.dupe(u8, plain) };
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
            } else try out.writer.print("{s}{s}{s}", .{ idle_color, label, theme.reset });
            try out.writer.writeAll(" ");
            ordinal += 1;
        }
        // A transient effort flash keeps its own styling, but must never turn
        // the policy marker into a TPS animation or a reasoning-level color.
        const separate_marker = motion.low_price_input and motion.effort_flash != null;
        if (separate_marker) {
            try out.writer.print("{s}L{s} ", .{ context_color, theme.reset });
            ordinal += 2;
        }
        const slot = if (separate_marker) value else percentage;
        if (slot_flow) {
            try flowText(&out.writer, slot, palette, motion.phase, &ordinal);
            try out.writer.writeAll(theme.reset);
        } else try out.writer.print("{s}{s}{s}", .{ slot_color, slot, theme.reset });
        try out.writer.writeAll(") ");
    }
    try out.writer.print("{s} ", .{marker});
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
    try std.testing.expectEqualStrings("src/main.zig  12 lines [partial]", done.label);
    const write = try caption(a, "write_file", "{\"path\":\"a.zig\",\"content\":\"secret-body-not-a-caption\"}");
    defer write.deinit(a);
    const changed = try completed(a, write, .{ .changes = .{ .modified = 3, .added = 5, .removed = 2 } });
    defer changed.deinit(a);
    try std.testing.expectEqualStrings("a.zig  ~3 +5 -2 lines", changed.label);
    const unknown = try completed(a, write, null);
    defer unknown.deinit(a);
    try std.testing.expectEqualStrings("a.zig  changes ?", unknown.label);
    const bad = try caption(a, "write_file", "{\"path\":\"unfinished");
    defer bad.deinit(a);
    try std.testing.expectEqualStrings("(file unavailable)", bad.label);
}

test "write count colors use numeric metadata not patterns in a hostile path" {
    const a = std.testing.allocator;
    const value: Caption = .{ .kind = .write, .label = "path +99 -88 中文" };
    const done = try completed(a, value, .{ .changes = .{ .modified = 4, .added = 12, .removed = 34 } });
    defer done.deinit(a);
    const body = try commandText(a, done, .success);
    defer a.free(body);
    const span: CommandSpan = .{ .start = 0, .end = body.len, .outcome = .success, .write_marks = done.write_marks.?.shifted(2) };
    const line = try commandLine(a, body, &.{span}, 200, null, null);
    defer a.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, theme.reset ++ theme.success ++ "w" ++ theme.muted ++ " path +99 -88 中文  ~4 "));
    try std.testing.expect(std.mem.indexOf(u8, line, theme.diff_added ++ "+12" ++ theme.muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, theme.diff_removed ++ "-34" ++ theme.muted) != null);
    for ([_]usize{ 1, 4, 20, 45, 55 }) |columns| {
        const clipped = try commandLine(a, body, &.{span}, columns, null, null);
        defer a.free(clipped);
        try std.testing.expect(@import("markdown_writer.zig").displayWidth(clipped) <= commandColumns(columns));
        try std.testing.expect(std.unicode.utf8ValidateSlice(clipped));
        try std.testing.expect(std.mem.indexOf(u8, clipped, theme.diff_added ++ "...") == null);
        try std.testing.expect(std.mem.indexOf(u8, clipped, theme.diff_removed ++ "...") == null);
    }
    const unknown = try completed(a, value, null);
    defer unknown.deinit(a);
    try std.testing.expect(unknown.write_marks == null);
}

test "context prompt is retained occupancy not cache billing and remains bounded at small widths" {
    const a = std.testing.allocator;
    const value = try prompt(a, "fixture", .{ .tokens = 16384, .limit = 32768 }, 79, .{});
    defer value.deinit(a);
    try std.testing.expectEqualStrings("(fixture 50.0%) > ", value.plain);
    try std.testing.expectEqualStrings("(" ++ theme.reset ++ "fixture" ++ theme.reset ++ " " ++ theme.failure ++ "50.0%" ++ theme.reset ++ ") > ", value.styled);
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

test "context percent thresholds follow displayed rounding without animation or overflow" {
    const a = std.testing.allocator;
    const cases = [_]struct { snapshot: ?shared.ContextSnapshot, label: []const u8, color: []const u8 }{
        .{ .snapshot = null, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 10, .limit = 100, .known = false }, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 10, .limit = 0 }, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 0, .limit = 100 }, .label = "0.0%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24949, .limit = 100000 }, .label = "24.9%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24950, .limit = 100000 }, .label = "25.0%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 25, .limit = 100 }, .label = "25.0%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49949, .limit = 100000 }, .label = "49.9%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49950, .limit = 100000 }, .label = "50.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = 50, .limit = 100 }, .label = "50.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = std.math.maxInt(u64), .limit = std.math.maxInt(u64) }, .label = "100.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = std.math.maxInt(u64), .limit = 1 }, .label = ">100%", .color = theme.failure },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |busy| {
            for ([_]usize{ 0, 11 }) |phase| {
                const value = try prompt(a, "fixture", case.snapshot, 79, .{ .busy = busy, .now_ms = 80, .phase = phase, .rate_band = .fast, .reasoning_effort = .high });
                defer value.deinit(a);
                const suffix = try std.fmt.allocPrint(a, " {s}{s}{s}) {s} ", .{ case.color, case.label, theme.reset, if (busy) activity.spinner(80) else ">" });
                defer a.free(suffix);
                try std.testing.expect(std.mem.endsWith(u8, value.styled, suffix));
                try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
            }
        }
    }
}

test "low price marker shares the full static context color and optout removes it" {
    const a = std.testing.allocator;
    const cases = [_]struct { snapshot: ?shared.ContextSnapshot, label: []const u8, color: []const u8 }{
        .{ .snapshot = null, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 10, .limit = 100, .known = false }, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 0, .limit = 100 }, .label = "0.0%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24949, .limit = 100000 }, .label = "24.9%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24950, .limit = 100000 }, .label = "25.0%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49949, .limit = 100000 }, .label = "49.9%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49950, .limit = 100000 }, .label = "50.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = std.math.maxInt(u64), .limit = 1 }, .label = ">100%", .color = theme.failure },
    };
    for (cases) |case| for ([_]bool{ false, true }) |enabled| for ([_]bool{ false, true }) |busy| for ([_]usize{ 0, 11 }) |phase| {
        const value = try prompt(a, "fixture", case.snapshot, 79, .{ .busy = busy, .now_ms = 80, .phase = phase, .rate_band = .fast, .reasoning_effort = .high, .low_price_input = enabled });
        defer value.deinit(a);
        const suffix = try std.fmt.allocPrint(a, " {s}{s}{s}{s}) {s} ", .{ case.color, if (enabled) "L " else "", case.label, theme.reset, if (busy) activity.spinner(80) else ">" });
        defer a.free(suffix);
        try std.testing.expect(std.mem.endsWith(u8, value.styled, suffix));
        try std.testing.expectEqual(enabled, std.mem.find(u8, value.plain, "L ") != null);
        try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
    };
    for (0..80) |columns| {
        const value = try prompt(a, "a very long model name", .{ .tokens = 10, .limit = 100 }, columns, .{ .low_price_input = true, .busy = true });
        defer value.deinit(a);
        try std.testing.expect(text.width(value.plain) <= @max(columns, 2));
        try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
        if (std.mem.find(u8, value.plain, "L ") != null) try std.testing.expect(std.mem.find(u8, value.plain, "L 10.0%") != null);
    }
}

test "low price marker stays context colored during effort flashes" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |busy| {
        const value = try prompt(a, "fixture", .{ .tokens = 50, .limit = 100 }, 79, .{ .busy = busy, .reasoning_effort = .medium, .effort_flash = .medium, .phase = 7, .low_price_input = true });
        defer value.deinit(a);
        try std.testing.expect(std.mem.find(u8, value.plain, "L medium") != null);
        try std.testing.expect(std.mem.find(u8, value.styled, theme.failure ++ "L" ++ theme.reset ++ " ") != null);
        try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
    }
}

test "effort confirmation replaces only the context slot and medium stays default color" {
    const a = std.testing.allocator;
    const context: shared.ContextSnapshot = .{ .tokens = 25, .limit = 100 };
    const flash = try prompt(a, "fixture", context, 79, .{ .reasoning_effort = .medium, .effort_flash = .medium });
    defer flash.deinit(a);
    try std.testing.expectEqualStrings("(fixture medium) > ", flash.plain);
    try std.testing.expectEqualStrings(flash.plain, flash.styled);
    const restored = try prompt(a, "fixture", context, 79, .{ .reasoning_effort = .medium });
    defer restored.deinit(a);
    try std.testing.expectEqualStrings("(fixture 25.0%) > ", restored.plain);
    const busy = try prompt(a, "fixture", context, 79, .{ .busy = true, .reasoning_effort = .high, .effort_flash = .high });
    defer busy.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, busy.plain, "(fixture high) "));
    for (0..80) |columns| {
        const narrow = try prompt(a, "very long model name", context, columns, .{ .reasoning_effort = .minimal, .effort_flash = .minimal });
        defer narrow.deinit(a);
        try std.testing.expect(text.width(narrow.plain) <= @max(columns, 2));
    }
}

test "model keeps effort and TPS waves while context percent has static occupancy color" {
    const a = std.testing.allocator;
    const efforts = [_]shared.ReasoningEffort{ .unspecified, .unknown, .none, .minimal, .low, .medium, .high, .xhigh };
    for ([_]shared.activity.RateBand{ .slow, .standard, .fast, .unknown }) |band| {
        const palette = theme.modelPalette(band);
        for ([_]usize{ 0, 2, 11, std.math.maxInt(usize) }) |phase| {
            for ([_]u64{ 0, 80, 120 }) |now| {
                // Only the model flows; the complete percentage stays green
                // regardless of phase, rate, spinner time or configured effort.
                var expected: std.Io.Writer.Allocating = .init(a);
                defer expected.deinit();
                try expected.writer.writeAll("(");
                for ("model", 0..) |byte, ordinal| {
                    try expected.writer.print("{s}{c}", .{ palette[(phase % palette.len + ordinal) % palette.len], byte });
                }
                try expected.writer.print("{s} {s}2.3%{s}) {s} ", .{ theme.reset, theme.success, theme.reset, activity.spinner(now) });
                for (efforts) |effort| {
                    const value = try prompt(a, "model", .{ .tokens = 22807, .limit = 1000000 }, 79, .{ .busy = true, .now_ms = now, .phase = phase, .rate_band = band, .reasoning_effort = effort });
                    defer value.deinit(a);
                    try std.testing.expectEqualStrings(expected.written(), value.styled);
                    const plain = try std.fmt.allocPrint(a, "(model 2.3%) {s} ", .{activity.spinner(now)});
                    defer a.free(plain);
                    try std.testing.expectEqualStrings(plain, value.plain);
                    try std.testing.expect(std.mem.find(u8, value.plain, "ctx") == null and std.mem.find(u8, value.plain, "/") == null);
                }
            }
        }
    }
    for (efforts) |effort| {
        const color = theme.effortColor(effort);
        const idle = try prompt(a, "model", .{ .tokens = 1, .limit = 1000 }, 79, .{ .reasoning_effort = effort });
        defer idle.deinit(a);
        const expected = try std.fmt.allocPrint(a, "({s}model{s} {s}0.1%{s}) > ", .{ color, theme.reset, theme.success, theme.reset });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, idle.styled);
        try std.testing.expectEqualStrings("(model 0.1%) > ", idle.plain);
        const percent = try prompt(a, "", null, 79, .{ .reasoning_effort = effort });
        defer percent.deinit(a);
        const percent_expected = try a.dupe(u8, percent.plain);
        defer a.free(percent_expected);
        try std.testing.expectEqualStrings("(?%) > ", percent.plain);
        try std.testing.expectEqualStrings(percent_expected, percent.styled);
        for (0..12) |columns| {
            for ([_]bool{ false, true }) |busy| {
                const narrow = try prompt(a, "model", null, columns, .{ .busy = busy, .now_ms = 80, .reasoning_effort = effort });
                defer narrow.deinit(a);
                try std.testing.expectEqualStrings(if (busy) "⠙ " else "> ", narrow.plain);
                try std.testing.expectEqualStrings(narrow.plain, narrow.styled);
            }
        }
    }
}

test "all four tool prefixes rotate80ms while preserving independent120ms warm pulse" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_]activity.Tool{ .bash, .read, .write, .memory }) |kind| {
        const value: Caption = .{ .kind = kind, .label = "operation target" };
        const body = try commandText(a, value, .pending);
        defer a.free(body);
        const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }};
        for ([_]u64{ 0, 80, 120 }) |time| {
            const line = try commandLine(a, body, spans, 100, null, time);
            defer a.free(line);
            const prefix = try std.fmt.allocPrint(a, "{s}{s}{s} operation target{s}", .{ theme.command_pulse[shared.activity.commandStep(time)], activity.spinner(time), theme.muted, theme.reset });
            defer a.free(prefix);
            try std.testing.expectEqualStrings(prefix, line);
        }
        const done = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .success }}, 100, null, 120);
        defer a.free(done);
        const expected = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ theme.reset ++ theme.success, activity.icon(kind), theme.muted, body[activity.icon(kind).len..], theme.reset });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, done);
    }
    try std.testing.expectEqualStrings("r", activity.icon(.read));
    try std.testing.expectEqualStrings("w", activity.icon(.write));
    try std.testing.expectEqualStrings("m", activity.icon(.memory));
}

test "tool details survive old cutoffs and rows clip at80percent with complete clusters and dots" {
    try text.initLocale();
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    for ([_][]const u8{ "bash", "read_file", "write_file", "memory" }) |name| {
        const long_detail: [160]u8 = @splat('a');
        const args = if (std.mem.eql(u8, name, "bash")) try std.fmt.allocPrint(a, "{{\"command\":\"{s}\"}}", .{long_detail[0..]}) else if (std.mem.eql(u8, name, "memory")) try std.fmt.allocPrint(a, "{{\"action\":\"read\",\"topic\":\"{s}\"}}", .{long_detail[0..]}) else try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{long_detail[0..]});
        defer a.free(args);
        const value = try caption(a, name, args);
        defer value.deinit(a);
        try std.testing.expect(value.label.len >= 160);
        const body = try commandText(a, value, .pending);
        defer a.free(body);
        for ([_]usize{ 0, 1, 4, 10, 80, 200, 512 }) |columns| {
            const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }}, columns, null, 80);
            defer a.free(line);
            try std.testing.expect(output.displayWidth(line) <= commandColumns(columns));
            try std.testing.expect(std.unicode.utf8ValidateSlice(line));
            if (columns >= 10 and columns <= 200) try std.testing.expect(std.mem.endsWith(u8, line, "..." ++ theme.reset));
        }
    }
    const body = "r 中文é repeated-path 中文é repeated-path 中文é repeated-path";
    const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }}, 80, null, 120);
    defer a.free(line);
    try std.testing.expect(output.displayWidth(line) <= 64);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expectEqual(@as(usize, 80), commandColumns(100));
    try std.testing.expectEqual(@as(usize, 63), commandColumns(79));
    for (0..128) |columns| try std.testing.expectEqual(if (columns == 0) @as(usize, 0) else @max(@as(usize, 1), columns * 4 / 5), commandColumns(columns));
    try std.testing.expect(commandColumns(std.math.maxInt(usize)) <= std.math.maxInt(usize));
    const memory = try caption(a, "memory", "{\"action\":\"write\",\"topic\":\"core\",\"content\":\"hidden-body\"}");
    defer memory.deinit(a);
    try std.testing.expectEqualStrings("write core", memory.label);
    const missing = try caption(a, "memory", "{\"action\":\"invented\"}");
    defer missing.deinit(a);
    try std.testing.expectEqualStrings("(operation unavailable)", missing.label);
}

test "command duration stays last and inside the row width for every outcome" {
    try text.initLocale();
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    const cases = [_]struct { ms: u64, suffix: []const u8 }{
        .{ .ms = 7, .suffix = "7ms" },
        .{ .ms = 1234, .suffix = "1.23s" },
        .{ .ms = 62000, .suffix = "1m02s" },
        .{ .ms = std.math.maxInt(u64), .suffix = "307445734561825m51s" },
    };
    for ([_]Outcome{ .pending, .success, .failed, .canceled }) |outcome| {
        const body = try commandText(a, .{ .kind = .bash, .label = "echo 中文é very-long-command 中文é very-long-command 中文é tail" }, outcome);
        defer a.free(body);
        for (cases) |case| {
            const ending = try std.fmt.allocPrint(a, "  {s}{s}", .{ case.suffix, theme.reset });
            defer a.free(ending);
            for ([_]usize{ 0, 1, 7, 12, 16, 40, 79, 200 }) |columns| {
                const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }}, columns, case.ms, 120);
                defer a.free(line);
                try std.testing.expect(output.displayWidth(line) <= commandColumns(columns));
                try std.testing.expect(std.unicode.utf8ValidateSlice(line));
                if (commandColumns(columns) >= case.suffix.len + 6) try std.testing.expect(std.mem.endsWith(u8, line, ending));
            }
        }
    }
}

test "only pending command prefix pulses and completed spans remain static and clipped safely" {
    const a = std.testing.allocator;
    const body = "> sleep 1";
    const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }};
    const first = try commandLine(a, body, spans, 79, null, 0);
    defer a.free(first);
    const second = try commandLine(a, body, spans, 79, null, 120);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.find(u8, first, theme.command_pulse[0] ++ "⠋" ++ theme.muted ++ " sleep 1") != null);
    for ([_]Outcome{ .success, .failed, .canceled }) |outcome| {
        const complete = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }};
        const one = try commandLine(a, body, complete, 79, null, 0);
        defer a.free(one);
        const two = try commandLine(a, body, complete, 79, null, 1);
        defer a.free(two);
        try std.testing.expectEqualStrings(one, two);
    }
    const narrow = try commandLine(a, "r long-path", &.{CommandSpan{ .start = 0, .end = "r long-path".len, .outcome = .pending }}, 4, null, 1);
    defer a.free(narrow);
    try std.testing.expect(std.unicode.utf8ValidateSlice(narrow));
    try std.testing.expectEqualStrings(theme.muted ++ "..." ++ theme.reset, narrow);
}

test "long byte capped paths use complete clusters and only ascii truncation dots" {
    try text.initLocale();
    const a = std.testing.allocator;
    const suffix: [30]u8 = @splat('b');
    for ([_]usize{ 497, 510, 511 }) |count| {
        const start = try a.alloc(u8, count);
        defer a.free(start);
        @memset(start, 'a');
        const args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}é{s}\"}}", .{ start, suffix[0..] });
        defer a.free(args);
        const value = try caption(a, "read_file", args);
        defer value.deinit(a);
        try std.testing.expect(value.label.len <= 512);
        const body = try commandText(a, value, .success);
        defer a.free(body);
        const row = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .success }}, 1000, null, null);
        defer a.free(row);
        try std.testing.expect(std.mem.indexOf(u8, row, "[truncated]") == null);
        try std.testing.expect(std.mem.indexOf(u8, row, "e...") == null);
        try std.testing.expect(std.mem.indexOf(u8, row, "...") != null);
        if (count == 497) try std.testing.expect(std.mem.indexOf(u8, row, "é") != null);
    }
    const literal = try caption(a, "read_file", "{\"path\":\"literal[truncated]file\"}");
    defer literal.deinit(a);
    try std.testing.expectEqualStrings("literal[truncated]file", literal.label);
}

test "all tool outcome prefixes are colored without recoloring summaries or durations" {
    const a = std.testing.allocator;
    for ([_]activity.Tool{ .bash, .read, .memory, .write }) |kind| {
        for ([_]Outcome{ .success, .failed, .canceled }) |outcome| {
            const value: Caption = .{ .kind = kind, .label = "operation target" };
            const body = try commandText(a, value, outcome);
            defer a.free(body);
            const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }};
            const line = try commandLine(a, body, spans, 100, 250, 0);
            defer a.free(line);
            const color = switch (outcome) {
                .success => theme.success,
                .failed => theme.failure,
                .canceled => theme.caution,
                .pending => unreachable,
            };
            const expected = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}{s}{s}  250ms{s}", .{ theme.reset, color, activity.icon(kind), outcomeColor(outcome), body[activity.icon(kind).len..], theme.reset, theme.muted, theme.reset });
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, line);
            try std.testing.expect(!std.mem.eql(u8, theme.thinking, color));
            try std.testing.expect(!std.mem.eql(u8, theme.thinking, outcomeColor(outcome)));
            const clipped = try commandLine(a, body, spans, 4, 250, 0);
            defer a.free(clipped);
            const clipped_expected = try std.fmt.allocPrint(a, "{s}...{s}", .{ outcomeColor(outcome), theme.reset });
            defer a.free(clipped_expected);
            try std.testing.expectEqualStrings(clipped_expected, clipped);
        }
    }
}

test "individual command rows retain their icons and own outcome prefix colors" {
    const a = std.testing.allocator;
    const body = "> date [error]";
    const line = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 79, null, null);
    defer a.free(line);
    const success = "> pwd";
    const success_line = try commandLine(a, success, &.{.{ .start = 0, .end = success.len, .outcome = .success }}, 79, null, null);
    defer a.free(success_line);
    try std.testing.expect(std.mem.find(u8, line, theme.reset ++ theme.failure ++ ">" ++ theme.failure ++ " date [error]") != null);
    try std.testing.expect(std.mem.find(u8, success_line, theme.reset ++ theme.success ++ ">" ++ theme.muted ++ " pwd") != null);
    try std.testing.expect(std.mem.find(u8, line, "pwd") == null);
    try std.testing.expect(std.mem.find(u8, success_line, "date") == null);
    try std.testing.expect(std.mem.findScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, success_line, '\n') == null);
    const clipped = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 10, null, null);
    defer a.free(clipped);
    try std.testing.expect(std.mem.endsWith(u8, clipped, "..." ++ theme.reset));
}
