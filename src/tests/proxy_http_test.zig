//! No real configuration, credentials, ambient network or external DNS.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const Client = @import("../llm/http.zig").Client;
const DecisionClient = @import("../app/decision_client.zig").Client;
const decision = @import("../core/decision.zig");
const t = std.testing;
const Io = std.Io;
const messages = [_]p.Message{.{ .role = .user, .blocks = &.{.{ .text = "owned fixture" }} }};
const tools = [_]p.ToolSchema{.{ .name = "lookup", .description = "fixture", .parameters_json = "{\"type\":\"object\",\"properties\":{}}" }};

fn envValue(name: []const u8) ![]const u8 {
    return t.environ.getPosix(name) orelse error.MissingProxyFixture;
}
fn origin(name: []const u8, scheme: []const u8, hostname: []const u8) ![]const u8 {
    const text = try envValue(name);
    const uri = try std.Uri.parse(text);
    const host = uri.host orelse return error.UnsafeFixture;
    const actual = switch (host) {
        .raw, .percent_encoded => |v| v,
    };
    if (!std.mem.eql(u8, uri.scheme, scheme) or !std.mem.eql(u8, actual, hostname) or uri.port == null or uri.port == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or !uri.path.isEmpty()) return error.UnsafeFixture;
    return text;
}
fn proxyPort(down: bool) !u16 {
    return std.fmt.parseInt(u16, try envValue(if (down) "THIN_PROXY_DOWN_PORT" else "THIN_PROXY_PORT"), 10);
}
fn transportEnv(a: std.mem.Allocator, good_ca: bool) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(a);
    errdefer env.deinit();
    try env.put("HOME", try envValue("HOME"));
    try env.put("CURL_CA_BUNDLE", try envValue(if (good_ca) "THIN_PROXY_CA" else "THIN_PROXY_WRONG_CA"));
    // Hostile ambient values must neither bypass listed routes nor capture direct ones.
    const proxy = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{try proxyPort(false)});
    defer a.free(proxy);
    for ([_][]const u8{ "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy" }) |name| try env.put(name, proxy);
    try env.put("NO_PROXY", "*");
    try env.put("no_proxy", "*");
    return env;
}
fn config(a: std.mem.Allocator, scenario: []const u8, protocol: p.Protocol, direct: bool, mismatch: bool) !cfg.Config {
    const base = if (direct) try origin("THIN_PROXY_HTTP", "http", "127.0.0.1") else if (mismatch) try origin("THIN_PROXY_MISMATCH", "https", "localhost") else try origin("THIN_PROXY_HTTPS", "https", "127.0.0.1");
    return .{
        .provider = .{ .base_url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, scenario }), .api_key_env = "UNUSED_FAKE_KEY" },
        .selected_provider = if (direct) "other" else "listed",
        .model = .{ .name = "raw/id", .protocol = protocol, .context_tokens = 32768 },
        .proxy = .{ .address = "127.0.0.1", .port = try proxyPort(false), .models = &.{"listed/raw/id"} },
        .limits = .{ .low_price_input = false, .request_timeout_ms = 4000 },
    };
}
fn request(c: cfg.Config, protocol: p.Protocol) p.Request {
    return .{ .scope = .{ .connection = c.provider.base_url, .model = c.model.name, .protocol = protocol }, .system = "fixed proxy fixture system", .messages = &messages, .tools = &tools, .max_output_tokens = 128 };
}
const Recorder = struct {
    io: Io,
    marker: ?[]const u8 = null,
    cancel: ?*p.Cancellation = null,
    text: usize = 0,
    tool: usize = 0,
    fn emit(raw: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *Recorder = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .text_delta => |s| {
                self.text += s.len;
                if (self.marker) |path| try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "delta observed" });
                if (self.cancel) |cancel| cancel.cancel();
            },
            .tool_delta => |d| self.tool += d.arguments.len,
            else => {},
        }
    }
    fn sink(self: *Recorder) p.ModelSink {
        return .{ .context = self, .emit_fn = emit };
    }
};
fn successful(out: p.Outcome) !p.Response {
    if (out != .success) return error.ExpectedProxySuccess;
    return out.success;
}

test "proxy: Chat Responses Anthropic headers scope summary and delta-tail handshake" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try transportEnv(t.allocator, true);
    defer env.deinit();
    for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
        var c = try config(a, @tagName(protocol), protocol, false, false);
        const before = c.provider.base_url;
        var client = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
        defer client.deinit();
        var rec = Recorder{ .io = backend.io(), .marker = if (protocol == .chat) try envValue("THIN_PROXY_DELTA_MARKER") else null };
        var req = request(c, protocol);
        const out = try successful(try client.model().call(a, req, rec.sink()));
        try t.expect(out.finish == .stop and rec.text == 2);
        try t.expectEqualStrings(before, c.provider.base_url);
        try t.expectEqualStrings(before, req.scope.connection);
        try t.expectEqualStrings("raw/id", req.scope.model);
        req.purpose = .summary;
        _ = try successful(try client.model().call(a, req, .{}));
        // Proxy selection never changes canonical replay scope validation.
        req.scope.connection = "http://127.0.0.1:1/not-the-scope";
        try t.expectError(error.ReplayScopeMismatch, client.model().call(a, req, .{}));
    }
}

