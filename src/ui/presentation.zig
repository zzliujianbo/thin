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
    // The same whole-cluster fit that bounds the row also decides whether the
    // ellipsis is needed; a byte cap or a cut source is still clipping metadata.
    const clipped = source_clipped or prefix.truncated or text.fitBytes(safe, columns) != safe.len;
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
    display: ?@import("../core/background_status.zig").Caption = null,

    pub fn deinit(self: Caption, a: std.mem.Allocator) void {
        a.free(self.label);
    }
};

/// Test-only: parse bounded canonical copies through the same shared Call path
/// the production callers (fromCall/fromToolView) use.
/// A normal tool row can exist before all arguments are available. Bash's >
/// marker identifies the tool; leave its body empty until a reliable command
/// exists. Other unknown targets retain the sanitized tool name.
pub fn fromToolView(a: std.mem.Allocator, name: []const u8, fields: @import("../core/tool_preview.zig").Snapshot) !Caption {
    const call = try shared.tools.Call.fromFields(a, name, fields);
    defer call.deinit(a);
    if (call.detail == null) return .{ .kind = call.kind, .label = if (call.kind == .bash) try a.dupe(u8, "") else try singleLine(a, name, 512) };
    return fromCall(a, call);
}

/// Replace a preview with the prepared, value-owned background metadata.
pub fn withBackground(a: std.mem.Allocator, value: Caption, display: @import("../core/background_status.zig").Caption) !Caption {
    var metadata = display;
    const label = if (metadata.action == .start) blk: {
        const command = if (metadata.command) |*cmd| cmd.slice() else "(command unavailable)";
        break :blk try std.fmt.allocPrint(a, "▶ {s}", .{command});
    } else blk: {
        const target = if (metadata.command) |*cmd| cmd.slice() else if (metadata.id) |*id| id.slice() else "";
        break :blk if (target.len == 0) try a.dupe(u8, @tagName(metadata.action)) else try std.fmt.allocPrint(a, "{s} {s}", .{ @tagName(metadata.action), target });
    };
    return .{ .kind = value.kind, .label = label, .failure_reason = value.failure_reason, .display = display };
}

/// Terminal widths and labels adapt shared structured data; no JSON parsing here.
pub fn fromCall(a: std.mem.Allocator, call: shared.tools.Call) !Caption {
    const kind = call.kind;
    if (call.display) |display| return withBackground(a, .{ .kind = kind, .label = "" }, display);
    if (kind == .other) return .{ .kind = kind, .label = try a.dupe(u8, "tool") };
    // Child status is a bare tool-name row, not a new panel or message body.
    if (kind == .parent_message) return .{ .kind = kind, .label = try a.dupe(u8, "message_parent") };
    const unavailable = switch (kind) {
        .bash => "(command unavailable)",
        .read, .write, .edit => "(file unavailable)",
        .memory => "(operation unavailable)",
        .subagent => "(task unavailable)",
        .subagent_id => "(id unavailable)",
        .parent_message => unreachable,
        .other => unreachable,
    };
    const detail = call.detail orelse return .{ .kind = kind, .label = try a.dupe(u8, unavailable) };
    // Preserve bounded detail until frame-time width is known; no old 32/72
    // cell path/command cutoff before applying the actual 95% row limit.
    return .{ .kind = kind, .label = try singleLineImpl(a, detail, 512, call.truncated) };
}

