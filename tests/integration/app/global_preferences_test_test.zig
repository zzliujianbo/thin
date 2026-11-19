test "global config switches survive model selection and session restart without a settings source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const legacy = "{\"low_price_input\":false}";
    try seed(home, plain, legacy);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    {
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
        defer session.deinit();
        // The retired settings file is ignored, even if it disagrees.
        try std.testing.expect(session.connection().current().low_price_input_enabled);
        try toggle(&session, .low_price_input, false);
        try std.testing.expect(!session.connection().current().low_price_input_enabled);
        try std.testing.expect(!session.global_config.?.value.limits.low_price_input);
        const connection = session.connection();
        try connection.select_model_fn.?(connection.context, "route/second");
        try std.testing.expect(!session.app.?.config.value.limits.low_price_input);
        const disk = try read(home, cfg.file_name);
        defer a.free(disk);
        var parsed = try cfg.parse(a, disk);
        defer cfg.release(&parsed);
        try std.testing.expect(!parsed.value.limits.low_price_input);
        try std.testing.expectEqualStrings("route/second", parsed.value.registry.?.default);
        try std.testing.expectEqualStrings("fake-owned-only", parsed.value.registry.?.find("route").?.connection.api_key.?);
        try std.testing.expectEqual(@as(?u32, 65536), parsed.value.registry.?.find("route").?.patchFor("first").?.context_tokens);
        const old = try read(home, "settings.json");
        defer a.free(old);
        try std.testing.expectEqualStrings(legacy, old);
    }
    var restarted = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer restarted.deinit();
    try std.testing.expect(!restarted.connection().current().low_price_input_enabled);
    const config = restarted.app.?.config.value;
    try std.testing.expect(!config.limits.low_price_input);
    try std.testing.expectEqualStrings("second", config.model.name);
}
test "history restore adopts current config switches rather than archived budget or tool prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, plain, null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var id: @import("session_id.zig").Id = undefined;
    {
        var source = try Session.initWithOptions(a, io, &env, home, .{}, .{});
        defer source.deinit();
        id = source.session_id;
        const app = source.app.?;
        const allocator = app.runtime.arena.allocator();
        try app.runtime.history.append(allocator, try p.cloneMessage(allocator, .{ .role = .user, .blocks = &.{.{ .text = "owned goal" }} }));
        try app.runtime.history.append(allocator, try p.cloneMessage(allocator, .{
            .role = .assistant,
            .blocks = &.{ .{ .reasoning = "old prefix" }, .{ .text = "owned answer" } },
            .replay = .{ .scope = .{ .connection = app.config.value.provider.base_url, .model = "first", .protocol = .anthropic }, .json = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"old prefix\",\"signature\":\"c2ln\"},{\"type\":\"text\",\"text\":\"owned answer\"}]}" },
        }));
        app.runtime.last_context_tokens = 77;
        try std.testing.expect(try source.saveOnExit());
    }
    {
        var store = try Store.openExisting(a, io, home);
        defer store.deinit();
        var declaration = try store.loadExisting();
        defer cfg.release(&declaration);
        declaration.value.limits.low_price_input = false;
        try store.save(declaration.value);
    }
    var restored = try Session.initWithOptions(a, io, &env, home, .{}, .{ .resume_session = id });
    defer restored.deinit();
    const state = restored.connection().current();
    try std.testing.expect(!state.low_price_input_enabled);
    const history = restored.app.?.runtime.messages();
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expect(history[1].replay != null);
    try std.testing.expectEqual(@as(usize, 2), history[1].blocks.len);
    try std.testing.expectEqualStrings("owned answer", history[1].blocks[1].text);
    try std.testing.expect(state.initial_context.?.known);
    try std.testing.expectEqual(@as(u64, 77), state.initial_context.?.tokens);
}
test "settings prepare owns latest declaration and extends redaction without publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try seed(home, plain, null);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const app = session.app.?;
    const config_arena = app.config.arena;
    const schema = app.runtime.executor.schemas.ptr;
    const disk = try read(home, cfg.file_name);
    defer a.free(disk);
    var declaration = try cfg.clone(a, session.global_config.?.value);
    var released = false;
    defer if (!released) cfg.release(&declaration);
    try cfg.setRegistryCredential(declaration.arena.allocator(), &declaration.value, "route", "fake-prepare-only-key");
    declaration.value.limits.request_timeout_ms += 1;
    var prepared = try app.prepareSettings(declaration.value, &env);
    defer prepared.deinit();
    cfg.release(&declaration);
    released = true;
    var remembered = false;
    for (app.journal.known_keys.items) |key|
        remembered = remembered or std.mem.eql(u8, key, "fake-prepare-only-key");
    try std.testing.expect(remembered);
    try std.testing.expect(app.config.arena == config_arena and app.runtime.executor.schemas.ptr == schema);
    const unchanged = try read(home, cfg.file_name);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(disk, unchanged);
}
test "obsolete settings file is ignored and preserved even when malformed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const bad = "{\"low_price_input\":\"bad\"}";
    try seed(home, plain, bad);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    const state = session.connection().current();
    try std.testing.expect(state.global_settings_available and state.low_price_input_enabled);
    try toggle(&session, .low_price_input, false);
    const bytes = try read(home, "settings.json");
    defer a.free(bytes);
    try std.testing.expectEqualStrings(bad, bytes);
    var restarted = try Session.init(a, io, &env, home, .{});
    defer restarted.deinit();
    try std.testing.expect(!restarted.app.?.config.value.limits.low_price_input);
}