test "proxy: exact alias isolation and native direct ignores environment proxies" {
    var backend = Io.Threaded.init(t.allocator, .{});
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try transportEnv(t.allocator, true);
    defer env.deinit();
    // An empty bypass list is essential here: a buggy environment-driven
    // transport must reach the rejecting proxy rather than bypass it.
    try env.put("NO_PROXY", "");
    try env.put("no_proxy", "");
    var c = try config(a, "alias-direct", .chat, true, false);
    // Same exact endpoint/raw-ID, only the alias changes selection.
    try t.expect(c.proxyFor("listed", "raw/id") != null);
    try t.expect(c.proxyFor("other", "raw/id") == null);
    try t.expect(c.proxyFor("listed", "raw/id-suffix") == null);
    try t.expect(c.proxyFor(null, "raw/id") == null);
    var client = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
    defer client.deinit();
    _ = try successful(try client.model().call(a, request(c, .chat), .{}));
    // A listed alias with the *same* HTTP endpoint must use the forward proxy,
    // which rejects this owned route. It cannot silently go direct.
    c.selected_provider = "listed";
    var listed = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
    defer listed.deinit();
    try t.expect((try listed.model().call(a, request(c, .chat), .{})) == .failure);
}

test "proxy: down wrong CA hostname fail closed and partial streams never succeed or replay" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "down", "wrong-ca", "hostname", "disconnect", "timeout", "cancel" }) |scenario| {
        const down = std.mem.eql(u8, scenario, "down");
        const timeout = std.mem.eql(u8, scenario, "timeout");
        const canceling = std.mem.eql(u8, scenario, "cancel");
        var c = try config(a, scenario, .chat, false, std.mem.eql(u8, scenario, "hostname"));
        if (down) c.proxy.?.port = try proxyPort(true);
        if (timeout) c.limits.request_timeout_ms = 350;
        var env = try transportEnv(t.allocator, !std.mem.eql(u8, scenario, "wrong-ca"));
        defer env.deinit();
        var client = try Client.initWithEnv(t.allocator, backend.io(), &c, "fake-proxy-key", &env);
        defer client.deinit();
        var cancellation = p.Cancellation{};
        var req = request(c, .chat);
        req.cancellation = &cancellation;
        // Cancel only inside a delta callback: proves origin arrival, not a timer.
        var rec = Recorder{ .io = backend.io(), .cancel = if (canceling) &cancellation else null };
        const out = try client.model().call(a, req, rec.sink());
        try t.expect(out == .failure);
        if (timeout) try t.expect(out.failure.kind == .timeout);
        if (canceling) try t.expect(out.failure.kind == .canceled and rec.text > 0);
        if (std.mem.eql(u8, scenario, "disconnect") or timeout) try t.expect(rec.tool > 0);
    }
}

test "proxy: actual SystemOne and generic judge identities independent of primary and environment" {
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    const a = t.allocator;
    for ([_][]const u8{ "systemone", "chat" }) |decision_protocol| {
        for ([_]bool{ false, true }) |listed| {
            var env = try transportEnv(a, true);
            defer env.deinit();
            if (!listed) {
                try env.put("NO_PROXY", "");
                try env.put("no_proxy", "");
            }
            const base = if (listed) try origin("THIN_PROXY_HTTPS", "https", "127.0.0.1") else try origin("THIN_PROXY_HTTP", "http", "127.0.0.1");
            const text = try std.fmt.allocPrint(a,
                \\{{"llm":{{"default":"main/chat","providers":{{"main":{{"base_url":"{s}/unused","api_key":"fake-primary","models":{{"chat":{{"protocol":"chat","context_tokens":32768}}}}}},"aux":{{"base_url":"{s}/{s}-{s}","api_key":"fake-proxy-key","models":{{"jev":{{"protocol":"{s}","context_tokens":32768}}}}}}}}}},"decision":{{"model":"aux/jev"}},"limits":{{"request_timeout_ms":3000}},"proxy":{{"address":"127.0.0.1","port":{d},"models":["{s}"]}}}}
            , .{ try origin("THIN_PROXY_HTTP", "http", "127.0.0.1"), base, if (std.mem.eql(u8, decision_protocol, "systemone")) "decision" else "judge", if (listed) "listed" else "direct", decision_protocol, try proxyPort(false), if (listed) "aux/jev" else "main/chat" });
            defer a.free(text);
            var parsed = try cfg.parse(a, text);
            defer cfg.release(&parsed);
            const client = (try DecisionClient.create(a, backend.io(), parsed.value, &env)) orelse return error.MissingDecisionClient;
            defer client.deinit();
            var cancellation = p.Cancellation{};
            const out = try client.service().decide(a, .{ .memory_write = .{ .topic = "fixture", .content = "owned fixture" } }, &cancellation);
            defer decision.freeOutput(a, out);
            try t.expect(out.memory_write);
            try t.expect(client.calls == 1);
            const resolved = client.resolved orelse return error.MissingDecisionResolution;
            try t.expect((resolved.client == null) == std.mem.eql(u8, decision_protocol, "systemone"));
            try t.expect((resolved.config.value.model.protocol == .systemone) == std.mem.eql(u8, decision_protocol, "systemone"));
            try t.expectEqual(@as(u32, 3000), resolved.config.value.limits.request_timeout_ms);
            try t.expectEqualStrings("main/chat", client.source.value.registry.?.default);
        }
    }
}
