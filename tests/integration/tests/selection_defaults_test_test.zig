test "selection defaults empty ready cross-provider survives restart without creating logs" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    const app = session.app.?;
    const limits = app.config.value.limits;
    const selected = catalog.find(target).?.model;
    try std.testing.expectEqual(@as(usize, 0), app.runtime.messages().len);
    try session.connection().selectModel(target);
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqualStrings(selected.name, app.config.value.model.name);
    try std.testing.expectEqual(selected.protocol, app.runtime.selector.effective());
    try std.testing.expectEqualStrings("Bearer fake-go-selection", app.client.authorization);
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    const empty_cache: @import("../app/model_metadata.zig").Cache = .{};
    try @import("../app/model_resolver.zig").applyDefault(disk.arena.allocator(), &disk.value, &empty_cache);
    try std.testing.expectEqualStrings(cfg.providers.Id.opencode_go.baseUrl(), disk.value.provider.base_url);
    try std.testing.expectEqualStrings(selected.name, disk.value.model.name);
    try std.testing.expectEqual(selected.protocol, disk.value.model.protocol);
    try std.testing.expectEqual(selected.context_tokens, disk.value.model.context_tokens);
    try std.testing.expectEqualDeep(limits, disk.value.limits);
    const registry = disk.value.registry.?;
    try std.testing.expectEqualStrings("fake-inline-deepseek-selection", registry.find("deepseek").?.connection.api_key.?);
    try std.testing.expectEqualStrings("fake-go-selection", registry.find("opencode-go").?.connection.api_key.?);
    try std.testing.expectEqualStrings("fake-zen-selection", registry.find("opencode-zen").?.connection.api_key.?);
    try std.testing.expectEqual(@as(usize, 1), registry.find("deepseek").?.models.len);
    try std.testing.expectEqualStrings("fake-go-selection", disk.value.provider.api_key.?);
    try fixture.noLogs();
    var restarted = try fixture.session();
    defer restarted.deinit();
    try std.testing.expectEqualStrings(selected.name, restarted.connection().current().model);
    try std.testing.expectEqual(selected.protocol, restarted.app.?.runtime.selector.effective());
    try std.testing.expectEqual(selected.context_tokens, restarted.connection().current().context_limit);
    try std.testing.expectEqual(context.inputBudget(disk.value), context.inputBudget(restarted.app.?.config.value));
    try std.testing.expectEqualStrings("Bearer fake-go-selection", restarted.app.?.client.authorization);
    try std.testing.expectEqualDeep(limits, restarted.app.?.config.value.limits);
    try std.testing.expect(!app.journal.started and !restarted.app.?.journal.started);
    try fixture.noLogs();
}
test "selection defaults user-only canonical history changes only session selection" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    const before = try fixture.bytes();
    defer a.free(before);
    const app = session.app.?;
    const id = session.session_id;
    const arena = app.runtime.arena.allocator();
    // A failed first model reply still leaves this user message canonical.
    const text = try arena.dupe(u8, "user retained after failed first reply");
    try app.runtime.history.append(arena, .{ .role = .user, .blocks = try arena.dupe(p.Block, &.{.{ .text = text }}) });
    app.journal.observer().notify(.{ .submitted = text });
    app.journal.flush();
    try std.testing.expect(app.journal.failure() == null);
    try session.connection().selectModel(target);
    app.journal.flush();
    try std.testing.expect(app.journal.failure() == null);
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqualSlices(u8, &id, &session.session_id);
    try std.testing.expectEqualSlices(u8, &id, &app.client.session_id.?);
    try std.testing.expectEqual(@as(usize, 1), app.runtime.messages().len);
    try std.testing.expectEqual(p.Role.user, app.runtime.messages()[0].role);
    try std.testing.expectEqualStrings(text, app.runtime.messages()[0].blocks[0].text);
    const checkpoint_bytes = try session.resume_lease.?.load(&session.project_root);
    defer a.free(checkpoint_bytes);
    const saved = try resume_codec.inspect(a, checkpoint_bytes, id);
    try std.testing.expectEqualStrings(catalog.find(target).?.model.name, saved.selection.model());
    try std.testing.expectEqual(cfg.providers.Id.opencode_go, saved.selection.provider.?);
    try std.testing.expectEqual(p.Protocol.anthropic, saved.selection.protocol);
    const after = try fixture.bytes();
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualStrings("deepseek-flash", session.global_config.?.value.model.name);
    var restarted = try fixture.session();
    defer restarted.deinit();
    try std.testing.expectEqualStrings("deepseek-flash", restarted.connection().current().model);
}
test "selection defaults empty catalog conflict allocation and write failures publish nothing" {
    inline for (.{ Failure.conflict, Failure.allocation, Failure.write }) |failure| try expectAtomicFailure(target, failure);
}
test "selection defaults empty explicit profile conflict allocation and write failures publish nothing" {
    inline for (.{ Failure.conflict, Failure.allocation, Failure.write }) |failure| try expectAtomicFailure("explicit-profile", failure);
}
test "selection defaults current row no-op never saves even with a stale store version" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    const app = session.app.?;
    const expected_version = session.store.expected_version;
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "home/.thin/config.json", .data = "external writer owns this version" });
    try session.connection().selectModel(session.connection().current().model);
    try std.testing.expect(session.app.? == app);
    try std.testing.expectEqualStrings("deepseek-flash", app.config.value.model.name);
    try std.testing.expectEqualDeep(expected_version, session.store.expected_version);
    const bytes = try fixture.bytes();
    defer a.free(bytes);
    try std.testing.expectEqualStrings("external writer owns this version", bytes);
    try fixture.noLogs();
}
test "selection defaults environment-backed same-provider change persists variable name only" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    var session = try fixture.session();
    defer session.deinit();
    try std.testing.expectEqualStrings("Bearer fake-resolved-env-selection-secret", session.app.?.client.authorization);
    try session.connection().selectModel("deepseek/deepseek-v4-pro");
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-pro", disk.value.registry.?.default);
    const declared = disk.value.registry.?.find("deepseek").?;
    try std.testing.expectEqualStrings("THIN_SELECTION_FAKE_KEY", declared.connection.api_key_env);
    try std.testing.expect(declared.connection.api_key == null);
    try std.testing.expectEqual(@as(usize, 1), declared.models.len);
    const bytes = try fixture.bytes();
    defer a.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fake-resolved-env-selection-secret") == null);
    try fixture.env.put("THIN_SELECTION_FAKE_KEY", "fake-new-env-selection-secret");
    var restarted = try fixture.session();
    defer restarted.deinit();
    try std.testing.expectEqualStrings("deepseek-v4-pro", restarted.connection().current().model);
    try std.testing.expectEqualStrings("Bearer fake-new-env-selection-secret", restarted.app.?.client.authorization);
    try fixture.noLogs();
}
