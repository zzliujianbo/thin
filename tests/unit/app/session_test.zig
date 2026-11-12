test "metadata notice TTL only expires complete refresh successes" {
    try std.testing.expectEqual(@as(u16, 3000), metadataNoticeTtl(official_refresh_success));
    try std.testing.expectEqual(@as(u16, 3000), metadataNoticeTtl(public_refresh_success));
    for ([_]?[]const u8{ null, "Official metadata partly refreshed; failed sources kept cached/default values", "Official model list refreshed; models.dev metadata refresh failed", "Metadata cache could not be saved; previous values kept", "Official metadata updated; models.dev refresh still running" }) |notice| {
        try std.testing.expectEqual(@as(u16, 0), metadataNoticeTtl(notice));
    }
}
test "global defaults distinguish machine prefixes from summarized or assistant history" {
    const Message = @import("../core/protocol.zig").Message;
    const context = @import("../core/context.zig");
    const machine: Message = .{ .role = .context, .blocks = &.{.{ .text = "owned environment prefix" }} };
    try std.testing.expect(!hasConversationData(&.{machine}));
    const summary: Message = .{ .role = .context, .blocks = &.{.{ .text = context.summary_marker ++ "prior user content" }} };
    try std.testing.expect(hasConversationData(&.{summary}));
    try std.testing.expect(hasConversationData(&.{ machine, .{ .role = .assistant, .blocks = &.{.{ .text = "saved reply" }} } }));
}
test "session completions survive activation and every owner replacement" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    try std.testing.expect(session.app == null);
    const queue = session.memory_notifications.?;
    const connection = session.connection();
    try connection.configure("fake-notification-key");
    var app = session.app.?;
    try std.testing.expect(app.memory_coordinator.notification_queue == queue);
    var incomplete: @import("../core/knowledge.zig").Capture = .{ .allocator = std.testing.allocator, .incomplete = true };
    try std.testing.expectError(error.IncompleteCapture, app.memory_coordinator.enqueueCopy(&incomplete, .chat, .{}));
    try std.testing.expectEqual(@as(u64, 1), session.peekMemoryCompletion().?.id);
    try std.testing.expectEqual(@as(u64, 1), session.peekMemoryCompletion().?.id);

    var declaration = app.config.value;
    declaration.limits.request_timeout_ms += 1;
    var settings = try app.prepareSettings(declaration, &fixture.env);
    defer settings.deinit();
    try std.testing.expect(settings.replace_memory);
    app.installSettings(&settings);
    try std.testing.expect(app.memory_coordinator.notification_queue == queue);
    app.memory_coordinator.next_id = 10;
    try std.testing.expectError(error.IncompleteCapture, app.memory_coordinator.enqueueCopy(&incomplete, .chat, .{}));

    const candidate_config = try cfg.clone(std.testing.allocator, app.config.value);
    const replacement = try app.prepareConnection(candidate_config, &fixture.env);
    app.installConnection(replacement);
    try std.testing.expect(app.memory_coordinator.notification_queue == queue);
    app.memory_coordinator.next_id = 20;
    try std.testing.expectError(error.IncompleteCapture, app.memory_coordinator.enqueueCopy(&incomplete, .chat, .{}));

    // A new App binds the same heap-stable queue before the old App is freed.
    const next = try session.prepareApp(try cfg.clone(std.testing.allocator, app.config.value));
    session.app = next;
    app.deinit();
    app = next;
    try std.testing.expect(app.memory_coordinator.notification_queue == queue);
    app.memory_coordinator.next_id = 30;
    try std.testing.expectError(error.IncompleteCapture, app.memory_coordinator.enqueueCopy(&incomplete, .chat, .{}));
    try std.testing.expectEqual(@as(u64, 1), connection.takeMemoryCompletion().?.id);
    for ([_]u64{ 11, 21, 31 }) |id| {
        try std.testing.expectEqual(id, session.peekMemoryCompletion().?.id);
        try std.testing.expectEqual(id, session.takeMemoryCompletion().?.id);
    }
    try std.testing.expect(session.takeMemoryCompletion() == null);
}
test "session title fallback model update and resume follow successful checkpoints" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var id: ids.Id = undefined;
    {
        var session = try fixture.open(.{});
        defer session.deinit();
        try session.connection().configure("fake-title-test");
        const app = session.app.?;
        try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .context, .blocks = &.{.{ .text = "environment is not a title" }} });
        try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{ .{ .text = "  \n " }, .{ .text = "  首条\n问题 " } } });
        try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "old-title-tool", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } }} });
        try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "old-title-tool", .text = "old result" } }} });
        try session.persistCheckpointInner(false);
        try std.testing.expectEqualStrings("首条 问题", session.saved_title.text());
        app.executor.session_title = session_metadata.Title.fromText("概括标题");
        try session.persistCheckpointInner(false);
        try std.testing.expectEqualStrings("概括标题", session.saved_title.text());
        try std.testing.expect(try session.saveOnExit());
        id = session.session_id;
    }
    {
        var restored = try fixture.open(.{ .resume_session = id });
        defer restored.deinit();
        try std.testing.expectEqualStrings("概括标题", restored.saved_title.text());
        try restored.connection().configure("fake-title-resume");
        try std.testing.expectEqualStrings("概括标题", restored.app.?.executor.session_title.?.text());
        try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "must-not-run.txt", .{}));
    }
}
test "title is not created without conversation or a checkpoint" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    try session.connection().configure("fake-title-empty");
    session.app.?.executor.session_title = session_metadata.Title.fromText("model title");
    session.publishCheckpoint();
    try std.testing.expect(!try session.saveOnExit());
    try std.testing.expect(session.resume_lease == null);
    var buffer: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".thin/sessions/{s}.title", .{session.session_id});
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, path, .{}));
}
test "title write failure preserves checkpoint and surfaces recording warning" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var id: ids.Id = undefined;
    {
        var session = try fixture.open(.{});
        defer session.deinit();
        try session.connection().configure("fake-title-failure");
        try seedSessionTestHistory(&session);
        try session.ensureWritableLease();
        id = session.session_id;
        var buffer: [100]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, ".thin/sessions/{s}.title", .{id});
        try fixture.tmp.dir.createDir(std.testing.io, path, .default_dir);
        try session.persistCheckpointInner(false);
        try std.testing.expect(session.checkpointError() != null);
        try std.testing.expectEqual(session.checkpointError().?, session.connection().current().log_error.?);
        try expectSessionTestHistory(&session);
        try std.testing.expect(try session.saveOnExit());
    }
    var restored = try fixture.open(.{ .resume_session = id });
    defer restored.deinit();
    try expectSessionTestHistory(&restored);
}
test "failed checkpoint does not create a title" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    try session.connection().configure("fake-title-checkpoint-failure");
    try seedSessionTestHistory(&session);
    session.app.?.executor.session_title = session_metadata.Title.fromText("model title");
    try session.ensureWritableLease();
    var checkpoint_buffer: [100]u8 = undefined;
    const checkpoint_path = try std.fmt.bufPrint(&checkpoint_buffer, ".thin/sessions/{s}.session", .{session.session_id});
    try fixture.tmp.dir.createDir(std.testing.io, checkpoint_path, .default_dir);
    session.publishCheckpoint();
    try std.testing.expect(session.checkpointError() != null);
    var title_buffer: [100]u8 = undefined;
    const title_path = try std.fmt.bufPrint(&title_buffer, ".thin/sessions/{s}.title", .{session.session_id});
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, title_path, .{}));
}
test "checkpoint persistence ignores machine-only context but retains prior conversation" {
    const Message = @import("../core/protocol.zig").Message;
    const summary_marker = @import("../core/context.zig").summary_marker;
    const cases = [_]struct { messages: []const Message, persists: bool }{
        .{ .messages = &.{.{ .role = .context, .blocks = &.{.{ .text = "machine prefix" }} }}, .persists = false },
        .{ .messages = &.{.{ .role = .context, .blocks = &.{.{ .text = summary_marker ++ "prior conversation" }} }}, .persists = true },
        .{ .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "prior question" }} }}, .persists = true },
        .{ .messages = &.{.{ .role = .assistant, .blocks = &.{.{ .text = "prior answer" }} }}, .persists = true },
    };
    for (cases) |case| {
        var fixture = try SessionTestFixture.init();
        defer fixture.deinit();
        var session = try fixture.open(.{});
        defer session.deinit();
        try session.connection().configure("fake-checkpoint-test");
        const app = session.app.?;
        try app.runtime.restoreCheckpoint(.{
            .system = "saved system",
            .selector = app.runtime.selector,
            .estimator = .{},
            .last_context_tokens = null,
            .permission_id = 0,
            .messages = case.messages,
        });
        try session.persistCheckpointInner(false);
        var path_buffer: [100]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".thin/sessions/{s}.session", .{session.session_id});
        if (case.persists) {
            _ = try fixture.tmp.dir.statFile(std.testing.io, path, .{});
        } else {
            try std.testing.expect(session.resume_lease == null);
            try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, path, .{}));
        }
        try std.testing.expectEqual(case.persists, try session.saveOnExit());
        if (!case.persists) try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, path, .{}));
    }
}
test "session observer allocates only checkpoint spans for commit and finish" {
    for ([_]bool{ false, true }) |fail_checkpoint| {
        var fixture = try SessionTestFixture.init();
        defer fixture.deinit();
        var session = try fixture.open(.{});
        defer session.deinit();
        try session.connection().configure("fake-observer-spans");
        const app = session.app.?;
        try app.runtime.restoreCheckpoint(.{
            .system = "saved system",
            .selector = app.runtime.selector,
            .estimator = .{},
            .last_context_tokens = null,
            .permission_id = 0,
            .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "question" }} }},
        });
        session.installObserver();
        try std.testing.expect(app.runtime.observer.context == @as(*anyopaque, &session));
        try session.ensureWritableLease();
        var path_buffer: [100]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".thin/sessions/{s}.session", .{session.session_id});
        if (fail_checkpoint) try fixture.tmp.dir.createDir(std.testing.io, path, .default_dir);

        app.runtime.observer.notify(.{ .submitted = "question" });
        app.journal.flush();
        try std.testing.expectEqual(null, app.journal.failure());
        try std.testing.expect(app.journal.diagnostic_ready.load(.acquire));
        const observations = [_]r.Observation{
            .{ .event = .{ .assistant_committed = &.{.{ .text = "answer" }} } },
            .{ .event = .{ .finished = .{ .status = .success } } },
        };
        for (observations) |observation| {
            // IDs are allocated before the lossy diagnostic enqueue.
            const before = app.journal.diagnostic_span.load(.monotonic);
            app.runtime.observer.notify(observation);
            try std.testing.expectEqual(before + 1, app.journal.diagnostic_span.load(.monotonic));
            try std.testing.expectEqual(fail_checkpoint, session.checkpointError() != null);
            if (fail_checkpoint) {
                try std.testing.expectEqual(session.checkpointError().?, session.connection().current().log_error.?);
            } else {
                _ = try fixture.tmp.dir.statFile(std.testing.io, path, .{});
            }
        }
    }
}
test "stream delta observations do not allocate diagnostic spans" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    try session.connection().configure("fake-archive-original");
    session.installObserver();
    const app = session.app.?;
    app.runtime.observer.notify(.{ .submitted = "test" });
    app.journal.flush();
    const before = app.journal.diagnostic_span;
    for (0..512) |_| {
        app.runtime.observer.notify(.{ .event = .{ .text = "delta" } });
        app.runtime.observer.notify(.{ .event = .{ .reasoning = "delta" } });
    }
    try std.testing.expectEqual(before, app.journal.diagnostic_span);
    try std.testing.expectEqual(@as(usize, 0), app.journal.diagnostic_outstanding);
    try std.testing.expectEqual(null, app.journal.failure());
}
test "empty HOME hides placeholder selection but retains initialized defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try std.testing.expect(session.loaded_checkpoint == null);
    const state = session.connection().current();
    try std.testing.expectEqualStrings("", state.model);
    try std.testing.expect(state.selection_name == null);
    try std.testing.expect(state.initial_context == null);
    try std.testing.expectEqual(@as(u32, 0), state.context_limit);
    // No active priced model: the UI flag is not the global policy toggle.
    try std.testing.expect(!state.low_price_input);
    try std.testing.expectEqual(@as(usize, 0), state.model_providers.len);
    try std.testing.expectEqualStrings("deepseek-flash", session.pending.?.value.model.name);
    const disk = try session.store.loadExisting();
    defer disk.deinit();
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", disk.value.registry.?.default);
    try std.testing.expectEqualStrings("deepseek-flash", disk.value.model.name);
}
test "provider menu preserves local credential aliases and actual endpoint identity" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"pending/saved","providers":{"pending":{"base_url":"https://pending.invalid/v1","models":{"saved":{"protocol":"chat","context_tokens":65536}}},"proxy-alias":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","api_key":"fake-proxy"},"official-one":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key":"fake-official"},"official-two":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key_env":"MENU_KEY"},"empty-env":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key_env":"EMPTY_MENU_KEY"},"missing-env":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key_env":"MISSING_MENU_KEY"}}},"limits":{"low_price_input":false}}
    );
    try fixture.env.put("MENU_KEY", "fake-env");
    try fixture.env.put("EMPTY_MENU_KEY", "");
    var session = try fixture.open(.{});
    defer session.deinit();
    const state = session.connection().current();
    const providers = state.model_providers;
    try std.testing.expectEqual(@as(usize, 3), providers.len);
    var seen: u8 = 0;
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.name, "proxy-alias")) {
            seen |= 1;
            try std.testing.expect(provider.allow_custom);
        } else if (std.mem.eql(u8, provider.name, "official-one")) {
            seen |= 2;
            try std.testing.expect(!provider.allow_custom);
        } else if (std.mem.eql(u8, provider.name, "official-two")) {
            seen |= 4;
            try std.testing.expect(!provider.allow_custom);
        } else return error.UnexpectedProvider;
    }
    try std.testing.expectEqual(@as(u8, 7), seen);
    // Fresh publication reflects local environment changes without rebuilding
    // model candidates or treating a kind hint as official identity.
    try fixture.env.put("MENU_KEY", "");
    try std.testing.expectEqual(@as(usize, 2), session.connection().current().model_providers.len);
    try std.testing.expectEqual(metadata.bit(.deepseek), session.configuredMask(session.global_config.?.value));
    const proxy = session.global_config.?.value.registry.?.find("proxy-alias").?;
    try std.testing.expect(session.hasLocalCredential(proxy.connection));
    var empty_literal = proxy.connection;
    empty_literal.api_key = "";
    try std.testing.expect(!session.hasLocalCredential(empty_literal));
}
test "codex public prompt and exact-generation cancellation" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    var job: CodexLoginJob = .{ .io = std.testing.io, .manager = undefined, .alias = undefined, .view = .{ .generation = 7, .status = .pending } };
    session.codex_job = &job;
    defer session.codex_job = null;
    try std.testing.expectError(error.InvalidSequence, session.cancelCodexLogin(6));
    try std.testing.expect(!job.cancel.isRequested());
    try CodexLoginJob.pending(&job, .{ .verification_url = codex_login.verification_url, .user_code = "ABCD-1234" });
    const view = session.codexLoginView();
    try std.testing.expectEqualStrings("ABCD-1234", view.userCode());
    try std.testing.expect(try session.pollCodexLogin());
    try std.testing.expect(!try session.pollCodexLogin());
    try session.cancelCodexLogin(7);
    try std.testing.expect(job.cancel.isRequested());
    try std.testing.expectError(error.InvalidDevicePrompt, CodexLoginJob.pending(&job, .{ .verification_url = "https://evil.invalid/", .user_code = "CODE" }));
}
test "codex login selects exact official alias without requiring credentials" {
    const official = cfg.Provider{ .base_url = ProviderId.openai_codex.baseUrl(), .kind = .openai_codex };
    const providers = [_]cfg.NamedProvider{
        .{ .name = "lookalike", .connection = .{ .base_url = "https://chatgpt.com/backend-api/codex/evil", .kind = .openai_codex } },
        .{ .name = "wrong-kind", .connection = .{ .base_url = ProviderId.openai_codex.baseUrl() } },
        .{ .name = "chatgpt", .connection = official },
        .{ .name = "codex", .connection = official },
    };
    const registry = cfg.Registry{ .default = "", .providers = &providers };
    try std.testing.expectEqualStrings("codex", codexLoginAlias(registry, "codex"));
    try std.testing.expectEqualStrings("chatgpt", codexLoginAlias(registry, "lookalike"));
    try std.testing.expectEqualStrings("chatgpt", codexLoginAlias(registry, "wrong-kind"));
    try std.testing.expectEqualStrings(ProviderId.openai_codex.slug(), codexLoginAlias(null, null));
    const invalid = cfg.Registry{ .default = "", .providers = providers[0..2] };
    try std.testing.expectEqualStrings(ProviderId.openai_codex.slug(), codexLoginAlias(invalid, "lookalike"));
}
test "codex credential presence requires exact official identity" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    var provider: cfg.Provider = .{ .base_url = ProviderId.openai_codex.baseUrl(), .kind = .openai_codex, .codex_oauth = .{ .access_token = "fixture", .refresh_token = "fixture", .expires_at_ms = 1 } };
    try std.testing.expect(session.hasLocalCredential(provider));
    provider.base_url = "https://example.invalid";
    try std.testing.expect(!session.hasLocalCredential(provider));
}
test "codex metadata shares the original official deadline" {
    const Fixture = struct {
        var acquires: usize = 0;
        var fetches: usize = 0;
        var acquire_ms: u32 = 0;
        var fetch_ms: u32 = 0;
        var advance_ms: i64 = 0;
        var cancel_after = false;
        fn source(ctx: ?*anyopaque, a: std.mem.Allocator, _: []const u8, _: ?*const p.Cancellation, timeout_ms: u32) !codex_auth.RequestCredential {
            const job: *MetadataJob = @ptrCast(@alignCast(ctx.?));
            acquires += 1;
            acquire_ms = timeout_ms;
            job.started_ms -= advance_ms;
            if (cancel_after) job.codex_cancel.cancel();
            const token = try a.dupe(u8, "token");
            errdefer a.free(token);
            return .{ .access_token = token, .account_id = try a.dupe(u8, "account") };
        }
        fn fetch(_: std.mem.Allocator, _: std.Io, _: *const codex_auth.RequestCredential, _: ?*const p.Cancellation, timeout_ms: u32) !metadata.Listing {
            fetches += 1;
            fetch_ms = timeout_ms;
            return .{};
        }
    };
    const now: i64 = @intCast(std.Io.Clock.awake.now(std.testing.io).toMilliseconds());
    try std.testing.expectEqual(@as(?u32, official_metadata_timeout_ms), MetadataJob.remainingCodexMs(now, now - 1));
    try std.testing.expectEqual(@as(?u32, 1), MetadataJob.remainingCodexMs(now, now + official_metadata_timeout_ms - 1));
    try std.testing.expectEqual(@as(?u32, null), MetadataJob.remainingCodexMs(now, now + official_metadata_timeout_ms));
    var job: MetadataJob = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .fetch = metadata.fetch,
        .dev_fetch = metadata.fetchDev,
        .manual = false,
        .started_ms = now - official_metadata_timeout_ms,
        .requested = metadata.bit(.openai_codex),
        .codex_fetch = Fixture.fetch,
    };
    job.codex_alias = @constCast("fixture");
    job.codex_source = .{ .context = &job, .acquire_fn = Fixture.source };
    Fixture.acquires = 0;
    Fixture.fetches = 0;
    Fixture.advance_ms = 0;
    Fixture.cancel_after = false;
    job.runCodex();
    try std.testing.expectEqual(@as(usize, 0), Fixture.acquires);
    try std.testing.expectEqual(@as(usize, 0), Fixture.fetches);

    job.started_ms = @intCast(std.Io.Clock.awake.now(job.io).toMilliseconds());
    Fixture.advance_ms = 1000;
    job.runCodex();
    try std.testing.expectEqual(@as(usize, 1), Fixture.acquires);
    try std.testing.expectEqual(@as(usize, 1), Fixture.fetches);
    try std.testing.expect(Fixture.fetch_ms > 0 and Fixture.fetch_ms < Fixture.acquire_ms);

    job.started_ms = @intCast(std.Io.Clock.awake.now(job.io).toMilliseconds());
    Fixture.advance_ms = official_metadata_timeout_ms;
    job.runCodex();
    try std.testing.expectEqual(@as(usize, 2), Fixture.acquires);
    try std.testing.expectEqual(@as(usize, 1), Fixture.fetches);

    job.started_ms = @intCast(std.Io.Clock.awake.now(job.io).toMilliseconds());
    Fixture.advance_ms = 0;
    Fixture.cancel_after = true;
    job.runCodex();
    try std.testing.expectEqual(@as(usize, 3), Fixture.acquires);
    try std.testing.expectEqual(@as(usize, 1), Fixture.fetches);
}
test "codex metadata refresh borrows the exact configured alias and skips sends before reauth" {
    const Fixture = struct {
        var acquires: std.atomic.Value(usize) = .init(0);
        var reauth: std.atomic.Value(bool) = .init(false);
        fn source(_: ?*anyopaque, a: std.mem.Allocator, alias: []const u8, _: ?*const p.Cancellation, _: u32) !codex_auth.RequestCredential {
            _ = acquires.fetchAdd(1, .monotonic);
            // Only the exact configured alias may be acquired.
            if (!std.mem.eql(u8, alias, "chatgpt")) return error.UnexpectedAlias;
            // refresh_pending means reauthentication is required: never send.
            if (reauth.load(.monotonic)) return error.OAuthReauthenticationRequired;
            return .{ .access_token = try a.dupe(u8, "fake-codex-access"), .account_id = try a.dupe(u8, "fake-codex-account") };
        }
        fn fetch(a: std.mem.Allocator, _: std.Io, credential: *const codex_auth.RequestCredential, _: ?*const p.Cancellation, _: u32) !metadata.Listing {
            if (!std.mem.eql(u8, credential.access_token, "fake-codex-access")) return error.UnexpectedCredential;
            return metadata.parseListing(a, "{\"models\":[{\"slug\":\"gpt-fixture\",\"visibility\":\"list\",\"context_window\":65536}]}", .openai_codex);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeSessionTestConfig(tmp.dir, session_codex_metadata_config);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    session.initial_default_pending = false;
    session.metadata_wall_ms = 1000;
    session.metadata_dev_fetch = MetadataFixture.dev;
    session.metadata_codex_source = .{ .acquire_fn = Fixture.source };
    session.metadata_codex_fetch = Fixture.fetch;
    Fixture.acquires.store(0, .monotonic);
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try std.testing.expectEqual(metadata.bit(.openai_codex) | metadata.dev_bit, job.requested);
    // Only the exact alias is copied; Codex never consults an API key.
    try std.testing.expectEqualStrings("chatgpt", job.codex_alias.?);
    try std.testing.expect(job.keys[@intCast(@backingInt(ProviderId.openai_codex))] == null);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 1), Fixture.acquires.load(.monotonic));
    const listed = LayeredMetadataFixture.row(&session.metadata_cache.directory, .openai_codex, "gpt-fixture");
    try std.testing.expectEqual(@as(?u32, 65536), listed.tokens);
    try std.testing.expectEqual(p.Protocol.responses, listed.protocol);
    var saved = try metadata.load(&session.store.root);
    defer saved.deinit(session.store.root.allocator);
    try std.testing.expect(saved.refresh[@intCast(@backingInt(ProviderId.openai_codex))].successful);
    try std.testing.expect(session.metadata_job == null);
    // A pending reauthentication keeps the last good list and issues no send.
    Fixture.reauth.store(true, .monotonic);
    session.metadata_wall_ms = 9999;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 2), Fixture.acquires.load(.monotonic));
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&session.metadata_cache.directory, .openai_codex, "gpt-fixture").tokens);
    var failed = try metadata.load(&session.store.root);
    defer failed.deinit(session.store.root.allocator);
    try std.testing.expect(!failed.refresh[@intCast(@backingInt(ProviderId.openai_codex))].successful);
}
test "new llm pending startup and custom login activate without inference" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try std.testing.expectEqualStrings("", session.connection().current().model);
    try std.testing.expect(session.connection().current().selection_name == null);
    try std.testing.expectEqual(@as(usize, 0), session.connection().current().model_providers.len);
    try std.testing.expectEqual(@as(usize, 0), Session.initialHistory(&session).len);
    try std.testing.expect(session.settings_notice != null);
    try session.connection().configure("fake-custom-key");
    try std.testing.expectEqualStrings("Bearer fake-custom-key", session.app.?.client.authorization);
    const logged_in = session.connection().current();
    try std.testing.expectEqual(@as(usize, 1), logged_in.model_providers.len);
    try std.testing.expectEqualStrings("archive", logged_in.model_providers[0].name);
    try std.testing.expect(logged_in.model_providers[0].allow_custom);
    try std.testing.expectEqualStrings("archive/saved", logged_in.selection_name.?);
    try std.testing.expectEqualStrings("archive/saved", session.global_config.?.value.registry.?.default);
    try std.testing.expectEqualDeep(r.ContextSnapshot{ .tokens = 0, .limit = 65536 }, logged_in.initial_context.?);
    // The no-checkpoint fallback itself also remains fresh known zero.
    session.initial_context = null;
    try std.testing.expectEqualDeep(r.ContextSnapshot{ .tokens = 0, .limit = 65536 }, session.connection().current().initial_context.?);
    try std.testing.expect(!session.app.?.journal.started);
    try std.testing.expect(!try session.saveOnExit());
}
test "checkpoint usage is display only without key and in read only viewers" {
    const Counter = struct {
        events: usize = 0,
        authorizations: usize = 0,
        fn emit(raw: ?*anyopaque, _: r.Event, _: *const p.Cancellation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.events += 1;
        }
        fn authorize(raw: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.authorizations += 1;
            return .allow_once;
        }
    };
    for ([_]?u64{ 77, 0, null }) |reported| {
        var fixture = try SessionTestFixture.init();
        defer fixture.deinit();
        const id = blk: {
            var source = try fixture.open(.{});
            defer source.deinit();
            try source.connection().configure("fake-archive-original");
            try seedSessionTestHistory(&source);
            source.app.?.runtime.last_context_tokens = reported;
            try std.testing.expect(try source.saveOnExit());
            break :blk source.session_id;
        };
        // The live model's resolved limit, not the old checkpoint's 65536.
        try writeSessionTestConfig(fixture.tmp.dir,
            \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","models":{"saved":{"protocol":"chat","context_tokens":131072}}}}},"limits":{"low_price_input":false}}
        );
        var counter: Counter = .{};
        const host = r.Host{ .context = &counter, .emit_fn = Counter.emit, .authorize_fn = Counter.authorize };
        var no_key = try Session.initWithOptions(std.testing.allocator, std.testing.io, &fixture.env, fixture.home, host, .{ .resume_session = id });
        defer no_key.deinit();
        try std.testing.expect(!no_key.read_only and no_key.app == null);
        try std.testing.expect(no_key.loaded_checkpoint != null and no_key.initial_context == null);
        const expected = r.ContextSnapshot{ .tokens = reported orelse 0, .limit = 131072, .known = reported != null };
        const pending = no_key.connection().current();
        try std.testing.expect(pending.runtime == null);
        try std.testing.expectEqualDeep(expected, pending.initial_context.?);
        try expectSessionTestHistory(&no_key);

        // Even with a usable key, a second reader must not acquire send rights.
        try writeSessionTestConfig(fixture.tmp.dir,
            \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key":"fake-reader-key","models":{"saved":{"protocol":"chat","context_tokens":131072}}}}},"limits":{"low_price_input":false}}
        );
        var reader = try Session.initWithOptions(std.testing.allocator, std.testing.io, &fixture.env, fixture.home, host, .{ .resume_session = id });
        defer reader.deinit();
        try std.testing.expect(reader.read_only and reader.app == null);
        try std.testing.expect(reader.loaded_checkpoint != null and reader.initial_context == null);
        const viewed = reader.connection().current();
        try std.testing.expect(viewed.runtime == null);
        try std.testing.expectEqualDeep(expected, viewed.initial_context.?);
        try expectSessionTestHistory(&reader);
        try std.testing.expectError(error.ResumeReadOnly, reader.connection().configure("fake-not-published"));
        try std.testing.expectEqual(@as(usize, 0), counter.events);
        try std.testing.expectEqual(@as(usize, 0), counter.authorizations);
    }
}
test "resume without key displays and saves history then custom login imports it exactly once" {
    const Counter = struct {
        started: usize = 0,
        fn emit(raw: ?*anyopaque, event: r.Event, _: *const @import("../core/protocol.zig").Cancellation) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (event == .tool_started) self.started += 1;
        }
        fn authorize(_: ?*anyopaque, _: r.Permission, _: *const @import("../core/protocol.zig").Cancellation) !r.Decision {
            return .allow_once;
        }
    };
    var counter: Counter = .{};
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    // Actual new-format fixture removes the saved inline key.
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    var resumed = try Session.initWithOptions(std.testing.allocator, std.testing.io, &fixture.env, fixture.home, .{ .context = &counter, .emit_fn = Counter.emit, .authorize_fn = Counter.authorize }, .{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.loaded_checkpoint != null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(try resumed.saveOnExit());
    try resumed.connection().configure("fake-custom-login");
    try std.testing.expect(resumed.loaded_checkpoint == null);
    try std.testing.expect(resumed.loaded_selection == null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqual(@as(u64, 13), resumed.app.?.journal.seq);
    try std.testing.expectEqual(@as(u64, 2), resumed.app.?.journal.turn);
    try std.testing.expectEqual(@as(u64, 77), resumed.initial_context.?.tokens);
    try std.testing.expect(resumed.app.?.journal.resumed);
    try resumed.connection().selectModel("archive/saved");
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqual(@as(usize, 0), counter.started);
    try std.testing.expectEqual(@as(u64, 0), resumed.app.?.runtime.permission_id);
}
test "invalid or empty key environment does not block restored history and can login locally" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    for ([_][]const u8{ "", "bad\nkey" }) |value| {
        try writeSessionTestConfig(fixture.tmp.dir,
            \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key_env":"ARCHIVE_TEST_KEY","models":{"saved":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false}}
        );
        try fixture.env.put("ARCHIVE_TEST_KEY", value);
        var resumed = try fixture.open(.{ .resume_session = id });
        defer resumed.deinit();
        try std.testing.expect(resumed.app == null);
        try std.testing.expect(std.mem.find(u8, resumed.settings_notice.?, "/login") != null);
        try expectSessionTestHistory(&resumed);
        try resumed.connection().configure("fake-valid-replacement");
        try std.testing.expect(resumed.app != null);
        try expectSessionTestHistory(&resumed);
        try std.testing.expect(!resumed.read_only);
        try std.testing.expect(try resumed.saveOnExit());
    }
}
test "concurrent checkpoint writer allows read only history without credentials" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    var writer = try fixture.open(.{ .resume_session = id });
    defer writer.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    var reader = try fixture.open(.{ .resume_session = id });
    defer reader.deinit();
    try std.testing.expect(reader.read_only);
    try std.testing.expect(reader.app == null);
    try std.testing.expect(std.mem.find(u8, reader.settings_notice.?, "read-only") != null);
    try expectSessionTestHistory(&reader);
    try std.testing.expect(!try reader.saveOnExit());
    try std.testing.expectError(error.ResumeReadOnly, reader.connection().configure("fake-not-published"));
}
test "changed credential and current budgets do not authenticate or reject checkpoint loading" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key":"fake-rotated-key","models":{"saved":{"protocol":"responses","context_tokens":131072,"output_tokens":16384}}}}},"limits":{"low_price_input":true,"max_input_tokens":12000,"input_margin_tokens":1000}}
    );
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqualStrings("Bearer fake-rotated-key", resumed.app.?.client.authorization);
    const current_config = resumed.app.?.config.value;
    try std.testing.expectEqual(@as(u32, 131072), current_config.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 16384), current_config.model.output_tokens);
    try std.testing.expect(current_config.model.input_price_threshold == null);
    try std.testing.expect(current_config.limits.low_price_input);
    try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.responses, current_config.model.protocol);
    try std.testing.expect(!resumed.read_only);
    try std.testing.expect(try resumed.saveOnExit());
}
test "missing alias cannot borrow same model credential and preserves historical header" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_missing_alias);
    try fixture.env.put("SESSION_TEST_KEY", "fake-unrelated-key");
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.pending.?.value.selection_pending);
    try std.testing.expect(resumed.connection().current().initial_context == null);
    try std.testing.expectEqualStrings("archive/saved", resumed.connection().current().selection_name.?);
    try std.testing.expectEqualStrings("saved", resumed.connection().current().model);
    try std.testing.expect(resumed.connection().current().provider == null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(try resumed.saveOnExit());
    try resumed.connection().selectModel("other/saved");
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqualStrings("other/saved", resumed.global_config.?.value.registry.?.default);
}
test "removed alias rebinds only by an unambiguous exact endpoint" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"renamed/saved","providers":{"renamed":{"base_url":"https://archive.invalid/v1","api_key":"fake-renamed","models":{"saved":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
    );
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expectEqualStrings("renamed/saved", resumed.connection().current().selection_name.?);
    try std.testing.expectEqualStrings("Bearer fake-renamed", resumed.app.?.client.authorization);
    try expectSessionTestHistory(&resumed);
}
test "unavailable model login saves credential without dropping history or changing default" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_unavailable);
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try resumed.connection().configure("fake-unavailable-model-key");
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.loaded_checkpoint != null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expectEqualStrings("other/other", resumed.global_config.?.value.registry.?.default);
    try std.testing.expectEqualStrings("fake-unavailable-model-key", resumed.global_config.?.value.registry.?.find("archive").?.connection.api_key.?);
    try std.testing.expect(std.mem.find(u8, resumed.settings_notice.?, "/model") != null);
    try resumed.connection().selectModel("archive/next");
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(resumed.loaded_checkpoint == null);
    try std.testing.expectEqualStrings("other/other", resumed.global_config.?.value.registry.?.default);
    try std.testing.expectEqualStrings("archive/next", resumed.connection().current().selection_name.?);
}
test "official provider login imports pending archive without switching global default" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"other/other","providers":{"archive":{"base_url":"https://api.deepseek.com","kind":"deepseek","models":{"saved":{"protocol":"chat","context_tokens":65536}}},"other":{"base_url":"https://other.invalid/v1","models":{"other":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
    );
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(!resumed.read_only);
    try std.testing.expect(try resumed.saveOnExit());
    try resumed.connection().configureProvider(.deepseek, "fake-official-login");
    try std.testing.expectEqualStrings("Bearer fake-official-login", resumed.app.?.client.authorization);
    try std.testing.expectEqualStrings("archive/saved", resumed.connection().current().selection_name.?);
    try std.testing.expectEqualStrings("other/other", resumed.global_config.?.value.registry.?.default);
    try std.testing.expect(resumed.loaded_checkpoint == null);
    try expectSessionTestHistory(&resumed);
}
test "missing config initializes latest defaults while retaining unconfigured archive" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try fixture.tmp.dir.deleteFile(std.testing.io, ".thin/config.json");
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    try std.testing.expect(resumed.app == null);
    try std.testing.expectEqualStrings("archive/saved", resumed.connection().current().selection_name.?);
    try expectSessionTestHistory(&resumed);
    _ = try fixture.tmp.dir.statFile(std.testing.io, ".thin/config.json", .{});
    try std.testing.expect(!resumed.read_only);
    try std.testing.expect(try resumed.saveOnExit());
}
test "restore selection without key or model remains pending and never imports messages" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_unavailable);
    var selected = try fixture.open(.{ .restore_selection = id });
    defer selected.deinit();
    try std.testing.expect(selected.app == null);
    try std.testing.expect(selected.loaded_checkpoint == null);
    try std.testing.expectEqual(@as(usize, 0), Session.initialHistory(&selected).len);
    try std.testing.expect(selected.pending.?.value.selection_pending);
    try std.testing.expect(!std.mem.eql(u8, &id, &selected.session_id));
    try std.testing.expect(!try selected.saveOnExit());
    try selected.connection().configure("fake-selection-only-key");
    try std.testing.expect(selected.app == null);
    try selected.connection().selectModel("archive/next");
    try std.testing.expectEqual(@as(usize, 0), selected.app.?.runtime.messages().len);
}
test "pending login save failure destroys candidate but retains source history" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    var resumed = try fixture.open(.{ .resume_session = id });
    defer resumed.deinit();
    const original_history = Session.initialHistory(&resumed).ptr;
    // Another writer changes the config after Session captured its CAS baseline.
    try writeSessionTestConfig(fixture.tmp.dir, session_test_unavailable);
    try std.testing.expectError(error.AuthVersionConflict, resumed.connection().configure("fake-rejected-key"));
    try std.testing.expect(resumed.app == null);
    try std.testing.expect(resumed.loaded_checkpoint != null);
    try std.testing.expect(original_history == Session.initialHistory(&resumed).ptr);
    try expectSessionTestHistory(&resumed);
    try std.testing.expect(resumed.global_config.?.value.registry.?.find("archive").?.connection.api_key == null);
}
test "custom credential rotation activates only on explicit same model reselect" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var session = try fixture.open(.{});
    defer session.deinit();
    try session.connection().configure("fake-custom-before");
    try seedSessionTestHistory(&session);
    const old_app = session.app.?;
    try session.connection().configure("fake-custom-after");
    try std.testing.expectEqual(old_app, session.app.?);
    try std.testing.expectEqualStrings("Bearer fake-custom-before", session.app.?.client.authorization);
    try std.testing.expectEqualStrings("fake-custom-after", session.global_config.?.value.registry.?.find("archive").?.connection.api_key.?);
    try session.connection().selectModel("archive/saved");
    try std.testing.expectEqualStrings("Bearer fake-custom-after", session.app.?.client.authorization);
    try expectSessionTestHistory(&session);
}
test "custom kind does not authorize official metadata or credential borrowing" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"proxy/saved","providers":{"proxy":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","api_key":"fake-proxy-only","models":{"saved":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false}}
    );
    var session = try fixture.open(.{});
    defer session.deinit();
    try std.testing.expectEqual(@as(u8, 0), session.configuredMask(session.global_config.?.value));
    try std.testing.expect(session.connection().current().provider == null);
    try std.testing.expect(!session.connection().current().allow_custom_models);
    // Real registry owners do not offer an inherited custom ID which the
    // resolver must reject. Declared custom profiles remain searchable.
    const state = session.connection().current();
    var picker = @import("../ui/model_picker.zig").Picker.init(std.testing.allocator);
    defer picker.deinit();
    picker.provider = state.provider;
    picker.allow_custom = state.allow_custom_models;
    _ = try picker.insert("never-declared", false);
    const unknown = try picker.choicesWithProviders(std.testing.allocator, state.selection_name.?, state.context_limit, state.models, state.model_disabled, state.model_providers);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
    try std.testing.expectError(error.DefaultModelUnavailable, session.connection().selectModel("proxy/never-declared"));
    try std.testing.expectEqualStrings("saved", session.app.?.config.value.model.name);
    picker.clear();
    _ = try picker.insert("saved", false);
    const declared = try picker.choicesWithProviders(std.testing.allocator, state.selection_name.?, state.context_limit, state.models, state.model_disabled, state.model_providers);
    defer std.testing.allocator.free(declared);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    try std.testing.expect(!declared[0].inherited);
    try std.testing.expectEqualStrings("proxy/saved", declared[0].name);
    try std.testing.expectError(error.ApiKeyNotFound, session.keyFor(.deepseek));
    try std.testing.expectEqualStrings("Bearer fake-proxy-only", session.app.?.client.authorization);
}
test "custom kind pending resume login stays on the actual endpoint" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","kind":"opencode_zen","models":{"saved":{"protocol":"chat","context_tokens":65536,"output_tokens":4096}}}}},"limits":{"low_price_input":false}}
    );
    var session = try fixture.open(.{ .resume_session = id });
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try std.testing.expect(session.connection().current().provider == null);
    try std.testing.expect(!session.connection().current().allow_custom_models);
    try expectSessionTestHistory(&session);
    try session.connection().configure("fake-proxy-resume-key");
    try expectSessionTestHistory(&session);
    try std.testing.expectEqualStrings("https://archive.invalid/v1", session.app.?.config.value.provider.base_url);
    try std.testing.expectEqualStrings("Bearer fake-proxy-resume-key", session.app.?.client.authorization);
    try std.testing.expectEqual(ProviderId.opencode_zen, session.app.?.config.value.provider.kind.?);
    try std.testing.expect(session.global_config.?.value.registry.?.find("opencode-zen") == null);
    try std.testing.expectEqual(@as(u8, 0), session.metadata_login_pending);
    try std.testing.expect(!session.app.?.journal.started);
}
test "pending model publication saves new archive selection without key" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    const id = try fixture.saveHistory();
    try writeSessionTestConfig(fixture.tmp.dir, session_test_config);
    {
        var resumed = try fixture.open(.{ .resume_session = id });
        defer resumed.deinit();
        try resumed.connection().selectModel("archive/next");
        try std.testing.expect(resumed.app == null);
        try std.testing.expectEqualStrings("archive/saved", resumed.global_config.?.value.registry.?.default);
        try std.testing.expect(try resumed.saveOnExit());
    }
    var reopened = try fixture.open(.{ .resume_session = id });
    defer reopened.deinit();
    try std.testing.expectEqualStrings("archive/next", reopened.connection().current().selection_name.?);
    try expectSessionTestHistory(&reopened);
}
test "Anthropic displayable session resume preserves signed replay and never executes tools" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const adapter = @import("../llm/anthropic.zig");
    const native = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private plan\",\"signature\":\"signed fixture\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque fixture\"},{\"type\":\"tool_use\",\"id\":\"saved-call\",\"name\":\"write_file\",\"input\":{\"path\":\"must-not-run.txt\",\"content\":\"no\"}}]}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"opencode-go/claude-haiku-5-5","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"claude-haiku-5-5":{"protocol":"anthropic","context_tokens":32768,"output_tokens":4096}}}}},"limits":{"low_price_input":false}}
    );
    var id: ids.Id = undefined;
    var expected: ?[]u8 = null;
    defer if (expected) |bytes| a.free(bytes);
    const Wire = struct {
        fn encode(allocator: std.mem.Allocator, session: *Session) ![]u8 {
            const app = session.app.?;
            // Wire-only replay fixture never sends; provide synthetic required capacity.
            return adapter.encode(allocator, .{
                .scope = .{ .connection = app.config.value.provider.base_url, .model = app.config.value.model.name, .protocol = .anthropic },
                .system = app.runtime.system,
                .messages = app.runtime.messages(),
                .tools = &.{},
                .model_output_tokens = app.config.value.model.output_tokens orelse 8192,
            });
        }
    };
    {
        var source = try Session.init(a, io, &env, home, .{});
        defer source.deinit();
        try source.connection().configureProvider(.opencode_go, "fake-anthropic-resume");
        try source.connection().selectModel("opencode-go/claude-haiku-5-5");
        id = source.session_id;
        const state: checkpoint.State = .{
            .system = "frozen Anthropic system",
            .selector = .{ .configured = .anthropic, .selected = .anthropic, .initial_attempted = true },
            .estimator = .{ .per_mille = 1200 },
            .last_context_tokens = 77,
            .context_tokens = 32768,
            .permission_id = 19,
            .messages = &.{
                .{ .role = .user, .blocks = &.{.{ .text = "original question" }} },
                .{ .role = .assistant, .blocks = &.{
                    .{ .reasoning = "private plan" },
                    .{ .tool_call = .{ .id = "saved-call", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } },
                }, .replay = .{ .scope = .{ .connection = ProviderId.opencode_go.baseUrl(), .model = "claude-haiku-5-5", .protocol = .anthropic }, .json = native } },
                .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "saved-call", .text = "prior result", .canceled = true, .is_error = true } }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "original answer" }} },
            },
        };
        try source.app.?.runtime.restoreCheckpoint(state);
        expected = try Wire.encode(a, &source);
        try std.testing.expect(try source.saveOnExit());
    }
    {
        var restored = try Session.initWithOptions(a, io, &env, home, .{}, .{ .resume_session = id });
        defer restored.deinit();
        try std.testing.expectEqual(id, restored.session_id);
        try std.testing.expect(restored.app.?.runtime.selector.selected == .anthropic);
        try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", restored.connection().current().selection_name.?);
        try std.testing.expectEqualStrings(native, restored.app.?.runtime.messages()[1].replay.?.json);
        const actual = try Wire.encode(a, &restored);
        defer a.free(actual);
        try std.testing.expectEqualStrings(expected.?, actual);
        try std.testing.expect(restored.resume_lease.?.writable);
        try std.testing.expect(!restored.read_only);
        try std.testing.expect(try restored.saveOnExit());
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "must-not-run.txt", .{}));
    }
}
test "Anthropic session resume invalidates null-hash replay when title tools are enabled" {
    const a = std.testing.allocator;
    const adapter = @import("../llm/anthropic.zig");
    const native = "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private null-hash plan\",\"signature\":\"signed null-hash fixture\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque null-hash fixture\"},{\"type\":\"tool_use\",\"id\":\"saved-call\",\"name\":\"write_file\",\"input\":{\"path\":\"must-not-run.txt\",\"content\":\"no\"}}]}";
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir,
        \\{"llm":{"default":"opencode-go/claude-haiku-5-5","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","api_key":"fake-null-hash-resume","models":{"claude-haiku-5-5":{"protocol":"anthropic","context_tokens":32768,"output_tokens":4096}}}}},"limits":{"low_price_input":false}}
    );
    var id: ids.Id = undefined;
    {
        var source = try fixture.open(.{});
        defer source.deinit();
        id = source.session_id;
        const state: checkpoint.State = .{
            .version = 2,
            .tool_schema_hash = null,
            .system = "frozen Anthropic system",
            .selector = .{ .configured = .anthropic, .selected = .anthropic, .initial_attempted = true },
            .estimator = .{ .per_mille = 1200 },
            .last_context_tokens = 77,
            .context_tokens = 32768,
            .permission_id = 19,
            .messages = &.{
                .{ .role = .user, .blocks = &.{.{ .text = "original question" }} },
                .{ .role = .assistant, .blocks = &.{
                    .{ .reasoning = "private null-hash plan" },
                    .{ .tool_call = .{ .id = "saved-call", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } },
                }, .replay = .{ .scope = .{ .connection = ProviderId.opencode_go.baseUrl(), .model = "claude-haiku-5-5", .protocol = .anthropic }, .json = native } },
                .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "saved-call", .text = "prior result" } }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "original answer" }} },
            },
        };
        // Save the nullable-hash DTO directly: Runtime export/saveOnExit would
        // replace null with the current schema hash and miss this restore path.
        const payload = try checkpoint.encode(a, state);
        defer a.free(payload);
        const selection = try selections.capture(source.app.?.config.value);
        const bytes = try resume_codec.encode(a, id, &selection, payload);
        defer a.free(bytes);
        var lease = try resume_store.Lease.create(&source.project_root, id);
        defer lease.deinit();
        try lease.save(&source.project_root, bytes);
    }
    var restored = try fixture.open(.{ .resume_session = id });
    defer restored.deinit();
    const app = restored.app.?;
    try std.testing.expectEqual(id, restored.session_id);
    try std.testing.expect(restored.resume_lease.?.writable and !restored.read_only);
    try std.testing.expect(restored.global_config.?.value.decision == null);
    try std.testing.expect(!restored.global_config.?.value.imageActive());
    try std.testing.expect(app.executor.session_title != null);
    var title_schemas: usize = 0;
    for (app.runtime.executor.schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "set_session_title")) title_schemas += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), title_schemas);
    try std.testing.expectEqual(@as(?u64, 77), app.runtime.last_context_tokens);
    try std.testing.expect(restored.initial_context.?.known);
    try std.testing.expectEqual(@as(u64, 77), restored.initial_context.?.tokens);
    try std.testing.expectEqual(@as(u64, 0), app.runtime.permission_id);
    try std.testing.expect(!app.journal.started);
    const expected: []const p.Message = &.{
        .{ .role = .user, .blocks = &.{.{ .text = "original question" }} },
        .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "saved-call", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } }} },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "saved-call", .text = "prior result" } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "original answer" }} },
    };
    try std.testing.expectEqualDeep(expected, app.runtime.messages());
    const wire = try adapter.encode(a, .{
        .scope = .{ .connection = app.config.value.provider.base_url, .model = app.config.value.model.name, .protocol = .anthropic },
        .system = app.runtime.system,
        .messages = app.runtime.messages(),
        .tools = app.runtime.executor.schemas,
        .model_output_tokens = app.config.value.model.output_tokens,
    });
    defer a.free(wire);
    for ([_][]const u8{ "signed null-hash fixture", "opaque null-hash fixture", "private null-hash plan", "\"thinking\"", "\"redacted_thinking\"" }) |stale| {
        try std.testing.expect(std.mem.indexOf(u8, wire, stale) == null);
    }
    const encoded = try std.json.parseFromSlice(std.json.Value, a, wire, .{});
    defer encoded.deinit();
    const wire_tools = encoded.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(app.runtime.executor.schemas.len, wire_tools.len);
    try std.testing.expectEqualStrings("set_session_title", wire_tools[wire_tools.len - 2].object.get("name").?.string);
    try std.testing.expectEqualStrings("edit_file", wire_tools[wire_tools.len - 1].object.get("name").?.string);
    const messages = encoded.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("original question", messages[0].object.get("content").?.array.items[0].object.get("text").?.string);
    const call = messages[1].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_use", call.get("type").?.string);
    try std.testing.expectEqualStrings("saved-call", call.get("id").?.string);
    try std.testing.expectEqualStrings("write_file", call.get("name").?.string);
    const result = messages[2].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_result", result.get("type").?.string);
    try std.testing.expectEqualStrings("saved-call", result.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings("prior result", result.get("content").?.string);
    try std.testing.expectEqualStrings("original answer", messages[3].object.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(std.testing.io, "must-not-run.txt", .{}));
}
test "closed turn checkpoint is resumable before exit" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var id: ids.Id = undefined;
    {
        var source = try Session.init(a, io, &env, home, .{});
        defer source.deinit();
        try source.connection().configure("fake-incremental-checkpoint");
        id = source.session_id;
        try source.app.?.runtime.restoreCheckpoint(.{
            .system = "saved system",
            .selector = source.app.?.runtime.selector,
            .estimator = .{},
            .last_context_tokens = null,
            .permission_id = 0,
            .messages = &.{
                .{ .role = .user, .blocks = &.{.{ .text = "incremental question" }} },
                .{ .role = .assistant, .blocks = &.{.{ .text = "incremental answer" }} },
            },
        });
        source.app.?.runtime.observer.notify(.{ .event = .{ .assistant_committed = &.{.{ .text = "incremental answer" }} } });
        try std.testing.expect(source.checkpointError() == null);
        try std.testing.expect(source.resume_lease != null);
        try std.testing.expect(source.resume_lease.?.writable);
        var selection_path: [80]u8 = undefined;
        const relative = try std.fmt.bufPrint(&selection_path, ".thin/sessions/{s}.selection.json", .{id});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, relative, .{}));
        releaseLease(&source);
    }
    {
        var resumed = try Session.initWithOptions(a, io, &env, home, .{}, .{ .resume_session = id });
        defer resumed.deinit();
        try std.testing.expectEqual(@as(usize, 2), resumed.app.?.runtime.messages().len);
        try std.testing.expectEqualStrings("incremental question", resumed.app.?.runtime.messages()[0].blocks[0].text);
        try std.testing.expectEqualStrings("incremental answer", resumed.app.?.runtime.messages()[1].blocks[0].text);
        try std.testing.expect(resumed.resume_lease.?.writable);
    }
}
test "checkpoint save conflict reaches UI without changing restored history" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    var source = try fixture.open(.{});
    defer source.deinit();
    try source.connection().configure("fake-checkpoint-conflict");
    try seedSessionTestHistory(&source);
    source.publishCheckpoint();
    try std.testing.expect(source.resume_lease != null);
    try std.testing.expect(source.checkpointError() == null);
    source.setCheckpointFailure(error.NoSpaceLeft);
    try std.testing.expectEqual(error.NoSpaceLeft, source.connection().current().log_error.?);
    source.publishCheckpoint();
    try std.testing.expect(source.checkpointError() == null);
    var buffer: [100]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".thin/sessions/{s}.session", .{source.session_id});
    // Simulate a noncooperating writer; publication must retain the disk CAS.
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "externally changed generation" });
    source.publishCheckpoint();
    try std.testing.expectEqual(error.ResumeConflict, source.checkpointError().?);
    try std.testing.expectEqual(error.ResumeConflict, source.connection().current().log_error.?);
    try expectSessionTestHistory(&source);
}
test "metadata publication failures survive both stage orders while clean successes alone expire" {
    for ([_]bool{ true, false }) |official_first| {
        for ([_]MetadataPublicationFixture.Fault{ .cache, .display, .none }) |fault| {
            for ([_]bool{ true, false }) |manual| try MetadataPublicationFixture.check(official_first, fault, manual);
        }
    }
}
test "initial default adopts late public metadata without cycling or normalizing preference" {
    const Fetch = struct {
        var release: std.atomic.Value(bool) = .init(false);
        fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            try std.testing.expectEqual(ProviderId.opencode_go, id);
            try std.testing.expectEqualStrings("fake-public-effort", key.?);
            return metadata.parseListing(a, "{\"data\":[{\"id\":\"gpt-6-luna\",\"context_window\":131072}]}", id);
        }
        fn public(a: std.mem.Allocator, io: std.Io) !metadata.Listing {
            const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
            while (!release.load(.acquire)) {
                if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.FixtureCompletionTimeout;
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
            return metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = true });
    defer session.deinit();
    Fetch.release.store(false, .release);
    defer Fetch.release.store(true, .release);
    session.metadata_fetch = Fetch.official;
    session.metadata_dev_fetch = Fetch.public;
    try session.connection().configureProvider(.opencode_go, "fake-public-effort");
    try session.connection().selectModel("opencode-go/gpt-6-luna");
    const before = session.app.?.config.value.model;
    try std.testing.expect(before.reasoning == null);
    try std.testing.expect(Session.pollModels(&session, true));
    const job = session.metadata_job.?;
    if (job.future) |*future| future.await(io);
    job.future = null;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectError(error.ThinkingCapabilitiesLoading, Session.cycleEffort(&session));
    try std.testing.expect(session.app.?.config.value.model.reasoning == null);
    Fetch.release.store(true, .release);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expect(!session.initial_default_pending);
    if (session.settings_notice) |notice| try std.testing.expect(std.mem.find(u8, notice, "not applied") == null);
    try std.testing.expectEqual(presentation.ReasoningEffort.off, try persistedEffortForTest(&session));
    const config = session.app.?.config.value;
    const next = presentation.ReasoningEffort.off;
    try std.testing.expectEqual(presentation.ReasoningEffort.off, session.preferred_effort.?);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, config.model.reasoning_source);
    try std.testing.expectEqualStrings(next.name().?, config.model.reasoning_effort.?);
    try std.testing.expect(session.capabilitiesFor(config).levels.contains(next));
    try std.testing.expectEqual(before.context_tokens, config.model.context_tokens);
    try std.testing.expectEqual(before.output_tokens, config.model.output_tokens);
    try std.testing.expectEqual(before.protocol, config.model.protocol);
    // Subsequent refreshes must not replace the now-accepted map.
    const accepted = config.model.reasoning;
    session.metadata_cache.deinit(session.allocator);
    session.metadata_cache = .{};
    try std.testing.expectEqualStrings(next.name().?, session.app.?.config.value.model.reasoning_effort.?);
    _ = try Session.cycleEffort(&session);
    try std.testing.expect(Session.sameDeclaration(accepted, session.app.?.config.value.model.reasoning));
    try std.testing.expect(!session.app.?.journal.started);
}
test "provider reasoning source DeepSeek then Go Haiku applies global default with early or late capabilities" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |late| {
        for ([_]presentation.ReasoningEffort{ .medium, .high }) |wanted| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path: [4096]u8 = undefined;
            const home = path[0..try tmp.dir.realPath(io, &path)];
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            try env.put("HOME", home);
            var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
            defer session.deinit();
            try setGlobalEffortForTest(&session, wanted);
            var deepseek_listing = try metadata.parseListing(a,
                \\{"data":[{"id":"deepseek-flash","effort":{"supported_levels":["off","low","high","max"]}}]}
            , .deepseek);
            defer deepseek_listing.deinit(a);
            session.metadata_cache.deinit(a);
            session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.deepseek), deepseek_listing);
            try session.connection().configureProvider(.deepseek, "fake-haiku-sequence-ds");
            try std.testing.expectEqualStrings("deepseek-flash", session.app.?.config.value.model.name);
            try std.testing.expectEqualStrings("high", session.app.?.config.value.model.reasoning_effort.?);
            var go_unknown = try metadata.parseListing(a,
                \\{"data":[{"id":"claude-haiku-5-5","protocol":"anthropic"}]}
            , .opencode_go);
            defer go_unknown.deinit(a);
            var go_known = try metadata.parseListing(a,
                \\{"data":[{"id":"claude-haiku-5-5","protocol":"anthropic","effort":{"format":"anthropic","supported_levels":["off","low","medium","high","max"]}}]}
            , .opencode_go);
            defer go_known.deinit(a);
            publicReasoningFixture(&go_known, "claude-haiku-5-5");
            session.metadata_cache.deinit(a);
            session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), if (late) go_unknown else go_known);
            try session.connection().configureProvider(.opencode_go, "fake-haiku-sequence-go");
            try std.testing.expectEqualStrings("deepseek-flash", session.app.?.config.value.model.name);
            try session.connection().selectModel("opencode-go/claude-haiku-5-5");
            const before = session.app.?.config.value.model;
            if (late) {
                try std.testing.expect(session.initial_default_pending);
                try std.testing.expect(before.reasoning == null and before.reasoning_effort == null);
                try std.testing.expectEqual(wanted, session.connection().current().pending_default_effort.?);
                session.metadata_cache.deinit(a);
                session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), go_known);
                const borrowed = session.effortCandidate(session.app.?.config.value).model.reasoning.?.map.high.?;
                try std.testing.expect(!(try session.completeInitialDefault(false)));
                session.app.?.runtime.busy.store(true, .release);
                try std.testing.expect(!(try session.completeInitialDefault(true)));
                session.app.?.runtime.busy.store(false, .release);
                try std.testing.expect(try session.completeInitialDefault(true));
                try std.testing.expect(borrowed.ptr != session.app.?.config.value.model.reasoning.?.map.high.?.ptr);
            }
            const model = session.app.?.config.value.model;
            try std.testing.expectEqualStrings(wanted.name().?, model.reasoning_effort.?);
            try std.testing.expectEqual(thinking.Format.anthropic, model.reasoning.?.format);
            try std.testing.expectEqual(wanted, session.connection().current().reasoning_effort);
            try std.testing.expectEqual(wanted, session.app.?.journal.selection.?.effort.?);
            try std.testing.expectEqual(model.protocol, session.app.?.journal.selection.?.protocol);
            try std.testing.expectEqualStrings(model.name, session.app.?.journal.selection.?.model());
            try std.testing.expectEqual(before.context_tokens, model.context_tokens);
            try std.testing.expectEqual(before.output_tokens, model.output_tokens);
            try std.testing.expectEqual(before.protocol, model.protocol);
            try std.testing.expectEqual(before.input_price_threshold, model.input_price_threshold);
            try std.testing.expectEqual(before.input_price_flat_limit, model.input_price_flat_limit);
            try std.testing.expect(!session.initial_default_pending);
            try std.testing.expectEqual(wanted, try persistedEffortForTest(&session));
            var disk = try session.store.loadExisting();
            defer cfg.release(&disk);
            try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", disk.value.registry.?.default);
            try std.testing.expect(disk.value.registry.?.find("opencode-go").?.patchFor("claude-haiku-5-5") == null);
            session.metadata_cache.deinit(a);
            session.metadata_cache = .{};
            try std.testing.expect(!(try session.completeInitialDefault(true)));
            try std.testing.expectEqualStrings(wanted.name().?, session.app.?.config.value.model.reasoning_effort.?);
            try std.testing.expect(!session.app.?.journal.started);
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".thin/settings.json", .{}));
        }
    }
}
test "first activation defaults clamp without changing preference and own late cache maps" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]presentation.ReasoningEffort{ .medium, .off, .high }) |saved| {
        for ([_]bool{ false, true }) |late| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buffer: [4096]u8 = undefined;
            const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            try env.put("HOME", home);
            // Login activates the preselected alias. Declare it without a key;
            // selecting an undeclared provider before /login is not onboarding.
            try writeSessionTestConfig(tmp.dir,
                \\{"llm":{"default":"opencode-go/gpt-6-luna","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go"}}},"limits":{"low_price_input":false}}
            );
            var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
            defer session.deinit();
            try setGlobalEffortForTest(&session, saved);
            var listing = try metadata.parseListing(a, "{\"data\":[{\"id\":\"gpt-6-luna\",\"protocol\":\"responses\",\"effort\":{\"supported_levels\":[\"off\",\"low\",\"high\",\"max\"]}}]}", .opencode_go);
            defer listing.deinit(a);
            publicReasoningFixture(&listing, "gpt-6-luna");
            if (!late) {
                session.metadata_cache.deinit(a);
                session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), listing);
            }
            try session.connection().configureProvider(.opencode_go, "fake-default-effort");
            const before = session.app.?.config.value.model;
            if (late) {
                try std.testing.expect(session.initial_default_pending);
                try std.testing.expectEqual(saved, session.connection().current().pending_default_effort.?);
                try std.testing.expect(before.reasoning_effort == null);
                session.metadata_cache.deinit(a);
                session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), listing);
                const borrowed = session.effortCandidate(session.app.?.config.value).model.reasoning.?.map.high.?;
                try std.testing.expect(!(try session.completeInitialDefault(false)));
                session.app.?.runtime.busy.store(true, .release);
                try std.testing.expect(!(try session.completeInitialDefault(true)));
                session.app.?.runtime.busy.store(false, .release);
                session.read_only = true;
                try std.testing.expect(!(try session.completeInitialDefault(true)));
                session.read_only = false;
                try std.testing.expect(try session.completeInitialDefault(true));
                try std.testing.expect(borrowed.ptr != session.app.?.config.value.model.reasoning.?.map.high.?.ptr);
            }
            const config = session.app.?.config.value;
            const cap = session.capabilitiesFor(config);
            try std.testing.expectEqualStrings(cap.effective(saved.name()).?, config.model.reasoning_effort.?);
            try std.testing.expectEqual(saved, try persistedEffortForTest(&session));
            try std.testing.expect(!session.initial_default_pending);
            try std.testing.expectEqual(before.context_tokens, config.model.context_tokens);
            try std.testing.expectEqual(before.output_tokens, config.model.output_tokens);
            try std.testing.expectEqual(before.protocol, config.model.protocol);
            try std.testing.expectEqual(before.input_price_threshold, config.model.input_price_threshold);
            const accepted = config.model.reasoning;
            session.metadata_cache.deinit(a);
            session.metadata_cache = .{};
            try std.testing.expect(!(try session.completeInitialDefault(true)));
            try std.testing.expect(Session.sameDeclaration(accepted, session.app.?.config.value.model.reasoning));
            try std.testing.expectEqualStrings(cap.map.high.?, session.app.?.config.value.model.reasoning.?.map.high.?);
            try std.testing.expect(!session.app.?.journal.started);
        }
    }
}
test "owner thinking selections merge only after join and preserve cache ownership" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fixture-key");
    try session.connection().selectModel("opencode-go/gpt-6-luna");
    var listing = try metadata.parseListing(a, "{\"data\":[{\"id\":\"gpt-6-luna\",\"protocol\":\"responses\",\"effort\":{\"supported_levels\":[\"low\",\"high\"]}}]}", .opencode_go);
    defer listing.deinit(a);
    publicReasoningFixture(&listing, "gpt-6-luna");
    session.metadata_cache.deinit(a);
    session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), listing);
    const app = session.app.?;
    const before = app.config.value.model;
    const borrowed = session.effortCandidate(app.config.value).model.reasoning.?.map.high.?;
    try session.beginOwnerTask();
    try std.testing.expectError(error.Busy, session.guardSelection());
    try Session.setEffort(&session, .high);
    try std.testing.expectEqualStrings("high", session.connection().current().reasoning_effort.name().?);
    try std.testing.expectEqual(before.reasoning_effort, app.config.value.model.reasoning_effort);
    try std.testing.expect(Session.sameDeclaration(before.reasoning, app.config.value.model.reasoning));
    const owned = app.thinking_control.get().?.reasoning.?.map.high.?;
    try std.testing.expect(borrowed.ptr != owned.ptr);
    session.metadata_cache.deinit(a);
    session.metadata_cache = .{};
    try std.testing.expectEqualStrings("high", owned);
    session.read_only = true;
    try std.testing.expectError(error.ResumeReadOnly, Session.setEffort(&session, .low));
    session.read_only = false;
    try std.testing.expectError(error.InvalidReasoningEffort, Session.setEffort(&session, .unknown));
    try Session.setEffort(&session, .low);
    _ = try Session.cycleEffort(&session);
    const last = try Session.cycleEffort(&session);
    try std.testing.expectEqual(before.reasoning_effort, app.config.value.model.reasoning_effort);
    // No worker was spawned in this fixture; finish models the completed join.
    session.finishOwnerTask();
    try std.testing.expectEqualStrings(last.name().?, app.config.value.model.reasoning_effort.?);
    try std.testing.expect(app.thinking_control.get() == null);
    try std.testing.expect(!session.owner_task_active);
}
test "initial default stops after journal start and never overwrites an accepted effort or map" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-default-journal");
    try session.connection().selectModel("opencode-go/gpt-6-luna");
    const app = session.app.?;
    try std.testing.expect(session.initial_default_pending);
    app.journal.started = true;
    try std.testing.expect(try session.completeInitialDefault(true));
    app.journal.started = false;
    try std.testing.expect(!session.initial_default_pending);
    var listing = try metadata.parseListing(a, "{\"data\":[{\"id\":\"gpt-6-luna\",\"protocol\":\"responses\",\"effort\":{\"supported_levels\":[\"low\",\"high\"]}}]}", .opencode_go);
    defer listing.deinit(a);
    publicReasoningFixture(&listing, "gpt-6-luna");
    session.metadata_cache.deinit(a);
    session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.opencode_go), listing);
    try std.testing.expect(!(try session.completeInitialDefault(true)));
    try std.testing.expect(app.config.value.model.reasoning == null);
    for ([_][]const u8{ "off", "high" }) |effort| {
        session.initial_default_pending = true;
        app.config.value.model.reasoning_effort = effort;
        _ = try session.completeInitialDefault(true);
        try std.testing.expectEqualStrings(effort, app.config.value.model.reasoning_effort.?);
        try std.testing.expect(app.config.value.model.reasoning == null);
    }
    app.config.value.model.reasoning_effort = null;
    app.config.value.model.reasoning = .{ .map = .{ .low = "accepted-low" } };
    session.initial_default_pending = true;
    _ = try session.completeInitialDefault(true);
    try std.testing.expectEqualStrings("accepted-low", app.config.value.model.reasoning.?.map.low.?);
    try std.testing.expect(app.config.value.model.reasoning_effort == null);
    // Stopping automatic initialization must not disable explicit cache adoption.
    app.config.value.model.reasoning = null;
    try std.testing.expectEqual(presentation.ReasoningEffort.low, try Session.cycleEffort(&session));
    try std.testing.expectEqualStrings("low", app.config.value.model.reasoning_effort.?);
}
test "effort action cannot borrow official reasoning for a proxy kind hint" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"proxy/deepseek-flash","providers":{"proxy":{"base_url":"https://proxy.invalid/v1","kind":"deepseek","api_key":"fake-proxy-effort","models":{"deepseek-flash":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false}}
    );
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{});
    defer session.deinit();
    var listing = try metadata.parseListing(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"effort\":{\"supported_levels\":[\"low\",\"high\",\"max\"]}}]}", .deepseek);
    defer listing.deinit(a);
    session.metadata_cache.deinit(a);
    session.metadata_cache = try metadata.commit(&session.store.root, metadata.bit(.deepseek), listing);
    try std.testing.expect(!(try session.completeInitialDefault(true)));
    try std.testing.expectError(error.ThinkingCapabilitiesUnknown, Session.cycleEffort(&session));
    try std.testing.expect(session.app.?.config.value.model.reasoning == null);
    try std.testing.expect(session.app.?.config.value.model.reasoning_effort == null);
    try std.testing.expectEqual(@as(u8, 0), session.connection().current().effort_levels.mask);
    try std.testing.expect(!session.app.?.journal.started);
}
test "timed automatic metadata refresh repeats while active capabilities stay frozen" {
    const Fixture = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn fetch(a: std.mem.Allocator, _: std.Io, _: ProviderId, _: ?[]const u8) !metadata.Listing {
            const call = calls.fetchAdd(1, .monotonic);
            return metadata.parseListing(a, if (call == 0)
                "{\"data\":[{\"id\":\"deepseek-flash\",\"protocol\":\"chat\",\"context_window\":131072}]}"
            else
                "{\"data\":[{\"id\":\"deepseek-flash\",\"protocol\":\"chat\",\"context_window\":262144}]}", .deepseek);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    Fixture.calls.store(0, .monotonic);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = Fixture.fetch;
    session.metadata_dev_fetch = MetadataFixture.dev;
    session.metadata_wall_ms = 1000000;
    session.metadata_awake_ms = 1000000;
    try session.connection().configureProvider(.deepseek, "fake-timed-refresh");
    const before = session.mutableConfig().*.model;
    const effort = session.connection().current().reasoning_effort;
    try std.testing.expect(Session.pollModels(&session, true)); // Login override.
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(u32, 131072), session.connection().current().models[0].context_tokens);
    session.metadata_wall_ms = 1000000 + session.refreshPolicy().ttl_ms - 1;
    session.metadata_awake_ms = 2000000;
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    session.metadata_wall_ms = session.metadata_wall_ms.? + 1;
    // Wall TTL alone cannot bypass the monotonic owner cadence.
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    session.metadata_awake_ms = 2060000;
    try std.testing.expect(!Session.pollModels(&session, false));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job != null);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 2), Fixture.calls.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 262144), session.connection().current().models[0].context_tokens);
    try std.testing.expectEqual(before.context_tokens, session.mutableConfig().*.model.context_tokens);
    try std.testing.expectEqual(before.output_tokens, session.mutableConfig().*.model.output_tokens);
    try std.testing.expectEqual(effort, session.connection().current().reasoning_effort);
    try std.testing.expect(!session.app.?.journal.started);
}
test "manual metadata refresh filters obsolete credentials even with automatic refresh disabled" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = false });
    defer session.deinit();
    session.metadata_fetch = MetadataFixture.fetch;
    session.metadata_dev_fetch = MetadataFixture.dev;
    MetadataFixture.calls.store(0, .monotonic);
    try session.connection().configureProvider(.deepseek, "fake-stale-first-key");
    var previous: metadata.Listing = .{ .directory_mask = metadata.bit(.deepseek) };
    defer previous.deinit(a);
    const previous_row = try previous.directory.upsert(a, .deepseek, "deepseek-flash");
    previous_row.available = true;
    previous_row.protocol = .chat;
    previous_row.tokens = 65536;
    previous_row.reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } });
    session.metadata_cache.deinit(a);
    session.metadata_cache = try metadata.commitAt(&session.store.root, metadata.bit(.deepseek), previous, 1000);
    session.metadata_wall_ms = 2000;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session); // Completed with the old key, not yet published.
    try session.connection().configureProvider(.deepseek, "fake-stale-new-key");
    try std.testing.expect(session.metadata_login_pending == 0); // No automatic re-query permission.
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&session.metadata_cache.directory, .deepseek, "deepseek-flash").tokens);
    try std.testing.expectEqualStrings("high", LayeredMetadataFixture.row(&session.metadata_cache.directory, .deepseek, "deepseek-flash").reasoning.?.declaration().map.high.?);
    var stale_disk = try metadata.load(&session.store.root);
    defer stale_disk.deinit(session.store.root.allocator);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&stale_disk.directory, .deepseek, "deepseek-flash").tokens);
    try std.testing.expectEqual(@as(?u64, 1000), session.metadata_cache.refresh[0].last_success_ms);
    try std.testing.expect(!session.metadata_cache.refresh[0].successful);
    try std.testing.expectEqual(@as(?u64, 2000), session.metadata_cache.refresh[ProviderId.all.len].last_success_ms);
    try std.testing.expect(session.metadata_cache.refresh[ProviderId.all.len].successful);
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 1), MetadataFixture.calls.load(.monotonic));
    // A new explicit refresh uses the replacement credential and can publish.
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(?u32, 1048576), LayeredMetadataFixture.row(&session.metadata_cache.directory, .deepseek, "deepseek-flash").tokens);
    try std.testing.expectEqual(@as(?u64, 2000), session.metadata_cache.refresh[0].last_success_ms);
    try std.testing.expect(session.metadata_cache.refresh[0].successful);
}
test "models.dev completion survives a stalled official source and owner teardown cancels both" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    session.metadata_fetch = MetadataFixture.stall;
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try session.connection().configureProvider(.opencode_go, "fake-stalled-official");
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try MetadataFixture.waitDone(session.io, &job.dev_done);
    try std.testing.expect(job.dev_future != null); // pollModels owns the actual join.
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
    try std.testing.expect(job.future != null);
    job.started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    try Session.refreshModels(&session);
    // deinit must cancel/join both futures and wipe the official key copies.
}
test "official results publish while models.dev retains an independent longer deadline" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    session.metadata_fetch = LayeredMetadataFixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    LayeredMetadataFixture.official_effort.store(false, .release);
    try session.connection().configureProvider(.opencode_go, "fake-deadline-go");
    var previous = try metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
    defer previous.deinit(a);
    session.metadata_cache.deinit(a);
    session.metadata_cache = try metadata.commit(&session.store.root, 0, previous);
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(job.future != null); // pollModels owns the actual join.
    job.started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == job and job.dev_future != null);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").tokens);
    for (job.keys) |key| try std.testing.expect(key == null);
    // Passing the old shared deadline does not cancel the public catalog.
    job.dev_started_ms -= official_metadata_timeout_ms + 1;
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(job.dev_future != null);
    job.dev_started_ms -= models_dev_timeout_ms;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    var saved = try metadata.load(&session.store.root);
    defer saved.deinit(session.store.root.allocator);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&saved.directory, .opencode_go, "claude-haiku-5-5").tokens);
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&saved.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
    try std.testing.expect(!Session.pollModels(&session, true)); // No tight automatic retry loop.
    // A user retry can still complete after the cancelled catalog attempt.
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
}
test "login with new credentials refreshes official metadata without waiting for stalled models.dev" {
    const Fixture = struct {
        fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            if (id != .opencode_go) return error.UnexpectedProvider;
            const rotated = std.mem.eql(u8, key orelse return error.MissingFixtureKey, "fake-rotated-go");
            return metadata.parseListing(a, if (rotated)
                "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"context_window\":131072}]}"
            else
                "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"context_window\":65536}]}", id);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = Fixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.devStall;
    try session.connection().configureProvider(.opencode_go, "fake-initial-go");
    try std.testing.expect(Session.pollModels(&session, true));
    const job = session.metadata_job.?;
    const public_started = job.dev_started_ms;
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(job.future == null and job.dev_future != null);
    try std.testing.expectEqual(@as(?u32, 65536), LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").tokens);
    try session.connection().configureProvider(.opencode_go, "fake-rotated-go");
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == job and job.future != null);
    try std.testing.expectEqual(public_started, job.dev_started_ms);
    try std.testing.expect(job.dev_future != null); // Existing public download not restarted.
    try MetadataFixture.waitDone(session.io, &job.done);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(?u32, 131072), LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").tokens);
    var rotated_disk = try metadata.load(&session.store.root);
    defer rotated_disk.deinit(session.store.root.allocator);
    try std.testing.expectEqual(@as(?u32, 131072), LayeredMetadataFixture.row(&rotated_disk.directory, .opencode_go, "claude-haiku-5-5").tokens);
    try std.testing.expect(job.dev_future != null and session.metadata_login_pending == 0);
    job.dev_started_ms -= models_dev_timeout_ms + 1;
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
}
test "login refreshes only saved provider despite prior attempt and queues behind old credentials" {
    const Fixture = struct {
        var calls: std.atomic.Value(usize) = .init(0);
        fn fetch(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            _ = calls.fetchAdd(1, .monotonic);
            if (id != .opencode_go) return error.UnexpectedProvider;
            const k = key orelse return error.MissingFixtureKey;
            if (std.mem.eql(u8, k, "fake-go-fail")) return error.FixtureOffline;
            const body = if (std.mem.eql(u8, k, "fake-go-haiku-only"))
                "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"context_window\":65536}]}"
            else if (std.mem.eql(u8, k, "fake-go-full"))
                "{\"data\":[{\"id\":\"minimax-m2.7\"},{\"id\":\"claude-haiku-5-5\"},{\"id\":\"kimi-k3\"}]}"
            else
                return error.UnexpectedFixtureKey;
            return metadata.parseListing(a, body, id);
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = Fixture.fetch;
    session.metadata_dev_fetch = MetadataFixture.dev;
    Fixture.calls.store(0, .monotonic);
    var claim = try metadata.claim(&session.store.root, metadata.bit(.opencode_go), false);
    defer claim.cache.deinit(a);
    try session.connection().configureProvider(.opencode_go, "fake-go-full");
    const original = session.connection().current().context_limit;
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(usize, 0), Fixture.calls.load(.monotonic));
    try std.testing.expect(!Session.pollModels(&session, false)); // Owner must be idle.
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(metadata.bit(.opencode_go) | metadata.dev_bit, session.metadata_job.?.requested);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 3), session.connection().current().models.len);
    try std.testing.expectEqual(original, session.connection().current().context_limit);
    try session.connection().configureProvider(.opencode_go, "fake-go-full");
    try std.testing.expect(Session.pollModels(&session, true));
    // A second save must not cancel/join in the key callback, or accept the old
    // worker's list as the result of this new login. Queue the newest key instead.
    try session.connection().configureProvider(.opencode_go, "fake-go-haiku-only");
    try std.testing.expectEqual(metadata.bit(.opencode_go), session.metadata_login_pending);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 3), session.connection().current().models.len);
    try std.testing.expect(Session.pollModels(&session, true));
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    const updated = session.connection().current();
    try std.testing.expectEqual(@as(usize, 1), updated.models.len);
    try std.testing.expectEqualStrings("opencode-go/claude-haiku-5-5", updated.models[0].name);
    try std.testing.expectEqual(@as(u32, 65536), updated.models[0].context_tokens);
    try std.testing.expect(updated.model_context_official[0]);
    try std.testing.expectEqual(original, updated.context_limit);
    try std.testing.expectEqualStrings("minimax-m2.7", updated.model); // No forced model change.
    try session.connection().configureProvider(.opencode_go, "fake-go-fail");
    try std.testing.expect(Session.pollModels(&session, true));
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 1), session.connection().current().models.len);
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null and session.metadata_login_pending == 0);
    try std.testing.expectEqual(@as(usize, 4), Fixture.calls.load(.monotonic));
    try std.testing.expect(std.mem.find(u8, session.metadata_notice.?, "failed") != null);
}
test "manual refresh asynchronously discovers new IDs and preserves public protocols through picker selection and reload" {
    const Fixture = struct {
        var requested: std.atomic.Value(u8) = .init(0);
        var public_calls: std.atomic.Value(usize) = .init(0);
        fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
            if (key == null or !std.mem.eql(u8, key.?, "fake-async-directory-key")) return error.InvalidFixtureKey;
            _ = requested.fetchOr(metadata.bit(id), .monotonic);
            return metadata.parseListing(a,
                \\{"data":[{"id":"future-official-id","context_window":131072},{"id":"future-unknown","context_window":65536}]}
            , id);
        }
        fn public(a: std.mem.Allocator, _: std.Io) !metadata.Listing {
            _ = public_calls.fetchAdd(1, .monotonic);
            return metadata.parseDev(a,
                \\{"deepseek":{"npm":"@ai-sdk/deepseek","models":{"future-official-id":{}}},"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"future-official-id":{"provider":{"npm":"@ai-sdk/openai"}}}},"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"future-official-id":{"provider":{"npm":"@ai-sdk/openai"}}}}}
            );
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    session.metadata_fetch = Fixture.official;
    session.metadata_dev_fetch = Fixture.public;
    for (legacyMetadataTestProviders) |id| try session.connection().configureProvider(id, "fake-async-directory-key");
    Fixture.requested.store(0, .monotonic);
    Fixture.public_calls.store(0, .monotonic);
    const before = session.mutableConfig().model;
    try Session.refreshModels(&session);
    const job = session.metadata_job.?;
    try std.testing.expectEqual(legacyMetadataTestMask | metadata.dev_bit, job.requested);
    try MetadataFixture.waitDone(session.io, &job.done);
    try MetadataFixture.waitDone(session.io, &job.dev_done);
    // Worker results remain private until owner join and revision filtering.
    try std.testing.expectEqual(@as(usize, 0), session.metadata_cache.directory.count);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(legacyMetadataTestMask, Fixture.requested.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), Fixture.public_calls.load(.monotonic));
    const state = session.connection().current();
    try std.testing.expectEqual(before.protocol, session.mutableConfig().model.protocol);
    try std.testing.expectEqual(before.context_tokens, state.context_limit);
    try std.testing.expectEqualStrings(before.name, state.model);
    var picker = @import("../ui/model_picker.zig").Picker.init(a);
    defer picker.deinit();
    picker.allow_custom = false;
    var reloaded = try metadata.load(&session.store.root);
    defer reloaded.deinit(session.store.root.allocator);
    for (legacyMetadataTestProviders) |id| {
        const selector = try std.fmt.allocPrint(a, "{s}/future-official-id", .{id.slug()});
        defer a.free(selector);
        picker.clear();
        try std.testing.expect(try picker.insert(selector, false));
        const latest = session.connection().current();
        const choices = try picker.choicesWithProviders(a, latest.selection_name orelse latest.model, latest.context_limit, latest.models, latest.model_disabled, latest.model_providers);
        defer a.free(choices);
        try std.testing.expectEqual(@as(usize, 1), choices.len);
        try std.testing.expect(!choices[0].disabled);
        const entry = metadata.findEntry(&reloaded, selector).?;
        try std.testing.expectEqual(if (id == .deepseek) @import("../core/protocol.zig").Protocol.chat else .responses, entry.model.protocol);
        // The picker yields exactly the owner's dynamic qualified selector.
        try session.connection().selectModel(choices[0].name);
        try std.testing.expectEqual(entry.model.protocol, session.mutableConfig().model.protocol);
        try std.testing.expectEqual(@as(u32, 131072), session.mutableConfig().model.context_tokens);
    }
    try std.testing.expectError(error.UnknownModelProtocol, session.connection().selectModel("opencode-go/future-unknown"));
}
test "dynamic models.dev refresh reaches model picker, cached reload and selection preference without POST" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    LayeredMetadataFixture.official_effort.store(false, .release);
    LayeredMetadataFixture.dev_calls.store(0, .monotonic);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = LayeredMetadataFixture.official;
    session.metadata_dev_fetch = LayeredMetadataFixture.dev;
    try session.connection().configureProvider(.opencode_go, "fake-layered-go");
    try setGlobalEffortForTest(&session, .max);
    const active_before = session.app.?.config.value.model;
    try std.testing.expect(Session.pollModels(&session, true)); // First/login-triggered refresh.
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(usize, 1), LayeredMetadataFixture.dev_calls.load(.monotonic));
    try std.testing.expectEqualStrings(active_before.name, session.app.?.config.value.model.name);
    try std.testing.expectEqual(active_before.context_tokens, session.app.?.config.value.model.context_tokens);
    try std.testing.expectEqual(active_before.output_tokens, session.app.?.config.value.model.output_tokens);
    for (session.connection().current().models) |model| {
        if (std.mem.eql(u8, model.name, "opencode-go/claude-haiku-5-5")) {
            try std.testing.expectEqual(thinking.Format.anthropic, model.reasoning.?.format);
            try std.testing.expectEqualStrings("max", model.reasoning.?.map.max.?);
            try std.testing.expect(model.reasoning.?.map.medium == null);
            try std.testing.expectEqual(@as(?u32, 16384), model.output_tokens);
            try std.testing.expectEqual(cfg.ReasoningSource.metadata, model.output_source);
            break;
        }
    } else return error.MissingModelPickerRow;
    var disk = try metadata.load(&session.store.root);
    defer disk.deinit(session.store.root.allocator);
    try std.testing.expectEqualStrings("disabled", LayeredMetadataFixture.row(&disk.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.off.?);
    {
        var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{ .auto_refresh_models = true });
        defer again.deinit();
        again.metadata_fetch = MetadataFixture.fail;
        again.metadata_dev_fetch = LayeredMetadataFixture.devFail;
        try std.testing.expect(!Session.pollModels(&again, true));
        try std.testing.expect(again.metadata_job == null); // Persisted attempt suppresses a restart fetch.
        again.preferred_effort = .max;
        // Check cached application without rewriting the shared config behind the
        // still-live first Session (whose auth-store digest protects such writes).
        var candidate_arena = std.heap.ArenaAllocator.init(a);
        defer candidate_arena.deinit();
        var candidate = again.global_config.?.value;
        model_resolver.apply(&candidate, try model_resolver.resolve(candidate_arena.allocator(), candidate, &again.metadata_cache, "opencode-go", "claude-haiku-5-5", false));
        try std.testing.expect(again.applyPreference(&candidate, again.preferred_effort, true) == null);
        try std.testing.expectEqualStrings("max", candidate.model.reasoning_effort.?);
        try std.testing.expectEqualStrings("disabled", candidate.model.reasoning.?.map.off.?);
    }
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("max", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expect(session.app.?.runtime.messages().len == 0);
    try std.testing.expectEqual(@as(?u32, 16384), session.app.?.config.value.model.output_tokens);
    // Manual refresh retries both sources; Go remains public-authoritative,
    // and refresh alone leaves active options frozen.
    LayeredMetadataFixture.official_effort.store(true, .release);
    try session.connection().refresh_models_fn.?(session.connection().context);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    try std.testing.expectEqual(@as(usize, 2), LayeredMetadataFixture.dev_calls.load(.monotonic));
    try std.testing.expectEqualStrings("max", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expect(LayeredMetadataFixture.row(&session.metadata_cache.directory, .opencode_go, "claude-haiku-5-5").reasoning.?.declaration().map.max == null);
    // Credential activation keeps actual options, including output capability.
    // A subsequent deliberate catalog confirmation may use the fresh metadata.
    const output_row = session.metadata_cache.directory.find(.opencode_go, "claude-haiku-5-5").?;
    session.metadata_cache.directory.rows[output_row].dev_output_tokens = 32768;
    const frozen_capacity = session.app.?.config.value.model.context_tokens;
    try session.connection().configureProvider(.opencode_go, "fake-layered-rotated-go");
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("max", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(frozen_capacity, session.app.?.config.value.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 16384), session.app.?.config.value.model.output_tokens);
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqualStrings("max", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(?u32, 32768), session.app.?.config.value.model.output_tokens);
    // Same protocol/map/capacity is not a no-op if a fresh output limit changed.
    session.metadata_cache.directory.rows[output_row].dev_output_tokens = 65536;
    try session.connection().selectModel("opencode-go/claude-haiku-5-5");
    try std.testing.expectEqual(@as(?u32, 65536), session.app.?.config.value.model.output_tokens);
    var persisted_defaults = try session.store.loadExisting();
    defer cfg.release(&persisted_defaults);
    try std.testing.expect(persisted_defaults.value.model.output_tokens == null);
    try std.testing.expectEqual(presentation.ReasoningEffort.max, session.preferred_effort.?);
    session.metadata_dev_fetch = LayeredMetadataFixture.devFail;
    try Session.refreshModels(&session);
    MetadataFixture.finish(&session);
    try std.testing.expect(Session.pollModels(&session, true));
    var failed_refresh_disk = try metadata.load(&session.store.root);
    defer failed_refresh_disk.deinit(session.store.root.allocator);
    try std.testing.expectEqualStrings("max", LayeredMetadataFixture.row(&failed_refresh_disk.directory, .opencode_go, "claude-haiku-5-5").dev_reasoning.?.declaration().map.max.?);
    try std.testing.expect(std.mem.find(u8, session.metadata_notice.?, "models.dev metadata refresh failed") != null);
}
test "dynamic official IDs select for all providers and reject unknown protocols without probing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    for (legacyMetadataTestProviders) |id| try session.connection().configureProvider(id, "fake-dynamic-key");
    session.metadata_cache.directory_mask = legacyMetadataTestMask;
    for (legacyMetadataTestProviders) |id| {
        const row = try session.metadata_cache.directory.upsert(a, id, "new/vendor-model");
        row.available = true;
        row.tokens = 131072;
        row.protocol = if (id == .deepseek) .chat else .responses;
        const unknown = try session.metadata_cache.directory.upsert(a, id, "new-unknown");
        unknown.available = true;
    }
    const models = try session.buildModels(session.global_config.?.value);
    session.freeDisplayModels(session.display_models);
    session.display_models = models;
    var state = session.connection().current();
    try std.testing.expectEqual(@as(usize, 6), state.models.len);
    for (state.models, 0..) |model, index| {
        try std.testing.expectEqual(model.protocol == .auto, state.model_disabled[index]);
    }
    for (legacyMetadataTestProviders) |id| {
        const selector = try std.fmt.allocPrint(a, "{s}/new/vendor-model", .{id.slug()});
        defer a.free(selector);
        try session.connection().selectModel(selector);
        try std.testing.expectEqual(id, session.mutableConfig().provider.kind.?);
        try std.testing.expectEqualStrings("new/vendor-model", session.mutableConfig().model.name);
        try std.testing.expectEqual(@as(u32, 131072), session.mutableConfig().model.context_tokens);
        try std.testing.expect(session.active_context_official);
        try session.connection().selectModel("new/vendor-model");
        // Missing presets may be restored from history, but are not new choices.
        for (catalog.entries) |entry| if (entry.provider == id) {
            try std.testing.expectError(error.DefaultModelUnavailable, session.connection().selectModel(entry.selector));
            break;
        };
    }
    const before = session.mutableConfig().model;
    try std.testing.expectError(error.UnknownModelProtocol, session.connection().selectModel("opencode-go/new-unknown"));
    // Raw lookup uses the current provider, not a global raw-ID guess.
    const current_id = session.mutableConfig().provider.kind.?;
    if (current_id != .deepseek) try std.testing.expectError(error.UnknownModelProtocol, session.connection().selectModel("new-unknown"));
    try std.testing.expectEqualStrings(before.name, session.mutableConfig().model.name);
    const current_row = &session.metadata_cache.directory.rows[session.metadata_cache.directory.find(current_id, before.name).?];
    current_row.tokens = 65536;
    current_row.protocol = .chat;
    // Reading a refreshed catalog alone never mutates the active connection.
    state = session.connection().current();
    try std.testing.expectEqual(before.protocol, session.mutableConfig().model.protocol);
    try std.testing.expectEqual(before.context_tokens, state.context_limit);
    try session.connection().configureProvider(current_id, "fake-rotated-dynamic-key");
    try session.connection().selectModel(session.selected_alias.?);
    try std.testing.expectEqual(before.protocol, session.mutableConfig().model.protocol);
    try std.testing.expectEqual(before.context_tokens, session.mutableConfig().model.context_tokens);
    state = session.connection().current();
    try std.testing.expectEqual(before.context_tokens, state.context_limit);
}
test "per-agent status rows are supported before app creation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.init(a, std.testing.io, &env, home, .{});
    defer session.deinit();
    try std.testing.expect(session.app == null);
    const state = session.connection().current();
    try std.testing.expect(state.subagents_supported);
    try std.testing.expectEqual(@as(usize, 0), state.subagents.agents.len);
    try std.testing.expectEqual(@as(usize, 0), session.last_subagent_view.agents.len);
    try std.testing.expect(!Session.pollModels(&session, false));
    try std.testing.expect(!Session.pollModels(&session, true));
}
test "login refresh opt out remains offline and explicit profiles survive availability filtering" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.init(a, std.testing.io, &env, home, .{});
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-go-offline");
    try std.testing.expect(!Session.pollModels(&session, true));
    try std.testing.expect(session.metadata_job == null and session.metadata_login_pending == 0);
    for (session.metadata_cache.directory.rows[0..session.metadata_cache.directory.count]) |*row| {
        if (row.provider == .opencode_go) row.available = false;
    }
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    var explicit = try cfg.parse(a,
        \\{"llm":{"default":"opencode-go/kimi-k3","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"kimi-k3":{"context_tokens":65536,"protocol":"chat"}}}}},"limits":{"low_price_input":false}}
    );
    defer cfg.release(&explicit);
    // An explicit registry patch remains selectable after the official source
    // marks every preset unavailable; opting out must still launch no fetch.
    const models = try session.buildModels(explicit.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("opencode-go/kimi-k3", models[0].name);
    try std.testing.expectEqual(@as(u32, 65536), models[0].context_tokens);
}
test "display candidates own names and explicit wires across cache and config replacement" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-owned-display-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    const row = try session.metadata_cache.directory.upsert(a, .opencode_go, "owned-cache-name");
    row.available = true;
    row.protocol = .chat;
    var profile_name = "owned-profile".*;
    var effort = "high".*;
    var wire = "custom-wire".*;
    var global = session.global_config.?.value;
    // Deliberately stack-backed registry declaration: buildModels must own its
    // published names and wire strings, just as for a released config arena.
    global.registry = .{ .default = "opencode-go/owned-profile", .providers = &.{.{
        .name = "opencode-go",
        .connection = catalog.connection(.opencode_go),
        .models = &.{.{ .name = &profile_name, .patch = .{
            .context_tokens = 32768,
            .protocol = .chat,
            .reasoning_effort = &effort,
            .reasoning = .{ .map = .{ .high = &wire } },
        } }},
    }} };
    const models = try session.buildModels(global);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    // A movable Session/cache and a released config arena are equivalent to
    // replacing these backing bytes. Published rows must own separate storage.
    @memset(session.metadata_cache.directory.names, 'X');
    profile_name[0] = 'X';
    effort[0] = 'X';
    wire[0] = 'X';
    try std.testing.expectEqualStrings("opencode-go/owned-cache-name", models[1].name);
    try std.testing.expectEqualStrings("opencode-go/owned-profile", models[0].name);
    try std.testing.expectEqualStrings("high", models[0].reasoning_effort.?);
    try std.testing.expectEqualStrings("custom-wire", models[0].reasoning.?.map.high.?);
}
test "raw explicit profile hides only the same provider dynamic identity" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-go-profile-key");
    try session.connection().configureProvider(.opencode_zen, "fake-zen-profile-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go) | metadata.bit(.opencode_zen);
    for ([_]ProviderId{ .opencode_go, .opencode_zen }) |id| {
        const row = try session.metadata_cache.directory.upsert(a, id, "shared-profile");
        row.available = true;
        row.protocol = .chat;
    }
    var explicit = try cfg.parse(a,
        \\{"llm":{"default":"opencode-go/shared-profile","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"shared-profile":{"context_tokens":32768,"protocol":"chat"}}},"opencode-zen":{"base_url":"https://opencode.ai/zen/v1","kind":"opencode_zen"}}},"limits":{"low_price_input":false}}
    );
    defer cfg.release(&explicit);
    const models = try session.buildModels(explicit.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("opencode-go/shared-profile", models[0].name);
    try std.testing.expectEqualStrings("opencode-zen/shared-profile", models[1].name);
}
test "explicit user reasoning overrides metadata and survives default persistence" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer source.deinit();
    // A manual registry patch is explicit; value/name similarity to metadata must not erase it.
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"opencode-go/gpt-6-luna","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"gpt-6-luna":{"protocol":"responses","context_tokens":32768,"reasoning_effort":"high","reasoning":{"map":{"high":"user-intensive"}}}}}}},"limits":{"low_price_input":false}}
    );
    defer cfg.release(&parsed);
    try model_resolver.applyDefault(parsed.arena.allocator(), &parsed.value, &source.metadata_cache);
    var config = parsed.value;
    source.metadata_cache.directory_mask |= metadata.bit(.opencode_go);
    const row = try source.metadata_cache.directory.upsert(a, .opencode_go, "gpt-6-luna");
    row.available = true;
    row.protocol = .responses;
    row.dev_present = true;
    row.dev_protocol = .responses;
    row.reasoning = try @import("model_directory.zig").Profile.from(.{ .map = .{ .low = "low" } });
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .map = .{ .max = "max" } });
    source.applyReasoningMetadata(&config);
    try std.testing.expectEqual(cfg.ReasoningSource.explicit, config.model.reasoning_source);
    try std.testing.expectEqualStrings("user-intensive", source.capabilitiesFor(config).wire("high").effort.?);
    const persisted = config.model.persisted();
    try std.testing.expectEqualStrings("user-intensive", persisted.reasoning.?.map.high.?);
    try std.testing.expectEqualStrings("high", persisted.reasoning_effort.?);
    var clone = try cfg.clone(a, config);
    defer cfg.release(&clone);
    try std.testing.expectEqualStrings("user-intensive", clone.value.model.reasoning.?.map.high.?);
}
test "derived reasoning stays frozen and foreign profiles cannot revive it after refresh or restart" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer source.deinit();
    try source.connection().configureProvider(.opencode_go, "fake-provenance-go");
    var listing = try metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
    defer listing.deinit(a);
    source.metadata_cache.deinit(a);
    source.metadata_cache = try metadata.commit(&source.store.root, 0, listing);
    try source.connection().selectModel("opencode-go/gpt-6-luna");
    try source.connection().setEffort(.max);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, source.app.?.config.value.model.reasoning_source);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    // A rejected preference write must not clear the active derived effort/map.
    const preference = try tmp.dir.readFileAlloc(std.testing.io, ".thin/config.json", a, .limited(65536));
    defer a.free(preference);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = "{}" });
    if (source.connection().setEffort(.low)) |_| return error.ExpectedPreferenceFailure else |_| {}
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = preference });
    {
        var disk = try source.store.loadExisting();
        defer cfg.release(&disk);
        try std.testing.expectEqualStrings("opencode-go/gpt-6-luna", disk.value.registry.?.default);
        // The derived profile must not be materialized as a manual disk patch.
        try std.testing.expect(disk.value.registry.?.find("opencode-go").?.patchFor("gpt-6-luna") == null);
        try std.testing.expect(disk.value.model.reasoning == null and disk.value.model.reasoning_effort == null);
    }
    const foreign_only =
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"gpt-6-luna":{"reasoning":true,"provider":{"npm":"@ai-sdk/openai"}}}},"one":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"reasoning_options":[{"type":"effort","values":["high"]}]}}},"two":{"npm":"@ai-sdk/openai","models":{"gpt-6-luna":{"reasoning_options":[{"type":"effort","values":["high"]}]}}}}
    ;
    var foreign_listing = try metadata.parseDev(a, foreign_only);
    defer foreign_listing.deinit(a);
    source.metadata_cache.deinit(a);
    source.metadata_cache = try metadata.commit(&source.store.root, 0, foreign_listing);
    const public_row = LayeredMetadataFixture.row(&source.metadata_cache.directory, .opencode_go, "gpt-6-luna");
    try std.testing.expect(public_row.dev_present and public_row.dev_reasoning == null);
    {
        var candidate_arena = std.heap.ArenaAllocator.init(a);
        defer candidate_arena.deinit();
        var candidate = source.global_config.?.value;
        model_resolver.apply(&candidate, try model_resolver.resolve(candidate_arena.allocator(), candidate, &source.metadata_cache, "opencode-go", "gpt-6-luna", false));
        try std.testing.expect(!source.capabilitiesFor(candidate).known);
    }
    // Until an explicit selection, the active runtime retains its frozen map.
    try std.testing.expect(source.capabilitiesFor(source.app.?.config.value).known);
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning.?.map.max.?);
    try source.connection().selectModel("opencode-go/gpt-6-luna");
    const model = source.app.?.config.value.model;
    try std.testing.expect(model.reasoning == null and model.reasoning_effort == null);
    try std.testing.expectEqual(presentation.ReasoningEffort.max, source.preferred_effort.?);
    for ([_]@import("../core/protocol.zig").Purpose{ .normal, .summary }) |purpose| {
        var base = @import("../tests/adapter_test_support.zig").request(.responses);
        base.purpose = purpose;
        const request = @import("../core/runtime.zig").withReasoning(source.app.?.config.value, base);
        try std.testing.expect(request.reasoning_effort == null and request.thinking == null);
    }
    {
        var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
        defer again.deinit();
        try std.testing.expect(!again.capabilitiesFor(again.mutableConfig().*).known);
        try std.testing.expect(again.mutableConfig().model.reasoning == null);
        try std.testing.expect(again.mutableConfig().model.reasoning_effort == null);
        try std.testing.expectEqual(presentation.ReasoningEffort.max, again.preferred_effort.?);
    }
    // Former preset maps (including Luna/Zen) also stay unknown with no source.
    source.metadata_cache.deinit(a);
    source.metadata_cache = .{};
    for (catalog.entries) |entry| {
        const config: cfg.Config = .{ .provider = catalog.connection(entry.provider), .model = entry.model };
        try std.testing.expect(!source.capabilitiesFor(config).known);
        try std.testing.expect(source.declarationForEntry(entry) == null);
    }
}
test "provider reasoning source Go ignores legacy official effort" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var session = try Session.init(a, std.testing.io, &env, home, .{});
    defer session.deinit();

    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    const config: cfg.Config = .{ .provider = catalog.connection(.opencode_go), .model = entry.model };
    session.metadata_cache.directory_mask |= metadata.bit(.opencode_go);
    const row = try session.metadata_cache.directory.upsert(a, .opencode_go, "gpt-6-luna");
    row.available = true;
    row.protocol = .responses;
    row.reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .standard, .map = .{ .low = "low", .high = "high" } });
    try std.testing.expect(!session.capabilitiesFor(config).known);
    // Go uses public data even if a legacy official profile is present.
    row.dev_present = true;
    row.dev_protocol = .responses;
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .standard, .map = .{ .low = "low", .max = "max", .off = "none" } });
    const fallback = session.capabilitiesFor(config);
    try std.testing.expectEqualStrings("low", fallback.map.low.?);
    try std.testing.expectEqualStrings("max", fallback.map.max.?);
    try std.testing.expectEqualStrings("none", fallback.map.off.?);
    row.dev_reasoning = null;
    try std.testing.expect(!session.capabilitiesFor(config).known); // Missing metadata stays unknown.
}
test "explicit raw and qualified profiles override dynamic rows including explicit auto" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"opencode-go/minimax-m2.7","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","models":{"raw-override":{"context_tokens":32768,"protocol":"auto"},"qualified-override":{"context_tokens":32768,"protocol":"chat"}}}}},"limits":{"low_price_input":false}}
    );
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-explicit-key");
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    for ([_][]const u8{ "raw-override", "qualified-override", "visible-unknown" }) |name| {
        const row = try session.metadata_cache.directory.upsert(a, .opencode_go, name);
        row.available = true;
    }
    const models = try session.buildModels(session.global_config.?.value);
    defer session.freeDisplayModels(models);
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("opencode-go/raw-override", models[0].name);
    try std.testing.expectEqualStrings("opencode-go/qualified-override", models[1].name);
    try std.testing.expectEqualStrings("opencode-go/visible-unknown", models[2].name);
    // Explicit auto is enabled by its own patch; the discovered unknown row is disabled.
    const old_models = session.display_models;
    session.display_models = models;
    const state = session.connection().current();
    const flags_match = std.mem.eql(bool, &.{ false, false, true }, state.model_disabled);
    session.display_models = old_models;
    try std.testing.expect(flags_match);
    try session.connection().selectModel("opencode-go/qualified-override");
    try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.chat, session.mutableConfig().model.protocol);
}
test "new raw custom model never inherits the previous model output capability" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeSessionTestConfig(tmp.dir,
        \\{"llm":{"default":"custom/previous","providers":{"custom":{"base_url":"https://custom.invalid/v1","models":{"previous":{"protocol":"chat","context_tokens":131072,"output_tokens":65536},"custom-next":{"protocol":"chat","context_tokens":131072},"custom-declared":{"protocol":"chat","context_tokens":131072,"output_tokens":4096}}}}},"limits":{"low_price_input":false}}
    );
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer session.deinit();
    try std.testing.expectEqual(@as(?u32, 65536), session.mutableConfig().model.output_tokens);
    try session.connection().selectModel("custom-next");
    try std.testing.expect(session.mutableConfig().model.output_tokens == null);
    try session.connection().selectModel("custom-declared");
    try std.testing.expectEqual(@as(?u32, 4096), session.mutableConfig().model.output_tokens);
    try std.testing.expectEqual(.explicit, session.mutableConfig().model.output_source);
}
test "pending auth retains trusted derived map while saving only cache backed defaults" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .deepseek);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer source.deinit();
    var listing: metadata.Listing = .{};
    defer listing.deinit(a);
    listing.directory_mask = metadata.bit(.deepseek);
    const row = try listing.directory.upsert(a, .deepseek, "deepseek-flash");
    row.available = true;
    row.protocol = .chat;
    row.reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .low = "low", .high = "high", .max = "max" } });
    source.metadata_cache.deinit(a);
    source.metadata_cache = try metadata.commit(&source.store.root, metadata.bit(.deepseek), listing);
    // Cache publication alone does not rewrite the pending resolved snapshot;
    // confirm the qualified candidate through the real new-selection path.
    try source.connection().selectModel("deepseek/deepseek-flash");
    try source.connection().setEffort(.max);
    try source.connection().configure("fake-derived-pending-auth");
    try std.testing.expectEqualStrings("max", source.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(cfg.ReasoningSource.metadata, source.app.?.config.value.model.reasoning_source);
    const request = @import("../core/runtime.zig").withReasoning(source.app.?.config.value, @import("../tests/adapter_test_support.zig").request(.chat));
    try std.testing.expectEqualStrings("max", request.reasoning_effort.?);
    try std.testing.expect(request.thinking.?);
    var disk = try source.store.loadExisting();
    defer cfg.release(&disk);
    try std.testing.expect(disk.value.model.reasoning == null and disk.value.model.reasoning_effort == null);
    var again = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("max", again.mutableConfig().model.reasoning_effort.?);
    try std.testing.expect(again.capabilitiesFor(again.mutableConfig().*).known);
}
test "derived metadata protocol or format mismatch clears stale mapping and effort" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try writeOfficialMetadataTestConfig(tmp.dir, .opencode_go);
    var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, .{});
    defer source.deinit();
    const entry = catalog.find("opencode-go/gpt-6-luna").?;
    const row = try source.metadata_cache.directory.upsert(a, .opencode_go, "gpt-6-luna");
    row.dev_present = true;
    row.dev_protocol = .responses;
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .map = .{ .high = "high" } });
    var config: cfg.Config = .{ .provider = catalog.connection(entry.provider), .model = entry.model };
    config.model.reasoning = .{ .map = .{ .max = "max" } };
    config.model.reasoning_effort = "max";
    config.model.reasoning_source = .metadata;
    config.model.protocol = .chat;
    source.applyReasoningMetadata(&config);
    try std.testing.expect(config.model.reasoning == null and config.model.reasoning_effort == null);
    try std.testing.expect(!source.capabilitiesFor(config).known);
    config.model.protocol = .responses;
    row.dev_reasoning = try @import("model_directory.zig").Profile.from(.{ .format = .anthropic, .map = .{ .high = "high" } });
    source.applyReasoningMetadata(&config);
    try std.testing.expect(!source.capabilitiesFor(config).known);
}
test "outdated cache recovers through automatic or explicit refresh only" {
    // A recognized older document is dropped only at claim time; the startup
    // cadence or an explicit refresh rebuilds the current format. Fake seams are
    // installed before any poll and the literal credential keeps construction
    // offline, so no real metadata endpoint is reachable.
    const legacy_cache =
        \\{"version":12,"attempted":3,"records":[{"selector":"deepseek/deepseek-flash","context_window":65536,"available":true}],"directory_mask":1,"models":[{"provider":"deepseek","id":"deepseek-flash","context_window":32768,"protocol":"chat","available":true}],"refresh":[{"generation":2,"last_attempt_ms":900,"last_success_ms":950,"successful":true},{},{},{}]}
    ;
    const config =
        \\{"llm":{"default":"deepseek/deepseek-flash","providers":{"deepseek":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key":"fake-outdated-cache","models":{"deepseek-flash":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
    ;
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ true, false }) |automatic| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [4096]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(io, &path)];
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        try writeSessionTestConfig(tmp.dir, config);
        try tmp.dir.writeFile(io, .{ .sub_path = ".thin/model-metadata.json", .data = legacy_cache });
        MetadataFixture.calls.store(0, .monotonic);
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = automatic });
        defer session.deinit();
        session.metadata_fetch = MetadataFixture.fetch;
        session.metadata_dev_fetch = MetadataFixture.dev;
        session.metadata_wall_ms = 1000000;
        session.metadata_awake_ms = 1000000;
        // Unreadable in memory, but not a poison state: cadence and manual
        // refresh both stay eligible.
        try std.testing.expect(!session.metadata_blocked);
        try std.testing.expectEqual(@as(usize, 0), session.metadata_cache.directory.count);
        if (automatic) {
            // Cadence success is reported by the launched job, not by this
            // return value: the branch may start refresh and still return false.
            _ = Session.pollModels(&session, true);
        } else {
            // Opting out of automatic refresh must leave the old bytes alone
            // and issue no request until the user asks for one.
            try std.testing.expect(!Session.pollModels(&session, true));
            try std.testing.expect(session.metadata_job == null);
            try std.testing.expectEqual(@as(usize, 0), MetadataFixture.calls.load(.monotonic));
            const untouched = try tmp.dir.readFileAlloc(io, ".thin/model-metadata.json", a, .limited(1 << 16));
            defer a.free(untouched);
            try std.testing.expectEqualStrings(legacy_cache, untouched);
            try Session.refreshModels(&session);
        }
        try std.testing.expect(session.metadata_job != null);
        MetadataFixture.finish(&session);
        try std.testing.expect(Session.pollModels(&session, true));
        try std.testing.expect(session.metadata_job == null);
        try std.testing.expectEqual(@as(usize, 1), MetadataFixture.calls.load(.monotonic));
        var disk = try metadata.load(&session.store.root);
        defer disk.deinit(session.store.root.allocator);
        const row = disk.directory.rows[disk.directory.find(.deepseek, "deepseek-flash").?];
        try std.testing.expectEqual(@as(?u32, 1048576), row.tokens);
        try std.testing.expectEqual(@as(?bool, true), row.available);
        const body = try tmp.dir.readFileAlloc(io, ".thin/model-metadata.json", a, .limited(1 << 16));
        defer a.free(body);
        const current_version = try std.fmt.allocPrint(a, "\"version\":{d}", .{metadata.cache_version});
        defer a.free(current_version);
        try std.testing.expect(std.mem.find(u8, body, current_version) != null);
        try std.testing.expect(std.mem.find(u8, body, "\"version\":12") == null);
    }
}
test "future or damaged cache blocks cadence until the file is moved away" {
    const config =
        \\{"llm":{"default":"deepseek/deepseek-flash","providers":{"deepseek":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key":"fake-poisoned-cache","models":{"deepseek-flash":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
    ;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const future = try std.fmt.allocPrint(a, "{{\"version\":{d},\"directory_mask\":1,\"models\":[]}}", .{metadata.cache_version + 1});
    defer a.free(future);
    const damaged = try std.fmt.allocPrint(a, "{{\"version\":{d},\"models\":\"damaged\"}}", .{metadata.cache_version});
    defer a.free(damaged);
    for ([_][]const u8{ future, damaged }) |poisoned| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [4096]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(io, &path)];
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        try writeSessionTestConfig(tmp.dir, config);
        try tmp.dir.writeFile(io, .{ .sub_path = ".thin/model-metadata.json", .data = poisoned });
        MetadataFixture.calls.store(0, .monotonic);
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = true });
        defer session.deinit();
        session.metadata_fetch = MetadataFixture.fetch;
        session.metadata_dev_fetch = MetadataFixture.dev;
        session.metadata_wall_ms = 1000000;
        session.metadata_awake_ms = 1000000;
        // Permissions follow the same path as any other load failure, so this
        // stays a strict refusal and never becomes an implicit rebuild.
        try std.testing.expect(session.metadata_blocked);
        try std.testing.expectEqual(@as(usize, 0), session.metadata_cache.directory.count);
        try std.testing.expect(!Session.pollModels(&session, true));
        try std.testing.expect(session.metadata_job == null);
        try std.testing.expectEqual(@as(usize, 0), MetadataFixture.calls.load(.monotonic));
        const untouched = try tmp.dir.readFileAlloc(io, ".thin/model-metadata.json", a, .limited(1 << 16));
        defer a.free(untouched);
        try std.testing.expectEqualStrings(poisoned, untouched);
        // Only removing the refused document lets an explicit claim succeed,
        // and that success clears the cadence block for this session.
        try tmp.dir.deleteFile(io, ".thin/model-metadata.json");
        try Session.refreshModels(&session);
        try std.testing.expect(!session.metadata_blocked);
        MetadataFixture.finish(&session);
        try std.testing.expect(Session.pollModels(&session, true));
        try std.testing.expect(session.metadata_job == null);
        try std.testing.expectEqual(@as(usize, 1), MetadataFixture.calls.load(.monotonic));
        var disk = try metadata.load(&session.store.root);
        defer disk.deinit(session.store.root.allocator);
        try std.testing.expect(disk.directory.find(.deepseek, "deepseek-flash") != null);
    }
}
test "proxy allowlist revalidates exact rows credentials and preserves unrelated settings" {
    const a = std.testing.allocator;
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, proxy_session_config);
    try fixture.env.put("PROXY_AUX_KEY", "fake-aux-key");
    var session = try fixture.open(.{});
    defer session.deinit();
    const app = session.app.?;
    const auth = app.client.authorization.ptr;
    const initial = session.connection().current();
    try std.testing.expect(initial.proxy_configured);
    try std.testing.expectEqual(@as(usize, 1), initial.proxy_models.len);
    try std.testing.expectEqualStrings("aux/review/raw/id", initial.proxy_models[0]);

    const saved = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(saved);
    // Duplicate add and absent delete are no-write no-ops.
    try proxyToggle(&session, "aux/review/raw/id", true);
    try proxyToggle(&session, "aux/absent", false);
    const after_noop = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(after_noop);
    try std.testing.expectEqualStrings(saved, after_noop);
    try std.testing.expectEqual(@as(usize, 1), session.connection().current().proxy_models.len);

    // Strict alias/raw-ID identity: exact alias, case-sensitive raw ID, full raw.
    try std.testing.expectError(error.UnknownProvider, proxyToggle(&session, "Main/chat", true));
    try std.testing.expectError(error.UnknownProxyModel, proxyToggle(&session, "main/CHAT", true));
    try std.testing.expectError(error.UnknownProxyModel, proxyToggle(&session, "aux/review/raw/id/extra", true));
    try std.testing.expectError(error.UnknownProxyModel, proxyToggle(&session, "aux/absent", true));
    try std.testing.expectError(error.InvalidDefault, proxyToggle(&session, "no-slash", true));

    // Declared SystemOne and unknown-window rows are real declarations, not
    // generic auxiliary candidates; logged-in literal keys are accepted.
    try proxyToggle(&session, "aux/native/raw", true);
    try proxyToggle(&session, "aux/unknown/raw", true);
    try proxyToggle(&session, "main/chat", true);
    try std.testing.expectError(error.ApiKeyNotFound, proxyToggle(&session, "unlogged/m", true));

    try proxyToggle(&session, "aux/native/raw", false);
    try fixture.env.put("PROXY_AUX_KEY", "");
    try std.testing.expectError(error.ApiKeyNotFound, proxyToggle(&session, "aux/native/raw", true));
    // An already selected duplicate remains a no-write no-op even after its
    // credential disappears; only a real insertion revalidates the key.
    try proxyToggle(&session, "aux/review/raw/id", true);
    try fixture.env.put("PROXY_AUX_KEY", "fake-aux-key");

    const state = session.connection().current();
    try std.testing.expectEqual(@as(usize, 3), state.proxy_models.len);
    try std.testing.expectEqualStrings("aux/review/raw/id", state.proxy_models[0]);
    try std.testing.expectEqualStrings("aux/unknown/raw", state.proxy_models[1]);
    try std.testing.expectEqualStrings("main/chat", state.proxy_models[2]);
    // The frozen primary route keeps its original allowlist for this session.
    try std.testing.expectEqual(@as(usize, 1), app.config.value.proxy.?.models.len);
    try std.testing.expectEqualStrings("aux/review/raw/id", app.config.value.proxy.?.models[0]);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expect(app.client.config == &app.config.value);
    try std.testing.expectEqualStrings("chat", app.config.value.model.name);

    const persisted = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(persisted);
    var parsed = try cfg.parse(a, persisted);
    defer cfg.release(&parsed);
    try std.testing.expectEqualStrings("10.0.0.9", parsed.value.proxy.?.address);
    try std.testing.expectEqual(@as(u16, 3128), parsed.value.proxy.?.port);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.proxy.?.models.len);
    try std.testing.expectEqualStrings("aux/review/raw/id", parsed.value.proxy.?.models[0]);
    try std.testing.expectEqualStrings("aux/unknown/raw", parsed.value.proxy.?.models[1]);
    try std.testing.expectEqualStrings("main/chat", parsed.value.proxy.?.models[2]);
    try std.testing.expectEqualStrings("aux/native/raw", parsed.value.decision.?.model);
    try std.testing.expect(!parsed.value.limits.low_price_input);
    try std.testing.expectEqualStrings("fake-main-key", parsed.value.registry.?.find("main").?.connection.api_key.?);
}
test "proxy refresh switches helper routes while primary client and history stay frozen" {
    const a = std.testing.allocator;
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, proxy_helper_config);
    try fixture.env.put("PROXY_AUX_KEY", "fake-aux-key");
    try fixture.env.put("PROXY_IMG_KEY", "fake-img-key");
    var session = try fixture.open(.{});
    defer session.deinit();
    const app = session.app.?;
    const auth = app.client.authorization.ptr;
    const session_id = app.client.session_id;
    const messages = app.runtime.messages().len;
    const decision_before = app.decision_client.?;
    const image_before = app.image_client.?;
    const memory_before = app.memory_coordinator;
    try prepareNativeRouteForTest(decision_before);
    try std.testing.expect(decision_before.native.?.proxy_url == null);
    try std.testing.expect(image_before.transport.proxy_url == null);
    try std.testing.expectEqual(@as(u64, 0), decision_before.calls);
    // The memory coordinator owns an independent extractor route.
    try std.testing.expect(memory_before.extractor != null);
    try std.testing.expect(memory_before.extractor.?.transport != null);
    try std.testing.expect(memory_before.extractor.?.transport.?.proxy_http == null);

    try proxyToggle(&session, "aux/native/raw", true);
    const decision_after = app.decision_client.?;
    try std.testing.expect(decision_after != decision_before);
    try prepareNativeRouteForTest(decision_after);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", decision_after.native.?.proxy_url.?);
    try std.testing.expectEqual(@as(u64, 0), decision_after.calls);
    // Both auxiliary owners are replaced, even when only one route changed.
    try std.testing.expect(app.image_client.? != image_before);
    try std.testing.expect(app.image_client.?.transport.proxy_url == null);
    // The extractor keeps its own primary-model route.
    const memory_after = app.memory_coordinator;
    try std.testing.expect(memory_after != memory_before);
    try std.testing.expectEqual(@as(usize, 2), decision_after.source.value.proxy.?.models.len);
    try std.testing.expect(memory_after.extractor.?.transport.?.proxy_http == null);
    // The primary transport, auth, model, session and history never move.
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expectEqual(session_id, app.client.session_id);
    try std.testing.expect(app.client.config == &app.config.value);
    try std.testing.expectEqualStrings("chat", app.config.value.model.name);
    try std.testing.expectEqualStrings("main", app.config.value.selected_provider.?);
    try std.testing.expectEqual(@as(usize, 1), app.config.value.proxy.?.models.len);
    try std.testing.expectEqual(messages, app.runtime.messages().len);
    var helper_route = false;
    for (decision_after.source.value.proxy.?.models) |name| {
        if (std.mem.eql(u8, name, "aux/native/raw")) helper_route = true;
    }
    try std.testing.expect(helper_route);

    // Removing the membership returns the decision client to a direct route.
    try proxyToggle(&session, "aux/native/raw", false);
    const memory_direct = app.memory_coordinator;
    try std.testing.expect(memory_direct != memory_after);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expect(app.decision_client.?.native.?.proxy_url == null);
    try std.testing.expectEqual(@as(usize, 1), app.decision_client.?.source.value.proxy.?.models.len);
    try std.testing.expect(memory_direct.extractor.?.transport.?.proxy_http == null);
    try proxyToggle(&session, "aux/native/raw", true);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.decision_client.?.native.?.proxy_url.?);

    try proxyToggle(&session, "img/deepseek-flash", true);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.decision_client.?.native.?.proxy_url.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.image_client.?.transport.proxy_url.?);
    const current = session.connection().current();
    try std.testing.expectEqual(@as(usize, 3), current.proxy_models.len);

    // The extractor's coordinator config carries the latest allowlist too, so an
    // explicit primary membership proxies only that helper transport.
    try proxyToggle(&session, "main/chat", true);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.decision_client.?.native.?.proxy_url.?);
    try std.testing.expectEqual(@as(usize, 4), session.connection().current().proxy_models.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.memory_coordinator.extractor.?.transport.?.proxy_http.?.proxy_url.?);
    try std.testing.expect(app.client.proxy_http == null);

    // An ordinary preference save must not revoke the already installed helper
    // routes or republish a primary client. The rebuilt memory coordinator must
    // keep the latest list rather than reverting to the frozen proxy config.
    const decision_now = app.decision_client.?;
    const image_now = app.image_client.?;
    const memory_now = app.memory_coordinator;
    const connection = session.connection();
    try connection.preference_fn.?(connection.context, .compaction_enabled, 0);
    try std.testing.expect(app.decision_client.? == decision_now);
    try std.testing.expect(app.image_client.? == image_now);
    try std.testing.expect(app.memory_coordinator != memory_now);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.decision_client.?.native.?.proxy_url.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.image_client.?.transport.proxy_url.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.memory_coordinator.extractor.?.transport.?.proxy_http.?.proxy_url.?);
    try std.testing.expectEqual(@as(usize, 4), app.decision_client.?.source.value.proxy.?.models.len);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expect(app.client.config == &app.config.value);
    try std.testing.expect(app.client.proxy_http == null);
    try std.testing.expectEqual(@as(usize, 1), app.config.value.proxy.?.models.len);
    try std.testing.expectEqualStrings("chat", app.config.value.model.name);
    try std.testing.expect(!app.config.value.limits.compaction_enabled);

    const persisted = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(persisted);
    var parsed = try cfg.parse(a, persisted);
    defer cfg.release(&parsed);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.proxy.?.models.len);
    try std.testing.expectEqualStrings("img/deepseek-flash", parsed.value.proxy.?.models[2]);
    try std.testing.expectEqualStrings("main/chat", parsed.value.proxy.?.models[3]);
}
test "proxy membership CAS conflict rolls back declaration and helper ownership" {
    const a = std.testing.allocator;
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, proxy_session_config);
    try fixture.env.put("PROXY_AUX_KEY", "fake-aux-key");
    var session = try fixture.open(.{});
    defer session.deinit();
    const app = session.app.?;
    try proxyToggle(&session, "aux/native/raw", true);
    const saved = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(saved);
    const decision = app.decision_client.?;
    try prepareNativeRouteForTest(decision);
    try std.testing.expectEqualStrings("http://10.0.0.9:3128", decision.native.?.proxy_url.?);
    const auth = app.client.authorization.ptr;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = "{}" });
    try std.testing.expectError(error.AuthVersionConflict, proxyToggle(&session, "main/chat", true));
    try std.testing.expectEqual(@as(usize, 2), session.global_config.?.value.proxy.?.models.len);
    try std.testing.expect(app.decision_client.? == decision);
    try std.testing.expectEqualStrings("http://10.0.0.9:3128", decision.native.?.proxy_url.?);
    try std.testing.expectEqual(@as(u64, 0), decision.calls);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expect(app.client.config == &app.config.value);
    try std.testing.expectEqual(@as(usize, 1), app.config.value.proxy.?.models.len);
    const failed = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(failed);
    try std.testing.expectEqualStrings("{}", failed);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = saved });
    try proxyToggle(&session, "main/chat", true);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://10.0.0.9:3128", app.decision_client.?.native.?.proxy_url.?);
    try std.testing.expectEqual(@as(usize, 3), session.global_config.?.value.proxy.?.models.len);
}
test "pending snapshot adopts an explicit proxy save without activating a route" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, proxy_pending_config);
    try fixture.env.put("PROXY_AUX_KEY", "fake-aux-key");
    var session = try fixture.open(.{});
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try proxyToggle(&session, "aux/other/raw", false);
    try std.testing.expect(session.app == null);
    try std.testing.expectEqual(@as(usize, 1), session.pending.?.value.proxy.?.models.len);
    try proxyToggle(&session, "aux/other/raw", true);
    try std.testing.expect(session.app == null);
    try std.testing.expectEqual(@as(usize, 2), session.pending.?.value.proxy.?.models.len);
    try std.testing.expectEqualStrings("aux/native/raw", session.pending.?.value.proxy.?.models[0]);
    try std.testing.expectEqualStrings("aux/other/raw", session.pending.?.value.proxy.?.models[1]);
    // Validation still rejects an undeclared raw ID before any write.
    try std.testing.expectError(error.UnknownProxyModel, proxyToggle(&session, "aux/undecided", true));
    try std.testing.expectEqual(@as(usize, 2), session.pending.?.value.proxy.?.models.len);
}
test "proxy endpoint save keeps members and moves only independent helpers" {
    const a = std.testing.allocator;
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, proxy_helper_config);
    try fixture.env.put("PROXY_AUX_KEY", "fake-aux-key");
    try fixture.env.put("PROXY_IMG_KEY", "fake-img-key");
    var session = try fixture.open(.{});
    defer session.deinit();
    const app = session.app.?;
    const auth = app.client.authorization.ptr;
    const session_id = app.client.session_id;
    const messages = app.runtime.messages().len;
    const decision_before = app.decision_client.?;
    const image_before = app.image_client.?;
    try prepareNativeRouteForTest(decision_before);
    try std.testing.expect(decision_before.native.?.proxy_url == null);
    try std.testing.expect(image_before.transport.proxy_url == null);

    // Install exact memberships so every independent helper uses the route.
    try proxyToggle(&session, "aux/native/raw", true);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.decision_client.?.native.?.proxy_url.?);
    try proxyToggle(&session, "img/deepseek-flash", true);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.decision_client.?.native.?.proxy_url.?);
    try proxyToggle(&session, "main/chat", true);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.decision_client.?.native.?.proxy_url.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.image_client.?.transport.proxy_url.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", app.memory_coordinator.extractor.?.transport.?.proxy_http.?.proxy_url.?);

    const saved = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(saved);
    // Surrounding whitespace and an identical host/port are no-write no-ops.
    const before_noop = app.decision_client.?;
    try setProxyEndpoint(&session, "  127.0.0.1:18080\n");
    try std.testing.expect(app.decision_client.? == before_noop);
    try std.testing.expectEqualStrings("http://127.0.0.1:18080", before_noop.native.?.proxy_url.?);
    const after_noop = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(after_noop);
    try std.testing.expectEqualStrings(saved, after_noop);
    var parsed_before = try cfg.parse(a, after_noop);
    defer cfg.release(&parsed_before);

    try setProxyEndpoint(&session, "[2001:db8::5]:8443");
    var state = session.connection().current();
    try std.testing.expect(state.proxy_configured);
    try std.testing.expectEqualStrings("2001:db8::5", state.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 8443), state.proxy_port);
    try std.testing.expectEqual(@as(usize, 4), state.proxy_models.len);
    // Auxiliary owners follow the new endpoint with the same exact members.
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expectEqualStrings("http://[2001:db8::5]:8443", app.decision_client.?.native.?.proxy_url.?);
    try std.testing.expectEqualStrings("http://[2001:db8::5]:8443", app.image_client.?.transport.proxy_url.?);
    try std.testing.expectEqualStrings("http://[2001:db8::5]:8443", app.memory_coordinator.extractor.?.transport.?.proxy_http.?.proxy_url.?);
    try std.testing.expectEqual(@as(usize, 4), app.decision_client.?.source.value.proxy.?.models.len);

    // The primary client, auth, identity and history never move; its frozen
    // declaration keeps the original endpoint and allowlist.
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expectEqual(session_id, app.client.session_id);
    try std.testing.expect(app.client.config == &app.config.value);
    try std.testing.expectEqualStrings("chat", app.config.value.model.name);
    try std.testing.expectEqual(messages, app.runtime.messages().len);
    try std.testing.expect(app.client.proxy_http == null);
    try std.testing.expectEqualStrings("127.0.0.1", app.config.value.proxy.?.address);
    try std.testing.expectEqual(@as(usize, 1), app.config.value.proxy.?.models.len);

    // An ordinary preference save must not revert helper routes to the frozen
    // primary endpoint, and must keep unrelated settings intact.
    const decision_now = app.decision_client.?;
    const image_now = app.image_client.?;
    const connection = session.connection();
    try connection.preference_fn.?(connection.context, .compaction_enabled, 0);
    try std.testing.expect(app.decision_client.? == decision_now);
    try std.testing.expect(app.image_client.? == image_now);
    try std.testing.expectEqualStrings("http://[2001:db8::5]:8443", app.decision_client.?.native.?.proxy_url.?);
    try std.testing.expect(!app.config.value.limits.compaction_enabled);
    try std.testing.expect(app.client.authorization.ptr == auth);

    // CAS conflict rolls the declaration, disk and helper ownership back.
    const persisted = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(persisted);
    const decision_before_conflict = app.decision_client.?;
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = "{}" });
    try std.testing.expectError(error.AuthVersionConflict, setProxyEndpoint(&session, "192.0.2.5:8888"));
    try std.testing.expectEqualStrings("2001:db8::5", session.global_config.?.value.proxy.?.address);
    try std.testing.expect(app.decision_client.? == decision_before_conflict);
    try std.testing.expectEqualStrings("http://[2001:db8::5]:8443", decision_before_conflict.native.?.proxy_url.?);
    try std.testing.expectEqual(@as(u64, 0), decision_before_conflict.calls);
    try std.testing.expect(app.client.authorization.ptr == auth);
    const failed = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(failed);
    try std.testing.expectEqualStrings("{}", failed);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = persisted });

    // Clearing disables the proxy everywhere and removes it from disk state.
    try setProxyEndpoint(&session, " \t ");
    state = session.connection().current();
    try std.testing.expect(!state.proxy_configured);
    try std.testing.expect(state.proxy_address == null);
    try std.testing.expectEqual(@as(u16, 0), state.proxy_port);
    try std.testing.expectEqual(@as(usize, 0), state.proxy_models.len);
    try prepareNativeRouteForTest(app.decision_client.?);
    try std.testing.expect(app.decision_client.?.native.?.proxy_url == null);
    try std.testing.expect(app.image_client.?.transport.proxy_url == null);
    try std.testing.expect(app.memory_coordinator.extractor.?.transport.?.proxy_http == null);
    try std.testing.expect(app.client.authorization.ptr == auth);
    try std.testing.expect(app.client.config == &app.config.value);
    try std.testing.expectEqual(messages, app.runtime.messages().len);
    const cleared = try readSessionConfigBytes(fixture.tmp.dir);
    defer a.free(cleared);
    try std.testing.expect(std.mem.find(u8, cleared, "\"proxy\"") == null);
    var parsed_cleared = try cfg.parse(a, cleared);
    defer cfg.release(&parsed_cleared);
    try std.testing.expect(parsed_cleared.value.proxy == null);
    try std.testing.expectEqualStrings("aux/native/raw", parsed_cleared.value.decision.?.model);
}
test "pending proxy endpoint save updates the pending snapshot only" {
    var fixture = try SessionTestFixture.init();
    defer fixture.deinit();
    try writeSessionTestConfig(fixture.tmp.dir, proxy_pending_config);
    try fixture.env.put("PROXY_AUX_KEY", "fake-aux-key");
    var session = try fixture.open(.{});
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try setProxyEndpoint(&session, "192.0.2.7:1080");
    try std.testing.expectEqualStrings("192.0.2.7", session.pending.?.value.proxy.?.address);
    try std.testing.expectEqual(@as(u16, 1080), session.pending.?.value.proxy.?.port);
    try std.testing.expectEqual(@as(usize, 1), session.pending.?.value.proxy.?.models.len);
    try std.testing.expectEqualStrings("aux/native/raw", session.pending.?.value.proxy.?.models[0]);
    try setProxyEndpoint(&session, "");
    try std.testing.expect(session.pending.?.value.proxy == null);
    try std.testing.expect(session.app == null);
}
