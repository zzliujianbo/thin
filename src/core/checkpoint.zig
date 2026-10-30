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
const Allocator = std.mem.Allocator;

pub const max_bytes: usize = 16 * 1024 * 1024;
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
    max_input_tokens: ?u32 = null,
    low_price_input: bool = false,
    input_margin_tokens: u32 = 5000,
    permission_id: u64,
    poisoned: bool = false,
    /// Observer continuity only; the Runtime never treats these as authority.
    journal_seq: u64 = 0,
    journal_turn: u64 = 0,
};

// Empty-buffer counter rejects before any output allocation, including escaping.
const Counter = struct {
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
    count: usize = 0,
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Counter = @fieldParentPtr("writer", w);
        const n = std.Io.Writer.countSplat(data, splat);
        if (n > max_bytes - self.count) return error.WriteFailed;
        self.count += n;
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
    const size = try encodedSize(state);
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try std.json.Stringify.value(state, .{ .emit_null_optional_fields = true }, &writer);
    std.debug.assert(writer.end == size);
    return bytes;
}

// Bound nesting and structural work before invoking an allocating JSON parser.
fn preflight(bytes: []const u8) !void {
    if (bytes.len > max_bytes) return error.InputLimit;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var quoted = false;
    var escaped = false;
    var depth: usize = 0;
    var nodes: usize = 0;
    for (bytes) |b| {
        if (quoted) {
            if (escaped) escaped = false else if (b == '\\') escaped = true else if (b == '"') quoted = false;
        } else switch (b) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                nodes += 1;
                if (depth > 64) return error.InputLimit;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            ',', ':' => nodes += 1,
            else => {},
        }
        if (nodes > 65536) return error.InputLimit;
    }
    if (quoted or depth != 0) return error.InvalidJson;
}

fn strictJson(a: Allocator, bytes: []const u8) !std.json.Parsed(j.Value) {
    try preflight(bytes);
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
                if (v.array.items.len > 1024) return error.InputLimit;
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
    const tree = try strictJson(a, bytes);
    defer tree.deinit();
    try shape(State, tree.value);
    const parsed = try std.json.parseFromValue(State, a, tree.value, .{});
    errdefer parsed.deinit();
    try basic(parsed.value);
    return parsed;
}

fn utf8(s: []const u8) !void {
    if (s.len > max_bytes) return error.InputLimit;
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
}

fn basic(state: State) !void {
    if (state.version != 2) return error.UnsupportedVersion;
    try utf8(state.system);
    if (state.messages.len > 1024) return error.InputLimit;
    var blocks: usize = 0;
    for (state.messages) |m| {
        if (m.blocks.len > 1024 - blocks) return error.InputLimit;
        blocks += m.blocks.len;
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
    // Exercise actual outgoing history validation, including native item expansion
    // count limits and Responses' native-reasoning requirement. No network calls.
    const wire = switch (proto) {
        .chat => try chat.encode(t, req),
        .responses => try responses.encode(t, req),
        .anthropic => try anthropic.encode(t, req),
        .auto, .systemone => unreachable,
    };
    if (wire.len > max_bytes) return error.InputLimit;
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
    if (r.json.len > max_bytes - prefix.len - 2) return error.InputLimit;
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

const fixture_config = cfg.Config{
    .provider = .{ .base_url = "https://fixture.invalid/v1", .api_key = "fake-key" },
    .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .auto },
};
// Tests construct actual requests explicitly; no production combination wrapper.
test "checkpoint DTO excludes OAuth config and preserves frozen context" {
    var config = fixture_config;
    config.provider.codex_oauth = .{ .access_token = "access-canary-private", .refresh_token = "refresh-canary-private", .expires_at_ms = 1 };
    var state = fixture(.responses);
    state.context_tokens = config.model.context_tokens;
    const bytes = try encode(std.testing.allocator, state);
    defer std.testing.allocator.free(bytes);
    for ([_][]const u8{ "access-canary-private", "refresh-canary-private", "codex_oauth" }) |secret| try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(state.context_tokens, decoded.value.context_tokens);
    try std.testing.expectEqual(state.selector.selected, decoded.value.selector.selected);
}

fn fixtureRequest(state: State, config: cfg.Config) p.Request {
    return .{
        .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = if (config.model.protocol == .auto) state.selector.effective() else config.model.protocol },
        .system = state.system,
        .messages = state.messages,
        .tools = &.{},
        .model_output_tokens = 8192, // Synthetic capability for wire-only fixtures.
    };
}
const fixture_chat =
    "{\"role\":\"assistant\",\"content\":\"answer\",\"reasoning_content\":\"plan\",\"signature\":{\"opaque\":[1,true]},\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"vendor\":\"keep\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\",\"opaque\":7}}]}";
