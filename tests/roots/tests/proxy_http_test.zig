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
        .model = .{ .name = "raw/id", .protocol = protocol, .context_tokens = 32768, .output_tokens = if (protocol == .anthropic) 128 else null },
        .proxy = .{ .address = "127.0.0.1", .port = try proxyPort(false), .models = &.{"listed/raw/id"} },
        .limits = .{ .low_price_input = false, .request_timeout_ms = 4000 },
    };
}
fn request(c: cfg.Config, protocol: p.Protocol) p.Request {
    return .{ .scope = .{ .connection = c.provider.base_url, .model = c.model.name, .protocol = protocol }, .system = "fixed proxy fixture system", .messages = &messages, .tools = &tools, .model_output_tokens = c.model.output_tokens };
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
