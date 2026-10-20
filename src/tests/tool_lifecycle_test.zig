//! Display-only lifecycle fixtures, no real configuration or I/O transports.
const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const cfg = @import("../core/config.zig");
const t = std.testing;
const schemas = [_]p.ToolSchema{.{ .name = "read_file", .description = "", .parameters_json = "{}" }};
const Fixture = struct {
    calls: usize = 0,
    attempts: usize = 0,
    executions: usize = 0,
    ready: usize = 0,
    commits: usize = 0,
    begins: usize = 0,
    discards: usize = 0,
    results: usize = 0,
    started: usize = 0,
    raw: usize = 0,
    final_only: bool = false,
    local: bool = false,
    fail: bool = false,
    cancel_model: bool = false,
    fallback: bool = false,
    reject_preview: bool = false,
    prepare_error: bool = false,
    deny: bool = false,
    cancel_permission: ?*p.Cancellation = null,
    keys: [2]p.ToolDisplayKey = undefined,
    streamed_key: ?p.ToolDisplayKey = null,
    generation: u64 = 0,
    fn call(raw: *anyopaque, a: std.mem.Allocator, req: p.Request, sink: p.ModelSink) !p.Outcome {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.attempts += 1;
        if (self.fallback and self.attempts == 1) return .{ .failure = .{ .kind = .unsupported_protocol, .message = "fixture" } };
        self.calls += 1;
        if (self.calls > 1) return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} }, .finish = .stop } };
        if (!self.final_only) {
            try sink.emit(.{ .tool_delta = .{ .index = 37, .name = "read_file", .call_id = "second", .arguments = "{\"path\":\"stream\"}" } });
            try t.expectEqual(@as(usize, 0), self.executions);
        }
        if (self.cancel_model) {
            @constCast(req.cancellation.?).cancel();
            return error.Canceled;
        }
        if (self.fail) return error.FixtureFailed;
        const blocks = try a.dupe(p.Block, &.{
            .{ .tool_call = .{ .id = "first", .name = "read_file", .arguments = "{\"path\":\"canonical first\"}" } },
            .{ .tool_call = .{ .id = "second", .name = "read_file", .arguments = "{\"path\":\"canonical second\"}" } },
        });
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = blocks }, .finish = .tool_calls } };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try t.expectEqual(@as(usize, if (self.local) 1 else 2), self.ready);
        try t.expectEqual(@as(usize, 1), self.commits);
        if (self.prepare_error) return error.BadArguments;
        return .{ .payload = raw, .description = "fixture", .explicit_denial = if (self.deny or self.cancel_permission != null) "Fixture requires explicit approval" else null };
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.executions += 1;
        return .{ .text = "ok" };
    }
    fn authorize(raw: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (self.cancel_permission) |cancel| cancel.cancel();
        return if (self.deny) .deny else .allow_once;
    }
    fn event(raw: ?*anyopaque, ev: r.Event, _: *const p.Cancellation) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        switch (ev) {
            .tool_views => |v| switch (v.phase) {
                .begin => {
                    try t.expect(v.generation > self.generation);
                    self.generation = v.generation;
                    self.begins += 1;
                },
                .commit => {
                    try t.expectEqual(@as(usize, if (self.local) 1 else 2), self.ready);
                    self.commits += 1;
                },
                .discard => self.discards += 1,
            },
            .tool_view => |v| {
                if (!v.ready) {
                    self.streamed_key = v.key;
                    if (self.reject_preview) return error.Disconnected;
                } else {
                    if (self.local) {
                        try t.expectEqualStrings("echo fixture", v.fields.command.?.text);
                    } else try t.expectEqualStrings(if (self.ready == 0) "canonical first" else "canonical second", v.fields.path.?.text);
                    self.keys[self.ready] = v.key;
                    self.ready += 1;
                }
            },
            .tool_preview => self.raw += 1,
            .tool_started => |v| {
                try t.expectEqual(@as(usize, 1), self.commits);
                try t.expect(v.display_key.?.eql(self.keys[self.started]));
                self.started += 1;
            },
            .tool_result => |v| {
                try t.expect(v.display_key.?.eql(self.keys[self.results]));
                self.results += 1;
            },
            else => {},
        }
    }
    fn runtime(self: *Fixture, config: *const cfg.Config) !r.Runtime {
        return r.Runtime.init(t.allocator, t.io, config, .{ .context = self, .call_fn = call }, .{
            .context = self,
            .schemas = &schemas,
            .prepare_fn = prepare,
            .execute_fn = execute,
        }, .{ .context = self, .emit_fn = event, .authorize_fn = authorize }, "");
    }
};
fn configuration() cfg.Config {
    return .{ .provider = .{ .base_url = "http://localhost", .api_key_env = "FAKE" }, .model = .{ .name = "fake", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
}
test "lifecycle local batch starts independent generation without inference" {
    var f: Fixture = .{ .local = true };
    var config = configuration();
    var runtime = try f.runtime(&config);
    defer runtime.deinit();
    runtime.display_generation = 40;
    var cancel: p.Cancellation = .{};
    const result = try runtime.executeCommand("!echo fixture", &cancel);
    try t.expectEqual(r.Status.success, result.status);
    try t.expectEqual(@as(usize, 0), f.attempts);
    try t.expectEqual(@as(usize, 1), f.executions);
    try t.expectEqual(@as(u64, 41), f.keys[0].generation);
    try t.expectEqual(@as(u32, 0), result.usage.normal_calls);
}

test "lifecycle binds same-name calls by id and canonical full arguments before execute" {
    var f: Fixture = .{};
    var config = configuration();
    var runtime = try f.runtime(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const result = try runtime.run("fixture", &cancel);
    try t.expectEqual(r.Status.success, result.status);
    try t.expectEqual(@as(usize, 2), f.executions);
    try t.expect(f.keys[1].eql(f.streamed_key.?));
    try t.expect(!f.keys[0].eql(f.keys[1]));
    try t.expectEqual(@as(usize, 37), f.keys[1].index);
    try t.expectEqual(@as(usize, 2), f.begins);
}
test "lifecycle final-only prepare failure and deny keep keys without starts" {
    for (0..3) |scenario| {
        var f: Fixture = .{ .final_only = true, .prepare_error = scenario == 1, .deny = scenario == 2 };
        var config = configuration();
        var runtime = try f.runtime(&config);
        defer runtime.deinit();
        var cancel: p.Cancellation = .{};
        try t.expectEqual(r.Status.success, (try runtime.run("fixture", &cancel)).status);
        try t.expectEqual(@as(usize, 2), f.results);
        try t.expect(!f.keys[0].eql(f.keys[1]));
        try t.expectEqual(@as(usize, if (scenario == 0) 2 else 0), f.started);
    }
}
test "lifecycle failed and canceled previews do not execute or commit" {
    for (0..3) |scenario| {
        var cancel: p.Cancellation = .{};
        var f: Fixture = .{ .fail = scenario == 0, .cancel_model = scenario == 1, .cancel_permission = if (scenario == 2) &cancel else null };
        var config = configuration();
        var runtime = try f.runtime(&config);
        defer runtime.deinit();
        const result = try runtime.run("fixture", &cancel);
        try t.expectEqual(if (scenario == 0) r.Status.failed else r.Status.canceled, result.status);
        try t.expectEqual(@as(usize, 0), f.executions);
        try t.expectEqual(@as(usize, if (scenario == 2) 1 else 0), f.commits);
    }
}
test "lifecycle fallback attempts get generations and display failure preserves original deltas" {
    var f: Fixture = .{ .fallback = true, .reject_preview = true };
    var config = configuration();
    config.model.protocol = .auto;
    var runtime = try f.runtime(&config);
    defer runtime.deinit();
    var cancel: p.Cancellation = .{};
    const result = try runtime.run("fixture", &cancel);
    try t.expectEqual(r.Status.success, result.status);
    try t.expectEqual(@as(usize, 3), f.begins);
    try t.expectEqual(@as(usize, 1), f.raw);
    try t.expectEqual(@as(u64, 2), f.keys[1].generation);
    try t.expectEqual(@as(u32, 3), result.usage.normal_calls);
}
