test "connection retry focused: recovery cap cancel timeout and no POST replay" {
    const Case = struct {
        failures: usize = 0,
        err: Io.net.IpAddress.ConnectError = error.ConnectionRefused,
        mode: @FieldType(Server, "mode") = .success,
        expected_attempts: usize,
        expected_kind: ?p.FailureKind = null,
        timeout_ms: u32 = 3000,
        retry_delays_ms: [2]u32 = .{ 20, 50 },
        cancel: bool = false,
        serve: bool = true,
    };
    const cases = [_]Case{
        .{ .failures = 1, .expected_attempts = 2 },
        .{ .failures = 2, .expected_attempts = 3 },
        .{ .failures = 99, .expected_attempts = 3, .expected_kind = .transport, .serve = false },
        .{ .failures = 1, .expected_attempts = 1, .expected_kind = .canceled, .retry_delays_ms = .{ 100, 200 }, .cancel = true, .serve = false },
        .{ .failures = 1, .expected_attempts = 1, .expected_kind = .timeout, .timeout_ms = 60, .retry_delays_ms = .{ 100, 200 }, .serve = false },
        // Second backoff must not get its own fresh timeout budget.
        .{ .failures = 2, .expected_attempts = 2, .expected_kind = .timeout, .timeout_ms = 60, .serve = false },
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
        client.retry_delays_ms = case.retry_delays_ms;
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
        if (!case.serve) {
            // invoke has joined the worker. Crossing both short test retry
            // deadlines must not produce a late socket/POST.
            try Io.sleep(real_io, .fromMilliseconds(150), .awake);
            try t.expectEqual(case.expected_attempts, f.attempts.load(.acquire));
            try t.expectEqual(@as(usize, 0), server.posts.load(.acquire));
            try t.expect(client.http.connection_pool.used.first == null);
            try t.expect(client.last_request_finish == null);
        } else try t.expect(client.last_request_finish != null);
    }
}
