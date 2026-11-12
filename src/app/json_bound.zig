//! Strict, iterative JSON preflight with dynamically allocated nesting state.
const std = @import("std");

pub fn validate(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    while (true) {
        const token = try scanner.next();
        if (token == .end_of_document) return;
    }
}
