//! Registry Session regressions. Temporary HOME, synthetic keys, no requests.
const std = @import("std");
const cfg = @import("../core/config.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const metadata = @import("model_metadata.zig");
const selections = @import("selection.zig");
const codec = @import("resume_codec.zig");
const a = std.testing.allocator;

fn save(home: []const u8, text: []const u8) !void {
    var store = try Store.open(a, std.testing.io, home);
    defer store.deinit();
    var parsed = try cfg.parse(a, text);
    defer cfg.release(&parsed);
    // Seed a literal disk document, independently of onboarding serialization.
    try store.root.writeMode(cfg.file_name, text, false, 0o600);
}

test "publication empty selection route constrains every capability before validation" {
    const resolver = @import("model_resolver.zig");
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"go/fresh","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","models":{"manual":{"context_tokens":65536},"conflict":{"protocol":"responses","context_tokens":65536},"probe":{"protocol":"auto","context_tokens":65536}}}}}}
    );
    defer cfg.release(&parsed);
    var cache: metadata.Cache = .{};
    const row = try cache.directory.upsert(.opencode_go, "fresh");
    row.available = true;
    row.protocol = .responses;
    row.tokens = 1000000;
    row.output_tokens = 128000;
    row.dev_protocol = .responses;
    row.dev_context_tokens = 1000000;
    row.dev_output_tokens = 128000;
    cache.directory_mask = metadata.bit(.opencode_go);
    try std.testing.expectError(error.UnknownModelContext, resolver.resolveRoute(parsed.arena.allocator(), parsed.value, &cache, "go", "fresh", .chat));
    // Matching public evidence can restore the historical concrete route when
    // current official metadata has no conflicting route/window declaration.
    row.protocol = .auto;
    row.tokens = null;
    row.dev_protocol = .chat;
    row.dev_context_tokens = 65536;
    row.dev_output_tokens = 4096;
    const restored = try resolver.resolveRoute(parsed.arena.allocator(), parsed.value, &cache, "go", "fresh", .chat);
    try std.testing.expectEqual(.chat, restored.model.protocol);
    try std.testing.expectEqual(@as(u32, 65536), restored.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 4096), restored.model.output_tokens);
    const preset = try resolver.resolveRoute(parsed.arena.allocator(), parsed.value, &cache, "go", "glm-5.3", .chat);
    try std.testing.expectEqual(@import("provider_catalog.zig").find("opencode-go/glm-5.3").?.model.context_tokens, preset.model.context_tokens);
    try std.testing.expect(preset.model.output_tokens == null);
    const manual = try resolver.resolveRoute(parsed.arena.allocator(), parsed.value, &cache, "go", "manual", .chat);
    try std.testing.expectEqual(@as(u32, 65536), manual.model.context_tokens);
    try std.testing.expect(manual.model.output_tokens == null);
    try std.testing.expectError(error.RestoredProtocolConflict, resolver.resolveRoute(parsed.arena.allocator(), parsed.value, &cache, "go", "conflict", .chat));
    try std.testing.expectError(error.RestoredProtocolConflict, resolver.resolveRoute(parsed.arena.allocator(), parsed.value, &cache, "go", "probe", .chat));
    try std.testing.expectError(error.UnknownModelProtocol, resolver.resolveRoute(parsed.arena.allocator(), parsed.value, &cache, "go", "manual", .auto));
}

