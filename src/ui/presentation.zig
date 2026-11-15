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
    /// Bounded, sanitized reason from shared tools. Owned by whoever set it, not
    /// by this caption; the row clips it again to the terminal width.
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
    // cell path/command cutoff before applying the actual full-width row limit.
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
        .pending => theme.muted, // Approval/generation slots stay neutral.
        .success => theme.success,
        .failed => theme.failure,
        .canceled => theme.caution,
    };
}

/// The settled status slot mirrors the result at the old spinner column. The
/// one-column slot is never removed, so the tool name and command do not shift.
pub fn statusGlyph(outcome: Outcome) []const u8 {
    return switch (outcome) {
        .pending => " ",
        .success => "\u{2713}",
        .failed => "\u{2717}",
        .canceled => "-",
    };
}

/// Composer busy marker palette; executing tool rows pulse the same phase and
/// colour at the status slot, then leave the command band to the row flow.
fn activeIndicatorColor(now_ms: u64) []const u8 {
    return theme.command_pulse[shared.activity.commandStep(now_ms)];
}

pub const CommandSpan = struct {
    start: usize,
    end: usize,
    outcome: Outcome,
    write_marks: ?WriteMarks = null,
    generating: bool = false,
    /// Byte offset where the command text begins. The slot and tool name before
    /// it keep their own colours and do not join the running flow. Zero means
    /// this span has no structured name prefix.
    label_start: usize = 0,
    /// Flow phase in milliseconds for a running row, already stepped by the
    /// owner. Null keeps the historical wall-clock phase for direct renderer
    /// callers that do not own an animation clock.
    flow_elapsed_ms: ?u64 = null,
};

/// Split a caption label into the separator after the tool name and the text
/// that actually follows it. An unavailable detail is the tool name itself;
/// provisional counts append two spaces to it, so neither repeats the name.
const LabelParts = struct { sep: []const u8, text: []const u8 };
fn labelParts(name: []const u8, label: []const u8) LabelParts {
    if (label.len == 0) return .{ .sep = "", .text = "" };
    if (std.mem.eql(u8, label, name)) return .{ .sep = "", .text = "" };
    if (label.len >= name.len + 2 and std.mem.startsWith(u8, label, name) and label[name.len] == ' ' and label[name.len + 1] == ' ')
        return .{ .sep = "", .text = label[name.len..] };
    return .{ .sep = " ", .text = label };
}

/// `indicator` fills the fixed one-column status slot while the call is pending
/// (the dot-matrix spinner during execution, a space for approval/generation).
/// A settled row replaces it with its outcome glyph in the same column, so the
/// tool name and command never shift. The glyph carries the outcome colour via
/// the same prefix span used by the renderer.
pub fn commandText(a: std.mem.Allocator, value: Caption, outcome: Outcome, indicator: []const u8) ![]const u8 {
    const name = activity.toolName(value.kind);
    const parts = labelParts(name, value.label);
    return std.fmt.allocPrint(a, "{s} {s}{s}{s}{s}", .{
        if (outcome == .pending) indicator else statusGlyph(outcome),
        name,
        parts.sep,
        if (value.display != null) "B: " else "",
        parts.text,
    });
}

/// One-row failure detail rendered below a failed command row. `reason` stays
/// raw on the record so a width change re-clips it instead of keeping stale cuts.
/// The first two columns stay empty to keep the status slot aligned; the branch
/// icon then marks the reason as a detail of the row above. Narrow rows drop the
/// icon, then the indent, instead of overflowing.
pub fn failureReasonLine(a: std.mem.Allocator, reason: []const u8, columns: usize) ![]const u8 {
    const branch = "  \u{21b3} ";
    const indent: []const u8 = if (columns > text.width(branch)) branch else if (columns > 2) "  " else "";
    const width = @max(1, columns -| text.width(indent));
    const line = try singleLine(a, reason, width);
    defer a.free(line);
    return std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ theme.failure, indent, line, theme.reset });
}

