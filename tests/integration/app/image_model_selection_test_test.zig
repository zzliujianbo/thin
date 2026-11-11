test "image Settings default Off exact logged candidates and independent transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-vision-own");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const app = session.app.?;
    const primary = app.client.authorization.ptr;
    const decision = app.decision_client.?;
    const state = session.connection().current();
    try std.testing.expect(!state.image_enabled and state.image_model == null);
    try std.testing.expectEqual(@as(usize, 1), state.image_models.len);
    try std.testing.expect(contains(state.image_models, "vision/deepseek-flash"));
    try std.testing.expect(app.image_client == null);
    try expectImageSchemas(app, false);
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "unlogged/deepseek-flash"));
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "similar/DeepSeek-Flash"));
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "vision/deepseek-v4-flash"));
    try choose(&session, "vision/deepseek-flash");
    try std.testing.expect(session.connection().current().image_enabled);
    try std.testing.expectEqualStrings("vision/deepseek-flash", app.config.value.image.model.?);
    try std.testing.expectEqualStrings("fake-vision-own", app.image_client.?.key);
    try std.testing.expectEqualStrings("https://vision.invalid/v1/chat/completions", app.image_client.?.endpoint);
    try expectImageSchemas(app, true);
    try std.testing.expectEqualStrings("read_image", app.runtime.executor.schemas[4].name);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    const selected = app.image_client.?;
    try env.put("VISION_OWN_KEY", "fake-refreshed-vision");
    try std.testing.expectEqualStrings("fake-vision-own", selected.key);
    try choose(&session, "vision/deepseek-flash");
    try std.testing.expect(app.image_client.? != selected);
    try std.testing.expectEqualStrings("fake-refreshed-vision", app.image_client.?.key);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    try expectPersistedImage(home, "vision/deepseek-flash");
    const connection = session.connection();
    try connection.image_fn.?(connection.context, .off);
    try std.testing.expect(app.image_client == null and !app.config.value.imageActive());
    try std.testing.expect(app.config.value.image.model == null);
    try std.testing.expect(!session.connection().current().image_enabled and session.connection().current().image_model == null);
    try expectPersistedImage(home, null);
    try expectImageSchemas(app, false);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    const bytes = try disk(home);
    defer a.free(bytes);
    var saved = try cfg.parse(a, bytes);
    defer cfg.release(&saved);
    try std.testing.expect(!saved.value.imageActive() and saved.value.image.model == null);
    try std.testing.expectEqualStrings("main/chat", saved.value.registry.?.default);
    try connection.image_fn.?(connection.context, .off);
    try std.testing.expect(app.image_client == null and app.config.value.image.model == null);
    try expectImageSchemas(app, false);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    const twice = try disk(home);
    defer a.free(twice);
    try std.testing.expectEqualStrings(bytes, twice);
    try expectPersistedImage(home, null);
}
test "image Settings context chat preserves actual usage missing usage and fresh zero" {
    try contextSurvivesImageSettings(.chat);
}
test "image Settings context responses preserves actual usage missing usage and fresh zero" {
    try contextSurvivesImageSettings(.responses);
}
test "image Settings context anthropic preserves actual usage missing usage and fresh zero" {
    try contextSurvivesImageSettings(.anthropic);
}
test "image Settings stale credential OOM and CAS failure publish nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, fixture);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-vision-own");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const app = session.app.?;
    const primary = app.client.authorization.ptr;
    const decision = app.decision_client.?;
    try env.put("VISION_OWN_KEY", "");
    try std.testing.expectError(error.UnknownImageModel, choose(&session, "vision/deepseek-flash"));
    try env.put("VISION_OWN_KEY", "fake-vision-own");
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    session.allocator = failing.allocator();
    const failed = choose(&session, "vision/deepseek-flash");
    session.allocator = a;
    try std.testing.expectError(error.OutOfMemory, failed);
    try choose(&session, "vision/deepseek-flash");
    const selected = app.image_client.?;
    try expectPersistedImage(home, "vision/deepseek-flash");
    const prior = try disk(home);
    defer a.free(prior);
    const changed = try std.fmt.allocPrint(a, "{s}\n", .{prior});
    defer a.free(changed);
    {
        var external = try Store.openExisting(a, io, home);
        defer external.deinit();
        try external.root.writeMode(cfg.file_name, changed, true, 0o600);
    }
    try std.testing.expectError(error.AuthVersionConflict, choose(&session, "vision/deepseek-flash"));
    const connection = session.connection();
    try std.testing.expectError(error.AuthVersionConflict, connection.image_fn.?(connection.context, .off));
    try std.testing.expect(app.image_client.? == selected and app.config.value.imageActive());
    try std.testing.expectEqualStrings("vision/deepseek-flash", app.config.value.image.model.?);
    try std.testing.expectEqualStrings("vision/deepseek-flash", session.connection().current().image_model.?);
    try std.testing.expect(app.client.authorization.ptr == primary and app.decision_client.? == decision);
    try expectImageSchemas(app, true);
    const after = try disk(home);
    defer a.free(after);
    try std.testing.expectEqualStrings(changed, after);
}
test "image official id-only listing authorizes exact availability not invented main capabilities" {
    const source =
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-primary","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"official":{"base_url":"https://api.deepseek.com","api_key_env":"VISION_OWN_KEY","models":{}}}},"limits":{"low_price_input":false,"safety_tokens":100}}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, source);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-official-own");
    for ([_][]const u8{ "{\"data\":[{\"id\":\"deepseek-flash\"},{\"id\":\"DeepSeek-Flash\"}]}", "{\"data\":[]}" }, 0..) |body, index| {
        try publish(home, body, 100 + index * 10);
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
        defer session.deinit();
        const state = session.connection().current();
        try std.testing.expectEqual(index == 0, contains(state.image_models, "official/deepseek-flash"));
        try std.testing.expect(!state.image_enabled and session.app.?.image_client == null);
        if (index == 0) {
            try choose(&session, "official/deepseek-flash");
            const client = session.app.?.image_client.?;
            try std.testing.expect(client.context_tokens == null);
            try std.testing.expectEqualStrings("fake-official-own", client.key);
            const connection = session.connection();
            try connection.image_fn.?(connection.context, .off);
        } else try std.testing.expectError(error.UnknownImageModel, choose(&session, "official/deepseek-flash"));
    }
}
test "image official Anthropic base uses the same availability and cached limits as its Chat route" {
    const source =
        \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-primary","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"anthropic":{"base_url":"https://api.deepseek.com/anthropic","api_key_env":"VISION_OWN_KEY","models":{}},"manual":{"base_url":"https://api.deepseek.com/anthropic","api_key_env":"VISION_OWN_KEY","models":{"deepseek-flash":{}}}}},"limits":{"low_price_input":false,"safety_tokens":100}}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    try seed(home, source);
    try publish(home, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":8192,\"protocol\":\"chat\"}]}", 100);
    {
        var store = try Store.openExisting(a, io, home);
        defer store.deinit();
        const claim = try metadata.claimAt(&store.root, metadata.dev_bit, true, 200, .{});
        const listing = try metadata.parseDev(a,
            \\{"deepseek":{"npm":"@ai-sdk/openai-compatible","models":{"deepseek-flash":{"limit":{"context":8192,"output":512}}}}}
        );
        const result = try metadata.commitClaimedAt(&store.root, 0, listing, claim.generations, 201);
        try std.testing.expectEqual(metadata.dev_bit, result.accepted);
    }
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("VISION_OWN_KEY", "fake-anthropic-own");
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    for ([_][]const u8{ "anthropic/deepseek-flash", "manual/deepseek-flash" }) |name| {
        try std.testing.expect(contains(session.connection().current().image_models, name));
        try choose(&session, name);
        const client = session.app.?.image_client.?;
        try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", client.endpoint);
        try std.testing.expectEqualStrings("fake-anthropic-own", client.key);
        try std.testing.expectEqual(@as(?u64, 8192), client.context_tokens);
        // Chat image requests do not consume the cached output capability as a cap.
        try std.testing.expectEqualStrings("chat", session.app.?.config.value.model.name);
    }
}
test "image unavailable own key preserves main startup and fails before file access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    var parsed = try cfg.parse(a, fixture);
    defer cfg.release(&parsed);
    parsed.value.image = .{ .model = "vision/deepseek-flash" };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(parsed.value, &out.writer);
    try seed(home, out.written());
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const app = session.app.?;
    try std.testing.expect(app.image_client == null and app.config.value.imageActive());
    try expectImageSchemas(app, true);
    try std.testing.expectError(error.ImageModelUnavailable, app.executor.image.?.checkReady());
    try std.testing.expectEqualStrings("chat", app.config.value.model.name);
    const connection = session.connection();
    try connection.image_fn.?(connection.context, .off);
    try std.testing.expect(app.executor.image == null and app.image_client == null);
    try expectImageSchemas(app, false);
}
