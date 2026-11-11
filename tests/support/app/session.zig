const session_test_config =
    \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key_env":"SESSION_TEST_KEY","models":{"saved":{"protocol":"chat","context_tokens":65536,"output_tokens":4096},"next":{"protocol":"chat","context_tokens":131072,"output_tokens":8192}}},"other":{"base_url":"https://other.invalid/v1","api_key_env":"SESSION_TEST_KEY","models":{"other":{"protocol":"chat","context_tokens":32768,"output_tokens":2048}}}}},"limits":{"low_price_input":false}}
;

const session_test_unavailable =
    \\{"llm":{"default":"other/other","providers":{"archive":{"base_url":"https://archive.invalid/v1","models":{"next":{"protocol":"chat","context_tokens":131072}}},"other":{"base_url":"https://other.invalid/v1","models":{"other":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;

const session_test_missing_alias =
    \\{"llm":{"default":"other/saved","providers":{"other":{"base_url":"https://other.invalid/v1","api_key_env":"SESSION_TEST_KEY","models":{"saved":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;

fn persistedEffortForTest(session: *Session) !presentation.ReasoningEffort {
    var parsed = try session.store.loadExisting();
    defer cfg.release(&parsed);
    return presentation.ReasoningEffort.fromName(parsed.value.registry.?.reasoning_effort orelse "medium");
}

fn setGlobalEffortForTest(session: *Session, effort: presentation.ReasoningEffort) !void {
    var candidate: ?std.json.Parsed(cfg.Config) = try cfg.clone(session.allocator, session.global_config.?.value);
    defer if (candidate) |*value| cfg.release(value);
    try cfg.setRegistryReasoningEffort(candidate.?.arena.allocator(), &candidate.?.value, effort.name().?);
    try session.persistSelectionDefaults(&candidate);
    session.preferred_effort = effort;
}

fn writeSessionTestConfig(dir: std.Io.Dir, bytes: []const u8) !void {
    dir.createDir(std.testing.io, ".thin", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try dir.writeFile(std.testing.io, .{ .sub_path = ".thin/config.json", .data = bytes });
}

const SessionTestFixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    env: std.process.Environ.Map,

    fn init() !SessionTestFixture {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const path = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
        const home = try a.dupe(u8, path);
        errdefer a.free(home);
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        try writeSessionTestConfig(tmp.dir, session_test_config);
        return .{ .tmp = tmp, .home = home, .env = env };
    }

    fn deinit(self: *SessionTestFixture) void {
        self.env.deinit();
        std.testing.allocator.free(self.home);
        self.tmp.cleanup();
    }

    fn open(self: *SessionTestFixture, options: Session.Options) !Session {
        return Session.initWithOptions(std.testing.allocator, std.testing.io, &self.env, self.home, .{}, options);
    }

    fn saveHistory(self: *SessionTestFixture) !ids.Id {
        var source = try self.open(.{});
        defer source.deinit();
        try source.connection().configure("fake-archive-original");
        try seedSessionTestHistory(&source);
        try std.testing.expect(try source.saveOnExit());
        return source.session_id;
    }
};

fn seedSessionTestHistory(session: *Session) !void {
    const app = session.app.?;
    try app.runtime.restoreCheckpoint(.{
        .system = "archived system, not current capabilities",
        .selector = app.runtime.selector,
        .estimator = .{ .per_mille = 1200 },
        .last_context_tokens = 77,
        .context_tokens = 65536,
        .output_tokens = 4096,
        .output_budget_frozen = true,
        .input_budget_frozen = true,
        .input_price_threshold = 100000,
        .max_input_tokens = 80000,
        .permission_id = 19,
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "saved question" }} },
            .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "old-tool", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } }} },
            .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "old-tool", .text = "old result" } }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = "saved answer" }} },
        },
    });
    app.journal.seq = 13;
    app.journal.turn = 2;
}

fn expectSessionTestHistory(session: *Session) !void {
    const messages = Session.initialHistory(session);
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("saved question", messages[0].blocks[0].text);
    try std.testing.expectEqualStrings("saved answer", messages[3].blocks[0].text);
    try std.testing.expectError(error.FileNotFound, session.project_root.dir.statFile(std.testing.io, "must-not-run.txt", .{}));
}

