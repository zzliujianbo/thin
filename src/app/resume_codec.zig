//! Authenticated immutable checkpoint framing, not diagnostic JSONL.
//! Layout: [0..8] magic, [8] version=1, [9] algorithm=1 (HMAC-SHA256),
//! [10..12] reserved zero, [12..28] random salt, [28..32] selection length
//! (u32 LE), [32..36] payload length (u32 LE), [36..68] tag, then selection
//! JSON and verbatim payload. MAC input is domain || header[0..36] || body.
//! Integrity only: no encryption, rollback prevention, account discovery, or
//! key-rotation compatibility. Caller must supply random salt and retain the
//! borrowed bytes unchanged through authentication AND subsequent DTO parsing.
const std = @import("std");
const selections = @import("selection_store.zig");
const ids = @import("session_id.zig");
const Hash = std.crypto.hash.sha2.Sha256;
const header_bytes = 68;
const tag_offset = 36;
const magic = "THINRSM\x00";
const domain = "thin.resume.checkpoint.hmac-sha256.v1\x00";
// Bound credential hashing work too; credentials are never written to the file.
const max_key_bytes = 64 * 1024;
pub const max_payload_bytes: usize = 16 * 1024 * 1024;
pub const max_file_bytes: usize = header_bytes + selections.max_bytes + max_payload_bytes;

/// Metadata is UNTRUSTED until authenticate succeeds. Payload is never parsed
/// here. Do not modify fields, construct envelopes manually, or mutate backing
/// storage. The fixed selection owns its strings; all wire slices are borrowed.
pub const Envelope = struct {
    selection: selections.Snapshot,
    payload: []const u8,
    wire: []const u8,
};

fn checkKey(key: []const u8) !void {
    if (key.len == 0 or key.len > max_key_bytes) return error.InvalidResumeKey;
}

fn totalSize(selection_len: usize, payload_len: usize) !usize {
    if (selection_len == 0 or selection_len > selections.max_bytes) return error.InvalidResumeLength;
    if (payload_len == 0 or payload_len > max_payload_bytes) return error.InvalidResumeLength;
    const body = std.math.add(usize, selection_len, payload_len) catch return error.InvalidResumeLength;
    return std.math.add(usize, header_bytes, body) catch return error.InvalidResumeLength;
}

fn framing(bytes: []const u8) !usize {
    if (bytes.len < header_bytes or bytes.len > max_file_bytes) return error.InvalidResumeLength;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidResumeMagic;
    if (bytes[8] != 1) return error.InvalidResumeVersion;
    if (bytes[9] != 1) return error.InvalidResumeAlgorithm;
    if (bytes[10] != 0 or bytes[11] != 0) return error.InvalidResumeReserved;
    const selection_len = std.mem.readInt(u32, bytes[28..32], .little);
    const payload_len = std.mem.readInt(u32, bytes[32..36], .little);
    if (try totalSize(selection_len, payload_len) != bytes.len) return error.InvalidResumeLength;
    return std.math.add(usize, header_bytes, selection_len) catch return error.InvalidResumeLength;
}

/// The selection schema contains exactly one object and scalar values only.
/// Reject every nested container before handing bounded input to std.json.
/// Strings/escapes are tracked so braces in model names are harmless.
fn shallowMetadata(bytes: []const u8) !void {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                quoted = false;
            }
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

fn parseSelection(a: std.mem.Allocator, bytes: []const u8, id: ids.Id) !selections.Snapshot {
    try shallowMetadata(bytes);
    return selections.parse(a, bytes, id) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SelectionIdentityMismatch => error.ResumeIdentityMismatch,
        else => error.InvalidResumeSelection,
    };
}

