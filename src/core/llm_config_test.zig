const std = @import("std");
const cfg = @import("config.zig");
const t = std.testing;

const proxy_prefix = "{\"llm\":{\"default\":\"p/vendor/raw/id\",\"providers\":{\"p\":{\"base_url\":\"https://fixture.invalid/v1\"},\"other\":{\"base_url\":\"https://fixture.invalid/v1\"}}}";
const proxy_fixture = proxy_prefix ++ ",\"proxy\":{\"address\":\"::1\",\"port\":8080,\"models\":[\"p/vendor/raw/id\"]}}";

test "HTTP proxy exact alias routing owned clone and sparse roundtrip" {
    const a = t.allocator;
    const input = try a.dupe(u8, proxy_fixture);
    defer a.free(input);
    var p = try cfg.parse(a, input);
    defer cfg.release(&p);
    @memset(input, 'x');
    try t.expectEqualStrings("::1", p.value.proxy.?.address);
    try t.expectEqualStrings("p/vendor/raw/id", p.value.proxy.?.models[0]);
    try t.expect(p.value.proxyFor("p", "vendor/raw/id") != null);
    try t.expect(p.value.proxyFor(null, "vendor/raw/id") == null);
    try t.expect(p.value.proxyFor("other", "vendor/raw/id") == null);
    try t.expect(p.value.proxyFor("P", "vendor/raw/id") == null);
    try t.expect(p.value.proxyFor("p", "vendor/raw/ID") == null);
    try t.expect(p.value.proxyFor("p", "vendor/raw/id/extra") == null);
    try t.expect(p.value.registry.?.find("p").?.patchFor("vendor/raw/id") == null);
    const url = try p.value.proxy.?.url(a);
    defer a.free(url);
    try t.expectEqualStrings("http://[::1]:8080", url);
    var copy = try cfg.clone(a, p.value);
    defer cfg.release(&copy);
    try t.expect(copy.value.proxy.?.address.ptr != p.value.proxy.?.address.ptr);
    try t.expect(copy.value.proxy.?.models.ptr != p.value.proxy.?.models.ptr);
    try t.expect(copy.value.proxy.?.models[0].ptr != p.value.proxy.?.models[0].ptr);
    try cfg.setRegistryCredential(copy.arena.allocator(), &copy.value, "p", "fixture-key");
    try cfg.setRegistryDefault(copy.arena.allocator(), &copy.value, "other", "new/raw/id");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(copy.value, &out.writer);
    var disk = try cfg.parse(a, out.written());
    defer cfg.release(&disk);
    try t.expectEqualDeep(p.value.proxy, disk.value.proxy);
    try t.expectEqualStrings("https://fixture.invalid/v1", disk.value.provider.base_url);
    try t.expectEqualStrings("other/new/raw/id", disk.value.registry.?.default);
    try t.expectEqualStrings("p/vendor/raw/id", p.value.registry.?.default);
    try t.expectEqual(@as(?u32, null), disk.value.model.input_price_threshold);
    for ([_][]const u8{ "}", ",\"proxy\":null}" }) |suffix| {
        const bytes = try std.mem.concat(a, u8, &.{ proxy_prefix, suffix });
        defer a.free(bytes);
        var absent = try cfg.parse(a, bytes);
        defer cfg.release(&absent);
        try t.expect(absent.value.proxyFor("p", "vendor/raw/id") == null);
        var sparse: std.Io.Writer.Allocating = .init(a);
        defer sparse.deinit();
        try cfg.writeDisk(absent.value, &sparse.writer);
        try t.expect(std.mem.find(u8, sparse.written(), "\"proxy\"") == null);
    }
    copy.value.proxy.?.models = &.{};
    try t.expect(copy.value.proxyFor("p", "vendor/raw/id") == null);
    // Runtime-only snapshots may retain explicit routing without a registry.
    copy.value.registry = null;
    copy.value.proxy.?.models = &.{"p/vendor/raw/id"};
    try cfg.validate(copy.value);
}