const session_codex_metadata_config =
    \\{"llm":{"default":"chatgpt/gpt-fixture","providers":{"chatgpt":{"base_url":"https://chatgpt.com/backend-api/codex","kind":"openai_codex","codex_oauth":{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_at_ms":123456789},"models":{"gpt-fixture":{"protocol":"responses","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
;

fn releaseLease(session: *Session) void {
    if (session.resume_lease) |*lease| lease.deinit();
    session.resume_lease = null;
}

const legacyMetadataTestProviders = [_]ProviderId{ .deepseek, .opencode_go, .opencode_zen };

const legacyMetadataTestMask = metadata.bit(.deepseek) | metadata.bit(.opencode_go) | metadata.bit(.opencode_zen);

fn writeOfficialMetadataTestConfig(dir: std.Io.Dir, id: ProviderId) !void {
    try writeSessionTestConfig(dir, switch (id) {
        .deepseek =>
        \\{"llm":{"default":"deepseek/deepseek-flash","providers":{"deepseek":{"base_url":"https://api.deepseek.com","kind":"deepseek","chat_max_tokens":true}}},"limits":{"low_price_input":false}}
        ,
        .opencode_go =>
        \\{"llm":{"default":"opencode-go/minimax-m2.7","providers":{"opencode-go":{"base_url":"https://opencode.ai/zen/go/v1","kind":"opencode_go","chat_max_tokens":true}}},"limits":{"low_price_input":false}}
        ,
        .opencode_zen =>
        \\{"llm":{"default":"opencode-zen/minimax-m2.7","providers":{"opencode-zen":{"base_url":"https://opencode.ai/zen/v1","kind":"opencode_zen","chat_max_tokens":true}}},"limits":{"low_price_input":false}}
        ,
        .openai_codex => return error.UnexpectedFixtureProvider,
    });
}

const MetadataFixture = struct {
    var calls: std.atomic.Value(usize) = .init(0);
    fn fetch(_: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
        _ = calls.fetchAdd(1, .monotonic);
        if (key == null or !std.mem.startsWith(u8, key.?, "fake-")) return error.InvalidFixtureKey;
        var values: metadata.Listing = .{};
        values.directory_mask = metadata.bit(id);
        for (catalog.entries) |entry| if (entry.provider == id) {
            const row = try values.directory.upsert(id, entry.model.name);
            row.tokens = 1048576;
            row.available = true;
            row.protocol = entry.model.protocol;
        };
        return values;
    }
    fn fail(_: std.mem.Allocator, _: std.Io, _: ProviderId, _: ?[]const u8) !metadata.Listing {
        return error.FixtureOffline;
    }
    fn stall(_: std.mem.Allocator, io: std.Io, _: ProviderId, _: ?[]const u8) !metadata.Listing {
        try std.Io.sleep(io, .fromSeconds(30), .awake);
        return error.UnexpectedFixtureTimeout;
    }
    /// Offline models.dev stand-in: a successful empty public catalog.
    fn dev(_: std.mem.Allocator, _: std.Io) !metadata.Listing {
        return .{ .dev_done = true };
    }
    fn waitDone(io: std.Io, done: *std.atomic.Value(bool)) !void {
        // Bounded fixture synchronization; leave Future ownership to pollModels.
        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
        while (!done.load(.acquire)) {
            if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.FixtureCompletionTimeout;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }
    fn finish(session: *Session) void {
        const job = session.metadata_job.?;
        if (job.future) |*future| future.await(session.io);
        job.future = null;
        if (job.dev_future) |*future| future.await(session.io);
        job.dev_future = null;
    }
};

const MetadataPublicationFixture = struct {
    const Fault = enum { none, cache, display };

    fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, _: ?[]const u8) !metadata.Listing {
        return metadata.parseListing(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":65536,\"protocol\":\"chat\"}]}", id);
    }
    fn public(_: std.mem.Allocator, _: std.Io) !metadata.Listing {
        return .{ .dev_done = true };
    }
    fn hold(io: std.Io) void {
        while (true) std.Io.sleep(io, .fromSeconds(60), .awake) catch return;
    }

    fn check(official_first: bool, fault: Fault, manual: bool) !void {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeSessionTestConfig(tmp.dir,
            \\{"memory":{"auto":false},"llm":{"default":"deepseek/deepseek-flash","providers":{"deepseek":{"base_url":"https://api.deepseek.com","api_key":"fake-owned-publication","models":{"deepseek-flash":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"low_price_input":false}}
        );
        var path: [4096]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(io, &path)];
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = false });
        defer session.deinit();
        session.initial_default_pending = false;
        session.metadata_wall_ms = 1000;
        const mask = metadata.bit(.deepseek) | metadata.dev_bit;
        const claim = try metadata.claimAt(&session.store.root, mask, manual, 1000, .{});
        try std.testing.expectEqual(mask, claim.mask);
        const job = try a.create(MetadataJob);
        job.* = .{
            .allocator = a,
            .io = io,
            .fetch = official,
            .dev_fetch = public,
            .manual = manual,
            .requested = mask,
            .generations = claim.generations,
            .credential_revisions = session.credential_revisions,
            .started_ms = @intCast(std.Io.Clock.awake.now(io).toMilliseconds()),
        };
        session.metadata_job = job; // Session owns every subsequent failure path.
        job.keys[@intCast(@backingInt(ProviderId.deepseek))] = try a.dupe(u8, "fake-local-fetch");
        job.run();
        job.runDev();
        try std.testing.expectEqual(metadata.bit(.deepseek), job.succeeded);
        try std.testing.expect(job.dev_listing.dev_done);
        if (official_first) {
            job.dev_done.store(false, .release);
            job.dev_started_ms = @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
            job.dev_future = try std.Io.concurrent(io, hold, .{io});
        } else {
            job.done.store(false, .release);
            job.future = try std.Io.concurrent(io, hold, .{io});
        }
        const previous_models = session.display_models;
        const previous_cache = session.metadata_cache;
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        {
            const session_allocator = session.allocator;
            const root_allocator = session.store.root.allocator;
            defer session.allocator = session_allocator;
            defer session.store.root.allocator = root_allocator;
            // Cache fault hits real commitClaimedAt -> load allocation, after
            // published is marked. Display fault hits the real buildModels,
            // after a successful on-disk commit. Neither needs a production seam.
            switch (fault) {
                .cache => session.store.root.allocator = failing.allocator(),
                .display => session.allocator = failing.allocator(),
                .none => {},
            }
            try std.testing.expect(Session.pollModels(&session, true));
        }
        try std.testing.expect(session.metadata_job == job);
        try std.testing.expectEqual(official_first, job.official_published);
        try std.testing.expectEqual(!official_first, job.dev_published);
        const expected: ?[]const u8 = switch (fault) {
            .cache => "Metadata cache could not be saved; previous values kept",
            .display => "Metadata display could not be updated; previous values kept",
            .none => null,
        };
        if (expected) |notice| {
            if (manual) {
                try std.testing.expectEqualStrings(notice, session.metadata_notice orelse return error.MissingFailureNotice);
            } else try std.testing.expect(session.metadata_notice == null);
            try std.testing.expect(session.display_models.ptr == previous_models.ptr);
            try std.testing.expectEqualDeep(previous_cache, session.metadata_cache);
        }
        const first_saved = try metadata.load(&session.store.root);
        const first_index: usize = if (official_first) @intCast(@backingInt(ProviderId.deepseek)) else ProviderId.all.len;
        try std.testing.expectEqual(fault != .cache, first_saved.refresh[first_index].successful);
        try std.testing.expectEqual(@as(u16, 0), metadataNoticeTtl(session.metadata_notice));
        if (official_first) {
            job.dev_future.?.cancel(io);
            job.dev_future = null;
        } else {
            job.future.?.cancel(io);
            job.future = null;
        }
        try std.testing.expect(Session.pollModels(&session, true));
        try std.testing.expect(session.metadata_job == null);
        // The second stage really committed successfully, not another failure.
        const saved = try metadata.load(&session.store.root);
        if (official_first) {
            try std.testing.expect(saved.refresh[ProviderId.all.len].successful);
        } else {
            const index: usize = @intCast(@backingInt(ProviderId.deepseek));
            try std.testing.expect(saved.refresh[index].successful);
        }
        if (!manual) {
            try std.testing.expect(session.metadata_notice == null);
        } else if (expected) |notice| {
            try std.testing.expectEqualStrings(notice, session.metadata_notice.?);
        } else {
            try std.testing.expectEqualStrings(official_refresh_success, session.metadata_notice.?);
        }
        try std.testing.expectEqual(@as(u16, if (manual and fault == .none) 3000 else 0), metadataNoticeTtl(session.metadata_notice));
    }
};

const LayeredMetadataFixture = struct {
    var official_effort: std.atomic.Value(bool) = .init(false);
    var dev_calls: std.atomic.Value(usize) = .init(0);
    fn official(a: std.mem.Allocator, _: std.Io, id: ProviderId, key: ?[]const u8) !metadata.Listing {
        if (id != .opencode_go or key == null or !std.mem.startsWith(u8, key.?, "fake-")) return error.UnexpectedFixtureCredential;
        const body = if (official_effort.load(.acquire))
            "{\"data\":[{\"id\":\"gpt-6-luna\"},{\"id\":\"claude-haiku-5-5\",\"effort\":{\"supported_levels\":[\"high\"]}}]}"
        else
            "{\"data\":[{\"id\":\"gpt-6-luna\",\"context_window\":262144},{\"id\":\"claude-haiku-5-5\",\"context_window\":65536}]}";
        return metadata.parseListing(a, body, id);
    }
    fn dev(a: std.mem.Allocator, _: std.Io) !metadata.Listing {
        _ = dev_calls.fetchAdd(1, .monotonic);
        return metadata.parseDev(a, @embedFile("models_dev_fixture.json"));
    }
    fn devStall(_: std.mem.Allocator, io: std.Io) !metadata.Listing {
        try std.Io.sleep(io, .fromSeconds(60), .awake);
        return error.UnexpectedFixtureTimeout;
    }
    fn devFail(_: std.mem.Allocator, _: std.Io) !metadata.Listing {
        return error.FixtureOffline;
    }
    fn row(records: *const directory.Directory, provider: ProviderId, raw_id: []const u8) directory.Record {
        return records.rows[records.find(provider, raw_id).?];
    }
};

fn publicReasoningFixture(listing: *metadata.Listing, name: []const u8) void {
    const row = &listing.directory.rows[listing.directory.find(.opencode_go, name).?];
    row.dev_protocol = row.protocol;
    row.dev_reasoning = row.reasoning;
    row.dev_present = true;
    row.reasoning = null;
    listing.dev_done = true;
}

const proxy_session_config =
    \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"aux":{"base_url":"https://aux.invalid/v1","api_key_env":"PROXY_AUX_KEY","models":{"review/raw/id":{"protocol":"chat","context_tokens":32768},"native/raw":{"protocol":"systemone"},"unknown/raw":{}}},"unlogged":{"base_url":"https://unlogged.invalid/v1","api_key_env":"PROXY_MISSING_KEY","models":{"m":{"protocol":"chat","context_tokens":65536}}}}},"decision":{"model":"aux/native/raw","enabled":true},"limits":{"low_price_input":false},"proxy":{"address":"10.0.0.9","port":3128,"models":["aux/review/raw/id"]}}
;

const proxy_helper_config =
    \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key":"fake-main-key","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"aux":{"base_url":"https://aux.invalid/v1","api_key_env":"PROXY_AUX_KEY","models":{"native/raw":{"protocol":"systemone"},"review/raw/id":{"protocol":"chat","context_tokens":32768}}},"img":{"base_url":"https://api.deepseek.com","kind":"deepseek","api_key_env":"PROXY_IMG_KEY","models":{"deepseek-flash":{"protocol":"chat","context_tokens":65536}}}}},"decision":{"model":"aux/native/raw","enabled":true},"image":{"model":"img/deepseek-flash"},"limits":{"low_price_input":false},"proxy":{"address":"127.0.0.1","port":18080,"models":["aux/review/raw/id"]}}