test "publication Session empty restore rejects current-route capacity while full signed restore stays frozen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"go/fresh","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key":"fake-route-go"}}}}
    );
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    {
        var store = try Store.openExisting(a, std.testing.io, home);
        defer store.deinit();
        _ = try metadata.commit(&store.root, metadata.bit(.opencode_go), try metadata.parseListing(a, "{\"data\":[{\"id\":\"fresh\",\"protocol\":\"chat\",\"context_window\":65536}]}", .opencode_go));
    }
    var id: @import("session_id.zig").Id = undefined;
    {
        var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{});
        defer source.deinit();
        id = source.session_id;
        const app = source.app.?;
        try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{.{ .text = "signed route fixture" }} });
        try std.testing.expect(try source.saveOnExit());
        var changed = try metadata.parseListing(a, "{\"data\":[{\"id\":\"fresh\",\"protocol\":\"responses\",\"context_window\":1000000}]}", .opencode_go);
        changed.directory.rows[0].output_tokens = 128000;
        _ = try metadata.commit(&source.store.root, metadata.bit(.opencode_go), changed);
    }
    try std.testing.expectError(error.UnknownModelContext, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = id, .logging = false }));
    var full = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .resume_session = id, .logging = false });
    defer full.deinit();
    try std.testing.expectEqual(.chat, full.app.?.config.value.model.protocol);
    try std.testing.expectEqual(@as(u32, 65536), full.app.?.config.value.model.context_tokens);
    try std.testing.expect(full.app.?.config.value.model.output_tokens == null);
    try std.testing.expectEqual(@as(usize, 1), full.app.?.runtime.messages().len);
}

const PublicationFetch = struct {
    var official: [3]std.atomic.Value(usize) = .{ .init(0), .init(0), .init(0) };
    var public_calls: std.atomic.Value(usize) = .init(0);
    var hold_public: std.atomic.Value(bool) = .init(false);
    fn fetch(_: std.mem.Allocator, _: std.Io, id: cfg.providers.Id, key: ?[]const u8) !metadata.Listing {
        if (key == null) return error.UnexpectedNullKey;
        _ = official[@intCast(@backingInt(id))].fetchAdd(1, .monotonic);
        return .{};
    }
    fn dev(_: std.mem.Allocator, io: std.Io) !metadata.Listing {
        _ = public_calls.fetchAdd(1, .monotonic);
        while (hold_public.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        return .{ .dev_done = true };
    }
    fn refresh(session: *Session) !void {
        const connection = session.connection();
        try connection.refresh_models_fn.?(connection.context);
    }
    fn poll(session: *Session) bool {
        const connection = session.connection();
        return connection.poll_models_fn.?(connection.context, true);
    }
    fn finishOfficial(session: *Session) void {
        const job = session.metadata_job.?;
        if (job.future) |*future| future.await(session.io);
        job.future = null;
    }
    fn finish(session: *Session) void {
        finishOfficial(session);
        const job = session.metadata_job.?;
        if (job.dev_future) |*future| future.await(session.io);
        job.dev_future = null;
    }
};

test "publication missing alias key isolates claimed official restart and public generations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"missing/m","providers":{"missing":{"base_url":"https://opencode.ai/zen/go/v1","api_key_env":"MISSING_KEY","models":{"m":{"protocol":"chat","context_tokens":65536}}},"ready":{"base_url":"https://opencode.ai/zen/go/v1","api_key":"fake-go"},"ds":{"base_url":"https://api.deepseek.com","api_key":"fake-ds"}}}}
    );
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    session.metadata_fetch = PublicationFetch.fetch;
    session.metadata_dev_fetch = PublicationFetch.dev;
    session.metadata_wall_ms = 1000;
    PublicationFetch.public_calls.store(0, .monotonic);
    for (&PublicationFetch.official) |*count| count.store(0, .monotonic);
    PublicationFetch.hold_public.store(true, .release);
    defer PublicationFetch.hold_public.store(false, .release);
    try PublicationFetch.refresh(&session);
    PublicationFetch.finishOfficial(&session);
    try std.testing.expect(PublicationFetch.poll(&session));
    const public_generation = session.metadata_job.?.generations[3];
    try std.testing.expectEqual(@as(usize, 0), PublicationFetch.official[1].load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), PublicationFetch.official[0].load(.monotonic));
    try std.testing.expect(!session.metadata_cache.refresh[1].successful);
    // Restart only the joined official slot while the public claim is live.
    session.metadata_login_pending = metadata.bit(.deepseek) | metadata.bit(.opencode_go);
    try std.testing.expect(PublicationFetch.poll(&session));
    try std.testing.expectEqual(public_generation, session.metadata_job.?.generations[3]);
    PublicationFetch.finishOfficial(&session);
    try std.testing.expect(PublicationFetch.poll(&session));
    try std.testing.expectEqual(@as(usize, 2), PublicationFetch.official[0].load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), PublicationFetch.official[1].load(.monotonic));
    PublicationFetch.hold_public.store(false, .release);
    PublicationFetch.finish(&session);
    try std.testing.expect(PublicationFetch.poll(&session));
    try std.testing.expect(session.metadata_job == null);
    try std.testing.expectEqual(@as(usize, 1), PublicationFetch.public_calls.load(.monotonic));
    try std.testing.expect(session.metadata_cache.refresh[3].successful);
    try std.testing.expectEqual(public_generation, session.metadata_cache.refresh[3].generation);
    // Only public is due: the missing official key must not even be looked up.
    session.metadata_auto = true;
    session.metadata_awake_ms = 1000000;
    session.metadata_wall_ms = 300000;
    session.metadata_cache.refresh[3].last_attempt_ms = null;
    // Persist the same public-only eligibility used by the owner, with official
    // claims fresh and still inside cooldown/TTL.
    const public_claim = try metadata.claimAt(&session.store.root, metadata.dev_bit, true, 0, .{});
    _ = public_claim;
    _ = PublicationFetch.poll(&session);
    try std.testing.expect(session.metadata_job != null);
    try std.testing.expectEqual(metadata.dev_bit, session.metadata_job.?.requested);
    PublicationFetch.finish(&session);
    try std.testing.expect(PublicationFetch.poll(&session));
}