test "HTTP proxy rejects malformed hosts numbers fields lists and alias guesses" {
    const a = t.allocator;
    for ([_][]const u8{
        "{}",                                                        "[]",                                                              "true",                                                          "1",                                                       "\"host\"",
        "{\"address\":\"host\"}",                                    "{\"port\":80}",                                                   "{\"address\":\"host\",\"port\":0}",                             "{\"address\":\"host\",\"port\":65536}",                   "{\"address\":\"host\",\"port\":-1}",
        "{\"address\":\"host\",\"port\":80.0}",                      "{\"address\":\"host\",\"port\":8e1}",                             "{\"address\":\"host\",\"port\":true}",                          "{\"address\":\"host\",\"port\":\"80\"}",                  "{\"address\":\"host\",\"port\":null}",
        "{\"address\":\"host\",\"port\":80,\"extra\":1}",            "{\"address\":\"host\",\"address\":\"other\",\"port\":80}",        "{\"address\":\"host\",\"port\":80,\"port\":81}",                "{\"address\":\"host\",\"port\":80,\"models\":null}",      "{\"address\":\"host\",\"port\":80,\"models\":\"p/m\"}",
        "{\"address\":\"host\",\"port\":80,\"models\":[1]}",         "{\"address\":\"host\",\"port\":80,\"models\":[\"p/m\",\"p/m\"]}", "{\"address\":\"host\",\"port\":80,\"models\":[\"missing/m\"]}", "{\"address\":\"host\",\"port\":80,\"models\":[\"p/*\"]}", "{\"address\":\"host\",\"port\":80,\"models\":[\"p/m?\"]}",
        "{\"address\":\"host\",\"port\":80,\"models\":[\"p/[m]\"]}", "{\"address\":\"host\",\"port\":80,\"models\":[\"m\"]}",           "{\"address\":\"host\",\"port\":80,\"models\":[\"p/\"]}",
    }) |value| {
        const text = try std.mem.concat(a, u8, &.{ proxy_prefix, ",\"proxy\":", value, "}" });
        defer a.free(text);
        if (cfg.parse(a, text)) |v| {
            var unexpected = v;
            cfg.release(&unexpected);
            return error.ExpectedRejection;
        } else |_| {}
    }
    var p = try cfg.parse(a, proxy_fixture);
    defer cfg.release(&p);
    for ([_][]const u8{ "", "http://host", "https://host", "user@host", "host:80", "host/path", "host?query", "host#frag", "[::1]", "::g", "fe80::1%eth0", " host", "host\n", "host\x00", "中文", ".", "a..b", "-host", "host-", "host_1", "host\\path" }) |host| {
        p.value.proxy.?.address = host;
        try t.expectError(error.InvalidProxyAddress, cfg.validate(p.value));
        try t.expectError(error.InvalidProxyAddress, p.value.proxy.?.url(a));
    }
    var long: [254]u8 = undefined;
    @memset(&long, 'a');
    p.value.proxy.?.address = &long;
    try t.expectError(error.InvalidProxyAddress, cfg.validate(p.value));
    for ([_][]const u8{ "localhost", "proxy.example", "127.0.0.1", "::1", "2001:db8::1" }) |host| {
        p.value.proxy.?.address = host;
        p.value.proxy.?.port = 65535;
        try cfg.validate(p.value);
        const url = try p.value.proxy.?.url(a);
        defer a.free(url);
        try t.expect(std.mem.startsWith(u8, url, "http://"));
    }
    var names: [129][]const u8 = undefined;
    for (&names) |*name| name.* = "p/m";
    p.value.proxy.?.models = &names;
    try t.expectError(error.TooManyProxyModels, cfg.validate(p.value));
}

test "HTTP proxy empty list explicit persistence and 128 exact dynamic IDs" {
    const a = t.allocator;
    var p = try cfg.parse(a, proxy_prefix ++ ",\"proxy\":{\"address\":\"proxy.example\",\"port\":1}}");
    defer cfg.release(&p);
    try t.expectEqual(@as(usize, 0), p.value.proxy.?.models.len);
    try t.expect(p.value.proxyFor("p", "vendor/raw/id") == null);
    const url = try p.value.proxy.?.url(a);
    defer a.free(url);
    try t.expectEqualStrings("http://proxy.example:1", url);
    var names: [128][]const u8 = undefined;
    for (&names, 0..) |*name, i| name.* = try std.fmt.allocPrint(p.arena.allocator(), "p/dynamic/raw/{d}", .{i});
    p.value.proxy.?.models = &names;
    try cfg.validate(p.value);
    try t.expect(p.value.proxyFor("p", "dynamic/raw/127") != null);
    try t.expect(p.value.proxyFor("other", "dynamic/raw/127") == null);
    var copy = try cfg.clone(a, p.value);
    defer cfg.release(&copy);
    try t.expect(copy.value.proxy.?.models.ptr != names[0..].ptr);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(copy.value, &out.writer);
    var disk = try cfg.parse(a, out.written());
    defer cfg.release(&disk);
    try t.expectEqualDeep(copy.value.proxy, disk.value.proxy);
    try t.expectError(error.DuplicateField, cfg.parse(a, proxy_prefix ++ ",\"proxy\":null,\"proxy\":null}"));
}

