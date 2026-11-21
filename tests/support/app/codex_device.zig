// One owned listener plays both potential routes. CONNECT proves proxy use;
// a TLS ClientHello proves bypass. Reject before any origin HTTP can be sent.
fn rejectOAuthConnection(io: Io, server: *Io.net.Server, direct: bool) !void {
    var stream = try server.accept(io);
    defer stream.close(io);
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = stream.reader(io, &buffer);
    if (direct) {
        try std.testing.expectEqual(@as(u8, 0x16), try reader.interface.takeByte());
        try std.testing.expectEqual(@as(u8, 0x03), try reader.interface.takeByte());
        return;
    }
    var headers: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &headers);
    var len: usize = 0;
    while (len < headers.len) {
        headers[len] = std.ascii.toLower(try reader.interface.takeByte());
        len += 1;
        if (std.mem.endsWith(u8, headers[0..len], "\r\n\r\n")) break;
    } else return error.HeadersTooLarge;
    var first: [96]u8 = undefined;
    const connect = try std.fmt.bufPrint(&first, "connect 127.0.0.1:{d} http/1.1\r\n", .{server.socket.address.getPort()});
    try std.testing.expect(std.mem.startsWith(u8, headers[0..len], connect));
    try std.testing.expect(std.mem.find(u8, headers[0..len], "authorization:") == null);
    try std.testing.expect(std.mem.find(u8, headers[0..len], "synthetic-refresh") == null);
    var out: [128]u8 = undefined;
    var writer = stream.writer(io, &out);
    try writer.interface.writeAll("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
}

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