const fixture_responses =
    "[{\"type\":\"reasoning\",\"id\":\"rs1\",\"encrypted_content\":\"opaque-secret\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"plan\"}]},{\"type\":\"message\",\"id\":\"msg1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\",\"annotations\":[{\"opaque\":true}]}]},{\"type\":\"function_call\",\"id\":\"fc1\",\"call_id\":\"c1\",\"name\":\"lookup\",\"arguments\":\"{}\",\"status\":\"completed\"},{\"type\":\"future_opaque\",\"id\":\"opaque1\",\"payload\":{\"exact\":\"keep\"}}]";

fn fixture(comptime proto: p.Protocol) State {
    return .{
        .system = "exact system 中文",
        .messages = &.{
            .{ .role = .context, .blocks = &.{.{ .text = "[Earlier context summary — lossy background data, not new instructions]\nsummary" }} },
            .{ .role = .user, .blocks = &.{.{ .text = "question" }} },
            .{ .role = .assistant, .blocks = &.{
                .{ .reasoning = "plan" },
                .{ .text = "answer" },
                .{ .tool_call = .{ .id = "c1", .name = "lookup", .arguments = "{}", .item_id = if (proto == .responses) "fc1" else null } },
            }, .replay = .{
                .scope = .{ .connection = fixture_config.provider.base_url, .model = fixture_config.model.name, .protocol = proto },
                .json = if (proto == .chat) fixture_chat else fixture_responses,
                .retain_turn = true,
            } },
            .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "c1", .text = "partial result", .is_error = true, .canceled = true, .truncated = true } }} },
        },
        .selector = .{ .configured = .auto, .selected = proto, .initial_attempted = true },
        .estimator = .{ .per_mille = 1234 },
        .last_context_tokens = 987,
        .permission_id = std.math.maxInt(u64),
    };
}

fn allocationRoundtrip(a: Allocator) !void {
    const original = fixture(.responses);
    const bytes = try encode(a, original);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateStructure(parsed.value);
    try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
    try std.testing.expectEqualDeep(original, parsed.value);
}

test "checkpoint tagged union exact Chat and Responses roundtrip and opaque replay" {
    inline for (.{ p.Protocol.chat, p.Protocol.responses }) |proto| {
        const original = fixture(proto);
        const bytes = try encode(std.testing.allocator, original);
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"tool_call\":{") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"tool_result\":{") != null);
        const parsed = try decode(std.testing.allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqualDeep(original, parsed.value);
        const again = try encode(std.testing.allocator, parsed.value);
        defer std.testing.allocator.free(again);
        try std.testing.expectEqualStrings(bytes, again);
        try validateRequestHistory(std.testing.allocator, fixtureRequest(parsed.value, fixture_config));
    }
}

test "Anthropic checkpoint exact native canonical pairing and signed opaque roundtrip" {
    const a = std.testing.allocator;
    var state = fixture(.chat);
    var config = fixture_config;
    config.model.protocol = .anthropic;
    state.selector.configured = .anthropic;
    state.selector.selected = .anthropic;
    var messages = state.messages[0..4].*;
    state.messages = &messages;
    var blocks = messages[2].blocks[0..3].*;
    messages[2].blocks = &blocks;
    messages[2].replay.?.scope.protocol = .anthropic;
    messages[2].replay.?.json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"signature\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque\"},{\"type\":\"text\",\"text\":\"answer\"},{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"lookup\",\"input\":{}}]}";
    try validateRequestHistory(a, fixtureRequest(state, config));
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateRequestHistory(a, fixtureRequest(parsed.value, config));
    try std.testing.expectEqualDeep(state, parsed.value);
    blocks[1] = .{ .text = "changed" };
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, config)));
    blocks[1] = .{ .text = "answer" };
    blocks[2].tool_call.item_id = "foreign-item";
    try std.testing.expectError(error.InvalidHistory, validateRequestHistory(a, fixtureRequest(state, config)));
    blocks[2].tool_call.item_id = null;
    messages[2].replay.?.retain_turn = false;
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, config)));
    messages[2].replay.?.retain_turn = true;
    messages[2].replay.?.scope.protocol = .chat;
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(state, config)));
}