const custom =
    \\{"llm":{"default":"alpha/org/shared","providers":{"alpha":{"base_url":"https://alpha.invalid/v1","api_key_env":"ALPHA_KEY","models":{"org/shared":{"protocol":"chat","context_tokens":65536,"output_tokens":8192},"other":{"protocol":"chat","context_tokens":32768}}},"beta":{"base_url":"https://beta.invalid/v1","api_key_env":"BETA_KEY","models":{"org/shared":{"protocol":"responses","context_tokens":131072,"output_tokens":16384}}}}}}
;

test "llm Session custom aliases select complete connections and only empty history persists defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home, custom);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("ALPHA_KEY", "fake-alpha");
    try env.put("BETA_KEY", "fake-beta");
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try std.testing.expect(session.app != null);
    try std.testing.expectEqualStrings("alpha", session.app.?.config.value.selected_provider.?);
    try std.testing.expectEqualStrings("alpha/org/shared", session.connection().current().selection_name.?);
    try session.connection().selectModel("beta/org/shared");
    try std.testing.expectEqualStrings("https://beta.invalid/v1", session.app.?.config.value.provider.base_url);
    try std.testing.expectEqual(.responses, session.app.?.config.value.model.protocol);
    try std.testing.expectEqual(@as(?u32, 16384), session.app.?.config.value.model.output_tokens);
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    try std.testing.expectEqualStrings("beta/org/shared", disk.value.registry.?.default);
    try std.testing.expectEqualStrings("ALPHA_KEY", disk.value.registry.?.find("alpha").?.connection.api_key_env);
    try std.testing.expectEqual(@as(usize, 1), disk.value.registry.?.find("beta").?.models.len);
    const app = session.app.?;
    try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{.{ .text = "canonical fixture" }} });
    try session.connection().selectModel("alpha/other");
    try std.testing.expectEqualStrings("alpha", session.app.?.config.value.selected_provider.?);
    try std.testing.expectEqual(@as(?u32, null), session.app.?.config.value.model.output_tokens);
    var after = try session.store.loadExisting();
    defer cfg.release(&after);
    try std.testing.expectEqualStrings("beta/org/shared", after.value.registry.?.default);
    try std.testing.expectEqual(@as(usize, 1), session.app.?.runtime.messages().len);
}