fn proxyAllocationExercise(a: std.mem.Allocator) !void {
    var p = try cfg.parse(a, proxy_fixture);
    defer cfg.release(&p);
    var copy = try cfg.clone(a, p.value);
    defer cfg.release(&copy);
    const url = try copy.value.proxy.?.url(a);
    defer a.free(url);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // This in-memory Allocating writer can fail writes only through its
    // backing allocator; restore the OOM category for the exhaustive sweep.
    cfg.writeDisk(copy.value, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    var disk = try cfg.parse(a, out.written());
    defer cfg.release(&disk);
    try t.expectEqualDeep(copy.value.proxy, disk.value.proxy);
}

test "HTTP proxy parse clone url disk allocation failures release ownership" {
    try t.checkAllAllocationFailures(t.allocator, proxyAllocationExercise, .{});
}

test "optional global decision owns qualified model and sparsely persists" {
    const a = t.allocator;
    const prefix = "{\"llm\":{\"default\":\"p/chat\",\"providers\":{\"p\":{\"base_url\":\"https://fixture.invalid\"},\"aux\":{\"base_url\":\"https://aux.invalid\"}}}";
    var baseline = try cfg.parse(a, prefix ++ "}");
    defer cfg.release(&baseline);
    try t.expect(!baseline.value.decisionActive());
    var absent: std.Io.Writer.Allocating = .init(a);
    defer absent.deinit();
    try cfg.writeDisk(baseline.value, &absent.writer);
    try t.expect(std.mem.find(u8, absent.written(), "decision") == null);
    var explicit_null = try cfg.parse(a, prefix ++ ",\"decision\":null}");
    defer cfg.release(&explicit_null);
    try t.expect(!explicit_null.value.decisionActive());
    var null_out: std.Io.Writer.Allocating = .init(a);
    defer null_out.deinit();
    try cfg.writeDisk(explicit_null.value, &null_out.writer);
    try t.expectEqualStrings(absent.written(), null_out.written());
    var parsed = try cfg.parse(a, prefix ++ ",\"decision\":{\"model\":\"aux/vendor/raw/id\"}}");
    defer cfg.release(&parsed);
    try t.expect(parsed.value.decision.?.enabled);
    try t.expect(parsed.value.decisionActive());
    try t.expectEqualStrings("p/chat", parsed.value.registry.?.default);
    try t.expectEqualStrings("vendor/raw/id", (try cfg.splitDefault(parsed.value.decision.?.model)).model);
    const auxiliary = parsed.value.decision.?.modelLimits(parsed.value.limits.request_timeout_ms);
    try t.expectEqual(parsed.value.limits.request_timeout_ms, auxiliary.request_timeout_ms);
    try t.expect(!auxiliary.low_price_input);
    try t.expectEqual(@as(u32, 8192), parsed.value.decision.?.max_input_tokens);
    // Auxiliary limits retain input protection, not a local output ceiling.
    try t.expectEqual(@as(?u32, 8192), auxiliary.max_input_tokens);
    var copy = try cfg.clone(a, parsed.value);
    defer cfg.release(&copy);
    try t.expect(copy.value.decision.?.model.ptr != parsed.value.decision.?.model.ptr);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(copy.value, &out.writer);
    var disk = try cfg.parse(a, out.written());
    defer cfg.release(&disk);
    try t.expectEqualDeep(copy.value.decision, disk.value.decision);
    // Reference validation never invents a protocol/window or borrows chat capabilities.
    try t.expect(disk.value.registry.?.find("aux").?.patchFor("vendor/raw/id") == null);
    for ([_][]const u8{
        "{}",                                                   "[]",                                                 "false",                                          "1",                                                 "\"aux/m\"",
        "{\"model\":\"missing/m\"}",                            "{\"model\":\"m\"}",                                  "{\"model\":\"p/\"}",                             "{\"model\":1}",                                     "{\"model\":null}",
        "{\"model\":\"p/m\",\"model\":\"p/n\"}",                "{\"model\":\"p/m\",\"extra\":true}",                 "{\"model\":\"p/m\",\"max_input_tokens\":1}",     "{\"model\":\"p/m\",\"max_input_tokens\":16777217}", "{\"model\":\"p/m\",\"max_output_tokens\":0}",
        "{\"model\":\"p/m\",\"max_output_tokens\":1024}",       "{\"model\":\"p/m\",\"max_output_tokens\":16777217}", "{\"model\":\"p/m\",\"max_output_tokens\":null}", "{\"model\":\"p/m\",\"max_output_tokens\":true}",    "{\"model\":\"p/m\",\"max_output_tokens\":-1}",
        "{\"model\":\"p/m\",\"max_output_tokens\":4294967296}",
    }) |value| {
        const raw = try std.mem.concat(a, u8, &.{ prefix, ",\"decision\":", value, "}" });
        defer a.free(raw);
        if (cfg.parse(a, raw)) |v| {
            var unexpected = v;
            cfg.release(&unexpected);
            return error.ExpectedRejection;
        } else |_| {}
    }
    copy.value.decision.?.max_input_tokens = 1;
    try t.expectError(error.InvalidLimit, cfg.clone(a, copy.value));
    copy.value.decision.?.max_input_tokens = 2;
    copy.value.limits.request_timeout_ms = 3600000;
    try cfg.validate(copy.value);
    copy.value.registry = null;
    try t.expectError(error.MissingRegistry, cfg.validate(copy.value));
}

test "decision enabled strict bool rejects null duplicates unknown and root overlay" {
    const a = t.allocator;
    for ([_][]const u8{ "true", "false" }) |value| {
        const raw = try std.mem.concat(a, u8, &.{ proxy_prefix, ",\"decision\":{\"model\":\"p/aux\",\"enabled\":", value, "}}" });
        defer a.free(raw);
        var parsed = try cfg.parse(a, raw);
        defer cfg.release(&parsed);
        try t.expectEqual(std.mem.eql(u8, value, "true"), parsed.value.decisionActive());
    }
    for ([_][]const u8{
        "null", "0", "1", "0.0", "1e0", "\"false\"", "[]", "{}",
    }) |value| {
        const raw = try std.mem.concat(a, u8, &.{ proxy_prefix, ",\"decision\":{\"model\":\"p/aux\",\"enabled\":", value, "}}" });
        defer a.free(raw);
        if (cfg.parse(a, raw)) |v| {
            var unexpected = v;
            cfg.release(&unexpected);
            return error.ExpectedRejection;
        } else |_| {}
    }
    try t.expectError(error.DuplicateField, cfg.parse(a, proxy_prefix ++ ",\"decision\":{\"model\":\"p/aux\",\"enabled\":false,\"enabled\":true}}"));
    try t.expectError(error.UnknownField, cfg.parse(a, proxy_prefix ++ ",\"decision\":{\"model\":\"p/aux\",\"enabled\":false,\"unknown\":true}}"));
    try t.expectError(error.UnknownField, cfg.parse(a, proxy_prefix ++ ",\"decision_enabled\":false}"));
    try t.expectError(error.UnknownField, cfg.parse(a, proxy_prefix ++ ",\"decision_enabled\":true,\"decision\":{\"model\":\"p/aux\",\"enabled\":false}}"));
}

test "disabled decision roundtrip preserves declared protocol credentials shared limits and proxy" {
    const a = t.allocator;
    const input =
        \\{"llm":{"default":"p/chat","reasoning_effort":"high","providers":{"p":{"base_url":"https://fixture.invalid/v1","api_key":"fixture-key","models":{"chat":{"context_tokens":65536},"aux/raw":{"protocol":"systemone","output_tokens":1234}}},"other":{"base_url":"https://other.invalid","api_key_env":"FIXTURE_KEY"}}},"decision":{"model":"p/aux/raw","enabled":false,"max_input_tokens":4321,"max_state_bytes":8192},"limits":{"low_price_input":false,"request_timeout_ms":1234,"max_input_tokens":50000},"proxy":{"address":"localhost","port":8080,"models":["p/aux/raw"]}}
    ;
    var parsed = try cfg.parse(a, input);
    defer cfg.release(&parsed);
    try t.expect(!parsed.value.decision.?.enabled);
    try t.expect(!parsed.value.decisionActive());
    var copy = try cfg.clone(a, parsed.value);
    defer cfg.release(&copy);
    try t.expect(!copy.value.decisionActive());
    try t.expectEqualDeep(parsed.value.decision, copy.value.decision);
    // A resolved runtime model must not replace persisted model declarations.
    copy.value.model.name = "runtime-only-model";
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(copy.value, &out.writer);
    try t.expect(std.mem.find(u8, out.written(), "decision_enabled") == null);
    try t.expect(std.mem.find(u8, out.written(), "runtime-only-model") == null);
    const encoded = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer encoded.deinit();
    const decision_object = encoded.value.object.get("decision").?.object;
    try t.expectEqual(@as(usize, 4), decision_object.count());
    try t.expect(decision_object.get("max_output_tokens") == null);
    try t.expect(decision_object.get("backend") == null);
    try t.expect(decision_object.get("request_timeout_ms") == null);
    var disk = try cfg.parse(a, out.written());
    defer cfg.release(&disk);
    try t.expect(!disk.value.decisionActive());
    try t.expectEqualDeep(parsed.value.decision, disk.value.decision);
    try t.expectEqualDeep(parsed.value.registry, disk.value.registry);
    try t.expectEqualDeep(parsed.value.limits, disk.value.limits);
    try t.expectEqualDeep(parsed.value.proxy, disk.value.proxy);
    try t.expectEqualStrings("fixture-key", disk.value.registry.?.find("p").?.connection.api_key.?);
    try t.expectEqualStrings("FIXTURE_KEY", disk.value.registry.?.find("other").?.connection.api_key_env);
    copy.value.decision.?.enabled = true;
    try t.expect(copy.value.decisionActive());
    try t.expect(!parsed.value.decisionActive());
    try t.expect(!disk.value.decisionActive());
}

test "SystemOne exact model declaration owns protocol and byte bounds without primary guesses" {
    const prefix = "{\"llm\":{\"default\":\"main/chat\",\"providers\":{\"main\":{\"base_url\":\"https://api.deepseek.com\"},\"aux\":{\"base_url\":\"https://native-fixture.invalid/v1\",\"models\":{\"judge/raw\":{\"protocol\":\"systemone\"}}}}}";
    var p = try cfg.parse(t.allocator, prefix ++ ",\"decision\":{\"model\":\"aux/judge/raw\",\"max_state_bytes\":8192}}");
    defer cfg.release(&p);
    try t.expect(p.value.registry.?.find("aux").?.patchFor("judge/raw").?.protocol == .systemone);
    try t.expectEqual(@as(u32, 8192), p.value.decision.?.max_state_bytes);
    try t.expect(p.value.registry.?.find("aux").?.patchFor("judge/raw").?.context_tokens == null);
    var copy = try cfg.clone(t.allocator, p.value);
    defer cfg.release(&copy);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try cfg.writeDisk(copy.value, &out.writer);
    var roundtrip = try cfg.parse(t.allocator, out.written());
    defer cfg.release(&roundtrip);
    try t.expectEqualDeep(copy.value.decision, roundtrip.value.decision);
    for ([_][]const u8{
        "{\"model\":\"aux/m\",\"max_state_bytes\":0}",
        "{\"model\":\"aux/m\",\"max_state_bytes\":65537}",
        "{\"model\":\"aux/m\",\"max_state_bytes\":2.0}",
    }) |bad| {
        const text = try std.mem.concat(t.allocator, u8, &.{ prefix, ",\"decision\":", bad, "}" });
        defer t.allocator.free(text);
        if (cfg.parse(t.allocator, text)) |parsed| {
            var unexpected = parsed;
            cfg.release(&unexpected);
            return error.ExpectedRejection;
        } else |_| {}
    }
    const providers = @constCast(copy.value.registry.?.providers);
    providers[1].connection.base_url = "https://opencode.ai/zen/go/v1";
    try cfg.validate(copy.value);
    try t.expect(copy.value.registry.?.find("aux").?.patchFor("judge/raw").?.protocol == .systemone);
    providers[1].connection.base_url = "https://opencode.ai/zen/v1";
    try cfg.validate(copy.value);
}

const fixture =
    \\{"llm":{"default":"custom/vendor/model","providers":{"custom":{"base_url":"https://proxy.invalid/v1","api_key_env":"CUSTOM_KEY","models":{"vendor/model":{"context_tokens":65536,"reasoning_effort":null},"auto":{"protocol":"auto"}}},"other":{"base_url":"https://other.invalid","api_key":"fake-backup","models":{"vendor/model":{"output_tokens":1234,"reasoning":{"format":"anthropic","map":{"high":"high"}}}}}}}}
;

test "llm registry presence isolation roundtrip frozen clone and candidate changes" {
    var p = try cfg.parse(t.allocator, fixture);
    defer cfg.release(&p);
    try t.expect(p.value.selection_pending);
    try t.expectEqualStrings("custom", p.value.selected_provider.?);
    try t.expectEqualStrings("vendor/model", p.value.model.name);
    try t.expect(p.value.model.context_tokens == 32768);
    const registry = p.value.registry.?;
    const patch = registry.find("custom").?.patchFor("vendor/model").?;
    try t.expect(patch.protocol == null and patch.reasoning_effort == null);
    try t.expect(registry.find("custom").?.patchFor("auto").?.protocol.? == .auto);
    try t.expect(patch.output_tokens == null);
    try t.expect(registry.find("other").?.patchFor("vendor/model").?.output_tokens.? == 1234);
    var active = p.value;
    active.selection_pending = false;
    active.model = .{ .name = "frozen-model", .context_tokens = 100000, .protocol = .responses, .output_tokens = 9000, .output_source = .metadata, .reasoning = .{ .map = .{ .high = "frozen-wire" } }, .reasoning_source = .metadata, .reasoning_effort = "high" };
    var copy = try cfg.clone(t.allocator, active);
    defer cfg.release(&copy);
    try t.expect(!copy.value.selection_pending);
    try t.expectEqualStrings("frozen-model", copy.value.model.name);
    try t.expect(copy.value.model.output_source == .metadata);
    try t.expectEqualStrings("frozen-wire", copy.value.model.reasoning.?.map.high.?);
    try t.expect(copy.value.registry.?.providers.ptr != registry.providers.ptr);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try cfg.writeDisk(copy.value, &out.writer);
    try t.expect(std.mem.find(u8, out.written(), "frozen") == null);
    try t.expect(std.mem.find(u8, out.written(), "selection_pending") == null);
    var disk = try cfg.parse(t.allocator, out.written());
    defer cfg.release(&disk);
    try t.expect(disk.value.selection_pending);
    try t.expectEqualStrings("CUSTOM_KEY", disk.value.registry.?.find("custom").?.connection.api_key_env);
    try t.expectEqualStrings("fake-backup", disk.value.registry.?.find("other").?.connection.api_key.?);
    const a = copy.arena.allocator();
    try cfg.setRegistryCredential(a, &copy.value, "other", "fake-new");
    try cfg.setRegistryDefault(a, &copy.value, "other", "new/raw/id");
    try t.expectEqualStrings("custom/vendor/model", registry.default);
    try t.expectEqualStrings("fake-backup", registry.find("other").?.connection.api_key.?);
    try t.expectEqualStrings("other/new/raw/id", copy.value.registry.?.default);
    try t.expectEqualStrings("fake-new", copy.value.registry.?.find("other").?.connection.api_key.?);
    const applied = (cfg.ModelPatch{ .reasoning = .{ .map = .{ .low = "low" } }, .output_tokens = 12 }).apply(active.model);
    try t.expect(applied.reasoning.?.map.high == null);
    try t.expect(applied.reasoning_source == .explicit and applied.output_source == .explicit);
}

test "llm registry strict root fields duplicate fields and malformed declarations" {
    const bad = [_][]const u8{
        \\{"llm":{"default":"a/m","providers":{}},"provider":{}}
        ,
        \\{"llm":{"default":"a/m","providers":{}},"credentials":{}}
        ,
        \\{"llm":{"default":"a/m","providers":{},"model":"x"}}
        ,
        \\{"llm":{"default":"a/m","default":"a/n","providers":{}}}
        ,
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://x","models":{"m":{"context_tokens":0}}}}}}
        ,
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://x","models":{"m":{"context_tokens":1.5}}}}}}
        ,
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://x","models":{"m":{"context_tokens":4294967296}}}}}}
        ,
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://x","models":{"m":{"name":"evil"}}}}}}
        ,
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://x","models":{"m":{"protocol":"auto","protocol":"chat"}}}}}}
        ,
        \\{"llm":{"default":"a/m","providers":{"a":{"base_url":"https://x","api_key":"fake\nkey"}}}}
        ,
        \\{"llm":{"default":"a/m","providers":{"bad/name":{"base_url":"https://x"}}}}
        ,
        \\{"llm":{"default":"missing/m","providers":{"a":{"base_url":"https://x"}}}}
        ,
        \\{"provider":{"base_url":"https://x"},"model":{"name":"m","context_tokens":32768},"selection_pending":false}
        ,
    };
    for (bad) |bytes| {
        if (cfg.parse(t.allocator, bytes)) |value| {
            var unexpected = value;
            cfg.release(&unexpected);
            return error.ExpectedRejection;
        } else |_| {}
    }
}

test "global reasoning preference roundtrips independently of model capability" {
    for ([_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |name| {
        const raw = try std.fmt.allocPrint(
            t.allocator,
            "{{\"llm\":{{\"default\":\"p/m\",\"reasoning_effort\":\"{s}\",\"providers\":{{\"p\":{{\"base_url\":\"https://x\"}}}}}}}}",
            .{name},
        );
        defer t.allocator.free(raw);
        var parsed = try cfg.parse(t.allocator, raw);
        defer cfg.release(&parsed);
        try t.expectEqualStrings(name, parsed.value.registry.?.reasoning_effort.?);
        // A preference alone must never authorize an unknown model capability.
        try t.expect(parsed.value.model.reasoning == null);
        try t.expect(parsed.value.model.reasoning_effort == null);
        var copy = try cfg.clone(t.allocator, parsed.value);
        defer cfg.release(&copy);
        try t.expectEqualStrings(name, copy.value.registry.?.reasoning_effort.?);
        try t.expect(copy.value.registry.?.reasoning_effort.?.ptr != parsed.value.registry.?.reasoning_effort.?.ptr);
        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try cfg.writeDisk(copy.value, &out.writer);
        var disk = try cfg.parse(t.allocator, out.written());
        defer cfg.release(&disk);
        try t.expectEqualStrings(name, disk.value.registry.?.reasoning_effort.?);
    }
}

test "global reasoning preference rejects unknown duplicate and wrong type" {
    for ([_][]const u8{ "\"none\"", "\"unknown\"", "\"HIGH\"", "\"\"", "\" high\"", "0", "true", "[]", "{}", "\"high\",\"reasoning_effort\":\"low\"" }) |value| {
        const raw = try std.mem.concat(t.allocator, u8, &.{
            "{\"llm\":{\"default\":\"p/m\",\"providers\":{\"p\":{\"base_url\":\"https://x\"}},\"reasoning_effort\":", value, "}}",
        });
        defer t.allocator.free(raw);
        if (cfg.parse(t.allocator, raw)) |result| {
            var unexpected = result;
            cfg.release(&unexpected);
            return error.ExpectedRejection;
        } else |_| {}
    }
    var parsed = try cfg.parse(t.allocator, fixture);
    defer cfg.release(&parsed);
    parsed.value.registry.?.reasoning_effort = "unknown";
    try t.expectError(error.InvalidReasoningEffort, cfg.validate(parsed.value));
    try t.expectError(error.InvalidReasoningEffort, cfg.clone(t.allocator, parsed.value));
}

test "global reasoning preference setter owns rejects aliases and preserves declarations" {
    var parsed = try cfg.parse(t.allocator, fixture);
    defer cfg.release(&parsed);
    try t.expect(parsed.value.registry.?.reasoning_effort == null);
    var copy = try cfg.clone(t.allocator, parsed.value);
    defer cfg.release(&copy);
    const a = copy.arena.allocator();
    const original = copy.value.registry.?;
    const active = copy.value.model;
    var name = [_]u8{ 'h', 'i', 'g', 'h' };
    try cfg.setRegistryReasoningEffort(a, &copy.value, &name);
    @memset(&name, 'x');
    try t.expectEqualStrings("high", copy.value.registry.?.reasoning_effort.?);
    try t.expect(parsed.value.registry.?.reasoning_effort == null);
    const before = copy.value.registry.?.reasoning_effort.?;
    try t.expectError(error.InvalidReasoningEffort, cfg.setRegistryReasoningEffort(a, &copy.value, "unknown"));
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, cfg.setRegistryReasoningEffort(failing.allocator(), &copy.value, "low"));
    try t.expect(copy.value.registry.?.reasoning_effort.?.ptr == before.ptr);
    try t.expectError(error.InvalidReasoningEffort, cfg.setRegistryReasoningEffort(a, &copy.value, "none"));
    try t.expect(copy.value.registry.?.reasoning_effort.?.ptr == before.ptr);
    try cfg.setRegistryReasoningEffort(a, &copy.value, "off");
    try t.expectEqualStrings("off", copy.value.registry.?.reasoning_effort.?);
    try t.expectEqualStrings(original.default, copy.value.registry.?.default);
    try t.expect(original.providers.ptr == copy.value.registry.?.providers.ptr);
    try t.expectEqualDeep(active, copy.value.model);
    try t.expectEqualDeep(parsed.value.provider, copy.value.provider);
    try t.expectEqualDeep(parsed.value.limits, copy.value.limits);
    try t.expectEqual(parsed.value.selection_pending, copy.value.selection_pending);
    try t.expectEqualStrings(parsed.value.selected_provider.?, copy.value.selected_provider.?);
    var runtime = parsed.value;
    runtime.registry = null;
    try t.expectError(error.MissingRegistry, cfg.setRegistryReasoningEffort(a, &runtime, "high"));

    // Disk authority remains manual patches, never active metadata.
    copy.value.model = .{ .name = "metadata-only", .context_tokens = 100000, .protocol = .responses, .reasoning_effort = "high", .reasoning = .{ .map = .{ .high = "metadata-wire" } }, .reasoning_source = .metadata, .output_tokens = 9999, .output_source = .metadata, .input_price_threshold = 50000, .input_price_flat_limit = 90000 };
    const persisted = copy.value.model.persisted();
    try t.expect(persisted.reasoning == null and persisted.reasoning_effort == null);
    try t.expect(persisted.output_tokens == null and persisted.input_price_threshold == null and persisted.input_price_flat_limit == null);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try cfg.writeDisk(copy.value, &out.writer);
    for ([_][]const u8{ "metadata-only", "metadata-wire", "9999", "input_price_threshold", "input_price_flat_limit" }) |forbidden| {
        try t.expect(std.mem.find(u8, out.written(), forbidden) == null);
    }
    var disk = try cfg.parse(t.allocator, out.written());
    defer cfg.release(&disk);
    try t.expectEqualStrings("off", disk.value.registry.?.reasoning_effort.?);
    try t.expectEqualDeep(original.providers, disk.value.registry.?.providers);
}

test "global preference does not reinterpret manual per model wire effort" {
    var parsed = try cfg.parse(t.allocator,
        \\{"llm":{"default":"p/m","reasoning_effort":"max","providers":{"p":{"base_url":"https://x","models":{"m":{"reasoning_effort":"none","output_tokens":1234}}}}}}
    );
    defer cfg.release(&parsed);
    try cfg.setRegistryReasoningEffort(parsed.arena.allocator(), &parsed.value, "off");
    try t.expectEqualStrings("none", parsed.value.registry.?.find("p").?.patchFor("m").?.reasoning_effort.?);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try cfg.writeDisk(parsed.value, &out.writer);
    var disk = try cfg.parse(t.allocator, out.written());
    defer cfg.release(&disk);
    try t.expectEqualStrings("off", disk.value.registry.?.reasoning_effort.?);
    try t.expectEqualStrings("none", disk.value.registry.?.find("p").?.patchFor("m").?.reasoning_effort.?);
    try t.expectEqual(@as(u32, 1234), disk.value.registry.?.find("p").?.patchFor("m").?.output_tokens.?);
}

test "absent and null global reasoning preferences stay sparse" {
    for ([_][]const u8{ "", ",\"reasoning_effort\":null" }) |field| {
        const raw = try std.mem.concat(t.allocator, u8, &.{ "{\"llm\":{\"default\":\"p/m\",\"providers\":{\"p\":{\"base_url\":\"https://x\"}}", field, "}}" });
        defer t.allocator.free(raw);
        var parsed = try cfg.parse(t.allocator, raw);
        defer cfg.release(&parsed);
        try t.expect(parsed.value.registry.?.reasoning_effort == null);
        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try cfg.writeDisk(parsed.value, &out.writer);
        try t.expect(std.mem.find(u8, out.written(), "reasoning_effort") == null);
    }
}

fn allocationCase(a: std.mem.Allocator) !void {
    var p = try cfg.parse(a, fixture);
    defer cfg.release(&p);
    var copy = try cfg.clone(a, p.value);
    defer cfg.release(&copy);
}

test "llm registry allocation failure paths release all owned arenas" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}

test "llm registry count limits and default need not be manually declared" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"llm\":{\"default\":\"p0/raw/id\",\"providers\":{");
    for (0..17) |i| {
        if (i != 0) try out.writer.writeAll(",");
        try out.writer.print("\"p{d}\":{{\"base_url\":\"https://x\"}}", .{i});
    }
    try out.writer.writeAll("}}}");
    try t.expectError(error.TooManyProviders, cfg.parse(t.allocator, out.written()));
    out.clearRetainingCapacity();
    try out.writer.writeAll("{\"llm\":{\"default\":\"p/missing\",\"providers\":{\"p\":{\"base_url\":\"https://x\",\"models\":{");
    for (0..64) |i| {
        if (i != 0) try out.writer.writeAll(",");
        try out.writer.print("\"m{d}\":{{}}", .{i});
    }
    const prefix_len = out.written().len;
    try out.writer.writeAll("}}}}}");
    var p = try cfg.parse(t.allocator, out.written());
    defer cfg.release(&p);
    try t.expect(p.value.registry.?.providers[0].models.len == 64);
    out.writer.end = prefix_len;
    try out.writer.writeAll(",\"extra\":{}}}}}}");
    try t.expectError(error.TooManyModels, cfg.parse(t.allocator, out.written()));
}