fn assertRequiredFields(comptime T: type, a: Allocator, value: j.Value) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |name, FT| {
                var missing = j.object(a);
                var it = value.object.iterator();
                while (it.next()) |entry| {
                    if (!common.eq(entry.key_ptr.*, name)) try j.put(a, &missing, entry.key_ptr.*, entry.value_ptr.*);
                }
                try std.testing.expectError(error.MissingField, shape(T, missing));
                try assertRequiredFields(FT, a, value.object.get(name).?);
            }
        },
        .optional => |info| if (value != .null) try assertRequiredFields(info.child, a, value),
        .pointer => |info| if (info.child != u8) {
            for (value.array.items) |item| try assertRequiredFields(info.child, a, item);
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, FT| {
                if (value.object.get(name)) |child| try assertRequiredFields(FT, a, child);
            }
        },
        else => {},
    }
}

test "checkpoint requires every emitted field recursively including nullable defaults" {
    const a = std.testing.allocator;
    const bytes = try encode(a, fixture(.chat));
    defer a.free(bytes);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tree = try strictJson(arena.allocator(), bytes);
    defer tree.deinit();
    try assertRequiredFields(State, arena.allocator(), tree.value);
    // Each removal starts with the current encoder's complete valid DTO.
    const removals = [_][]const u8{
        "\"version\":2,",              "\"context_tokens\":null,", "\"context_official\":false,",
        ",\"initial_attempted\":true", "\"per_mille\":1234",       ",\"replay\":null",
        ",\"item_id\":null",           "\"canceled\":true,",       ",\"retain_turn\":true",
    };
    for (removals) |field| {
        const missing = try std.mem.replaceOwned(u8, a, bytes, field, "");
        defer a.free(missing);
        try std.testing.expect(missing.len < bytes.len);
        try std.testing.expectError(error.MissingField, decode(a, missing));
    }
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateStructure(parsed.value);
    try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
}

test "checkpoint display accepts representable stale budgets and provenance but not wrong types" {
    const a = std.testing.allocator;
    var state = fixture(.chat);
    for ([_]u32{ 0, 16 * 1024 * 1024 + 1, std.math.maxInt(u32) }) |tokens| {
        state.context_tokens = tokens;
        state.output_tokens = tokens;
        state.input_price_threshold = tokens;
        state.input_margin_tokens = tokens;
        const bytes = try encode(a, state);
        defer a.free(bytes);
        const parsed = try decode(a, bytes);
        defer parsed.deinit();
        try std.testing.expectEqualDeep(state, parsed.value);
    }
    state.context_tokens = null;
    state.context_official = true;
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    for ([_][]const u8{ "\"context_tokens\":\"32768\"", "\"context_tokens\":1.0", "\"context_tokens\":-1", "\"context_tokens\":4294967296" }) |replacement| {
        const bad = try std.mem.replaceOwned(u8, a, bytes, "\"context_tokens\":null", replacement);
        defer a.free(bad);
        try badDecode(bad);
    }
}

test "checkpoint exact capacity provenance roundtrip and config match preserve validation" {
    const a = std.testing.allocator;
    inline for (.{ p.Protocol.chat, p.Protocol.responses }) |proto| {
        for ([_]u32{ 1, 65536, 16 * 1024 * 1024 }) |tokens| {
            for ([_]bool{ false, true }) |official| {
                var state = fixture(proto);
                state.context_tokens = tokens;
                state.context_official = official;
                const bytes = try encode(a, state);
                defer a.free(bytes);
                const parsed = try decode(a, bytes);
                defer parsed.deinit();
                try std.testing.expectEqualDeep(state, parsed.value);
                try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
                var config = fixture_config;
                config.model.context_tokens = tokens;
                try validateRequestHistory(a, fixtureRequest(parsed.value, config));
                state.estimator.per_mille = 999;
                try validateRequestHistory(a, fixtureRequest(state, config));
                state.estimator = parsed.value.estimator;
                state.messages = state.messages[0..3];
                try std.testing.expectError(error.IncompleteToolGroup, validateRequestHistory(a, fixtureRequest(state, config)));
            }
        }
    }
}

test "checkpoint allocation failures clean every owned parse and validation arena" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationRoundtrip, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

fn badDecode(bytes: []const u8) !void {
    if (decode(std.testing.allocator, bytes)) |parsed| {
        parsed.deinit();
        return error.ExpectedDecodeFailure;
    } else |_| {}
}

