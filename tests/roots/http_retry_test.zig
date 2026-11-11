//! Private offline transport seam: only netConnectIp is replaced. All other
//! operations retain the original Threaded userdata/vtable, including sleep and
//! cancellation. Actual successful connections go only to our owned loopback.
const std = @import("std");
const Io = std.Io;
const t = std.testing;
const Client = @import("llm/http.zig").Client;
const cfg = @import("core/config.zig");
const p = @import("core/protocol.zig");

const Fault = struct {
    original: Io,
    attempts: std.atomic.Value(usize) = .init(0),
    failures: usize,
    err: Io.net.IpAddress.ConnectError = error.ConnectionRefused,
};
// Used only by this single serial test, published before worker creation and
// removed only after every worker is joined. Never part of production Client.
var fault: ?*Fault = null;
fn connect(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    const f = fault.?;
    const n = f.attempts.fetchAdd(1, .acq_rel);
    if (n < f.failures) return f.err;
    return f.original.vtable.netConnectIp(userdata, address, options);
}

const Server = struct {
    io: Io,
    listener: Io.net.Server,
    mode: enum { success, before_head, mid_stream, rate_limit, server_error },
    posts: std.atomic.Value(usize) = .init(0),

    fn run(self: *Server) anyerror!void {
        const stream = try self.listener.accept(self.io);
        defer stream.close(self.io);
        var rb: [8192]u8 = undefined;
        var wb: [8192]u8 = undefined;
        var r = stream.reader(self.io, &rb);
        var w = stream.writer(self.io, &wb);
        var server = std.http.Server.init(&r.interface, &w.interface);
        var req = try server.receiveHead();
        try t.expectEqual(std.http.Method.POST, req.head.method);
        const size = req.head.content_length orelse return error.MissingLength;
        try t.expect(size <= 4096);
        var body: [4096]u8 = undefined;
        const reader = req.readerExpectNone(&.{});
        try reader.readSliceAll(body[0..@intCast(size)]);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body[0..@intCast(size)], .{});
        defer parsed.deinit();
        inline for (.{ "max_tokens", "max_completion_tokens", "max_output_tokens" }) |key|
            try t.expect(parsed.value.object.get(key) == null);
        // Count fully received POSTs, not TCP connections or partial headers.
        _ = self.posts.fetchAdd(1, .release);
        switch (self.mode) {
            .before_head => return,
            .mid_stream => {
                try w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 9999\r\nConnection: close\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n");
                try w.interface.flush();
            },
            .success => try req.respond("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", .{
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            }),
            .rate_limit, .server_error => try req.respond("{}", .{
                .status = if (self.mode == .rate_limit) .too_many_requests else .internal_server_error,
                .keep_alive = false,
            }),
        }
    }
};

fn request(config: *const cfg.Config, cancel: ?*const p.Cancellation) p.Request {
    return .{
        .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = .chat },
        .system = "offline fixture",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "hello" }} }},
        .tools = &.{},
        .cancellation = cancel,
    };
}

fn cancelInBackoff(io: Io, f: *Fault, cancel: *p.Cancellation) anyerror!void {
    // Wait for the injected refusal, then cancel well inside its backoff sleep.
    while (f.attempts.load(.acquire) == 0) try Io.sleep(io, .fromMilliseconds(1), .awake);
    try Io.sleep(io, .fromMilliseconds(5), .awake);
    cancel.cancel();
}

// One serial test owns the seam for its entire lifetime. Each scenario gets a
// fresh backend, client and listener. No shared integration fixtures or env/key.
