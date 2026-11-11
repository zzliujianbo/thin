//! Run only through tests/product/anthropic_mock.mjs with an owned literal loopback URL.
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const Client = @import("../llm/http.zig").Client;
const Selector = @import("../llm/llm.zig").Selector;
const t = std.testing;
const Io = std.Io;
const tools = [_]p.ToolSchema{.{ .name = "lookup", .description = "Local fixture only", .parameters_json = "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}},\"required\":[\"q\"],\"additionalProperties\":false}" }};
const initial = [_]p.Message{.{ .role = .user, .blocks = &.{.{ .text = "hello fixture" }} }};

fn config(a: std.mem.Allocator, scenario: []const u8) !cfg.Config {
    const base = t.environ.getPosix("THIN_ANTHROPIC_FIXTURE_URL") orelse return error.MissingFixtureEnvironment;
    const uri = try std.Uri.parse(base);
    const host = uri.host orelse return error.UnsafeFixtureUrl;
    const host_text = switch (host) {
        .raw, .percent_encoded => |s| s,
    };
    if (!std.mem.eql(u8, uri.scheme, "http") or !std.mem.eql(u8, host_text, "127.0.0.1") or uri.port == null or uri.port == 0 or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or !uri.path.isEmpty()) return error.UnsafeFixtureUrl;
    return .{ .provider = .{ .base_url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, scenario }), .api_key_env = "THIN_FAKE_KEY" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .anthropic, .output_tokens = 128 }, .limits = .{ .low_price_input = false, .request_timeout_ms = 10000 } };
}
fn request(c: cfg.Config) p.Request {
    // The fixture model has a synthetic verified output capacity, not a cap setting.
    return .{ .scope = .{ .connection = c.provider.base_url, .model = c.model.name, .protocol = .anthropic }, .system = "fixed fixture system", .tools = &tools, .messages = &initial, .model_output_tokens = c.model.output_tokens };
}
fn success(out: p.Outcome) !p.Response {
    // Never print failure messages, native replay, assertion operands, or response bodies.
    if (out != .success) return error.ExpectedFixtureSuccess;
    return out.success;
}
const Recorder = struct {
    text: [128]u8 = undefined,
    len: usize = 0,
    reasoning: usize = 0,
    tool: usize = 0,
    usage: p.Usage = .{},
    cancel: ?*p.Cancellation = null,
    fn emit(ctx: ?*anyopaque, event: p.ModelEvent) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .text_delta => |s| {
                if (s.len > self.text.len - self.len) return error.FixtureTextLimit;
                @memcpy(self.text[self.len..][0..s.len], s);
                self.len += s.len;
            },
            .reasoning_delta => |s| self.reasoning += s.len,
            .tool_delta => |d| self.tool += d.arguments.len,
            .usage => |u| {
                self.usage = u;
                if (self.cancel) |c| c.cancel();
            },
        }
    }
    fn sink(self: *Recorder) p.ModelSink {
        return .{ .context = self, .emit_fn = emit };
    }
};
fn usage(u: p.Usage, output: u64) !void {
    try t.expect(u.input_tokens == 15);
    try t.expect(u.cached_input_tokens == 3);
    try t.expect(u.cache_write_tokens == 2);
    try t.expect(u.output_tokens == output);
    try t.expect(u.total() == 15 + output);
}