test "disk schema requires llm and rejects every former root and runtime field" {
    try t.expectError(error.MissingField, cfg.parse(t.allocator, "{}"));
    try t.expectError(error.MissingField, cfg.parse(t.allocator, "{\"limits\":{}}"));
    inline for (.{ "provider", "model", "models", "credentials", "registry", "selected_provider", "selection_pending" }) |field| {
        const old = "{\"" ++ field ++ "\":null}";
        try t.expectError(error.UnknownField, cfg.parse(t.allocator, old));
    }
    try t.expectError(error.UnknownField, cfg.parse(t.allocator,
        \\{"provider":{"base_url":"https://api.deepseek.com"},"model":{"name":"deepseek-flash","context_tokens":1000000}}
    ));
}

test "registry limits and model patches reject coerced numeric and boolean values" {
    const prefix = "{\"llm\":{\"default\":\"p/m\",\"providers\":{\"p\":{\"base_url\":\"https://x\"}}},\"limits\":";
    for ([_][]const u8{ "{\"max_rounds\":\"50\"}", "{\"read_bytes\":1.0}", "{\"max_input_tokens\":\"90000\"}", "{\"low_price_input\":\"false\"}", "{\"read_bytes\":null}", "{\"unknown\":1}" }) |limits| {
        const raw = try std.mem.concat(t.allocator, u8, &.{ prefix, limits, "}" });
        defer t.allocator.free(raw);
        if (cfg.parse(t.allocator, raw)) |value| {
            var unexpected = value;
            cfg.release(&unexpected);
            return error.ExpectedRejection;
        } else |_| {}
    }
    try t.expectError(error.InvalidNumber, cfg.parse(t.allocator,
        \\{"llm":{"default":"p/m","providers":{"p":{"base_url":"https://x","models":{"m":{"context_tokens":"65536"}}}}}}
    ));
    try t.expectError(error.UnknownField, cfg.parse(t.allocator,
        \\{"llm":{"default":"p/m","providers":{"p":{"base_url":"https://x","models":{"m":{"input_price_threshold":100000}}}}}}
    ));
}