/// One muted task-summary row below a terminal outcome: files edited, tool
/// calls and wall-clock time. Stays a styled display line, never part of a
/// sanitized notice body.
pub fn taskSummaryLine(a: std.mem.Allocator, tool_calls: u32, files_edited: u32, duration_ms: u64, columns: usize) ![]const u8 {
    var buffer: [160]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("  \u{00b7} ");
    try writer.print("{d} {s} changed \u{00b7} {d} {s} \u{00b7} ", .{
        files_edited,
        if (files_edited == 1) "file" else "files",
        tool_calls,
        if (tool_calls == 1) "tool call" else "tool calls",
    });
    try shared.activity.formatDuration(&writer, duration_ms);
    const line = try singleLine(a, writer.buffered(), columns);
    defer a.free(line);
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ theme.muted, line, theme.reset });
}

/// Byte length of the fixed prefix `commandText` writes before its label; used
/// to shift label-relative diff marks onto the rendered row. Settled rows use
/// their status glyph; pending callers supply the exact indicator they passed
/// to `commandText` (a braille spinner or one space).
pub fn commandPrefixLen(value: Caption, outcome: Outcome, indicator: []const u8) usize {
    const name = activity.toolName(value.kind);
    const parts = labelParts(name, value.label);
    const slot = if (outcome == .pending) indicator else statusGlyph(outcome);
    return slot.len + 1 + name.len + parts.sep.len + @intFromBool(value.display != null) * "B: ".len;
}

/// Caption bodies are already sanitized, and spans are renderer-owned offsets.
/// Clip BEFORE SGR so no partial escapes; mixed outcomes keep independent colors.
pub fn commandColumns(columns: usize) usize {
    // The row owns the full terminal width; only a zero-width frame has none.
    return columns;
}

/// One bright band bounces across the command body: the head column is
/// brightest and the band fades behind the moving head. Only foreground color
/// changes between frames, so no cluster, column or cell width moves; at either
/// edge the head reverses instead of leaving the row dark. The caller starts
/// after the status slot and tool name, so neither joins the sweep.
fn writeFlow(writer: *std.Io.Writer, row: []const u8, begin: usize, end: usize, now_ms: u64) !void {
    // Bounce over the visible command, not the whole terminal: a short caption
    // keeps its band moving instead of spending most of the cycle in empty
    // columns.
    const head = shared.activity.flowHead(now_ms, @max(1, text.width(row[begin..end])));
    var column: usize = 0;
    var tone: []const u8 = "";
    var at = begin;
    while (at < end) {
        const cluster = text.nextCluster(row, at, column);
        const stop = @min(cluster.end, end);
        const next = flowTone(column, head);
        if (!std.mem.eql(u8, next, tone)) {
            try writer.writeAll(next);
            tone = next;
        }
        try writer.writeAll(row[at..stop]);
        column += cluster.width;
        at = stop;
    }
}

/// The band trails the head: to the left on a forward sweep, to the right when
/// the head travels back, so the brightest column always faces the motion.
fn flowTone(column: usize, head: shared.activity.FlowHead) []const u8 {
    const offset = if (head.backward) column -| head.column else head.column -| column;
    const within = if (head.backward) column >= head.column else head.column >= column;
    return if (within and offset < theme.flow_band.len) theme.flow_band[offset] else theme.muted;
}