test "llm Session retained inline credential never wipes the independent global baseline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"alpha/m","providers":{"alpha":{"base_url":"https://alpha.invalid/v1","api_key":"fake-inline-baseline","models":{"m":{"protocol":"chat","context_tokens":65536,"output_tokens":8192}}}}}}
    );
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    for ([_][]const u8{ "m", "alpha/m", "m" }) |selector| {
        try session.connection().selectModel(selector);
        try std.testing.expectEqualStrings("fake-inline-baseline", session.global_config.?.value.registry.?.find("alpha").?.connection.api_key.?);
        var copy = try cfg.clone(a, session.global_config.?.value);
        defer cfg.release(&copy);
        try std.testing.expectEqualStrings("fake-inline-baseline", copy.value.registry.?.find("alpha").?.connection.api_key.?);
    }
}

test "llm Session unresolved defaults stay pending and custom unknown rows never probe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"proxy/unknown","providers":{"proxy":{"base_url":"https://proxy.invalid/v1","kind":"opencode_go","api_key_env":"ABSENT_KEY","models":{"unknown":{"context_tokens":65536},"ready":{"protocol":"chat","context_tokens":65536}}}}}}
    );
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try std.testing.expect(session.app == null);
    try std.testing.expect(session.pending.?.value.selection_pending);
    try std.testing.expect(session.connection().current().settings_notice != null);
    try std.testing.expectEqual(@as(u32, 0), session.connection().current().context_limit);
    try std.testing.expect(session.connection().current().initial_context == null);
    try std.testing.expect(session.connection().current().runtime == null);
    for (session.connection().current().models, 0..) |model, index| {
        if (std.mem.eql(u8, model.name, "proxy/unknown")) try std.testing.expect(session.connection().current().model_disabled[index]);
    }
    try std.testing.expectError(error.UnknownModelProtocol, session.connection().selectModel("proxy/unknown"));
    try session.connection().configureProvider(.opencode_go, "fake-official-only");
    try std.testing.expect(session.app == null);
    try std.testing.expect(session.global_config.?.value.registry.?.find("proxy").?.connection.api_key == null);
    try std.testing.expectEqualStrings("ABSENT_KEY", session.global_config.?.value.registry.?.find("proxy").?.connection.api_key_env);
    try std.testing.expectEqualStrings("proxy/unknown", session.global_config.?.value.registry.?.default);
    try session.connection().selectModel("proxy/ready");
    try std.testing.expect(session.app == null);
    try std.testing.expect(!session.pending.?.value.selection_pending);
    try std.testing.expectEqualStrings("ready", session.pending.?.value.model.name);
}

test "llm Session directory fields merge per alias and auth preserves all declarations and default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"go/shared","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key_env":"MISSING_GO","models":{"shared":{"context_tokens":200000}}},"custom":{"base_url":"https://custom.invalid/v1","api_key_env":"CUSTOM_ENV","models":{"shared":{"protocol":"chat","context_tokens":32768}}}}}}
    );
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    session.metadata_cache.directory_mask = metadata.bit(.opencode_go);
    const row = try session.metadata_cache.directory.upsert(.opencode_go, "shared");
    row.available = true;
    row.tokens = 1000000;
    row.protocol = .responses;
    row.dev_protocol = .responses;
    row.dev_output_tokens = 128000;
    const extra = try session.metadata_cache.directory.upsert(.opencode_go, "extra");
    extra.available = true;
    extra.tokens = 65536;
    extra.protocol = .chat;
    try session.connection().selectModel("go/shared");
    try std.testing.expectEqual(.responses, session.pending.?.value.model.protocol);
    try std.testing.expectEqual(@as(u32, 200000), session.pending.?.value.model.context_tokens);
    try std.testing.expectEqual(@as(?u32, 128000), session.pending.?.value.model.output_tokens);
    var saw_extra = false;
    var saw_custom = false;
    for (session.connection().current().models) |model| {
        if (std.mem.eql(u8, model.name, "go/extra")) saw_extra = true;
        if (std.mem.eql(u8, model.name, "custom/shared")) {
            saw_custom = true;
            try std.testing.expectEqual(.chat, model.protocol);
            try std.testing.expectEqual(@as(u32, 32768), model.context_tokens);
        }
    }
    try std.testing.expect(saw_extra and saw_custom);
    try session.connection().configureProvider(.opencode_go, "fake-new-go");
    try std.testing.expect(session.app != null);
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    try std.testing.expectEqualStrings("go/shared", disk.value.registry.?.default);
    try std.testing.expectEqual(@as(usize, 2), disk.value.registry.?.providers.len);
    try std.testing.expectEqualStrings("CUSTOM_ENV", disk.value.registry.?.find("custom").?.connection.api_key_env);
    try std.testing.expectEqualStrings("fake-new-go", disk.value.registry.?.find("go").?.connection.api_key.?);
    try std.testing.expect(disk.value.registry.?.find("go").?.models[0].patch.protocol == null);
}

