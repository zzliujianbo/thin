//! Offline cross-provider budget-to-wire contract. No credentials or network.
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

test "output budget provider matrix uses one shared ceiling and the declared wire field" {
    const a = std.testing.allocator;
    const messages = [_]p.Message{.{ .role = .user, .blocks = &.{.{ .text = "offline budget fixture" }} }};
    for ([_]?providers.Id{ .deepseek, .opencode_go, .opencode_zen, null }) |provider| {
        for ([_]u32{ 131072, 1000000 }) |window| {
            for ([_]p.Protocol{ .chat, .responses, .anthropic }) |protocol| {
                if (provider == .deepseek and protocol != .chat) continue;
                const connection: cfg.Provider = if (provider) |id| catalog.connection(id) else .{ .base_url = "https://custom.invalid/v1", .chat_max_tokens = true };
                const format: thinking.Format = if (protocol == .anthropic) .anthropic else if (provider == .deepseek) .deepseek else .standard;
                var config: cfg.Config = .{
                    .provider = connection,
                    .limits = .{ .low_price_input = false },
                    .model = .{ .name = "budget-fixture", .protocol = protocol, .context_tokens = window, .output_tokens = 65536, .reasoning_effort = "high", .reasoning = .{ .format = format, .map = .{ .off = if (format == .anthropic) "disabled" else if (format == .deepseek) "off" else "none", .high = "high" } } },
                };
                try cfg.validate(config);
                const capabilities = thinking.resolve(connection.base_url, config.model.name, config.model.reasoning);
                const wire = capabilities.wire(config.model.reasoning_effort);
                for ([_]usize{ 1000, 120000 }) |estimated_input| {
                    for ([_]p.Purpose{ .normal, .summary }) |purpose| {
                        var arena = std.heap.ArenaAllocator.init(a);
                        defer arena.deinit();
                        const allocator = arena.allocator();
                        const budget = try context.outputBudget(config, purpose, estimated_input);
                        try std.testing.expectEqual(if (window == 1000000 or estimated_input == 1000) @as(u32, 65536) else @as(u32, 6976), budget);
                        const request: p.Request = .{
                            .scope = .{ .connection = connection.base_url, .model = config.model.name, .protocol = protocol },
                            .system = "budget fixture",
                            .tools = &.{},
                            .messages = &messages,
                            .max_output_tokens = budget,
                            .reasoning_effort = wire.effort,
                            .thinking = wire.thinking,
                            .reasoning_format = format,
                            .purpose = purpose,
                        };
                        const encoded = switch (protocol) {
                            .chat => try chat.encodeWithOptions(allocator, request, connection.chat_max_tokens),
                            .responses => try responses.encode(allocator, request),
                            .anthropic => try anthropic.encode(allocator, request),
                            .systemone => return error.SystemOneNotChatModel, // Not a generative wire encoder.
                            .auto => unreachable,
                        };
                        const parsed = try std.json.parseFromSlice(j.Value, allocator, encoded, .{});
                        const key = if (protocol == .responses) "max_output_tokens" else if (protocol == .anthropic or connection.chat_max_tokens) "max_tokens" else "max_completion_tokens";
                        const value = j.get(parsed.value, key) orelse return error.MissingOutputBudget;
                        try std.testing.expectEqual(@as(i64, budget), value.integer);
                        for ([_][]const u8{ "max_tokens", "max_completion_tokens", "max_output_tokens" }) |other| {
                            if (!std.mem.eql(u8, key, other)) try std.testing.expect(j.get(parsed.value, other) == null);
                        }
                        // Existing Anthropic support is adaptive, not numeric-budget
                        // enabled thinking. Neither it nor DeepSeek adds thinking on
                        // top of the shared response ceiling.
                        try std.testing.expect(std.mem.indexOf(u8, encoded, "budget_tokens") == null);
                        if (protocol == .anthropic or format == .deepseek) {
                            const mode = j.get(j.get(parsed.value, "thinking").?, "type").?.string;
                            try std.testing.expectEqualStrings(if (protocol == .anthropic) "adaptive" else "enabled", mode);
                        }
                    }
                }
                // An explicit request cap remains a cap instead of silently taking
                // a model's larger allowance on another provider.
                config.limits.max_output_tokens = 4096;
                try std.testing.expectEqual(@as(u32, 4096), try context.outputBudget(config, .normal, 1000));
            }
        }
    }
}