/// `duration_ms` is the measured wall-clock execution time of this row. It is
/// rendered last, in muted color, so it survives label clipping and never
/// competes with the outcome color or diff marks. `active_time_ms` drives both
/// the status-slot pulse and the command band; settled rows ignore it. Outcome
/// glyphs live only in the fixed status slot, so the whole body stays clip-able
/// and no trailing marker is reserved. A failed call's reason lives on its own
/// row below, never in this line.
pub fn commandLine(a: std.mem.Allocator, body: []const u8, spans: []const CommandSpan, columns: usize, duration_ms: ?u64, active_time_ms: ?u64) ![]const u8 {
    // Detail stays <=512 bytes; allow its prefix and bounded observed counts
    // without sanitizing/truncating the same path a second time at512 bytes.
    // Reserve the suffix inside the existing full-width limit, not after clipping.
    // On tiny terminals omit optional time rather than wrapping the command.
    var duration_buf: [32]u8 = undefined;
    var duration_writer = std.Io.Writer.fixed(&duration_buf);
    if (duration_ms) |ms| {
        try duration_writer.writeAll("  ");
        try shared.activity.formatDuration(&duration_writer, ms);
    }
    const limit = commandColumns(columns);
    // The duration is optional; it never wraps the command onto another row.
    const suffix: []const u8 = if (duration_ms != null and limit >= 4 + duration_writer.buffered().len) duration_writer.buffered() else "";
    const safe = try boundedLine(a, body, limit -| suffix.len, false, 640);
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
        const running = span.outcome == .pending and active_time_ms != null and !span.generating and has_prefix;
        // The status slot owns its own colour. A running row pulses exactly like
        // the composer's dot matrix; settled rows use the outcome colour.
        if (has_prefix) {
            const slot_color = if (span.outcome == .pending)
                (if (running) activeIndicatorColor(active_time_ms.?) else theme.muted)
            else
                prefixColor(span.outcome);
            try out.writer.print("{s}{s}{s}", .{ theme.reset, slot_color, safe[begin..prefix_end] });
        }
        const name_begin = if (has_prefix) prefix_end else begin;
        // The tool name has its own colour and never joins the command flow.
        // A clipped row has no reliable name boundary, so it stays one color.
        const name_end = if (has_prefix and span.label_start != 0) @min(@max(span.label_start, name_begin), end) else name_begin;
        if (name_end > name_begin) try out.writer.print("{s}{s}", .{ theme.tool_name, safe[name_begin..name_end] });
        const command_begin = name_end;
        if (running) {
            const flow_ms = span.flow_elapsed_ms orelse active_time_ms.?;
            if (command_begin < end) try writeFlow(&out.writer, safe, command_begin, end, flow_ms);
            try out.writer.writeAll(theme.reset);
        } else if (span.generating) {
            try out.writer.writeAll(theme.muted);
            var cursor = command_begin;
            if (span.write_marks) |marks| {
                const ranges = [_]Range{ marks.added, marks.removed };
                const colors = [_][]const u8{ theme.diff_added, theme.diff_removed };
                for (ranges, colors) |range, tone| {
                    if (range.start < cursor or range.end < range.start or range.end > end or range.end > body.len or !std.mem.eql(u8, safe[range.start..range.end], body[range.start..range.end])) continue;
                    try out.writer.print("{s}{s}{s}{s}", .{ safe[cursor..range.start], tone, safe[range.start..range.end], theme.muted });
                    cursor = range.end;
                }
            }
            try out.writer.print("{s}{s}", .{ safe[cursor..end], theme.reset });
        } else {
            const color = outcomeColor(span.outcome);
            try out.writer.writeAll(color);
            var cursor = command_begin;
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
    if (suffix.len != 0) try out.writer.print("{s}{s}{s}", .{ theme.duration, suffix, theme.reset });
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
    /// Tokens are arriving now. The flowing model label exists only for this
    /// state; a busy turn without output keeps the static styling.
    streaming: bool = false,
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
    const styled_model = label.len != 0 and (motion.streaming or !std.mem.eql(u8, idle_color, theme.reset));
    const styled_slot = slot_flow or !std.mem.eql(u8, slot_color, theme.reset) or (motion.low_price_input and !std.mem.eql(u8, context_color, theme.reset));
    if (!motion.busy and ((label.len == 0 and !percent_only) or (!styled_model and !styled_slot))) return .{ .plain = plain, .styled = try a.dupe(u8, plain) };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const palette = theme.modelPalette(motion.rate_band);
    var ordinal: usize = 0;
    if (label.len != 0 or percent_only) {
        if (label.len != 0) {
            try out.writer.writeAll("(");
            if (motion.streaming) {
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