test "llm Session custom full resume authenticates named endpoint and frozen budgets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home, custom);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("ALPHA_KEY", "fake-alpha");
    try env.put("BETA_KEY", "fake-beta");
    var id: @import("session_id.zig").Id = undefined;
    {
        var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{});
        defer source.deinit();
        try source.connection().selectModel("beta/org/shared");
        id = source.session_id;
        const app = source.app.?;
        app.config.value.model.output_tokens = null;
        app.config.value.model.context_tokens = 65536;
        try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{.{ .text = "resume canonical fixture" }} });
        try std.testing.expect(try source.saveOnExit());
    }
    var restored = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .resume_session = id });
    defer restored.deinit();
    try std.testing.expectEqualStrings("beta", restored.app.?.config.value.selected_provider.?);
    try std.testing.expectEqualStrings("https://beta.invalid/v1", restored.app.?.config.value.provider.base_url);
    try std.testing.expectEqual(@as(usize, 1), restored.app.?.runtime.messages().len);
    // No default re-resolution may overwrite authenticated frozen state.
    try std.testing.expectEqual(@as(?u32, null), restored.app.?.config.value.model.output_tokens);
    try std.testing.expectEqual(@as(u32, 65536), restored.app.?.config.value.model.context_tokens);
}

test "llm Session failed default persistence publishes neither connection nor selection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home, custom);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("ALPHA_KEY", "fake-alpha");
    try env.put("BETA_KEY", "fake-beta");
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    var external = try Store.openExisting(a, std.testing.io, home);
    defer external.deinit();
    var changed = try external.loadExisting();
    defer cfg.release(&changed);
    try cfg.setRegistryDefault(changed.arena.allocator(), &changed.value, "alpha", "other");
    try external.save(changed.value);
    try std.testing.expectError(error.AuthVersionConflict, session.connection().selectModel("beta/org/shared"));
    try std.testing.expectEqualStrings("alpha", session.app.?.config.value.selected_provider.?);
    try std.testing.expectEqualStrings("org/shared", session.app.?.config.value.model.name);
    try std.testing.expectEqualStrings("alpha/org/shared", session.global_config.?.value.registry.?.default);
}

test "llm Session raw IDs keep unconfigured slash prefixes and qualified IDs keep all remaining slashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"alpha/start","providers":{"alpha":{"base_url":"https://alpha.invalid/v1","api_key_env":"ALPHA_KEY","models":{"start":{"protocol":"chat","context_tokens":65536},"vendor/new/model":{"protocol":"chat","context_tokens":32768}}},"beta":{"base_url":"https://beta.invalid/v1","api_key_env":"BETA_KEY","models":{"vendor/another/model":{"protocol":"responses","context_tokens":131072}}}}}}
    );
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("ALPHA_KEY", "fake-alpha");
    try env.put("BETA_KEY", "fake-beta");
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try session.connection().selectModel("vendor/new/model");
    try std.testing.expectEqualStrings("alpha", session.app.?.config.value.selected_provider.?);
    try std.testing.expectEqualStrings("vendor/new/model", session.app.?.config.value.model.name);
    try std.testing.expectEqual(@as(u32, 32768), session.app.?.config.value.model.context_tokens);
    try session.connection().selectModel("beta/vendor/another/model");
    try std.testing.expectEqualStrings("beta", session.app.?.config.value.selected_provider.?);
    try std.testing.expectEqualStrings("vendor/another/model", session.app.?.config.value.model.name);
    try std.testing.expectEqual(.responses, session.app.?.config.value.model.protocol);
}

