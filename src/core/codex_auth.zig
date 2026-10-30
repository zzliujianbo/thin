const std = @import("std");
const protocol = @import("protocol.zig");

pub const RequestCredential = struct {
    access_token: []u8,
    account_id: []u8,
    /// Private redaction material; never encoded or sent on the wire.
    redaction_refresh_token: ?[]u8 = null,

    pub fn deinit(self: *RequestCredential, a: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.access_token);
        std.crypto.secureZero(u8, self.account_id);
        if (self.redaction_refresh_token) |refresh| {
            std.crypto.secureZero(u8, refresh);
            a.free(refresh);
        }
        a.free(self.access_token);
        a.free(self.account_id);
        self.* = undefined;
    }
};

test "request credential releases all three erased buffers" {
    const Observer = struct {
        backing: std.mem.Allocator,
        frees: usize = 0,
        pointers: [3]?[*]u8 = .{ null, null, null },
        seen: [3]bool = .{ false, false, false },
        canary_found: bool = false,
        nonzero: bool = false,
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawAlloc(len, alignment, ra);
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(ctx: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.frees += 1;
            for (self.pointers, 0..) |ptr, i| if (ptr != null and ptr.? == bytes.ptr) {
                self.seen[i] = true;
            };
            for (bytes) |byte| {
                if (byte == 'A' or byte == 'B' or byte == 'C') self.canary_found = true;
                if (byte != 0) self.nonzero = true;
            }
        }
    };
    var storage: [128]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var observer: Observer = .{ .backing = fixed.allocator() };
    const a: std.mem.Allocator = .{ .ptr = &observer, .vtable = &.{ .alloc = Observer.alloc, .resize = Observer.resize, .remap = Observer.remap, .free = Observer.free } };
    var credential: RequestCredential = .{
        .access_token = try a.dupe(u8, "AAAAAAAA"),
        .account_id = try a.dupe(u8, "BBBBBBBB"),
        .redaction_refresh_token = try a.dupe(u8, "CCCCCCCC"),
    };
    observer.pointers = .{ credential.access_token.ptr, credential.account_id.ptr, credential.redaction_refresh_token.?.ptr };
    credential.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), observer.frees);
    try std.testing.expect(observer.seen[0] and observer.seen[1] and observer.seen[2]);
    try std.testing.expect(!observer.canary_found);
    if (@import("builtin").mode == .small) try std.testing.expect(!observer.nonzero);
}

pub const CredentialSource = struct {
    context: ?*anyopaque = null,
    acquire_fn: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, ?*const protocol.Cancellation, u32) anyerror!RequestCredential = null,

    pub fn acquire(self: CredentialSource, a: std.mem.Allocator, provider_alias: []const u8, cancel: ?*const protocol.Cancellation, remaining_timeout_ms: u32) !RequestCredential {
        const callback = self.acquire_fn orelse return error.MissingCredentialSource;
        return callback(self.context, a, provider_alias, cancel, remaining_timeout_ms);
    }
};
