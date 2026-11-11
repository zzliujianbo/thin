//! Allocation-free lexical preflight shared by bounded metadata parsers.
//! It counts containers, scalar tokens and keys before std.json allocates.
//! JSON syntax, escape validity and duplicate fields are still checked by parsers.

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
