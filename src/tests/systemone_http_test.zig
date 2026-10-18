//! Run only through tests/product/systemone_mock.mjs. No ambient credentials/network.
const std = @import("std");
const cfg = @import("../core/config.zig");
const decision = @import("../core/decision.zig");
const p = @import("../core/protocol.zig");
const Client = @import("../app/decision_client.zig").Client;
const t = std.testing;
const Io = std.Io;

fn fixture(name: []const u8) ![]const u8 {
    return std.testing.environ.getPosix(name) orelse error.MissingSystemoneFixture;
}

// Even fixture URLs are validated before they can reach the real transport.
fn base(name: []const u8, tls: bool, mismatch: bool) ![]const u8 {
    const text = try fixture(name);
    const uri = try std.Uri.parse(text);
    const host = uri.host orelse return error.UnsafeFixture;
    const hostname = switch (host) {
        .raw, .percent_encoded => |v| v,
    };
    if (!std.mem.eql(u8, uri.scheme, if (tls) "https" else "http") or
        !std.mem.eql(u8, hostname, if (mismatch) "localhost" else "127.0.0.1") or
        uri.port == null or uri.port == 0 or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or !uri.path.isEmpty()) return error.UnsafeFixture;
    return text;
}

const Trust = enum { direct, trusted_proxy, untrusted_proxy, mismatch_proxy };
fn makeClient(a: std.mem.Allocator, io: Io, scenario: []const u8, timeout_ms: u32, trust: Trust) !*Client {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", try fixture("HOME"));
    // Explicit empty proxy map for direct calls; no transport environment is inherited.
    if (trust != .direct) {
        try env.put("HTTPS_PROXY", try base("THIN_SYSTEMONE_PROXY", false, false));
        try env.put("NO_PROXY", "");
        if (trust != .untrusted_proxy) try env.put("CURL_CA_BUNDLE", try fixture("THIN_SYSTEMONE_CA"));
    }
    const origin = try base(if (trust == .direct) "THIN_SYSTEMONE_HTTP" else if (trust == .mismatch_proxy) "THIN_SYSTEMONE_MISMATCH" else "THIN_SYSTEMONE_HTTPS", trust != .direct, trust == .mismatch_proxy);
    const text = try std.fmt.allocPrint(a,
        \\{{"llm":{{"default":"main/chat","providers":{{"main":{{"base_url":"{s}/primary-never","api_key":"fake-primary-key","models":{{"chat":{{"protocol":"chat","context_tokens":32768}}}}}},"aux":{{"base_url":"{s}/{s}","api_key":"fake-systemone-key"}}}}}},"decision":{{"model":"aux/jev-fixture","backend":"systemone","max_state_bytes":16384,"request_timeout_ms":{d}}}}}
    , .{ try base("THIN_SYSTEMONE_HTTP", false, false), origin, scenario, timeout_ms });
    defer a.free(text);
    var parsed = try cfg.parse(a, text);
    defer cfg.release(&parsed);
    if (trust != .direct) {
        const proxy = try std.Uri.parse(try base("THIN_SYSTEMONE_PROXY", false, false));
        parsed.value.proxy = .{ .address = "127.0.0.1", .port = proxy.port.?, .models = &.{"aux/jev-fixture"} };
        // The explicit allowlist, not inherited HTTPS_PROXY, owns this route.
        try env.put("NO_PROXY", "*");
    }
    const client = (try Client.create(a, io, parsed.value, &env)) orelse return error.MissingClient;
    errdefer client.deinit();
    try t.expect(client.resolved == null and client.calls == 0);
    try t.expect(client.last_usage.input_tokens == null);
    return client;
}

const command: decision.Input = .{ .command = .{ .command = "printf fixture", .proposed_timeout_ms = 120000, .max_timeout_ms = 300000 } };
const memory: decision.Input = .{ .memory_write = .{ .topic = "style/original-id", .content = "Prefer explicit bounded ownership and concise reports.", .expected_version = "v-original-7" } };