test "checkpoint strict duplicate unknown type version UTF8 depth and size" {
    const a = std.testing.allocator;
    const bytes = try encode(a, fixture(.chat));
    defer a.free(bytes);
    for ([_][]const u8{
        "\"version\":2,", "\"unknown\":true,", "\"permission_id\":\"1\",",
    }) |injection| {
        const bad = try std.fmt.allocPrint(a, "{{{s}{s}", .{ injection, bytes[1..] });
        defer a.free(bad);
        try badDecode(bad);
    }
    // Replacing the actual field (rather than injecting a duplicate) catches
    // std.json's permissive integer/string, float/integer and enum conversions.
    for ([_][]const u8{ "\"1\"", "1.0", "true", "1", "null", "-1" }) |v| {
        const bad = try std.mem.replaceOwned(u8, a, bytes, "\"version\":2", tryVersionPrefix(v));
        defer a.free(bad);
        try badDecode(bad);
    }
    const enum_bad = try std.mem.replaceOwned(u8, a, bytes, "\"role\":\"context\"", "\"role\":3");
    defer a.free(enum_bad);
    try badDecode(enum_bad);
    const union_bad = try std.mem.replaceOwned(u8, a, bytes, "\"reasoning\":\"plan\"", "\"reasoning\":\"plan\",\"text\":\"plan\"");
    defer a.free(union_bad);
    try badDecode(union_bad);
    try badDecode("{\"version\":1,\"system\":\"\xff\"}");
    var deep: [130]u8 = undefined;
    @memset(deep[0..65], '[');
    @memset(deep[65..], ']');
    try std.testing.expectError(error.InputLimit, decode(a, &deep));
    const huge = try a.alloc(u8, max_bytes + 1);
    defer a.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.InputLimit, decode(a, huge));
    var state = fixture(.chat);
    state.version = 1;
    try std.testing.expectError(error.UnsupportedVersion, encode(a, state));
    state.version = 2;
    state.system = huge;
    try std.testing.expectError(error.InputLimit, encode(a, state));
    // Escaping expands input beyond the limit: the counting pass, not a late
    // post-allocation check, must reject it.
    @memset(huge[0 .. max_bytes / 2], '\n');
    state.system = huge[0 .. max_bytes / 2];
    try std.testing.expectError(error.InputLimit, encode(a, state));
}

fn tryVersionPrefix(v: []const u8) []const u8 {
    if (common.eq(v, "\"1\"")) return "\"version\":\"1\"";
    if (common.eq(v, "1.0")) return "\"version\":1.0";
    if (common.eq(v, "true")) return "\"version\":true";
    if (common.eq(v, "1")) return "\"version\":1";
    if (common.eq(v, "null")) return "\"version\":null";
    return "\"version\":-1";
}

test "SystemOne history remains structural data but cannot authorize chat requests" {
    const a = std.testing.allocator;
    var state = fixture(.chat);
    state.selector = llm.Selector.init(.systemone);
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(state, parsed.value);
    var config = fixture_config;
    config.model.protocol = .systemone;
    try std.testing.expectError(error.SystemOneNotChatModel, validateRequestHistory(a, fixtureRequest(parsed.value, config)));
}

test "checkpoint loads poison estimator selector independently from pre-send scope checks" {
    const a = std.testing.allocator;
    var s = fixture(.chat);
    s.poisoned = true;
    s.estimator.per_mille = 0;
    s.selector = .{ .configured = .anthropic, .selected = .auto };
    const bytes = try encode(a, s);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(s, parsed.value);
    s = fixture(.chat);
    var config = fixture_config;
    config.provider.base_url = "https://other.invalid";
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(s, config)));
    config = fixture_config;
    config.model.name = "another-model";
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(s, config)));
    s.selector.selected = .responses;
    try std.testing.expectError(error.ReplayScopeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
}