/// Add display-only subagent progress without changing the borrowed caption.
/// Strip terminal escape sequences before the common single-line sanitizer.
pub fn subagentProgress(a: std.mem.Allocator, value: Caption, progress: []const u8) !Caption {
    var result = value;
    if (value.kind != .subagent and value.kind != .subagent_id) {
        result.label = try a.dupe(u8, value.label);
        return result;
    }
    var buf: [512]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < progress.len and len < buf.len) {
        if (progress[i] == 0x1b) {
            i += 1;
            if (i == progress.len) break;
            const kind = progress[i];
            i += 1;
            if (kind == '[') {
                while (i < progress.len) {
                    const c = progress[i];
                    i += 1;
                    if (c >= 0x40 and c <= 0x7e) break;
                }
            } else if (kind == ']') {
                while (i < progress.len) {
                    if (progress[i] == 7) {
                        i += 1;
                        break;
                    }
                    if (progress[i] == 0x1b and i + 1 < progress.len and progress[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            }
            continue;
        }
        buf[len] = progress[i];
        len += 1;
        i += 1;
    }
    const note = std.mem.trim(u8, buf[0..len], " \t\r\n\x0b\x0c");
    if (note.len == 0) {
        result.label = try a.dupe(u8, value.label);
        return result;
    }
    const joined = try std.mem.concat(a, u8, &.{ value.label, " · ", note });
    defer a.free(joined);
    result.label = try singleLineImpl(a, joined, 512, i < progress.len);
    return result;
}

/// Numeric observations survive Bridge text clipping. Missing is ?, not zero.
/// This helper is called for successful results only; failures retain the path
/// but must not claim any uncompleted read/write or requested-content line count.
pub fn provisionalWrite(a: std.mem.Allocator, value: Caption, progress: @import("../core/write_preview.zig").Progress) !Caption {
    std.debug.assert(value.kind == .write);
    var marks: ?WriteMarks = null;
    const label = if (progress.added != null and progress.deleted != null) blk: {
        const added = value.label.len + "  ".len;
        const removed = added + 1 + decimalLength(progress.added.?) + 1;
        marks = .{ .added = .{ .start = added, .end = added + 1 + decimalLength(progress.added.?) }, .removed = .{ .start = removed, .end = removed + 1 + decimalLength(progress.deleted.?) } };
        break :blk try std.fmt.allocPrint(a, "{s}  +{d} -{d} preview", .{ value.label, progress.added.?, progress.deleted.? });
    } else try std.fmt.allocPrint(a, "{s}  +? -? preview", .{value.label});
    return .{ .kind = .write, .label = label, .write_marks = marks };
}

pub fn completed(a: std.mem.Allocator, value: Caption, stats: ?line_stats.File) !Caption {
    var marks: ?WriteMarks = null;
    const label = switch (value.kind) {
        .read => if (stats != null and stats.?.read != null)
            try std.fmt.allocPrint(a, "{s}  {d} lines{s}", .{ value.label, stats.?.read.?, if (stats.?.partial) " [partial]" else "" })
        else
            try std.fmt.allocPrint(a, "{s}  lines ?", .{value.label}),
        .write, .edit => if (stats != null and stats.?.changes != null) blk: {
            const c = stats.?.changes.?;
            const added = value.label.len + "  ~".len + decimalLength(c.modified) + 1;
            const removed = added + 1 + decimalLength(c.added) + 1;
            marks = .{ .added = .{ .start = added, .end = added + 1 + decimalLength(c.added) }, .removed = .{ .start = removed, .end = removed + 1 + decimalLength(c.removed) } };
            break :blk try std.fmt.allocPrint(a, "{s}  ~{d} +{d} -{d} lines", .{ value.label, c.modified, c.added, c.removed });
        } else try std.fmt.allocPrint(a, "{s}  changes ?", .{value.label}),
        else => try a.dupe(u8, value.label),
    };
    return .{ .kind = value.kind, .label = label, .write_marks = marks, .display = value.display };
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
        .pending => "", // Before execution: neutral; the running icon breathes on its own.
        .success => theme.success,
        .failed => theme.failure,
        .canceled => theme.caution,
    };
}

/// Composer busy marker palette; tool rows breathe with `theme.toolIconColor`.
fn activeIndicatorColor(now_ms: u64) []const u8 {
    return theme.command_pulse[shared.activity.commandStep(now_ms)];
}

pub const CommandSpan = struct { start: usize, end: usize, outcome: Outcome, write_marks: ?WriteMarks = null, generating: bool = false };

pub fn commandText(a: std.mem.Allocator, value: Caption, outcome: Outcome) ![]const u8 {
    const reason = if (outcome == .failed) value.failure_reason orelse "" else "";
    return std.fmt.allocPrint(a, "{s} {s}{s}{s}{s}", .{ if (value.display != null) "B:" else activity.icon(value.kind), value.label, switch (outcome) {
        .failed => " [error]",
        .canceled => " [canceled]",
        else => "",
    }, if (reason.len != 0) " " else "", reason });
}

/// Bytes at the end of `commandText` carrying the outcome marker and its bounded
/// reason. The renderer keeps them out of the clipped label, so a failure reason
/// never degrades into a lone `[error]` fragment.
pub fn commandSuffixLen(value: Caption, outcome: Outcome) usize {
    const marker: usize = switch (outcome) {
        .failed => " [error]".len,
        .canceled => " [canceled]".len,
        else => return 0,
    };
    const reason = if (outcome == .failed) value.failure_reason orelse "" else "";
    return marker + @intFromBool(reason.len != 0) + reason.len;
}

/// Caption bodies are already sanitized, and spans are renderer-owned offsets.
/// Clip BEFORE SGR so no partial escapes; mixed outcomes keep independent colors.
pub fn commandColumns(columns: usize) usize {
    // Overflow-safe floor(95%), including very narrow frames.
    return if (columns == 0) 0 else @max(1, columns / 20 * 19 + columns % 20 * 19 / 20);
}

/// `duration_ms` is the measured wall-clock execution time of this row. It is
/// rendered last, in muted color, so it survives label clipping and never
/// competes with the outcome color or diff marks. `active_time_ms` is the icon
/// breathing clock only; the two are deliberately independent. `keep_tail` is
/// the byte offset of the outcome suffix (` [error] reason`), which is reserved
/// before the label is clipped; zero keeps the whole body clip-able.
pub fn commandLine(a: std.mem.Allocator, body: []const u8, spans: []const CommandSpan, columns: usize, duration_ms: ?u64, active_time_ms: ?u64, keep_tail: usize) ![]const u8 {
    // Detail stays <=512 bytes; allow its prefix and bounded observed counts
    // without sanitizing/truncating the same path a second time at512 bytes.
    // Reserve the suffix inside the existing 95% limit, not after clipping.
    // On tiny terminals omit optional time rather than wrapping the command.
    var duration_buf: [32]u8 = undefined;
    var duration_writer = std.Io.Writer.fixed(&duration_buf);
    if (duration_ms) |ms| {
        try duration_writer.writeAll("  ");
        try shared.activity.formatDuration(&duration_writer, ms);
    }
    const limit = commandColumns(columns);
    // The outcome tail (` [error] reason`) is reserved before the label is
    // clipped: a narrow row shortens the target, never the reason.
    var tail: []const u8 = if (keep_tail != 0 and keep_tail < body.len) body[keep_tail..] else "";
    if (tail.len != 0) {
        // Keep a little room for the clipped target; when even that is gone, fall
        // back to the bare marker and finally to nothing at all.
        const marker: usize = if (std.mem.startsWith(u8, tail, " [canceled]")) " [canceled]".len else " [error]".len;
        if (text.width(tail) + 4 > limit) tail = tail[0..@min(tail.len, marker)];
        if (text.width(tail) + 4 > limit) tail = "";
    }
    const tail_width = text.width(tail);
    const suffix = if (duration_ms != null and limit >= tail_width + duration_writer.buffered().len + 4) duration_writer.buffered() else "";
    const head = if (tail.len == 0) body else body[0..keep_tail];
    const safe = try boundedLine(a, head, limit -| tail_width -| suffix.len, false, 640);
    defer a.free(safe);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var at: usize = 0;
    var tail_written = false;
    for (spans) |span| {
        const begin = @min(@max(at, span.start), safe.len);
        const end = @min(@max(begin, span.end), safe.len);
        try out.writer.writeAll(safe[at..begin]);
        const prefix_end = if (begin < end) @min(text.nextCluster(safe, begin, 0).end, end) else begin;
        // Never turn clipped ellipsis bytes into a phantom running tool icon.
        const has_prefix = begin == span.start and begin < body.len and std.mem.eql(u8, safe[begin..prefix_end], body[begin..text.nextCluster(body, begin, 0).end]);
        // An executing call keeps its own icon: only its brightness breathes, so
        // glyph, column and cell width match the finished row exactly. A row that
        // is still generating arguments (or awaiting approval) is not executing,
        // so it stays neutral and static instead of claiming a running call.
        if (span.outcome == .pending and active_time_ms != null and has_prefix) {
            const indicator = if (span.generating) theme.muted else theme.toolIconColor(active_time_ms.?);
            try out.writer.print("{s}{s}{s}", .{ indicator, safe[begin..prefix_end], theme.muted });
            if (span.generating and span.write_marks != null) {
                var cursor = prefix_end;
                const marks = span.write_marks.?;
                const ranges = [_]Range{ marks.added, marks.removed };
                const colors = [_][]const u8{ theme.diff_added, theme.diff_removed };
                for (ranges, colors) |range, tone| {
                    if (range.start < cursor or range.end < range.start or range.end > end or range.end > body.len or !std.mem.eql(u8, safe[range.start..range.end], body[range.start..range.end])) continue;
                    try out.writer.print("{s}{s}{s}{s}", .{ safe[cursor..range.start], tone, safe[range.start..range.end], theme.muted });
                    cursor = range.end;
                }
                try out.writer.print("{s}{s}", .{ safe[cursor..end], theme.reset });
            } else try out.writer.print("{s}{s}", .{ safe[prefix_end..end], theme.reset });
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
            // The outcome tail shares the last span's color, so a failed row
            // still reads as one `[error] reason` run in the same SGR context.
            if (tail.len != 0 and end == safe.len) {
                try out.writer.print("{s}{s}{s}", .{ safe[cursor..end], tail, theme.reset });
                tail_written = true;
            } else try out.writer.print("{s}{s}", .{ safe[cursor..end], theme.reset });
        }
        at = end;
        if (at == safe.len) break;
    }
    try out.writer.writeAll(safe[at..]);
    if (tail.len != 0 and !tail_written) try out.writer.print("{s}{s}{s}", .{ outcomeColor(if (spans.len != 0) spans[spans.len - 1].outcome else .pending), tail, theme.reset });
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

// Preserve exact palette/layout goldens independently of the added weight.

pub const PromptActivity = struct {
    busy: bool = false,
    now_ms: u64 = 0,
    phase: usize = 0,
    rate_band: shared.activity.RateBand = .unknown,
    reasoning_effort: shared.ReasoningEffort = .unspecified,
    /// Transient level confirmation: temporarily replaces the context percentage
    /// in the prefix with the chosen level name; the owner expires it.
    effort_flash: ?shared.ReasoningEffort = null,
    /// Owner says tiered-price protection is active for the selected model;
    /// not merely the global toggle, and never inferred from latest usage.
    low_price_input: bool = false,
};

/// The model keeps idle effort/busy TPS styling; context occupancy has a static
/// threshold color in both states. A transient effort confirmation retains its
/// previous styling. Only the busy marker shares the tool indicator pulse;
/// parentheses, spaces, idle marker and editor stay default.
pub fn prompt(a: std.mem.Allocator, model: []const u8, snapshot: ?shared.ContextSnapshot, columns: usize, motion: PromptActivity) !Prompt {
    const base = try promptLayout(a, model, snapshot, columns, motion);
    defer a.free(base.styled);
    errdefer a.free(base.plain);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const bold = "\x1b[1m";
    try out.writer.writeAll(bold);
    // Keep all existing colors and restore weight after their full SGR resets.
    // The final separator/editor must start in the terminal's default style.
    var spans = std.mem.splitSequence(u8, base.styled[0 .. base.styled.len - 1], theme.reset);
    try out.writer.writeAll(spans.first());
    while (spans.next()) |span| {
        try out.writer.writeAll(theme.reset);
        if (span.len != 0) try out.writer.print("{s}{s}", .{ bold, span });
    }
    if (!std.mem.endsWith(u8, base.styled[0 .. base.styled.len - 1], theme.reset)) try out.writer.writeAll(theme.reset);
    try out.writer.writeAll(" ");
    return .{ .plain = base.plain, .styled = try a.dupe(u8, out.written()) };
}

fn promptLayout(a: std.mem.Allocator, model: []const u8, snapshot: ?shared.ContextSnapshot, columns: usize, motion: PromptActivity) !Prompt {
    if (model.len == 0) {
        const plain = try std.fmt.allocPrint(a, "{s} ", .{if (motion.busy) activity.spinner(motion.now_ms) else ">"});
        errdefer a.free(plain);
        return .{ .plain = plain, .styled = try a.dupe(u8, plain) };
    }
    const value = if (motion.effort_flash) |level|
        try a.dupe(u8, level.name() orelse "?")
    else
        try contextLabel(a, snapshot);
    defer a.free(value);
    const percentage = try std.fmt.allocPrint(a, "{s}{s}", .{ if (motion.low_price_input) "L" else "", value });
    defer a.free(percentage);
    const marker = if (motion.busy) activity.spinner(motion.now_ms) else ">";
    const reserve: usize = @min(@as(usize, 24), columns / 3);
    const room: usize = columns -| (reserve + 5 + text.width(percentage));
    const label = try singleLine(a, model, if (columns < 12) 0 else room);
    defer a.free(label);
    const percent_only = columns >= 12 and label.len == 0 and text.width(percentage) + 2 + reserve <= columns;
    const plain = if (label.len != 0)
        try std.fmt.allocPrint(a, "({s}) {s}{s} ", .{ label, percentage, marker })
    else if (percent_only)
        try std.fmt.allocPrint(a, "{s}{s} ", .{ percentage, marker })
    else
        try std.fmt.allocPrint(a, "{s} ", .{marker});
    errdefer a.free(plain);
    const idle_color = theme.effortColor(motion.reasoning_effort);
    const slot_flow = motion.busy and motion.effort_flash != null;
    const context_color = theme.contextColor(if (snapshot) |current| shared.state.contextRatio(current) else null);
    const slot_color = if (motion.effort_flash != null) idle_color else context_color;
    const styled_model = label.len != 0 and (motion.busy or !std.mem.eql(u8, idle_color, theme.reset));
    const styled_slot = slot_flow or !std.mem.eql(u8, slot_color, theme.reset) or (motion.low_price_input and !std.mem.eql(u8, context_color, theme.reset));
    if (!motion.busy and ((label.len == 0 and !percent_only) or (!styled_model and !styled_slot))) return .{ .plain = plain, .styled = try a.dupe(u8, plain) };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const palette = theme.modelPalette(motion.rate_band);
    var ordinal: usize = 0;
    if (label.len != 0 or percent_only) {
        if (label.len != 0) {
            try out.writer.writeAll("(");
            if (motion.busy) {
                try flowText(&out.writer, label, palette, motion.phase, &ordinal);
                try out.writer.writeAll(theme.reset);
            } else try out.writer.print("{s}{s}{s}", .{ idle_color, label, theme.reset });
            try out.writer.writeAll(") ");
            ordinal += 1;
        }
        // A transient effort flash keeps its own styling, but must never turn
        // the policy marker into a TPS animation or a reasoning-level color.
        const separate_marker = motion.low_price_input and motion.effort_flash != null;
        if (separate_marker) {
            try out.writer.print("{s}L{s}", .{ context_color, theme.reset });
            ordinal += 1;
        }
        const slot = if (separate_marker) value else percentage;
        if (slot_flow) {
            try flowText(&out.writer, slot, palette, motion.phase, &ordinal);
            try out.writer.writeAll(theme.reset);
        } else try out.writer.print("{s}{s}{s}", .{ slot_color, slot, theme.reset });
    }
    if (motion.busy) {
        try out.writer.print("{s}{s}{s} ", .{ activeIndicatorColor(motion.now_ms), marker, theme.reset });
    } else try out.writer.print("{s} ", .{marker});
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

// Test-only: the visible text of a rendered row, with renderer-owned SGR removed.
