//! Untrusted displayable checkpoint payload, NOT diagnostic JSONL.
//! Decode checks representability only. validateRequestHistory is a separate,
//! mandatory pre-send check against the actual current request.
//! No credentials, authorization grants, I/O or model execution live here.
const std = @import("std");
const p = @import("protocol.zig");
const cfg = @import("config.zig");
const context = @import("context.zig");
const llm = @import("../llm/llm.zig");
const common = @import("../llm/common.zig");
const chat = @import("../llm/chat.zig");
const responses = @import("../llm/responses.zig");
const anthropic = @import("../llm/anthropic.zig");
const j = @import("../util/json.zig");
const json_bound = @import("../app/json_bound.zig");
const Allocator = std.mem.Allocator;

pub const State = struct {
    version: u32 = 2,
    /// Tool-prefix provenance only, never configuration or send authority.
    tool_schema_hash: ?[32]u8 = null,
    system: []const u8,
    messages: []const p.Message,
    selector: llm.Selector,
    estimator: context.Estimator,
    last_context_tokens: ?u64,
    /// Archived display/resave metadata; never overrides current declarations.
    context_tokens: ?u32 = null,
    /// UI provenance only; the parent Session owns saving/restoring this flag.
    context_official: bool = false,
    /// Archived output metadata, not permission to change current output policy.
    output_tokens: ?u32 = null,
    output_source: cfg.ReasoningSource = .explicit,
    output_budget_frozen: bool = false,
    /// Archived input metadata for display/resave, not a trusted runtime policy.
    input_budget_frozen: bool = false,
    input_price_threshold: ?u32 = null,
    input_price_flat_limit: ?u32 = null,
    low_price_input: bool = false,
    permission_id: u64,
    poisoned: bool = false,
    /// Observer continuity only; the Runtime never treats these as authority.
    journal_seq: u64 = 0,
    journal_turn: u64 = 0,
    /// Display-only line counts for resumed tool rows. Never model input, replay
    /// data or send authority; absent in older checkpoints.
    tool_stats: ?[]const ToolStat = null,
};

/// One saved row's file-change counters, keyed by the canonical tool call id.
pub const ToolStat = struct {
    call_id: []const u8,
    modified: u64 = 0,
    added: u64 = 0,
    removed: u64 = 0,
};

pub const max_tool_stats = 256;
pub const max_tool_stat_id = 128;

// Count escaped output before allocating the exact encoded size.
const Counter = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    count: usize = 0,
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Counter = @fieldParentPtr("writer", w);
        const n = std.Io.Writer.countSplat(data, splat);
        self.count = std.math.add(usize, self.count, n) catch return error.WriteFailed;
        return n;
    }
};

fn encodedSize(state: State) !usize {
    try basic(state);
    var counter = Counter{};
    std.json.Stringify.value(state, .{ .emit_null_optional_fields = true }, &counter.writer) catch return error.InputLimit;
    return counter.count;
}

