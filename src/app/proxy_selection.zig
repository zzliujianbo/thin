//! Pure declaration editing for the explicit HTTP proxy endpoint and exact allowlist.
//! Endpoint presence enables routing; clearing it removes the whole declaration.
//! Never guess an endpoint or normalize a declared model identity.
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
    const models = try a.alloc([]const u8, proxy.models.len + 1);
    @memcpy(models[0..proxy.models.len], proxy.models);
    models[proxy.models.len] = try a.dupe(u8, name);
    config.proxy.?.models = models;
    return true;
}

/// Replace only the endpoint. An empty address disables the proxy by removing
/// the whole declaration, including its previous allowlist; a non-empty one
/// keeps the current exact members (or starts empty). Identical host/port is an
/// intentional no-write no-op. Mutates an arena-owned clone only.
pub fn applyAddress(a: std.mem.Allocator, config: *cfg.Config, raw: []const u8) !bool {
    const endpoint = try cfg.parseProxyEndpoint(raw);
    if (endpoint == null) {
        if (config.proxy == null) return false;
        config.proxy = null;
        return true;
    }
    const next = endpoint.?;
    if (config.proxy) |proxy| {
        if (std.mem.eql(u8, proxy.address, next.address) and proxy.port == next.port) return false;
        config.proxy = .{ .address = try a.dupe(u8, next.address), .port = next.port, .models = proxy.models };
        return true;
    }
    config.proxy = .{ .address = try a.dupe(u8, next.address), .port = next.port, .models = &.{} };
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