test "llm Session login appends missing official declaration without switching or changing default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"deepseek/deepseek-flash","providers":{"deepseek":{"base_url":"https://api.deepseek.com","api_key_env":"DS_KEY","models":{"deepseek-flash":{"protocol":"chat","context_tokens":131072}}}}}}
    );
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("DS_KEY", "fake-ds");
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try session.connection().configureProvider(.opencode_go, "fake-go");
    try std.testing.expectEqualStrings("deepseek", session.app.?.config.value.selected_provider.?);
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    const registry = disk.value.registry.?;
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", registry.default);
    try std.testing.expectEqual(@as(usize, 2), registry.providers.len);
    const ds = registry.find("deepseek").?;
    try std.testing.expectEqualStrings("DS_KEY", ds.connection.api_key_env);
    try std.testing.expect(ds.connection.api_key == null);
    try std.testing.expectEqual(@as(usize, 1), ds.models.len);
    try std.testing.expectEqual(@as(?u32, 131072), ds.models[0].patch.context_tokens);
    try std.testing.expectEqual(.chat, ds.models[0].patch.protocol.?);
    const go = registry.find("opencode-go").?;
    try std.testing.expectEqualStrings(cfg.providers.Id.opencode_go.baseUrl(), go.connection.base_url);
    try std.testing.expectEqualStrings("fake-go", go.connection.api_key.?);
    try std.testing.expectEqual(@as(usize, 0), go.models.len);
    try session.connection().selectModel("opencode-go/glm-5.3");
    try std.testing.expectEqualStrings("opencode-go", session.app.?.config.value.selected_provider.?);
    try std.testing.expectEqualStrings("glm-5.3", session.app.?.config.value.model.name);
}

test "llm Session login rejects canonical custom name conflicts and ambiguous official aliases" {
    const documents = [_][]const u8{
        \\{"llm":{"default":"proxy/start","providers":{"proxy":{"base_url":"https://proxy.invalid/v1","models":{"start":{"protocol":"chat","context_tokens":65536}}},"opencode-go":{"base_url":"https://custom.invalid/v1"}}}}
        ,
        \\{"llm":{"default":"proxy/start","providers":{"proxy":{"base_url":"https://proxy.invalid/v1","models":{"start":{"protocol":"chat","context_tokens":65536}}},"go1":{"base_url":"https://opencode.ai/zen/go/v1"},"go2":{"base_url":"https://opencode.ai/zen/go/v1"}}}}
        ,
    };
    for (documents, 0..) |document, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
        try save(home, document);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
        defer session.deinit();
        if (index == 0) try std.testing.expectError(error.ProviderNameConflict, session.connection().configureProvider(.opencode_go, "fake-go")) else try std.testing.expectError(error.AmbiguousProvider, session.connection().configureProvider(.opencode_go, "fake-go"));
        var disk = try session.store.loadExisting();
        defer cfg.release(&disk);
        try std.testing.expectEqualStrings("proxy/start", disk.value.registry.?.default);
        try std.testing.expectEqual(@as(usize, index + 2), disk.value.registry.?.providers.len);
    }
}

