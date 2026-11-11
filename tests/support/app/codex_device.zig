const Fake = struct {
    responses: []const struct { status: u16, body: []const u8 },
    index: usize = 0,
    now_ms: i64 = 1000,
    cancel_on_response: ?*p.Cancellation = null,
    fn now(raw: ?*anyopaque, _: Io) i64 {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        return self.now_ms;
    }
    fn post(raw: ?*anyopaque, a: Allocator, _: Io, _: Endpoint, _: Content, _: []const u8, _: ?*const p.Cancellation, _: u32) !Response {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        if (self.index >= self.responses.len) return error.UnexpectedRequest;
        const item = self.responses[self.index];
        self.index += 1;
        const body = try a.dupe(u8, item.body);
        if (self.cancel_on_response) |c| c.cancel();
        return .{ .status = item.status, .body = body };
    }
    fn transport(self: *Fake) Transport {
        return .{ .context = self, .post_fn = post, .now_fn = now };
    }
};