test "login credential edits replace only the selected registry source and own secrets" {
    var parsed = try cfg.parse(t.allocator, fixture);
    defer cfg.release(&parsed);
    var candidate = try cfg.clone(t.allocator, parsed.value);
    defer cfg.release(&candidate);
    var key = [_]u8{ 'f', 'a', 'k', 'e', '-', 'n', 'e', 'w' };
    try cfg.setRegistryCredential(candidate.arena.allocator(), &candidate.value, "custom", &key);
    @memset(&key, 'x');
    try t.expectEqualStrings("fake-new", candidate.value.provider.api_key.?);
    try t.expectEqualStrings("", candidate.value.provider.api_key_env);
    try t.expectEqualStrings("CUSTOM_KEY", parsed.value.provider.api_key_env);
    try t.expect(parsed.value.provider.api_key == null);
    try t.expectEqualStrings("fake-backup", candidate.value.registry.?.find("other").?.connection.api_key.?);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("CUSTOM_KEY", "fake-env");
    const resolved = try cfg.resolveApiKey(t.allocator, candidate.value, &env);
    defer {
        std.crypto.secureZero(u8, resolved);
        t.allocator.free(resolved);
    }
    try t.expectEqualStrings("fake-new", resolved);
    try t.expect(resolved.ptr != candidate.value.provider.api_key.?.ptr);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try cfg.writeDisk(candidate.value, &out.writer);
    var disk = try cfg.parse(t.allocator, out.written());
    defer cfg.release(&disk);
    try t.expectEqualStrings("fake-new", disk.value.provider.api_key.?);
    try t.expectEqualStrings("", disk.value.provider.api_key_env);
    try t.expectError(error.UnknownProvider, cfg.setRegistryCredential(candidate.arena.allocator(), &candidate.value, "missing", "fake"));
    try t.expectError(error.InvalidApiKey, cfg.setRegistryCredential(candidate.arena.allocator(), &candidate.value, "custom", "bad\rkey"));
    try t.expectEqualStrings("fake-new", candidate.value.provider.api_key.?);
}
