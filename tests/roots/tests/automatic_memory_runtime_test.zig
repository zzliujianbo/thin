//! Dedicated headless automatic Memory lifecycle tests. No App/config files/API.
const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const k = @import("../core/knowledge.zig");

const Fake = struct {
    retrieves: usize = 0,
    completes: usize = 0,
    calls: usize = 0,
    summaries: usize = 0,
    finished: usize = 0,
    reference: []const u8 = "project facts A",
    retrieval_error: bool = false,
    retrieval_poison: ?anyerror = null,
    invalid_return: bool = false,
    maxbytes: usize = 0,
    tool: bool = false,
    output: r.Execution = .{ .text = "verified tool fact" },
    fail: bool = false,
    refused: bool = false,
    disconnect: bool = false,
    cancel_stop: ?*p.Cancellation = null,
    box: ?*r.Inbox = null,
    steer: bool = false,
    source_count: usize = 0,
    source_text: [8192]u8 = undefined,
    source_len: usize = 0,
    incomplete: bool = false,
    fn retrieve(raw: *anyopaque, _: std.mem.Allocator, _: []const u8, maxbytes: usize) ![]const u8 {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.retrieves += 1;
        self.maxbytes = maxbytes;
        if (self.retrieval_poison) |err| return err;
        if (self.retrieval_error) return error.OfflineUnavailable;
        if (self.invalid_return) return &@as([8193]u8, @splat('x'));
        return if (self.reference.len <= maxbytes) self.reference else "";
    }
    fn finalize(raw: *anyopaque, capture: *const k.Capture, _: p.Protocol) void {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.completes += 1;
        self.source_count = capture.sources.items.len;
        self.incomplete = capture.incomplete;
        self.source_len = 0;
        for (capture.sources.items) |source| {
            const n = @min(source.text.len, self.source_text.len - self.source_len);
            @memcpy(self.source_text[self.source_len..][0..n], source.text[0..n]);
            self.source_len += n;
        }
    }
    fn call(raw: *anyopaque, _: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (request.purpose == .summary) {
            self.summaries += 1;
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "Earlier work summarized." }} }, .finish = .stop } };
        }
        self.calls += 1;
        if (self.summaries != 0) for (request.messages) |message| {
            try std.testing.expect(message.replay == null);
        };
        if (self.fail) return error.OfflineModelFailure;
        if (self.tool and self.calls == 1) return .{ .success = .{
            .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "offline-one", .name = "probe", .arguments = "{\"guess\":\"do not capture arguments\"}" } }} },
            .finish = .tool_calls,
        } };
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "assistant conjecture must not be captured" }} }, .finish = .stop, .refused = self.refused } };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return .{ .payload = raw, .description = "offline probe" };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *Fake = @ptrCast(@alignCast(raw));
        return self.output;
    }
    fn authorize(_: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        return .allow_once;
    }
    fn event(raw: ?*anyopaque, event_value: r.Event, _: *const p.Cancellation) !void {
        const self: *Fake = @ptrCast(@alignCast(raw.?));
        if (event_value == .finished) self.finished += 1;
        if (event_value == .assistant_committed and event_value.assistant_committed.len == 1 and event_value.assistant_committed[0] == .text) {
            if (self.cancel_stop) |cancel| cancel.cancel();
            if (self.disconnect) return error.OfflineHostGone;
            if (self.steer) {
                self.steer = false;
                _ = try self.box.?.enqueue(std.testing.allocator, .steering, "committed steering fact");
            }
        }
    }
    fn init(self: *Fake, config: *cfg.Config) !r.Runtime {
        var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, config, .{ .context = self, .call_fn = call }, .{ .context = self, .schemas = &.{.{ .name = "probe", .description = "offline", .parameters_json = "{}" }}, .prepare_fn = prepare, .execute_fn = execute }, .{ .context = self, .emit_fn = event, .authorize_fn = authorize }, "stale startup snapshot");
        runtime.memory_hooks = .{ .context = self, .retrieve_fn = retrieve, .submit_fn = finalize };
        runtime.inbox = self.box;
        return runtime;
    }
    fn captured(self: *Fake) []const u8 {
        return self.source_text[0..self.source_len];
    }
};
fn configValue() cfg.Config {
    return .{ .provider = .{ .base_url = "http://offline.invalid" }, .model = .{ .name = "fixture", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
}
fn referenceCount(runtime: *r.Runtime) usize {
    var n: usize = 0;
    for (runtime.messages()) |message| if (message.role == .context) {
        for (message.blocks) |block| if (block == .text and std.mem.startsWith(u8, block.text, "Latest Memory reference")) {
            n += 1;
        };
    };
    return n;
}
fn lastReference(runtime: *r.Runtime) []const u8 {
    var latest: []const u8 = "";
    for (runtime.messages()) |message| if (message.role == .context) {
        for (message.blocks) |block| if (block == .text and std.mem.startsWith(u8, block.text, "Latest Memory reference")) {
            latest = block.text;
        };
    };
    return latest;
}
