const std = @import("std");
const cfg = @import("config.zig");
const t = std.testing;
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
    for ([_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max", "none" }) |name| {
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
    for ([_][]const u8{ "\"unknown\"", "\"HIGH\"", "\"\"", "\" high\"", "0", "true", "[]", "{}", "\"high\",\"reasoning_effort\":\"low\"" }) |value| {
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

test "global reasoning preference setter owns normalizes and preserves declarations" {
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
    try cfg.setRegistryReasoningEffort(a, &copy.value, "none");
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
        \\{"llm":{"default":"p/m","reasoning_effort":"max","providers":{"p":{"base_url":"https://x","models":{"m":{"reasoning_effort":"custom-wire-value","output_tokens":1234}}}}}}
    );
    defer cfg.release(&parsed);
    try cfg.setRegistryReasoningEffort(parsed.arena.allocator(), &parsed.value, "none");
    try t.expectEqualStrings("custom-wire-value", parsed.value.registry.?.find("p").?.patchFor("m").?.reasoning_effort.?);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try cfg.writeDisk(parsed.value, &out.writer);
    var disk = try cfg.parse(t.allocator, out.written());
    defer cfg.release(&disk);
    try t.expectEqualStrings("off", disk.value.registry.?.reasoning_effort.?);
    try t.expectEqualStrings("custom-wire-value", disk.value.registry.?.find("p").?.patchFor("m").?.reasoning_effort.?);
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
