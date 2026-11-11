test "diagnostic span pairs and cancellation is idempotent" {
    const Capture = struct {
        records: [2]Record = undefined,
        count: usize = 0,
        fn next(_: ?*anyopaque) u64 {
            return 7;
        }
        fn emit(ctx: ?*anyopaque, record: Record) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.records[self.count] = record;
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    var span = Span.start(.{ .context = &capture, .emit_fn = Capture.emit, .next_fn = Capture.next }, std.testing.io, .{ .stage = .memory_finalize });
    span.fail(error.Canceled);
    span.finish(.ok);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(Phase.begin, capture.records[0].phase);
    try std.testing.expectEqual(Phase.end, capture.records[1].phase);
    try std.testing.expectEqual(Result.canceled, capture.records[1].result.?);
    try std.testing.expectEqualStrings("Canceled", capture.records[1].error_name.?.name());
}
test "diagnostic disabled and bounded error name" {
    const n = ErrorName.fromError(error.Canceled);
    try std.testing.expectEqualStrings("Canceled", n.name());
    try std.testing.expectEqual(@as(u64, 0), (Sink{}).next());
}
