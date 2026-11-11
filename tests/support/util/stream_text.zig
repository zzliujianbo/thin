const TestSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    fail: bool = false,
    fn emit(self: *TestSink, safe: []const u8) !void {
        if (self.fail) return error.TestFailure;
        try self.bytes.appendSlice(std.testing.allocator, safe);
    }
    fn deinit(self: *TestSink) void {
        self.bytes.deinit(std.testing.allocator);
    }
};
