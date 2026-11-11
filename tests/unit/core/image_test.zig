test "image inspection is bounded and a poisoned service wins over cancellation" {
    const Fake = struct {
        calls: usize = 0,
        poisoned: bool = false,
        fn check(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.poisoned) return error.CleanupFailed;
        }
        fn inspect(raw: *anyopaque, a: std.mem.Allocator, _: Input, _: *const p.Cancellation) !Output {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .text = try a.dupe(u8, "image description") };
        }
    };
    var fake: Fake = .{};
    const service: Service = .{ .context = &fake, .inspect_fn = Fake.inspect, .check_fn = Fake.check };
    const input: Input = .{ .image = .{ .data = "fixture", .format = .png, .width = 1, .height = 1 } };
    var cancel: p.Cancellation = .{};
    const output = try service.inspect(std.testing.allocator, input, &cancel);
    defer std.testing.allocator.free(output.text);
    try std.testing.expectEqualStrings("image description", output.text);
    cancel.cancel();
    try std.testing.expectError(error.Canceled, service.inspect(std.testing.allocator, input, &cancel));
    fake.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, service.inspect(std.testing.allocator, input, &cancel));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    var invalid = input;
    invalid.image.width = max_dimension + 1;
    try std.testing.expectError(error.InvalidImageDimensions, validate(invalid));
    invalid = input;
    invalid.question = "";
    try std.testing.expectError(error.InvalidImageQuestion, validate(invalid));
}