// Explicit HMAC implementation allows wiping ALL local normalized keys, pads,
// intermediate digests and hash states (the std HMAC init uses unwiped locals).
fn mac(out: *[32]u8, bytes: []const u8, key: []const u8) void {
    var pad: [64]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &pad);
    var inner: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &inner);
    var hash = Hash.init(.{});
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    if (key.len > pad.len) {
        hash.update(key);
        hash.final(pad[0..32]);
        std.crypto.secureZero(u8, std.mem.asBytes(&hash));
        hash = Hash.init(.{});
    } else @memcpy(pad[0..key.len], key);
    for (&pad) |*byte| byte.* ^= 0x36;
    hash.update(&pad);
    hash.update(domain);
    hash.update(bytes[0..tag_offset]);
    hash.update(bytes[header_bytes..]);
    hash.final(&inner);
    for (&pad) |*byte| byte.* ^= 0x36 ^ 0x5c;
    std.crypto.secureZero(u8, std.mem.asBytes(&hash));
    hash = Hash.init(.{});
    hash.update(&pad);
    hash.update(&inner);
    hash.final(out);
}

pub fn encode(a: std.mem.Allocator, id: ids.Id, selection: *const selections.Snapshot, payload: []const u8, key: []const u8, salt: [16]u8) ![]u8 {
    try checkKey(key);
    if (!ids.valid(id)) return error.InvalidSessionID;
    if (payload.len == 0 or payload.len > max_payload_bytes) return error.InvalidResumeLength;
    // Snapshot.model() assumes its length invariant, so check it before encode.
    if (selection.model_len == 0 or selection.model_len > selection.model_buffer.len) return error.InvalidResumeSelection;
    var metadata: [selections.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&metadata);
    selections.encode(&writer, id, selection) catch return error.InvalidResumeSelection;
    const selection_bytes = writer.buffered();
    _ = try parseSelection(a, selection_bytes, id);
    const size = try totalSize(selection_bytes.len, payload.len);
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    @memcpy(bytes[0..8], magic);
    bytes[8] = 1;
    bytes[9] = 1;
    @memset(bytes[10..12], 0);
    @memcpy(bytes[12..28], &salt);
    std.mem.writeInt(u32, bytes[28..32], @intCast(selection_bytes.len), .little);
    std.mem.writeInt(u32, bytes[32..36], @intCast(payload.len), .little);
    const end = header_bytes + selection_bytes.len; // totalSize checked both additions
    @memcpy(bytes[header_bytes..end], selection_bytes);
    @memcpy(bytes[end..], payload);
    mac(bytes[tag_offset..header_bytes], bytes, key);
    return bytes;
}

pub fn inspect(a: std.mem.Allocator, bytes: []const u8, expected_id: ids.Id) !Envelope {
    const end = try framing(bytes);
    if (!ids.valid(expected_id)) return error.InvalidSessionID;
    return .{ .selection = try parseSelection(a, bytes[header_bytes..end], expected_id), .payload = bytes[end..], .wire = bytes };
}

pub fn authenticate(envelope: *const Envelope, key: []const u8) !void {
    try checkKey(key);
    _ = try framing(envelope.wire);
    var computed: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &computed);
    mac(&computed, envelope.wire, key);
    if (!std.crypto.timing_safe.eql([32]u8, computed, envelope.wire[tag_offset..header_bytes].*)) return error.ResumeAuthenticationFailed;
}

const test_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
const test_key = "fake-credential-for-codec-tests";
const test_payload = "{\"quoted\":\"a\\\"b\"}\x00\xff";
fn fixture() selections.Snapshot {
    var s: selections.Snapshot = .{ .endpoint = @splat('a'), .provider = null, .protocol = .responses, .effort = null };
    const model = "model {\"quoted\"}";
    @memcpy(s.model_buffer[0..model.len], model);
    s.model_len = model.len;
    return s;
}

fn allocationRoundtrip(a: std.mem.Allocator) !void {
    const s = fixture();
    const bytes = try encode(a, test_id, &s, test_payload, test_key, @splat(7));
    defer a.free(bytes);
    const envelope = try inspect(a, bytes, test_id);
    try authenticate(&envelope, test_key);
    try std.testing.expectEqualSlices(u8, test_payload, envelope.payload);
    try std.testing.expectEqualStrings(s.model(), envelope.selection.model());
}