test "llm Session manual effort and resolved metadata map stay frozen across startup effort changes and cache refresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try save(home,
        \\{"llm":{"default":"go/gpt-5.6-luna","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key_env":"GO_KEY","models":{"gpt-5.6-luna":{"context_tokens":65536,"reasoning_effort":"high"}}}}}}
    );
    const catalog = @import("provider_catalog.zig");
    const index = for (catalog.entries, 0..) |entry, i| {
        if (entry.provider == .opencode_go and std.mem.eql(u8, entry.model.name, "gpt-5.6-luna")) break i;
    } else unreachable;
    {
        var store = try Store.openExisting(a, std.testing.io, home);
        defer store.deinit();
        var listing: metadata.Listing = .{};
        listing.reasoning[index] = .{ .format = .standard, .map = .{ .low = "low", .high = "high" } };
        _ = try metadata.commit(&store.root, metadata.bit(.opencode_go), listing);
    }
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("GO_KEY", "fake-go");
    var session = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .logging = false });
    defer session.deinit();
    try std.testing.expectEqualStrings("high", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqualStrings("high", session.app.?.config.value.model.reasoning.?.map.high.?);
    // Owner cache replacement models a completed refresh losing capabilities.
    // UI/Shift+Tab must still use the accepted owned map, not latest metadata.
    session.metadata_cache = .{};
    try std.testing.expect(session.connection().current().effort_levels.contains(.high));
    try std.testing.expect(session.connection().current().effort_levels.contains(.low));
    try session.connection().setEffort(.low);
    try std.testing.expectEqualStrings("low", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expectEqualStrings("high", session.app.?.config.value.model.reasoning.?.map.high.?);
    try session.connection().selectModel("gpt-5.6-luna");
    try std.testing.expectEqualStrings("low", session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expect(session.connection().current().effort_levels.contains(.high));
    var disk = try session.store.loadExisting();
    defer cfg.release(&disk);
    const patch = disk.value.registry.?.find("go").?.patchFor("gpt-5.6-luna").?;
    try std.testing.expectEqualStrings("high", patch.reasoning_effort.?);
    try std.testing.expect(patch.reasoning == null);
}

test "llm Session dynamic frozen checkpoint survives lost window and delisting with known and unknown output" {
    for ([_]?u32{ 128000, null }) |output| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
        try save(home,
            \\{"llm":{"default":"go/cached.protochat","providers":{"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key":"fake-frozen-go"}}}}
        );
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        {
            var store = try Store.openExisting(a, std.testing.io, home);
            defer store.deinit();
            var listing: metadata.Listing = .{ .directory_mask = metadata.bit(.opencode_go) };
            const row = try listing.directory.upsert(.opencode_go, "cached.protochat");
            row.available = true;
            row.protocol = .chat;
            row.tokens = 1000000;
            row.dev_present = true;
            row.dev_protocol = .chat;
            row.dev_output_tokens = output;
            listing.dev_done = true;
            _ = try metadata.commit(&store.root, metadata.bit(.opencode_go), listing);
        }
        var id: @import("session_id.zig").Id = undefined;
        {
            var source = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{});
            defer source.deinit();
            id = source.session_id;
            const app = source.app.?;
            try std.testing.expectEqual(@as(u32, 1000000), app.config.value.model.context_tokens);
            try std.testing.expectEqual(output, app.config.value.model.output_tokens);
            try app.runtime.history.append(app.runtime.arena.allocator(), .{ .role = .user, .blocks = &.{.{ .text = "frozen dynamic canonical fixture" }} });
            // Publish an ordinary in-session checkpoint; saveOnExit is a
            // terminal one-shot and must not be invoked twice on this owner.
            try source.connection().selectModel("cached.protochat");
            try std.testing.expect(source.resume_lease != null);
            // Official refresh removes the context and marks the ID absent.
            // Keep protocol evidence so empty-chat restore fails specifically
            // for the unknown window, not an unrelated unavailable route.
            var listing: metadata.Listing = .{ .directory_mask = metadata.bit(.opencode_go) };
            const row = try listing.directory.upsert(.opencode_go, "cached.protochat");
            row.available = false;
            row.dev_present = true;
            row.dev_protocol = .chat;
            row.dev_output_tokens = 4096;
            listing.dev_done = true;
            _ = try metadata.commit(&source.store.root, metadata.bit(.opencode_go), listing);
            source.metadata_cache = try metadata.load(&source.store.root);
            try std.testing.expect(try source.saveOnExit());
            try std.testing.expectEqualStrings("fake-frozen-go", source.global_config.?.value.registry.?.find("go").?.connection.api_key.?);
        }
        try std.testing.expectError(error.UnknownModelContext, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = id, .logging = false }));
        {
            var restored = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .resume_session = id });
            defer restored.deinit();
            try std.testing.expectEqual(@as(u32, 1000000), restored.app.?.config.value.model.context_tokens);
            try std.testing.expectEqual(output, restored.app.?.config.value.model.output_tokens);
            try std.testing.expectEqual(.chat, restored.app.?.config.value.model.protocol);
            try std.testing.expectEqual(@as(usize, 1), restored.app.?.runtime.messages().len);
            try std.testing.expect(try restored.saveOnExit());
        }
        {
            // A later refresh removes the row and every models.dev capability.
            var store = try Store.openExisting(a, std.testing.io, home);
            defer store.deinit();
            const listing: metadata.Listing = .{ .directory_mask = metadata.bit(.opencode_go), .dev_done = true };
            _ = try metadata.commit(&store.root, metadata.bit(.opencode_go), listing);
            var restored = try Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .resume_session = id });
            defer restored.deinit();
            try std.testing.expectEqual(@as(u32, 1000000), restored.app.?.config.value.model.context_tokens);
            try std.testing.expectEqual(output, restored.app.?.config.value.model.output_tokens);
            try std.testing.expect(try restored.saveOnExit());
        }
        // Valid lease/digest, but invalid HMAC and invalid payload JSON: auth
        // must win over model resolution AND payload decoding on both paths.
        var store = try Store.openExisting(a, std.testing.io, home);
        defer store.deinit();
        var parsed = try store.loadExisting();
        defer cfg.release(&parsed);
        parsed.value.selected_provider = "go";
        parsed.value.model = .{ .name = "cached.protochat", .protocol = .chat, .context_tokens = 1000000 };
        const snapshot = try selections.capture(parsed.value);
        const wire = try codec.encode(a, id, &snapshot, "{bad-json", "fake-frozen-go", @splat(0));
        defer a.free(wire);
        wire[36] ^= 1;
        var root = try @import("settings_store.zig").Store.open(a, std.testing.io, home);
        defer root.deinit();
        const resumes = @import("resume_store.zig");
        var lease = try resumes.Lease.open(&root.root, id, true);
        try lease.save(&root.root, wire);
        lease.deinit();
        try std.testing.expectError(error.ResumeAuthenticationFailed, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .resume_session = id }));
        try std.testing.expectError(error.ResumeAuthenticationFailed, Session.initWithOptions(a, std.testing.io, &env, home, .{}, true, .{ .restore_selection = id }));
    }
}

