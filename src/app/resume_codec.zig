//! Unauthenticated checkpoint framing. v3 uses magic[8], version 3,
//! selection length u32 LE, payload length u64 LE, then selection and payload.
//! Existing v2 frames use a u32 payload length and remain readable.
//! Framing grants no trust.
const std = @import("std");
const selections = @import("selection.zig");
const ids = @import("session_id.zig");
const checkpoint = @import("../core/checkpoint.zig");
const magic = "THINRSM\x00";
const header_v2_bytes = 17;
const header_bytes = 21;

/// Owned selection plus borrowed payload/wire. No authentication or key binding.
pub const Envelope = struct {
    selection: selections.Snapshot,
    payload: []const u8,
    wire: []const u8,
};

fn totalSize(selection_len: usize, payload_len: usize) !usize {
    if (selection_len == 0 or selection_len > selections.max_bytes or payload_len == 0) return error.InvalidResumeLength;
    const prefix = std.math.add(usize, header_bytes, selection_len) catch return error.InvalidResumeLength;
    return std.math.add(usize, prefix, payload_len) catch return error.InvalidResumeLength;
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
    try checkPayload(a, payload);
    return encodeUnchecked(a, id, selection, payload);
}

/// Save-path variant: the caller already validated/encoded the checkpoint payload.
pub fn encodeUnchecked(a: std.mem.Allocator, id: ids.Id, selection: *const selections.Snapshot, payload: []const u8) ![]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    if (payload.len == 0) return error.InvalidResumeLength;
    if (selection.model_len == 0 or selection.model_len > selection.model_buffer.len or selection.provider_name_len > selection.provider_name_buffer.len) return error.InvalidResumeSelection;
    var metadata: [selections.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&metadata);
    selections.encode(&writer, selection) catch return error.InvalidResumeSelection;
    const selection_bytes = writer.buffered();
    _ = try parseSelection(a, selection_bytes);
    const bytes = try a.alloc(u8, try totalSize(selection_bytes.len, payload.len));
    @memcpy(bytes[0..8], magic);
    bytes[8] = 3;
    std.mem.writeInt(u32, bytes[9..13], @intCast(selection_bytes.len), .little);
    std.mem.writeInt(u64, bytes[13..21], @intCast(payload.len), .little);
    const end = header_bytes + selection_bytes.len;
    @memcpy(bytes[header_bytes..end], selection_bytes);
    @memcpy(bytes[end..], payload);
    return bytes;
}

pub fn inspect(a: std.mem.Allocator, bytes: []const u8, expected_id: ids.Id) !Envelope {
    if (!ids.valid(expected_id)) return error.InvalidSessionID;
    if (bytes.len < header_v2_bytes) return error.InvalidResumeLength;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidResumeMagic;
    const frame_header: usize = switch (bytes[8]) {
        2 => header_v2_bytes,
        3 => header_bytes,
        else => return error.InvalidResumeVersion,
    };
    if (bytes.len < frame_header) return error.InvalidResumeLength;
    const selection_len = std.mem.readInt(u32, bytes[9..13], .little);
    const payload_len = if (bytes[8] == 2) @as(u64, std.mem.readInt(u32, bytes[13..17], .little)) else std.mem.readInt(u64, bytes[13..21], .little);
    if (selection_len == 0 or selection_len > selections.max_bytes or payload_len == 0) return error.InvalidResumeLength;
    const payload_size = std.math.cast(usize, payload_len) orelse return error.InvalidResumeLength;
    const end = std.math.add(usize, frame_header, selection_len) catch return error.InvalidResumeLength;
    const total = std.math.add(usize, end, payload_size) catch return error.InvalidResumeLength;
    if (total != bytes.len) return error.InvalidResumeLength;
    const selection = try parseSelection(a, bytes[frame_header..end]);
    try checkPayload(a, bytes[end..]);
    return .{ .selection = selection, .payload = bytes[end..], .wire = bytes };
}