test "resume codec roundtrip raw payload and allocation cleanup" {
    try allocationRoundtrip(std.testing.allocator);
    // std.json's arena can take an optional resize/remap path depending on
    // backing allocator addresses. Refuse that optimization for deterministic
    // fault indices; retain exhaustive allocation failures and leak accounting.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationRoundtrip, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}

test "resume codec every wire byte tamper wrong keys and identity" {
    const a = std.testing.allocator;
    const s = fixture();
    const bytes = try encode(a, test_id, &s, test_payload, test_key, @splat(7));
    defer a.free(bytes);
    const envelope = try inspect(a, bytes, test_id);
    try std.testing.expectError(error.ResumeAuthenticationFailed, authenticate(&envelope, "wrong-fake-key"));
    try std.testing.expectError(error.InvalidResumeKey, authenticate(&envelope, ""));
    try std.testing.expectError(error.ResumeIdentityMismatch, inspect(a, bytes, "1123456789abcdef0123456789abcdef".*));
    for (0..bytes.len) |i| {
        bytes[i] ^= 1;
        defer bytes[i] ^= 1;
        if (inspect(a, bytes, test_id)) |changed| {
            try std.testing.expectError(error.ResumeAuthenticationFailed, authenticate(&changed, test_key));
        } else |_| {}
    }
}

test "resume codec truncation trailing oversized lengths and fixed header validation" {
    const a = std.testing.allocator;
    const s = fixture();
    const bytes = try encode(a, test_id, &s, test_payload, test_key, @splat(7));
    defer a.free(bytes);
    for (0..bytes.len) |len| try std.testing.expectError(error.InvalidResumeLength, inspect(std.testing.failing_allocator, bytes[0..len], test_id));
    const trailing = try std.mem.concat(a, u8, &.{ bytes, "x" });
    defer a.free(trailing);
    try std.testing.expectError(error.InvalidResumeLength, inspect(std.testing.failing_allocator, trailing, test_id));
    for ([_]usize{ 28, 32 }) |offset| {
        const old = bytes[offset..][0..4].*;
        @memset(bytes[offset..][0..4], 255);
        try std.testing.expectError(error.InvalidResumeLength, inspect(std.testing.failing_allocator, bytes, test_id));
        @memset(bytes[offset..][0..4], 0);
        try std.testing.expectError(error.InvalidResumeLength, inspect(std.testing.failing_allocator, bytes, test_id));
        @memcpy(bytes[offset..][0..4], &old);
    }
    bytes[8] = 2;
    try std.testing.expectError(error.InvalidResumeVersion, inspect(std.testing.failing_allocator, bytes, test_id));
    bytes[8] = 1;
    bytes[9] = 2;
    try std.testing.expectError(error.InvalidResumeAlgorithm, inspect(std.testing.failing_allocator, bytes, test_id));
    bytes[9] = 1;
    bytes[11] = 1;
    try std.testing.expectError(error.InvalidResumeReserved, inspect(std.testing.failing_allocator, bytes, test_id));
}

test "resume codec strict selection and preparse nesting guard" {
    const a = std.testing.allocator;
    const s = fixture();
    const original = try encode(a, test_id, &s, test_payload, test_key, @splat(7));
    defer a.free(original);
    for ([_][]const u8{ "{}", "[]", "{\"version\":1,\"version\":1}", "{\"x\":{}}", "{\"x\":[[[[[]]]]]}", "\xff" }) |metadata| {
        const bytes = try a.alloc(u8, header_bytes + metadata.len + 1);
        defer a.free(bytes);
        @memcpy(bytes[0..header_bytes], original[0..header_bytes]);
        std.mem.writeInt(u32, bytes[28..32], @intCast(metadata.len), .little);
        std.mem.writeInt(u32, bytes[32..36], 1, .little);
        @memcpy(bytes[header_bytes..][0..metadata.len], metadata);
        bytes[bytes.len - 1] = 0;
        try std.testing.expectError(error.InvalidResumeSelection, inspect(a, bytes, test_id));
    }
    try std.testing.expectError(error.InvalidResumeSelection, parseSelection(std.testing.failing_allocator, "{\"x\":{}}", test_id));
    var invalid = s;
    invalid.model_len = 65535;
    try std.testing.expectError(error.InvalidResumeSelection, encode(a, test_id, &invalid, "x", test_key, @splat(0)));
    invalid = s;
    invalid.endpoint[0] = 'z';
    try std.testing.expectError(error.InvalidResumeSelection, encode(a, test_id, &invalid, "x", test_key, @splat(0)));
    try std.testing.expectError(error.InvalidResumeLength, encode(a, test_id, &s, "", test_key, @splat(0)));
    try std.testing.expectError(error.InvalidResumeKey, encode(a, test_id, &s, "x", "", @splat(0)));
}

test "resume codec rejects selection scalar type duplicate unknown field and oversize inputs" {
    const a = std.testing.allocator;
    const s = fixture();
    const original = try encode(a, test_id, &s, test_payload, test_key, @splat(7));
    defer a.free(original);
    const end = try framing(original);
    const metadata = original[header_bytes..end];
    const mutations = [_][2][]const u8{
        .{ "\"version\":1", "\"version\":\"1\"" },
        .{ "\"version\":1", "\"version\":1.0" },
        .{ "\"version\":1", "\"version\":2" },
        .{ "\"version\":1", "\"version\":1,\"version\":1" },
        .{ "\"version\":1", "\"version\":1,\"unknown\":0" },
        .{ "\"provider\":null", "\"provider\":42" },
        .{ "\"effort\":null", "\"effort\":false" },
        .{ "\"protocol\":\"responses\"", "\"protocol\":null" },
        .{ "\"effort_hash\":null", "\"effort_hash\":[]" },
    };
    for (mutations) |change| {
        try std.testing.expect(std.mem.find(u8, metadata, change[0]) != null);
        const altered = try std.mem.replaceOwned(u8, a, metadata, change[0], change[1]);
        defer a.free(altered);
        const bytes = try std.mem.concat(a, u8, &.{ original[0..header_bytes], altered, test_payload });
        defer a.free(bytes);
        std.mem.writeInt(u32, bytes[28..32], @intCast(altered.len), .little);
        try std.testing.expectError(error.InvalidResumeSelection, inspect(a, bytes, test_id));
    }
    const oversized = try a.alloc(u8, max_payload_bytes + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.InvalidResumeLength, encode(std.testing.failing_allocator, test_id, &s, oversized, test_key, @splat(0)));
    const big_key: [max_key_bytes + 1]u8 = @splat('k');
    try std.testing.expectError(error.InvalidResumeKey, encode(std.testing.failing_allocator, test_id, &s, "x", &big_key, @splat(0)));
    const envelope = try inspect(a, original, test_id);
    try std.testing.expectError(error.InvalidResumeKey, authenticate(&envelope, &big_key));
    try std.testing.expectError(error.InvalidSessionID, encode(std.testing.failing_allocator, @splat('Z'), &s, "x", test_key, @splat(0)));
}

test "resume codec HMAC matches standard including long key normalization" {
    const a = std.testing.allocator;
    const s = fixture();
    const long_key: [100]u8 = @splat('k');
    for ([_][]const u8{ test_key, &long_key }) |key| {
        const bytes = try encode(a, test_id, &s, test_payload, key, @splat(7));
        defer a.free(bytes);
        const message = try std.mem.concat(a, u8, &.{ domain, bytes[0..tag_offset], bytes[header_bytes..] });
        defer a.free(message);
        var expected: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, message, key);
        try std.testing.expectEqualSlices(u8, &expected, bytes[tag_offset..header_bytes]);
    }
}
