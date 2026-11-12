test "SystemOne owned HTTP app decisions conservative policy and independent route" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const io = backend.io();
    const a = t.allocator;
    var cancel = p.Cancellation{};
    for ([_][]const u8{ "command-boundary", "command-above", "command-high" }) |scenario| {
        const client = try makeClient(a, io, scenario, 3000, .direct);
        defer client.deinit();
        const out = try client.service().decide(a, command, &cancel);
        defer decision.freeOutput(a, out);
        try t.expectEqual(!std.mem.eql(u8, scenario, "command-boundary"), out.command.ask);
        try usage(client);
    }
    // More than 2KiB, with a critical middle error, operational metadata and
    // hundreds of progress lines. Only exact trivial middle lines may disappear.
    var original: std.Io.Writer.Allocating = .init(a);
    defer original.deinit();
    try original.writer.writeAll("BEGIN path=src/worker.zig version=v7 count=91\nprogress 0%\n");
    for (0..240) |i| {
        if (i == 120) try original.writer.writeAll("ERROR src/worker.zig:417 unresolved: checksum mismatch\nmetadata exit=23 truncated=true state=failed\nprogress important diagnostic\n");
        try original.writer.writeAll("tick\nprogress 50%\n");
    }
    try original.writer.writeAll("progress 100%\nEND unresolved failure, do not claim success\n");
    try t.expect(original.written().len >= 2048);
    const items = [_]decision.RefineItem{
        .{ .id = "call_original/alpha-42", .text = original.written() },
        .{ .id = "call_original/beta-99", .text = "tick\nmetadata untouched\ntick\nERROR keep me\ntick\n" },
    };
    const client = try makeClient(a, io, "refine", 3000, .direct);
    defer client.deinit();
    const out = try client.service().decide(a, .{ .refine_outputs = &items }, &cancel);
    defer decision.freeOutput(a, out);
    try t.expectEqual(@as(usize, 2), out.refine_outputs.len);
    try t.expectEqualStrings(items[0].id, out.refine_outputs[0].id);
    try t.expectEqualStrings(items[1].id, out.refine_outputs[1].id);
    try t.expectEqualStrings("BEGIN path=src/worker.zig version=v7 count=91\nprogress 0%\nERROR src/worker.zig:417 unresolved: checksum mismatch\nmetadata exit=23 truncated=true state=failed\nprogress important diagnostic\nprogress 100%\nEND unresolved failure, do not claim success\n", out.refine_outputs[0].text);
    try t.expectEqualStrings(items[1].text, out.refine_outputs[1].text);
    try usage(client);
}
test "SystemOne no-op uses owned copies and mixed batch sends once unchanged" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const a = t.allocator;
    var cancel: p.Cancellation = .{};
    const no_op = try makeClient(a, backend.io(), "no-op", 3000, .direct);
    defer no_op.deinit();
    const id = try a.dupe(u8, "immutable-id");
    defer a.free(id);
    const text = try a.dupe(u8, "诊断\ntick\nERROR");
    defer a.free(text);
    const unchanged = [_]decision.RefineItem{
        .{ .id = id, .text = text },
        .{ .id = "fenced", .text = "```\ntick\ntick\ntick\n```" },
    };
    const copied = try no_op.service().decide(a, .{ .refine_outputs = &unchanged }, &cancel);
    defer decision.freeOutput(a, copied);
    try t.expectEqual(@as(usize, 2), copied.refine_outputs.len);
    for (unchanged, copied.refine_outputs) |original, owned| {
        try t.expectEqualStrings(original.id, owned.id);
        try t.expectEqualStrings(original.text, owned.text);
        try t.expect(original.id.ptr != owned.id.ptr and original.text.ptr != owned.text.ptr);
    }
    @memset(id, 'x');
    @memset(text, 'x');
    try t.expectEqualStrings("immutable-id", copied.refine_outputs[0].id);
    try t.expectEqualStrings("诊断\ntick\nERROR", copied.refine_outputs[0].text);
    try independent(no_op, 0);
    try t.expect(no_op.last_http_status == null and no_op.last_failure == null);
    inline for (@typeInfo(p.Usage).@"struct".field_names) |name| try t.expect(@field(no_op.last_usage, name) == null);

    const mixed = [_]decision.RefineItem{
        .{ .id = "unchanged/id", .text = "diagnostic\ntick\nend" },
        .{ .id = "eligible/id", .text = "BEGIN\ntick\nprogress 2%\nERROR\ntick\nEND" },
        .{ .id = "fenced/id", .text = "~~~\ntick\ntick\ntick\n~~~" },
    };
    const client = try makeClient(a, backend.io(), "mixed-refine", 3000, .direct);
    defer client.deinit();
    const refined = try client.service().decide(a, .{ .refine_outputs = &mixed }, &cancel);
    defer decision.freeOutput(a, refined);
    try t.expectEqual(@as(usize, mixed.len), refined.refine_outputs.len);
    for (mixed, refined.refine_outputs) |original, owned| {
        try t.expectEqualStrings(original.id, owned.id);
        try t.expect(original.id.ptr != owned.id.ptr and original.text.ptr != owned.text.ptr);
    }
    try t.expectEqualStrings(mixed[0].text, refined.refine_outputs[0].text);
    try t.expectEqualStrings("BEGIN\ntick\nERROR\ntick\nEND", refined.refine_outputs[1].text);
    try t.expectEqualStrings(mixed[2].text, refined.refine_outputs[2].text);
    try usage(client);
}
test "SystemOne owned failures never retry redirect or silently fallback" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const io = backend.io();
    const a = t.allocator;
    for ([_][]const u8{ "invalid-json", "invalid-score", "missing-answers", "forbidden", "server-error", "redirect", "oversized", "truncated", "stalled", "cancel" }) |scenario| {
        const is_cancel = std.mem.eql(u8, scenario, "cancel");
        const is_stall = std.mem.eql(u8, scenario, "stalled");
        // The legacy "oversized" fixture is whitespace-only, not valid JSON:
        // its size is accepted by transport and rejected by semantic decoding.
        const invalid_output = std.mem.startsWith(u8, scenario, "invalid") or std.mem.eql(u8, scenario, "missing-answers") or std.mem.eql(u8, scenario, "oversized");
        const client = try makeClient(a, io, scenario, if (is_stall) 350 else if (is_cancel) 8000 else 3000, .direct);
        defer client.deinit();
        var cancel = p.Cancellation{};
        const marker = try std.fmt.allocPrint(a, "{s}/cancel-arrived", .{try fixture("HOME")});
        defer a.free(marker);
        var future: ?Io.Future(anyerror!void) = if (is_cancel) try Io.concurrent(io, cancelAfterArrival, .{ io, &cancel, marker }) else null;
        defer if (future) |*f| {
            f.cancel(io) catch {};
        };
        const start = Io.Clock.awake.now(io);
        if (client.service().decide(a, command, &cancel)) |out| {
            decision.freeOutput(a, out);
            return error.ExpectedFailClosed;
        } else |err| {
            if (is_cancel) try t.expectEqual(error.Canceled, err);
            if (invalid_output) try t.expectEqual(error.InvalidDecisionOutput, err);
        }
        if (future) |*f| try f.await(io);
        try t.expect(start.untilNow(io, .awake).toMilliseconds() < 6000);
        try independent(client, 1);
        try t.expect(client.last_usage.input_tokens == null and client.last_usage.output_tokens == null);
        if (std.mem.eql(u8, scenario, "forbidden")) try t.expectEqual(@as(?u16, 403), client.last_http_status);
        if (std.mem.eql(u8, scenario, "server-error")) try t.expectEqual(@as(?u16, 500), client.last_http_status);
        if (is_cancel) {
            try t.expect(client.last_failure == null);
        } else {
            const diagnostic = client.last_failure.?;
            try t.expectEqual(decision.Diagnostic.Backend.systemone, diagnostic.backend);
            try t.expectEqual(decision.Diagnostic.Operation.command, diagnostic.operation);
            try t.expectEqual(client.last_http_status, diagnostic.http_status);
            try t.expect(diagnostic.causeName().len != 0);
            if (invalid_output) {
                try t.expectEqual(decision.Diagnostic.Stage.decode, diagnostic.stage);
                try t.expectEqualStrings("InvalidDecisionOutput", diagnostic.causeName());
            }
            if (std.mem.eql(u8, scenario, "forbidden") or std.mem.eql(u8, scenario, "server-error") or std.mem.eql(u8, scenario, "redirect")) {
                try t.expectEqual(decision.Diagnostic.Stage.http, diagnostic.stage);
            }
            if (is_stall) try t.expectEqual(decision.Diagnostic.Stage.transport, diagnostic.stage);
        }
    }
}
test "SystemOne real curl CONNECT TLS CA and hostname verification" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    for ([_]Trust{ .trusted_proxy, .untrusted_proxy, .mismatch_proxy }) |trust| {
        const client = try makeClient(t.allocator, backend.io(), @tagName(trust), 3000, trust);
        defer client.deinit();
        var cancel = p.Cancellation{};
        if (trust == .trusted_proxy) {
            const out = try client.service().decide(t.allocator, command, &cancel);
            try t.expect(out.command.ask);
            try usage(client);
        } else {
            if (client.service().decide(t.allocator, command, &cancel)) |out| {
                decision.freeOutput(t.allocator, out);
                return error.ExpectedCertificateFailure;
            } else |_| {}
            try independent(client, 1);
            try t.expect(client.last_http_status == null);
            const diagnostic = client.last_failure.?;
            try t.expectEqual(decision.Diagnostic.Stage.transport, diagnostic.stage);
            // curl 60 means certificate verification failed; no body or stderr
            // enters diagnostics and the owned fixture still proves zero HTTP.
            try t.expectEqual(@as(?u8, 60), diagnostic.transport_exit_code);
        }
    }
}
