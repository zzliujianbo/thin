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
        .max_output_tokens = 16,
        .cancellation = cancel,
    };
}

fn cancelInBackoff(io: Io, f: *Fault, cancel: *p.Cancellation) anyerror!void {
    // Wait for the injected refusal, then cancel well inside the 200ms sleep.
    while (f.attempts.load(.acquire) == 0) try Io.sleep(io, .fromMilliseconds(1), .awake);
    try Io.sleep(io, .fromMilliseconds(30), .awake);
    cancel.cancel();
}

// One serial test owns the seam for its entire lifetime. Each scenario gets a
// fresh backend, client and listener. No shared integration fixtures or env/key.
test "connection retry focused: recovery cap cancel timeout and no POST replay" {
    const Case = struct {
        failures: usize = 0,
        err: Io.net.IpAddress.ConnectError = error.ConnectionRefused,
        mode: @FieldType(Server, "mode") = .success,
        expected_attempts: usize,
        expected_kind: ?p.FailureKind = null,
        timeout_ms: u32 = 3000,
        cancel: bool = false,
        serve: bool = true,
    };
    const cases = [_]Case{
        .{ .failures = 1, .expected_attempts = 2 },
        .{ .failures = 2, .expected_attempts = 3 },
        .{ .failures = 99, .expected_attempts = 3, .expected_kind = .transport, .serve = false },
        .{ .failures = 1, .expected_attempts = 1, .expected_kind = .canceled, .cancel = true, .serve = false },
        .{ .failures = 1, .expected_attempts = 1, .expected_kind = .timeout, .timeout_ms = 60, .serve = false },
        // Second backoff must not get its own fresh timeout budget.
        .{ .failures = 2, .expected_attempts = 2, .expected_kind = .timeout, .timeout_ms = 350, .serve = false },
        .{ .failures = 99, .err = error.AccessDenied, .expected_attempts = 1, .expected_kind = .transport, .serve = false },
        .{ .mode = .before_head, .expected_attempts = 1, .expected_kind = .transport },
        .{ .mode = .mid_stream, .expected_attempts = 1, .expected_kind = .transport },
        .{ .mode = .rate_limit, .expected_attempts = 1, .expected_kind = .rate_limit },
        .{ .mode = .server_error, .expected_attempts = 1, .expected_kind = .server },
    };
    for (cases, 0..) |case, case_index| {
        var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
        defer backend.deinit();
        const real_io = backend.io();
        var table = real_io.vtable.*;
        table.netConnectIp = connect;
        const io: Io = .{ .userdata = real_io.userdata, .vtable = &table };
        var f: Fault = .{ .original = real_io, .failures = case.failures, .err = case.err };
        fault = &f;
        defer fault = null;
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server: Server = .{ .io = real_io, .listener = try address.listen(real_io, .{ .reuse_address = true }), .mode = case.mode };
        defer server.listener.deinit(real_io);
        var sf: ?Io.Future(anyerror!void) = if (case.serve) try Io.concurrent(real_io, Server.run, .{&server}) else null;
        defer if (sf) |*future| {
            future.cancel(real_io) catch {};
        };
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{server.listener.socket.address.getPort()});
        var config: cfg.Config = .{
            .provider = .{ .base_url = url },
            .model = .{ .name = "fixture", .context_tokens = 32768 },
            .limits = .{ .request_timeout_ms = case.timeout_ms },
        };
        var client = try Client.init(t.allocator, io, &config, "fake-offline-key");
        defer client.deinit();
        var cancellation: p.Cancellation = .{};
        var cf: ?Io.Future(anyerror!void) = if (case.cancel) try Io.concurrent(real_io, cancelInBackoff, .{ real_io, &f, &cancellation }) else null;
        defer if (cf) |*future| {
            future.cancel(real_io) catch {};
        };
        const started = Io.Clock.awake.now(real_io);
        const out = try client.model().call(a, request(&config, &cancellation), .{});
        const elapsed_ms = started.untilNow(real_io, .awake).toMilliseconds();
        if (case.expected_kind) |kind| {
            try t.expect(out == .failure);
            try t.expectEqual(kind, out.failure.kind);
        } else if (out == .failure) {
            // Only local case IDs and normalized kinds, never upstream text.
            std.debug.print("retry case {d}: unexpected {s}, attempts={d}\n", .{ case_index, @tagName(out.failure.kind), f.attempts.load(.acquire) });
            return error.ExpectedSuccess;
        }
        if (case.mode == .mid_stream) try t.expect(out.failure.observed_content);
        if (sf) |*future| try future.await(real_io);
        if (cf) |*future| try future.await(real_io);
        try t.expectEqual(case.expected_attempts, f.attempts.load(.acquire));
        try t.expectEqual(@as(usize, if (case.serve) 1 else 0), server.posts.load(.acquire));
        if (case.cancel or case.timeout_ms == 60) try t.expect(elapsed_ms < 190);
        if (case.timeout_ms == 350) try t.expect(elapsed_ms < 650);
        if (!case.serve) {
            // invoke has joined the worker. Crossing both retry deadlines must
            // not produce a late socket/POST after cancellation/timeout.
            try Io.sleep(real_io, .fromMilliseconds(750), .awake);
            try t.expectEqual(case.expected_attempts, f.attempts.load(.acquire));
            try t.expectEqual(@as(usize, 0), server.posts.load(.acquire));
            try t.expect(client.http.connection_pool.used.first == null);
            try t.expect(client.last_request_finish == null);
        } else try t.expect(client.last_request_finish != null);
    }
}
