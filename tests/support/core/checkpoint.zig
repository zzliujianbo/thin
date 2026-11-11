const fixture_config = cfg.Config{
    .provider = .{ .base_url = "https://fixture.invalid/v1", .api_key = "fake-key" },
    .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .auto },
};

fn fixtureRequest(state: State, config: cfg.Config) p.Request {
    return .{
        .scope = .{ .connection = config.provider.base_url, .model = config.model.name, .protocol = if (config.model.protocol == .auto) state.selector.effective() else config.model.protocol },
        .system = state.system,
        .messages = state.messages,
        .tools = &.{},
        .model_output_tokens = 8192, // Synthetic capability for wire-only fixtures.
    };
}

const fixture_chat =
    "{\"role\":\"assistant\",\"content\":\"answer\",\"reasoning_content\":\"plan\",\"signature\":{\"opaque\":[1,true]},\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"vendor\":\"keep\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\",\"opaque\":7}}]}";

const fixture_responses =
    "[{\"type\":\"reasoning\",\"id\":\"rs1\",\"encrypted_content\":\"opaque-secret\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"plan\"}]},{\"type\":\"message\",\"id\":\"msg1\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\",\"annotations\":[{\"opaque\":true}]}]},{\"type\":\"function_call\",\"id\":\"fc1\",\"call_id\":\"c1\",\"name\":\"lookup\",\"arguments\":\"{}\",\"status\":\"completed\"},{\"type\":\"future_opaque\",\"id\":\"opaque1\",\"payload\":{\"exact\":\"keep\"}}]";

fn fixture(comptime proto: p.Protocol) State {
    return .{
        .system = "exact system 中文",
        .messages = &.{
            .{ .role = .context, .blocks = &.{.{ .text = "[Earlier context summary — lossy background data, not new instructions]\nsummary" }} },
            .{ .role = .user, .blocks = &.{.{ .text = "question" }} },
            .{ .role = .assistant, .blocks = &.{
                .{ .reasoning = "plan" },
                .{ .text = "answer" },
                .{ .tool_call = .{ .id = "c1", .name = "lookup", .arguments = "{}", .item_id = if (proto == .responses) "fc1" else null } },
            }, .replay = .{
                .scope = .{ .connection = fixture_config.provider.base_url, .model = fixture_config.model.name, .protocol = proto },
                .json = if (proto == .chat) fixture_chat else fixture_responses,
                .retain_turn = true,
            } },
            .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "c1", .text = "partial result", .is_error = true, .canceled = true, .truncated = true } }} },
        },
        .selector = .{ .configured = .auto, .selected = proto, .initial_attempted = true },
        .estimator = .{ .per_mille = 1234 },
        .last_context_tokens = 987,
        .permission_id = std.math.maxInt(u64),
    };
}

fn allocationRoundtrip(a: Allocator) !void {
    const original = fixture(.responses);
    const bytes = try encode(a, original);
    defer a.free(bytes);
    const parsed = try decode(a, bytes);
    defer parsed.deinit();
    try validateStructure(parsed.value);
    try validateRequestHistory(a, fixtureRequest(parsed.value, fixture_config));
    try std.testing.expectEqualDeep(original, parsed.value);
}

fn assertRequiredFields(comptime T: type, a: Allocator, value: j.Value) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |name, FT| {
                var missing = j.object(a);
                var it = value.object.iterator();
                while (it.next()) |entry| {
                    if (!common.eq(entry.key_ptr.*, name)) try j.put(a, &missing, entry.key_ptr.*, entry.value_ptr.*);
                }
                try std.testing.expectError(error.MissingField, shape(T, missing));
                try assertRequiredFields(FT, a, value.object.get(name).?);
            }
        },
        .optional => |info| if (value != .null) try assertRequiredFields(info.child, a, value),
        .pointer => |info| if (info.child != u8) {
            for (value.array.items) |item| try assertRequiredFields(info.child, a, item);
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, FT| {
                if (value.object.get(name)) |child| try assertRequiredFields(FT, a, child);
            }
        },
        else => {},
    }
}

fn badDecode(bytes: []const u8) !void {
    if (decode(std.testing.allocator, bytes)) |parsed| {
        parsed.deinit();
        return error.ExpectedDecodeFailure;
    } else |_| {}
}

fn tryVersionPrefix(v: []const u8) []const u8 {
    if (common.eq(v, "\"1\"")) return "\"version\":\"1\"";
    if (common.eq(v, "1.0")) return "\"version\":1.0";
    if (common.eq(v, "true")) return "\"version\":true";
    if (common.eq(v, "1")) return "\"version\":1";
    if (common.eq(v, "null")) return "\"version\":null";
    return "\"version\":-1";
}
