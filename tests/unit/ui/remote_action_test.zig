test "Codex login submit owns the callback and wipes it on queue abort" {
    const Observer = struct {
        callback: []const u8,
        wiped: bool = false,

        fn free(ctx: *anyopaque, block: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const start = @intFromPtr(self.callback.ptr);
            const base = @intFromPtr(block.ptr);
            if (start >= base and start + self.callback.len <= base + block.len)
                self.wiped = std.mem.allEqual(u8, self.callback, 0);
            std.testing.allocator.rawFree(block, alignment, ra);
        }
    };
    var input = "synthetic-callback".*;
    var observer: Observer = undefined;
    {
        const request = try Owned.create(std.testing.allocator, 1, 2, 3, .{ .codex_login = .{
            .action = .{ .submit = &input },
            .generation = 4,
        } });
        defer request.deinit();
        const login = request.action.codex_login;
        @memset(&input, 'x');
        try std.testing.expectEqualStrings("synthetic-callback", login.action.submit);
        try std.testing.expectEqual(@as(u64, 4), login.generation);
        observer = .{ .callback = login.action.submit };
        request.arena.child_allocator = .{ .ptr = &observer, .vtable = &.{
            .alloc = std.mem.Allocator.noAlloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = Observer.free,
        } };
    }
    try std.testing.expect(observer.wiped);
}

test "large submitted input is owned without an ingress quota" {
    const a = std.testing.allocator;
    const draft = try a.alloc(u8, 65537);
    defer a.free(draft);
    @memset(draft, 'x');
    const request = try Owned.create(a, 1, 2, 3, .{ .submit = .{ .kind = .prompt, .text = draft } });
    defer request.deinit();
    @memset(draft, 'y');
    try std.testing.expectEqual(@as(usize, 65537), request.action.submit.text.len);
    try std.testing.expectEqual(@as(u8, 'x'), request.action.submit.text[65536]);
}
test "resume management request owns its selected project and id" {
    var id = "0123456789abcdef0123456789abcdef".*;
    var project = "/workspace/project A".*;
    const request = try Owned.create(std.testing.allocator, 1, 2, 3, .{ .manage = .{ .@"resume" = .{ .id = id, .project = &project } } });
    defer request.deinit();
    @memset(&id, 'f');
    @memset(&project, 'x');
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", &request.action.manage.@"resume".id);
    try std.testing.expectEqualStrings("/workspace/project A", request.action.manage.@"resume".project.?);
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
