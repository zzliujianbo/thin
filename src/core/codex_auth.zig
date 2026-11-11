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

pub const CredentialSource = struct {
    context: ?*anyopaque = null,
    acquire_fn: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, ?*const protocol.Cancellation, u32) anyerror!RequestCredential = null,

    pub fn acquire(self: CredentialSource, a: std.mem.Allocator, provider_alias: []const u8, cancel: ?*const protocol.Cancellation, remaining_timeout_ms: u32) !RequestCredential {
        const callback = self.acquire_fn orelse return error.MissingCredentialSource;
        return callback(self.context, a, provider_alias, cancel, remaining_timeout_ms);
    }
};