test "checkpoint roles closure global duplicate ids argument objects and bounds" {
    const a = std.testing.allocator;
    var s = fixture(.chat);
    s.messages = s.messages[0..3];
    try std.testing.expectError(error.IncompleteToolGroup, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    const good = fixture(.chat);
    var messages = [_]p.Message{ good.messages[2], good.messages[3], good.messages[2], good.messages[3] };
    s.messages = &messages;
    try std.testing.expectError(error.DuplicateToolId, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    s.messages = &.{good.messages[3]};
    try std.testing.expectError(error.OrphanToolResult, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    for ([_]p.Role{ .user, .context, .tool }) |role| {
        s.messages = &.{.{ .role = role, .blocks = &.{.{ .reasoning = "bad" }} }};
        try std.testing.expectError(error.InvalidHistory, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    }
    s.messages = &.{.{ .role = .tool, .blocks = &.{.{ .text = "bad" }} }};
    try std.testing.expectError(error.InvalidHistory, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    s.messages = &.{.{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "c", .name = "lookup", .arguments = "[]" } }} }};
    try std.testing.expectError(error.InvalidToolArguments, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
    const many = try a.alloc(p.Message, 1025);
    defer a.free(many);
    @memset(many, .{ .role = .user, .blocks = &.{} });
    s.messages = many;
    try std.testing.expectError(error.InputLimit, encode(a, s));
    const blocks = try a.alloc(p.Block, 1025);
    defer a.free(blocks);
    @memset(blocks, .{ .text = "" });
    s.messages = &.{.{ .role = .user, .blocks = blocks }};
    try std.testing.expectError(error.InputLimit, encode(a, s));
    s.messages = &.{ .{ .role = .user, .blocks = blocks[0..600] }, .{ .role = .user, .blocks = blocks[600..] } };
    try std.testing.expectError(error.InputLimit, encode(a, s));
}

test "checkpoint accepts out of order Chat arrival without weakening call identity" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stream = chat.Stream.init(arena.allocator(), .{
        .connection = fixture_config.provider.base_url,
        .model = fixture_config.model.name,
        .protocol = .chat,
    }, .{});
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]}}]}");
    try stream.feed("", "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"x\\\":1}\"}}]},\"finish_reason\":\"tool_calls\"}]}");
    try stream.feed("", "[DONE]");
    const outcome = try stream.finish();
    const message = switch (outcome) {
        .success => |value| value.message,
        .failure => return error.UnexpectedStreamFailure,
    };
    try std.testing.expectEqualStrings("b", message.blocks[0].tool_call.id);
    var blocks = [_]p.Block{ message.blocks[0], message.blocks[1] };
    var messages = [_]p.Message{
        message,
        .{ .role = .tool, .blocks = &.{
            .{ .tool_result = .{ .call_id = "b", .text = "result b" } },
            .{ .tool_result = .{ .call_id = "a", .text = "result a" } },
        } },
    };
    messages[0].blocks = &blocks;
    var state = fixture(.chat);
    state.messages = &messages;
    try validateRequestHistory(a, fixtureRequest(state, fixture_config));
    const bytes = try encode(a, state);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
    try std.testing.expectEqualDeep(state, parsed.value);
    blocks[0].tool_call.arguments = "{\"x\":1}";
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
    blocks[0] = message.blocks[0];
    blocks[0].tool_call.name = "different";
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
    blocks[0] = message.blocks[0];
    blocks[0].tool_call.id = "missing";
    try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
    blocks[0] = message.blocks[1];
    try std.testing.expectError(error.DuplicateToolId, validateRequestHistory(a, fixtureRequest(state, fixture_config)));
}

test "checkpoint native mismatches and unsupported native forms fail closed" {
    const a = std.testing.allocator;
    inline for (.{ p.Protocol.chat, p.Protocol.responses }) |proto| {
        const original = fixture(proto);
        var s = original;
        var blocks = [_]p.Block{ original.messages[2].blocks[0], .{ .text = "different" }, original.messages[2].blocks[2] };
        var messages = [_]p.Message{ original.messages[2], original.messages[3] };
        messages[0].blocks = &blocks;
        s.messages = &messages;
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        blocks[1] = original.messages[2].blocks[1];
        blocks[0] = .{ .reasoning = "different" };
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        blocks[0] = original.messages[2].blocks[0];
        blocks[2].tool_call.arguments = "{\"changed\":true}";
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        blocks[2] = original.messages[2].blocks[2];
        messages[0].replay.?.retain_turn = false;
        try std.testing.expectError(error.NativeMismatch, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
        messages[0].replay.?.retain_turn = true;
        messages[0].replay.?.json = if (proto == .chat) "[]" else "{}";
        if (validateRequestHistory(a, fixtureRequest(s, fixture_config))) |_| return error.ExpectedValidationFailure else |_| {}
    }
    var s = fixture(.responses);
    s.messages = &.{.{ .role = .assistant, .blocks = &.{.{ .reasoning = "native missing" }} }};
    try std.testing.expectError(error.NativeReplayRequired, validateRequestHistory(a, fixtureRequest(s, fixture_config)));
}
