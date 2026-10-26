//! Pure global-declaration editing for the explicit HTTP proxy allowlist.
//! Address/port are owned elsewhere; this module only keeps exact per-model
//! membership and never guesses a route for an undeclared identity.
const std = @import("std");
const cfg = @import("../core/config.zig");
const decision_selection = @import("decision_selection.zig");

/// Exact alias/raw-ID membership. Duplicate adds and absent removals are
/// intentional no-write no-ops. Existing order is preserved; new names append.
/// The caller revalidates the row and its local credential before saving.
pub fn apply(a: std.mem.Allocator, config: *cfg.Config, name: []const u8, enabled: bool) !bool {
    _ = try cfg.splitDefault(name);
    const proxy = config.proxy orelse return error.ProxyNotConfigured;
    for (proxy.models, 0..) |existing, index| {
        if (!std.mem.eql(u8, existing, name)) continue;
        if (enabled) return false;
        const models = try a.alloc([]const u8, proxy.models.len - 1);
        @memcpy(models[0..index], proxy.models[0..index]);
        @memcpy(models[index..], proxy.models[index + 1 ..]);
        config.proxy.?.models = models;
        return true;
    }
    if (!enabled) return false;
    if (proxy.models.len >= 128) return error.TooManyProxyModels;
    const models = try a.alloc([]const u8, proxy.models.len + 1);
    @memcpy(models[0..proxy.models.len], proxy.models);
    models[proxy.models.len] = try a.dupe(u8, name);
    config.proxy.?.models = models;
    return true;
}

/// Deep-copy a declaration's proxy into arena-owned storage. Only an explicit
/// proxy settings save may call this for a not-yet-active pending snapshot.
fn adopt(a: std.mem.Allocator, config: *cfg.Config, proxy: ?cfg.ProxyConfig) !void {
    if (proxy) |value| {
        const models = try a.alloc([]const u8, value.models.len);
        for (value.models, 0..) |name, index| models[index] = try a.dupe(u8, name);
        config.proxy = .{ .address = try a.dupe(u8, value.address), .port = value.port, .models = models };
    } else config.proxy = null;
}

/// Pending snapshots have no established primary transport, so an explicit
/// proxy save may update them. The active App path keeps its frozen primary
/// proxy through `decision_selection.activeClone`.
pub fn pendingClone(a: std.mem.Allocator, active: cfg.Config, declaration: cfg.Config, adopt_proxy: bool) !std.json.Parsed(cfg.Config) {
    var owned = try decision_selection.activeClone(a, active, declaration);
    errdefer cfg.release(&owned);
    if (adopt_proxy) try adopt(owned.arena.allocator(), &owned.value, declaration.proxy);
    return owned;
}

const fixture =
    \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main","models":{"main":{"protocol":"chat","context_tokens":65536},"raw/id":{"protocol":"systemone"}}}}},"decision":{"model":"p/raw/id","enabled":false},"limits":{"low_price_input":false},"proxy":{"address":"::1","port":8080,"models":["p/raw/id"]}}
;

test "proxy allowlist appends exact IDs removes only matches and preserves order" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a, fixture);
    defer cfg.release(&parsed);
    const arena = parsed.arena.allocator();
    const decision_before = parsed.value.decision.?.model;
    // Duplicate add and absent removal never rewrite the declaration.
    try std.testing.expect(!try apply(arena, &parsed.value, "p/raw/id", true));
    try std.testing.expectEqual(@as(usize, 1), parsed.value.proxy.?.models.len);
    try std.testing.expect(!try apply(arena, &parsed.value, "p/absent", false));
    try std.testing.expect(try apply(arena, &parsed.value, "p/main", true));
    try std.testing.expectEqualStrings("p/raw/id", parsed.value.proxy.?.models[0]);
    try std.testing.expectEqualStrings("p/main", parsed.value.proxy.?.models[1]);
    try std.testing.expect(try apply(arena, &parsed.value, "p/raw/id", false));
    try std.testing.expectEqual(@as(usize, 1), parsed.value.proxy.?.models.len);
    try std.testing.expectEqualStrings("p/main", parsed.value.proxy.?.models[0]);
    try std.testing.expectEqualStrings("::1", parsed.value.proxy.?.address);
    try std.testing.expectEqual(@as(u16, 8080), parsed.value.proxy.?.port);
    try std.testing.expectEqualStrings(decision_before, parsed.value.decision.?.model);
    try std.testing.expectError(error.InvalidDefault, apply(arena, &parsed.value, "p", true));
    try cfg.validate(parsed.value);
}

test "proxy allowlist refuses to exceed the declaration bound" {
    const a = std.testing.allocator;
    var parsed = try cfg.parse(a,
        \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main","models":{"main":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"low_price_input":false},"proxy":{"address":"127.0.0.1","port":1}}
    );
    defer cfg.release(&parsed);
    const arena = parsed.arena.allocator();
    var index: usize = 0;
    while (index < 128) : (index += 1) {
        var buffer: [32]u8 = undefined;
        try std.testing.expect(try apply(arena, &parsed.value, try std.fmt.bufPrint(&buffer, "p/m{d}", .{index}), true));
    }
    try std.testing.expectError(error.TooManyProxyModels, apply(arena, &parsed.value, "p/extra", true));
    try std.testing.expectEqual(@as(usize, 128), parsed.value.proxy.?.models.len);
}
