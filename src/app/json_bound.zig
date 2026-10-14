//! Allocation-free lexical preflight shared by bounded metadata parsers.
//! It counts containers, scalar tokens and keys before std.json allocates.
//! JSON syntax, escape validity and duplicate fields are still checked by parsers.
const std = @import("std");

pub const max_depth = 32;

pub fn bound(bytes: []const u8, byte_limit: usize, node_limit: usize) !void {
    if (bytes.len > byte_limit) return error.MetadataTooLarge;
    var stack: [max_depth]u8 = undefined;
    var depth: usize = 0;
    var nodes: usize = 0;
    var quoted = false;
    var escaped = false;
    var scalar = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                quoted = false;
            }
            continue;
        }
        switch (c) {
            '{', '[' => {
                if (depth == stack.len) return error.MetadataTooDeep;
                stack[depth] = c;
                depth += 1;
                nodes += 1;
                scalar = false;
            },
            '}', ']' => {
                if (depth == 0 or stack[depth - 1] != (if (c == '}') @as(u8, '{') else '[')) return error.InvalidMetadata;
                depth -= 1;
                scalar = false;
            },
            '"' => {
                quoted = true;
                nodes += 1;
                scalar = false;
            },
            ' ', '\t', '\r', '\n', ',', ':' => scalar = false,
            else => {
                if (!scalar) nodes += 1;
                scalar = true;
            },
        }
        if (nodes > node_limit) return error.MetadataTooComplex;
    }
    if (quoted or depth != 0) return error.InvalidMetadata;
}

test "bounded lexical preflight rejects depth, complexity and unbalanced input" {
    try bound("{\"a\":[1,2]}", 64, 16);
    try std.testing.expectError(error.MetadataTooLarge, bound("{}", 1, 16));
    try std.testing.expectError(error.MetadataTooComplex, bound("[1,2,3]", 64, 2));
    try std.testing.expectError(error.InvalidMetadata, bound("{]", 64, 16));
    try std.testing.expectError(error.InvalidMetadata, bound("{\"x\":\"open", 64, 16));
    var deep: [max_depth + 1]u8 = undefined;
    @memset(deep[0..max_depth], '[');
    deep[max_depth] = '[';
    try std.testing.expectError(error.MetadataTooDeep, bound(&deep, 64, 1000));
}
