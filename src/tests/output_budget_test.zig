//! Offline provider-owned output length contract. No credentials or network.
const std = @import("std");
const cfg = @import("../core/config.zig");
const context = @import("../core/context.zig");
const p = @import("../core/protocol.zig");
const thinking = @import("../core/thinking.zig");
const providers = @import("../core/providers.zig");
const catalog = @import("../app/provider_catalog.zig");
const chat = @import("../llm/chat.zig");
const responses = @import("../llm/responses.zig");
const anthropic = @import("../llm/anthropic.zig");
const j = @import("../util/json.zig");

test "provider output matrix omits optional caps and only Anthropic uses model capacity" {
    const a = std.testing.allocator;
    const messages = [_]p.Message{.{ .role = .user, .blocks = &.{.{ .text = "offline provider-owned output fixture" }} }};
    for ([_]?providers.Id{ .deepseek, .opencode_go, .opencode_zen, null }) |provider| {
        for ([_]u32{ 131072, 1000000 }) |window| {
            for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
                if (provider == .deepseek and protocol != .chat) continue;
                const connection: cfg.Provider = if (provider) |id| catalog.connection(id) else .{ .base_url = "https://custom.invalid/v1" };
                const format: thinking.Format = if (protocol == .anthropic) .anthropic else if (provider == .deepseek) .deepseek else .standard;
                for ([_]?u32{ null, 65536 }) |capacity| {
                    const config: cfg.Config = .{
                        .provider = connection,
                        .limits = .{ .low_price_input = false },
                        .model = .{ .name = "output-fixture", .protocol = protocol, .context_tokens = window, .output_tokens = capacity, .reasoning_effort = "high", .reasoning = .{ .format = format, .map = .{ .off = if (format == .anthropic) "disabled" else if (format == .deepseek) "off" else "none", .high = "high" } } },
                    };
                    try cfg.validate(config);
                    const wire = thinking.resolve(connection.base_url, config.model.name, config.model.reasoning).wire(config.model.reasoning_effort);
                    for ([_]usize{ 1000, 120000 }) |estimated_input| {
                        for ([_]p.Purpose{ .normal, .summary }) |purpose| {
                            try context.checkInputFor(config, purpose, estimated_input);
                            var arena = std.heap.ArenaAllocator.init(a);
                            defer arena.deinit();
                            const allocator = arena.allocator();
                            const request: p.Request = .{
                                .scope = .{ .connection = connection.base_url, .model = config.model.name, .protocol = protocol },
                                .system = "provider output fixture",
                                .tools = &.{},
                                .messages = &messages,
                                .model_output_tokens = capacity,
                                .reasoning_effort = wire.effort,
                                .thinking = wire.thinking,
                                .reasoning_format = format,
                                .purpose = purpose,
                            };
                            if (protocol == .anthropic and capacity == null) {
                                try std.testing.expectError(error.UnknownModelOutputCapacity, anthropic.encode(allocator, request));
                                continue;
                            }
                            const encoded = switch (protocol) {
                                .chat => try chat.encode(allocator, request),
                                .responses => try responses.encode(allocator, request),
                                .anthropic => try anthropic.encode(allocator, request),
                                .auto, .systemone => unreachable,
                            };
                            const parsed = try std.json.parseFromSlice(j.Value, allocator, encoded, .{});
                            for ([_][]const u8{ "max_tokens", "max_completion_tokens", "max_output_tokens" }) |key| {
                                if (protocol == .anthropic and std.mem.eql(u8, key, "max_tokens")) {
                                    // Required protocol capacity is not shrunk to the
                                    // 6976-token input headroom in the small-window case.
                                    try std.testing.expectEqual(@as(i64, capacity.?), j.get(parsed.value, key).?.integer);
                                } else try std.testing.expect(j.get(parsed.value, key) == null);
                            }
                            try std.testing.expect(std.mem.indexOf(u8, encoded, "budget_tokens") == null);
                        }
                    }
                }
            }
        }
    }
}

test "retired output settings are absent and rejected instead of silently preserved" {
    const Key = @import("../core/settings.zig").Key;
    try std.testing.expect(std.meta.stringToEnum(Key, "max_output_tokens") == null);
    const prefix = "{\"llm\":{\"default\":\"p/m\",\"providers\":{\"p\":{\"base_url\":\"http://127.0.0.1:1/v1\",\"models\":{\"m\":{\"protocol\":\"chat\",\"context_tokens\":32768}}}}},\"limits\":";
    for ([_][]const u8{ "{\"max_output_tokens\":4096}", "{\"max_output_tokens\":null}", "{\"summary_tokens\":100}" }) |retired| {
        const body = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, retired, "}" });
        defer std.testing.allocator.free(body);
        try std.testing.expectError(error.UnknownField, cfg.parse(std.testing.allocator, body));
    }
}