fn independent(client: *Client, calls: u64) !void {
    try t.expect(client.resolved == null); // No primary resolution or capability borrowing.
    try t.expectEqual(calls, client.calls);
    try t.expectEqualStrings("main/chat", client.source.value.registry.?.default);
    try t.expectEqualStrings("fake-systemone-key", client.key.?);
    const primary = try std.fmt.allocPrint(t.allocator, "{s}/primary-never", .{try base("THIN_SYSTEMONE_HTTP", false, false)});
    defer t.allocator.free(primary);
    try t.expectEqualStrings(primary, client.source.value.provider.base_url);
    try t.expectEqual(@as(u32, 32768), client.source.value.model.context_tokens);
}

fn usage(client: *Client) !void {
    try t.expectEqual(@as(?u16, 200), client.last_http_status);
    try t.expectEqual(@as(?u64, 37), client.last_usage.input_tokens);
    try t.expectEqual(@as(?u64, 4), client.last_usage.output_tokens);
    try independent(client, 1);
}

// Wait for the fixture to observe the complete body, never cancel merely on a timer.
fn cancelAfterArrival(io: Io, cancel: *p.Cancellation, marker: []const u8) anyerror!void {
    const start = Io.Clock.awake.now(io);
    while (start.untilNow(io, .awake).toMilliseconds() < 5000) {
        if (Io.Dir.cwd().openFile(io, marker, .{})) |file| {
            file.close(io);
            cancel.cancel();
            return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.CancellationArrivalMarkerMissing;
}

test "SystemOne owned HTTP app decisions conservative policy and independent route" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const io = backend.io();
    const a = t.allocator;
    var cancel = p.Cancellation{};
    for ([_][]const u8{ "command-none", "command-finite", "command-uncertain" }) |scenario| {
        const client = try makeClient(a, io, scenario, 3000, .direct);
        defer client.deinit();
        const out = try client.service().decide(a, command, &cancel);
        defer decision.freeOutput(a, out);
        if (std.mem.eql(u8, scenario, "command-none")) {
            try t.expect(!out.command.ask);
            try t.expect(out.command.timeout == .none);
        } else {
            try t.expect(out.command.ask);
            try t.expectEqual(@as(u32, if (std.mem.eql(u8, scenario, "command-finite")) 30000 else 120000), out.command.timeout.milliseconds);
        }
        try usage(client);
    }
    for ([_][]const u8{ "memory-positive", "memory-negative" }) |scenario| {
        const client = try makeClient(a, io, scenario, 3000, .direct);
        defer client.deinit();
        const out = try client.service().decide(a, memory, &cancel);
        try t.expectEqual(std.mem.eql(u8, scenario, "memory-positive"), out.memory_write);
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

test "SystemOne owned failures never retry redirect or silently fallback" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const io = backend.io();
    const a = t.allocator;
    for ([_][]const u8{ "invalid-json", "invalid-score", "missing-answers", "forbidden", "server-error", "redirect", "oversized", "truncated", "stalled", "cancel" }) |scenario| {
        const is_cancel = std.mem.eql(u8, scenario, "cancel");
        const is_stall = std.mem.eql(u8, scenario, "stalled");
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
            if (std.mem.startsWith(u8, scenario, "invalid") or std.mem.eql(u8, scenario, "missing-answers")) try t.expectEqual(error.InvalidDecisionOutput, err);
        }
        if (future) |*f| try f.await(io);
        try t.expect(start.untilNow(io, .awake).toMilliseconds() < 6000);
        try independent(client, 1);
        try t.expect(client.last_usage.input_tokens == null and client.last_usage.output_tokens == null);
        if (std.mem.eql(u8, scenario, "forbidden")) try t.expectEqual(@as(?u16, 403), client.last_http_status);
        if (std.mem.eql(u8, scenario, "server-error")) try t.expectEqual(@as(?u16, 500), client.last_http_status);
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
            const out = try client.service().decide(t.allocator, memory, &cancel);
            try t.expect(out.memory_write);
            try usage(client);
        } else {
            if (client.service().decide(t.allocator, memory, &cancel)) |out| {
                decision.freeOutput(t.allocator, out);
                return error.ExpectedCertificateFailure;
            } else |_| {}
            try independent(client, 1);
            try t.expect(client.last_http_status == null);
        }
    }
}
