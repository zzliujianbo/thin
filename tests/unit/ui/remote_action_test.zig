test "resume management request owns its selected id" {
    var id = "0123456789abcdef0123456789abcdef".*;
    const request = try Owned.create(std.testing.allocator, 1, 2, 3, .{ .manage = .{ .@"resume" = &id } });
    defer request.deinit();
    @memset(&id, 'f');
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", request.action.manage.@"resume");
}
test "asynchronous commands own text independently of the editor and retain identity" {
    var draft: [5]u8 = @splat('x');
    const request = try Owned.create(std.testing.allocator, 11, 9, 7, .{ .submit = .{ .kind = .prompt, .text = &draft } });
    defer request.deinit();
    @memset(&draft, 'y');
    try std.testing.expectEqualStrings("xxxxx", request.action.submit.text);
    try std.testing.expectEqual(@as(u64, 11), request.ticket);
    try std.testing.expectEqual(@as(u64, 9), request.generation);
    try std.testing.expectEqual(@as(u64, 7), request.epoch);
}
