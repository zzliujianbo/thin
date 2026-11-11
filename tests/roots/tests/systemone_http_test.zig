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
        \\{{"llm":{{"default":"main/chat","providers":{{"main":{{"base_url":"{s}/primary-never","api_key":"fake-primary-key","models":{{"chat":{{"protocol":"chat","context_tokens":32768}}}}}},"aux":{{"base_url":"{s}/{s}","api_key":"fake-systemone-key","models":{{"jev-fixture":{{"protocol":"systemone"}}}}}}}}}},"decision":{{"model":"aux/jev-fixture","max_state_bytes":16384}},"limits":{{"request_timeout_ms":{d}}}}}
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
    try t.expect(client.resolved == null and client.native == null and client.calls == 0);
    try t.expect(client.last_usage.input_tokens == null);
    return client;
}

const command: decision.Input = .{ .command = .{ .command = "printf fixture" } };

fn independent(client: *Client, calls: u64) !void {
    const resolved = client.resolved orelse return error.MissingNativeResolution;
    try t.expect(resolved.client == null); // Native resolution never creates a Chat client.
    try t.expect(resolved.config.value.model.protocol == .systemone);
    try t.expectEqualStrings("jev-fixture", resolved.config.value.model.name);
    try t.expectEqual(client.source.value.limits.request_timeout_ms, resolved.config.value.limits.request_timeout_ms);
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
