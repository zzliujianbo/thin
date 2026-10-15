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
    try t.expect(p.value.model.context_tokens == 32768 and p.value.models.len == 0);
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
