//! Bounded, unauthenticated checkpoint framing. v2 layout: magic[8]
//! "THINRSM\0", version byte 2, selection length u32 LE at [9..13],
//! payload length u32 LE at [13..17], then selection JSON and payload JSON.
//! Only this current format is supported. Framing grants no trust.
const std = @import("std");
const selections = @import("selection.zig");
const ids = @import("session_id.zig");
const checkpoint = @import("../core/checkpoint.zig");
const magic = "THINRSM\x00";
const header_bytes = 17;
pub const max_payload_bytes: usize = checkpoint.max_bytes;
pub const max_file_bytes: usize = header_bytes + selections.max_bytes + max_payload_bytes;

/// Owned selection plus borrowed payload/wire. No authentication or key binding.
pub const Envelope = struct {
    selection: selections.Snapshot,
    payload: []const u8,
    wire: []const u8,
};

fn totalSize(selection_len: usize, payload_len: usize) !usize {
    if (selection_len == 0 or selection_len > selections.max_bytes or payload_len == 0 or payload_len > max_payload_bytes) return error.InvalidResumeLength;
    return header_bytes + selection_len + payload_len; // bounded above, cannot overflow
}

fn shallowMetadata(bytes: []const u8) !void {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
            continue;
        }
        switch (byte) {
            '"' => quoted = true,
            '[', ']' => return error.InvalidResumeSelection,
            '{' => {
                if (depth != 0) return error.InvalidResumeSelection;
                depth = 1;
            },
            '}' => {
                if (depth != 1) return error.InvalidResumeSelection;
                depth = 0;
            },
            else => {},
        }
    }
    if (depth != 0 or quoted or escaped) return error.InvalidResumeSelection;
}

fn parseSelection(a: std.mem.Allocator, bytes: []const u8) !selections.Snapshot {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidResumeSelection;
    try shallowMetadata(bytes);
    return selections.parse(a, bytes) catch |err| return if (err == error.OutOfMemory) err else error.InvalidResumeSelection;
}

fn checkPayload(a: std.mem.Allocator, bytes: []const u8) !void {
    const parsed = try checkpoint.decode(a, bytes);
    parsed.deinit();
}

pub fn encode(a: std.mem.Allocator, id: ids.Id, selection: *const selections.Snapshot, payload: []const u8) ![]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    if (payload.len == 0 or payload.len > max_payload_bytes) return error.InvalidResumeLength;
    if (selection.model_len == 0 or selection.model_len > selection.model_buffer.len or selection.provider_name_len > selection.provider_name_buffer.len) return error.InvalidResumeSelection;
    var metadata: [selections.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&metadata);
    selections.encode(&writer, selection) catch return error.InvalidResumeSelection;
    const selection_bytes = writer.buffered();
    _ = try parseSelection(a, selection_bytes);
    try checkPayload(a, payload);
    const bytes = try a.alloc(u8, try totalSize(selection_bytes.len, payload.len));
    @memcpy(bytes[0..8], magic);
    bytes[8] = 2;
    std.mem.writeInt(u32, bytes[9..13], @intCast(selection_bytes.len), .little);
    std.mem.writeInt(u32, bytes[13..17], @intCast(payload.len), .little);
    const end = header_bytes + selection_bytes.len;
    @memcpy(bytes[header_bytes..end], selection_bytes);
    @memcpy(bytes[end..], payload);
    return bytes;
}

pub fn inspect(a: std.mem.Allocator, bytes: []const u8, expected_id: ids.Id) !Envelope {
    if (!ids.valid(expected_id)) return error.InvalidSessionID;
    if (bytes.len < header_bytes or bytes.len > max_file_bytes) return error.InvalidResumeLength;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidResumeMagic;
    if (bytes[8] != 2) return error.InvalidResumeVersion;
    const selection_len = std.mem.readInt(u32, bytes[9..13], .little);
    const payload_len = std.mem.readInt(u32, bytes[13..17], .little);
    if (try totalSize(selection_len, payload_len) != bytes.len) return error.InvalidResumeLength;
    const end = header_bytes + selection_len;
    const selection = try parseSelection(a, bytes[header_bytes..end]);
    try checkPayload(a, bytes[end..]);
    return .{ .selection = selection, .payload = bytes[end..], .wire = bytes };
}

const test_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
fn fixturePayload(a: std.mem.Allocator) ![]u8 {
    return checkpoint.encode(a, .{ .system = "hello", .messages = &.{}, .selector = .{ .configured = .auto, .selected = null }, .estimator = .{}, .last_context_tokens = null, .permission_id = 0 });
}
fn fixture() selections.Snapshot {
    var s: selections.Snapshot = .{ .endpoint = @splat('a'), .provider = null, .protocol = .responses, .effort = null };
    @memcpy(s.model_buffer[0..5], "model");
    s.model_len = 5;
    return s;
}

fn allocationRoundtrip(a: std.mem.Allocator) !void {
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    const envelope = try inspect(a, bytes, test_id);
    try std.testing.expectEqualStrings(payload, envelope.payload);
    try std.testing.expectEqualStrings(s.model(), envelope.selection.model());
}

test "resume codec v2 roundtrip allocation cleanup no credentials or identity binding" {
    try allocationRoundtrip(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationRoundtrip, .{});
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    _ = try inspect(a, bytes, "1123456789abcdef0123456789abcdef".*);
    const offset = std.mem.find(u8, bytes, "hello").?;
    bytes[offset] = 'j'; // Still valid JSON is loadable, not authenticated.
    _ = try inspect(a, bytes, test_id);
    for (0..bytes.len) |len| {
        if (inspect(a, bytes[0..len], test_id)) |_| return error.AcceptedTruncation else |_| {}
    }
}

test "resume codec bounded lengths malformed selection and payload reject without authentication" {
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    const trailing = try std.mem.concat(a, u8, &.{ bytes, "x" });
    defer a.free(trailing);
    try std.testing.expectError(error.InvalidResumeLength, inspect(a, trailing, test_id));
    for ([_]usize{ 9, 13 }) |offset| {
        const saved = bytes[offset..][0..4].*;
        @memset(bytes[offset..][0..4], 255);
        try std.testing.expectError(error.InvalidResumeLength, inspect(a, bytes, test_id));
        @memset(bytes[offset..][0..4], 0);
        try std.testing.expectError(error.InvalidResumeLength, inspect(a, bytes, test_id));
        @memcpy(bytes[offset..][0..4], &saved);
    }
    try std.testing.expectError(error.InvalidSessionID, inspect(a, bytes, @splat('/')));
    try std.testing.expectError(error.InvalidResumeSelection, parseSelection(a, "{\"x\":{}}"));
    try std.testing.expectError(error.InvalidResumeSelection, parseSelection(a, "{\"session\":\"\xff\"}"));
    if (encode(a, test_id, &s, "[]")) |bad| {
        a.free(bad);
        return error.AcceptedInvalidPayload;
    } else |_| {}
}

test "resume codec rejects v1 frames and corrupted current payload" {
    const a = std.testing.allocator;
    const s = fixture();
    const payload = try fixturePayload(a);
    defer a.free(payload);
    const bytes = try encode(a, test_id, &s, payload);
    defer a.free(bytes);
    bytes[8] = 1;
    try std.testing.expectError(error.InvalidResumeVersion, inspect(a, bytes, test_id));
    bytes[8] = 2;
    bytes[bytes.len - 1] = '!';
    if (inspect(a, bytes, test_id)) |_| return error.AcceptedInvalidJson else |_| {}
}