test "llm selection optional provider name remains owned authenticated and legacy compatible" {
    var parsed = try cfg.parse(a, custom);
    defer cfg.release(&parsed);
    parsed.value.selected_provider = "alpha";
    const snapshot = try selections.capture(parsed.value);
    try std.testing.expectEqualStrings("alpha", snapshot.providerName().?);
    var encoded: [selections.max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&encoded);
    const id = "0123456789abcdef0123456789abcdef".*;
    try selections.encode(&writer, id, &snapshot);
    const owned = try selections.parse(a, writer.buffered(), id);
    @memset(&encoded, 0);
    try std.testing.expectEqualStrings("alpha", owned.providerName().?);
    const framed = try codec.encode(a, id, &snapshot, "{}", "fake-key", @splat(0));
    defer a.free(framed);
    var envelope = try codec.inspect(a, framed, id);
    try codec.authenticate(&envelope, "fake-key");
    try std.testing.expectEqualStrings("alpha", envelope.selection.providerName().?);
    const legacy = "{\"version\":1,\"session\":\"0123456789abcdef0123456789abcdef\",\"provider\":null,\"endpoint\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"model\":\"legacy\",\"protocol\":\"chat\",\"effort\":null,\"effort_hash\":null}";
    const old = try selections.parse(a, legacy, id);
    try std.testing.expect(old.providerName() == null);
}
