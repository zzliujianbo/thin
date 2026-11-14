//! Codex Responses driver. Codex is not a public Protocol; it is selected by
//! the openai_codex provider and uses the Responses stream grammar with a
//! Codex-specific request body.
const std = @import("std");
const responses = @import("responses.zig");

pub const Stream = responses.Stream;

pub fn encode(a: std.mem.Allocator, req: @import("../core/protocol.zig").Request) ![]u8 {
    return responses.encodeCodex(a, req);
}
