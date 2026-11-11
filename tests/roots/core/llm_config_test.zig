const std = @import("std");
const cfg = @import("config.zig");
const t = std.testing;

const proxy_prefix = "{\"llm\":{\"default\":\"p/vendor/raw/id\",\"providers\":{\"p\":{\"base_url\":\"https://fixture.invalid/v1\"},\"other\":{\"base_url\":\"https://fixture.invalid/v1\"}}}";
const proxy_fixture = proxy_prefix ++ ",\"proxy\":{\"address\":\"::1\",\"port\":8080,\"models\":[\"p/vendor/raw/id\"]}}";

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

const fixture =
    \\{"llm":{"default":"custom/vendor/model","providers":{"custom":{"base_url":"https://proxy.invalid/v1","api_key_env":"CUSTOM_KEY","models":{"vendor/model":{"context_tokens":65536,"reasoning_effort":null},"auto":{"protocol":"auto"}}},"other":{"base_url":"https://other.invalid","api_key":"fake-backup","models":{"vendor/model":{"output_tokens":1234,"reasoning":{"format":"anthropic","map":{"high":"high"}}}}}}}}
;

fn allocationCase(a: std.mem.Allocator) !void {
    var p = try cfg.parse(a, fixture);
    defer cfg.release(&p);
    var copy = try cfg.clone(a, p.value);
    defer cfg.release(&copy);
}
