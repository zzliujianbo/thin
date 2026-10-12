//! Positive request/protocol contracts; fake models only, no HTTP or storage.
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const thinking = @import("../core/thinking.zig");
const r = @import("../core/runtime.zig");
const chat = @import("../llm/chat.zig");
const responses = @import("../llm/responses.zig");
const support = @import("adapter_test_support.zig");

const Stub = struct {
    fn call(_: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
        return error.UnexpectedRequest;
    }
    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }
    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
};

fn runtime(config: *cfg.Config, dummy: *u8) !r.Runtime {
    return r.Runtime.init(std.testing.allocator, std.testing.io, config, .{ .context = dummy, .call_fn = Stub.call }, .{ .context = dummy, .schemas = &.{}, .prepare_fn = Stub.prepare, .execute_fn = Stub.execute }, .{}, "", false);
}

test "explicit mapped standard wire off survives normal and summary adapter encoding" {
    const a = std.testing.allocator;
    const cap = thinking.resolve("https://proxy.invalid", "custom", .{ .map = .{ .off = "off", .low = "off", .high = "provider-high" } });
    for ([_]p.Protocol{ .chat, .responses }) |protocol| {
        for ([_]p.Purpose{ .normal, .summary }) |purpose| {
            for ([_][]const u8{ "off", "none", "low" }) |logical| {
                const wire = cap.wire(logical);
                try std.testing.expectEqualStrings("off", wire.effort.?);
                var req = support.request(protocol);
                req.reasoning_effort = wire.effort;
                req.reasoning_format = cap.format;
                req.purpose = purpose;
                const encoded = if (protocol == .chat) try chat.encode(a, req) else try responses.encode(a, req);
                defer a.free(encoded);
                const parsed = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
                defer parsed.deinit();
                const actual = if (protocol == .chat) parsed.value.object.get("reasoning_effort").? else parsed.value.object.get("reasoning").?.object.get("effort").?;
                try std.testing.expectEqualStrings("off", actual.string);
                if (purpose == .summary) try std.testing.expectEqualStrings("none", parsed.value.object.get("tool_choice").?.string);
            }
        }
    }
}

test "known DeepSeek format selects Chat before an auto request even when effort is unspecified" {
    var dummy: u8 = 0;
    for ([_]bool{ false, true }) |explicit| {
        var config: cfg.Config = .{
            .provider = .{ .base_url = if (explicit) "https://proxy.invalid" else "https://api.deepseek.com" },
            .model = .{ .name = if (explicit) "custom" else "deepseek-flash", .context_tokens = 32768, .protocol = .auto, .reasoning = if (explicit) .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } } else null },
        };
        var owner = try runtime(&config, &dummy);
        defer owner.deinit();
        try std.testing.expectEqual(p.Protocol.chat, owner.selector.effective());
        try std.testing.expect(owner.selector.initial_attempted);
        try std.testing.expectEqual(p.Protocol.auto, owner.selector.configured);
        try std.testing.expect(config.model.reasoning_effort == null);
        try std.testing.expectEqualDeep(owner.selector, r.initialSelector(config));
    }
}

test "shared request options encode custom mapping and DeepSeek probe parity offline" {
    const a = std.testing.allocator;
    for ([_]thinking.Format{ .standard, .deepseek }) |format| {
        var config: cfg.Config = .{
            .provider = .{ .base_url = "https://proxy.invalid" },
            .model = .{ .name = "custom", .context_tokens = 32768, .protocol = .auto, .reasoning = .{ .format = format, .map = .{ .off = "off", .high = "intensive" } } },
        };
        for ([_]?[]const u8{ null, "off", "high" }) |effort| {
            config.model.reasoning_effort = effort;
            const selector = r.initialSelector(config);
            const req = r.withReasoning(config, support.request(selector.effective()));
            try std.testing.expectEqual(format, req.reasoning_format);
            const encoded = if (selector.effective() == .chat) try chat.encode(a, req) else try responses.encode(a, req);
            defer a.free(encoded);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
            defer parsed.deinit();
            const object = parsed.value.object;
            if (effort) |level| {
                if (format == .deepseek) {
                    const off = std.mem.eql(u8, level, "off");
                    try std.testing.expectEqualStrings(if (off) "disabled" else "enabled", object.get("thinking").?.object.get("type").?.string);
                    if (off) try std.testing.expect(!object.contains("reasoning_effort")) else try std.testing.expectEqualStrings("intensive", object.get("reasoning_effort").?.string);
                } else {
                    try std.testing.expectEqualStrings(if (std.mem.eql(u8, level, "off")) "off" else "intensive", object.get("reasoning").?.object.get("effort").?.string);
                }
            } else {
                try std.testing.expect(!object.contains("thinking") and !object.contains("reasoning") and !object.contains("reasoning_effort"));
            }
        }
    }
}

test "incompatible retained auto selection rejects before replay calibration or config publication" {
    var dummy: u8 = 0;
    var config: cfg.Config = .{ .provider = .{ .base_url = "https://proxy.invalid" }, .model = .{ .name = "old", .context_tokens = 32768, .protocol = .auto } };
    var owner = try runtime(&config, &dummy);
    defer owner.deinit();
    owner.selector.selected = .responses;
    owner.selector.initial_attempted = true;
    owner.estimator.per_mille = 2300;
    var message = try p.textMessage(owner.arena.allocator(), .assistant, "retained visible answer");
    message.replay = .{ .scope = .{ .connection = config.provider.base_url, .model = "old", .protocol = .responses }, .json = "[]" };
    try owner.history.append(owner.arena.allocator(), message);
    const previous = owner.selector;
    var next = config.model;
    next.name = "deepseek-style";
    next.reasoning = .{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } };
    try std.testing.expectError(error.IncompatibleReasoningProtocol, owner.prepareSelection(next));
    try std.testing.expectEqualDeep(previous, owner.selector);
    try std.testing.expectEqual(@as(u64, 2300), owner.estimator.per_mille);
    try std.testing.expect(owner.history.items[0].replay != null);
    try std.testing.expectEqualStrings("retained visible answer", owner.history.items[0].blocks[0].text);
    try std.testing.expectEqualStrings("old", config.model.name);
}