pub fn encode(a: Allocator, state: State) ![]u8 {
    try basic(state);
    var allocating = std.Io.Writer.Allocating.init(a);
    defer allocating.deinit();
    std.json.Stringify.value(state, .{ .emit_null_optional_fields = true }, &allocating.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return allocating.toOwnedSlice();
}

// Check UTF-8 and basic bracket balance before strict JSON parsing.
fn preflight(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var quoted = false;
    var escaped = false;
    var depth: usize = 0;
    for (bytes) |b| {
        if (quoted) {
            if (escaped) escaped = false else if (b == '\\') escaped = true else if (b == '"') quoted = false;
        } else switch (b) {
            '"' => quoted = true,
            '{', '[' => {
                depth = std.math.add(usize, depth, 1) catch return error.InputLimit;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    if (quoted or depth != 0) return error.InvalidJson;
}

fn strictJson(a: Allocator, bytes: []const u8) !std.json.Parsed(j.Value) {
    try preflight(bytes);
    try json_bound.validate(a, bytes);
    return std.json.parseFromSlice(j.Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    });
}

// std.json accepts numeric strings and integral floats for integer fields, and
// integer enum values. Require the actual DTO JSON types before typed decoding.
fn shape(comptime T: type, v: j.Value) !void {
    switch (@typeInfo(T)) {
        .int => {
            if (v != .number_string or v.number_string.len == 0) return error.InvalidType;
            for (v.number_string) |b| if (b < '0' or b > '9') return error.InvalidType;
            _ = std.fmt.parseInt(T, v.number_string, 10) catch return error.InvalidType;
        },
        .bool => if (v != .bool) return error.InvalidType,
        .@"enum" => if (v != .string) return error.InvalidType,
        .optional => |info| if (v != .null) try shape(info.child, v),
        .pointer => |info| {
            if (info.child == u8) {
                if (v != .string) return error.InvalidType;
                if (!std.unicode.utf8ValidateSlice(v.string)) return error.InvalidUtf8;
            } else {
                if (v != .array) return error.InvalidType;
                for (v.array.items) |item| try shape(info.child, item);
            }
        },
        .array => |info| {
            // std.json renders UTF-8 byte arrays as fixed-length strings.
            if (info.child == u8 and v == .string) {
                if (v.string.len != info.len) return error.InvalidType;
                return;
            }
            if (v != .array or v.array.items.len != info.len) return error.InvalidType;
            for (v.array.items) |item| try shape(info.child, item);
        },
        .@"struct" => |info| {
            if (v != .object) return error.InvalidType;
            inline for (info.field_names) |name| {
                if (!v.object.contains(name)) return error.MissingField;
            }
            var it = v.object.iterator();
            while (it.next()) |kv| {
                inline for (info.field_names, info.field_types) |name, FT| {
                    if (std.mem.eql(u8, name, kv.key_ptr.*)) {
                        try shape(FT, kv.value_ptr.*);
                        break;
                    }
                } else return error.UnknownField;
            }
        },
        .@"union" => |info| {
            if (v != .object or v.object.count() != 1) return error.InvalidType;
            var it = v.object.iterator();
            const kv = it.next().?;
            inline for (info.field_names, info.field_types) |name, FT| {
                if (std.mem.eql(u8, name, kv.key_ptr.*)) {
                    try shape(FT, kv.value_ptr.*);
                    return;
                }
            }
            return error.UnknownField;
        },
        else => @compileError("unsupported checkpoint type"),
    }
}

pub fn decode(a: Allocator, bytes: []const u8) !std.json.Parsed(State) {
    var tree = try strictJson(a, bytes);
    defer tree.deinit();
    // v2 formerly persisted these policy fields at the top level. Validate
    // their original types before removing only these known retired keys.
    if (tree.value == .object) {
        if (tree.value.object.get("max_input_tokens")) |v| try shape(?u32, v);
        if (tree.value.object.get("input_margin_tokens")) |v| try shape(u32, v);
        _ = tree.value.object.swapRemove("max_input_tokens");
        _ = tree.value.object.swapRemove("input_margin_tokens");
        // Display-only metadata added later: an older checkpoint simply has no
        // such rows, and must still resume.
        if (!tree.value.object.contains("tool_stats")) try tree.value.object.put(tree.arena.allocator(), "tool_stats", .null);
    }
    try shape(State, tree.value);
    const parsed = try std.json.parseFromValue(State, a, tree.value, .{});
    errdefer parsed.deinit();
    try basic(parsed.value);
    return parsed;
}

fn utf8(s: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
}

fn basic(state: State) !void {
    if (state.version != 2) return error.UnsupportedVersion;
    try utf8(state.system);
    if (state.tool_stats) |stats| {
        if (stats.len > max_tool_stats) return error.InputLimit;
        for (stats) |stat| {
            try utf8(stat.call_id);
            if (stat.call_id.len == 0 or stat.call_id.len > max_tool_stat_id) return error.InvalidHistory;
        }
    }
    for (state.messages) |m| {
        if (m.replay) |r| {
            try utf8(r.scope.connection);
            try utf8(r.scope.model);
            try utf8(r.json);
        }
        for (m.blocks) |b| switch (b) {
            .text, .reasoning => |s| try utf8(s),
            .tool_call => |c| {
                try utf8(c.id);
                try utf8(c.name);
                try utf8(c.arguments);
                if (c.item_id) |id| try utf8(id);
            },
            .tool_result => |r| {
                try utf8(r.call_id);
                try utf8(r.text);
            },
        };
    }
}

/// Structural bounds for owned copying or saving, never a request permission.
pub fn validateStructure(state: State) !void {
    _ = try encodedSize(state);
}

/// Validate the ACTUAL request, independent of persisted selectors, budgets or
/// poison flags. Used before every model boundary, including fake models.
pub fn validateRequestHistory(a: Allocator, req: p.Request) !void {
    const proto = req.scope.protocol;
    if (proto == .auto) return error.InvalidSelector;
    if (proto == .systemone) return error.SystemOneNotChatModel;
    try basic(.{ .system = req.system, .messages = req.messages, .selector = llm.Selector.init(proto), .estimator = .{}, .last_context_tokens = null, .permission_id = 0 });
    try common.validateRequest(req, proto);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    var ids = std.StringHashMap(void).init(t);
    for (req.messages) |m| {
        if (m.role == .tool and m.blocks.len == 0) return error.InvalidHistory;
        for (m.blocks) |b| switch (b) {
            .text => if (m.role == .tool) return error.InvalidHistory,
            .reasoning => if (m.role != .assistant) return error.InvalidHistory,
            .tool_call => |call| {
                if (m.role != .assistant or call.name.len == 0) return error.InvalidHistory;
                if (proto != .responses and call.item_id != null) return error.InvalidHistory;
                try common.checkUnique(&ids, call.id);
                const args = try strictJson(t, call.arguments);
                if (args.value != .object) return error.InvalidToolArguments;
            },
            .tool_result => if (m.role != .tool) return error.InvalidHistory,
        };
        if (m.replay) |r| {
            const native = try strictJson(t, r.json);
            switch (proto) {
                .chat => try validateChat(t, m, native.value),
                .responses => try validateResponses(t, m),
                .anthropic => {
                    const blocks = try anthropic.nativeBlocks(t, native.value);
                    if (!r.retain_turn or blocks.len != m.blocks.len) return error.NativeMismatch;
                    for (blocks, m.blocks) |x, y| if (!sameBlock(x, y)) return error.NativeMismatch;
                },
                .auto, .systemone => unreachable,
            }
        }
    }
    // boundaries allocates before some errors; the temporary arena owns failures.
    _ = try context.boundaries(t, req.messages);
    // Exercise actual outgoing history validation and native-reasoning requirements.
    // No network calls.
    const wire = switch (proto) {
        .chat => try chat.encode(t, req),
        .responses => try responses.encode(t, req),
        .anthropic => try anthropic.encode(t, req),
        .auto, .systemone => unreachable,
    };
    _ = wire;
}

fn sameCall(a: p.ToolCall, b: p.ToolCall) bool {
    return common.eq(a.id, b.id) and common.eq(a.name, b.name) and common.eq(a.arguments, b.arguments) and
        (if (a.item_id) |id| b.item_id != null and common.eq(id, b.item_id.?) else b.item_id == null);
}

fn sameBlock(a: p.Block, b: p.Block) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .text => |s| common.eq(s, b.text),
        .reasoning => |s| common.eq(s, b.reasoning),
        .tool_call => |c| sameCall(c, b.tool_call),
        .tool_result => false,
    };
}

fn validateResponses(a: Allocator, m: p.Message) !void {
    const r = m.replay.?;
    const prefix = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":";
    // Only the event envelope is synthetic. Output bytes/opaque fields are never
    // rewritten, stripped, or converted; the adapter derives canonical blocks.
    const event = try std.fmt.allocPrint(a, "{s}{s}}}}}", .{ prefix, r.json });
    var stream = responses.Stream.init(a, r.scope, .{});
    try stream.feed("", event);
    const finished = try stream.finish();
    const out = switch (finished) {
        .success => |result| result.message,
        .failure => return error.InvalidReplay,
    };
    if (out.blocks.len != m.blocks.len) return error.NativeMismatch;
    for (out.blocks, m.blocks) |x, y| if (!sameBlock(x, y)) return error.NativeMismatch;
    const native_replay = out.replay orelse return error.InvalidReplay;
    if (native_replay.retain_turn and !r.retain_turn) return error.NativeMismatch;
}

fn optionalText(v: j.Value, key: []const u8) ![]const u8 {
    const field = j.get(v, key) orelse return "";
    if (field == .null) return "";
    return j.string(field) orelse error.InvalidReplay;
}

fn validateChat(a: Allocator, m: p.Message, native: j.Value) !void {
    if (!common.eq(try common.text(native, "role"), "assistant")) return error.InvalidReplay;
    try common.chatCalls(native);
    const content = try optionalText(native, "content");
    const refusal = try optionalText(native, "refusal");
    // A complete Chat object loses interleaving between content and refusal.
    // Fail closed for this ambiguous combination instead of inventing an order.
    if (content.len != 0 and refusal.len != 0) return error.UnsupportedNativeCombination;
    const text = if (content.len != 0) content else refusal;
    const reasoning = try optionalText(native, "reasoning_content");
    var text_offset: usize = 0;
    var reason_offset: usize = 0;
    const calls = if (j.get(native, "tool_calls")) |v| if (v == .null) &.{} else try common.list(v) else &.{};
    var count: usize = 0;
    var retain = !common.onlyKeys(native, &.{ "role", "content", "tool_calls" });
    for (m.blocks) |b| switch (b) {
        .text => |s| {
            if (!std.mem.startsWith(u8, text[text_offset..], s)) return error.NativeMismatch;
            text_offset += s.len;
        },
        .reasoning => |s| {
            if (!std.mem.startsWith(u8, reasoning[reason_offset..], s)) return error.NativeMismatch;
            reason_offset += s.len;
        },
        .tool_call => |call| {
            if (count >= calls.len) return error.NativeMismatch;
            // Canonical blocks keep first-arrival order; native calls keep wire
            // index order. Both sides have unique IDs, so ID matching plus the
            // final count check establishes exact one-to-one coverage.
            const v = matched: {
                for (calls) |candidate| {
                    if (common.eq(try common.text(candidate, "id"), call.id)) break :matched candidate;
                }
                return error.NativeMismatch;
            };
            const f = j.get(v, "function").?;
            if (!sameCall(call, .{ .id = try common.text(v, "id"), .name = try common.text(f, "name"), .arguments = try common.text(f, "arguments") })) return error.NativeMismatch;
            retain = retain or !common.onlyKeys(v, &.{ "id", "type", "function" }) or !common.onlyKeys(f, &.{ "name", "arguments" });
            count += 1;
        },
        .tool_result => return error.NativeMismatch,
    };
    _ = a;
    if (text_offset != text.len or reason_offset != reasoning.len or count != calls.len or
        (retain and !m.replay.?.retain_turn)) return error.NativeMismatch;
}

// Tests construct actual requests explicitly; no production combination wrapper.