;

const proxy_pending_config =
    \\{"llm":{"default":"main/chat","providers":{"main":{"base_url":"https://main.invalid/v1","api_key_env":"PROXY_MAIN_MISSING","models":{"chat":{"protocol":"chat","context_tokens":65536}}},"aux":{"base_url":"https://aux.invalid/v1","api_key_env":"PROXY_AUX_KEY","models":{"native/raw":{"protocol":"systemone"},"other/raw":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false},"proxy":{"address":"10.0.0.9","port":3128,"models":["aux/native/raw"]}}
;

fn readSessionConfigBytes(dir: std.Io.Dir) ![]u8 {
    return dir.readFileAlloc(std.testing.io, ".thin/config.json", std.testing.allocator, .limited(1 << 16));
}

fn proxyToggle(session: *Session, name: []const u8, enabled: bool) !void {
    const connection = session.connection();
    const callback = connection.proxy_fn orelse return error.ProxyCallbackUnavailable;
    try callback(connection.context, name, enabled);
}

fn prepareNativeRouteForTest(client: *@import("decision_client.zig").Client) !void {
    const a = std.testing.allocator;
    try std.testing.expect(client.native == null and client.resolved == null);
    var cancel: p.Cancellation = .{};
    const output = try client.service().decide(a, .{ .refine_outputs = &.{} }, &cancel);
    defer @import("../core/decision.zig").freeOutput(a, output);
    try std.testing.expect(output == .refine_outputs and output.refine_outputs.len == 0);
    try std.testing.expect(client.native != null and client.resolved != null);
    try std.testing.expectEqual(@as(u64, 0), client.calls);
}

fn setProxyEndpoint(session: *Session, raw: []const u8) !void {
    const connection = session.connection();
    const callback = connection.proxy_address_fn orelse return error.ProxyCallbackUnavailable;
    try callback(connection.context, raw);
}
