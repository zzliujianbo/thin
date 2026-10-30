//! Zero-request creation from the selected image alias, never the primary key.
//! An unavailable auxiliary model must not block startup/history/settings.
const std = @import("std");
const cfg = @import("../core/config.zig");
const image = @import("../core/image.zig");
const selection = @import("image_selection.zig");
const metadata = @import("model_metadata.zig");
const Store = @import("auth_store.zig").Store;
const Client = @import("image_client.zig").Client;

pub fn create(a: std.mem.Allocator, io: std.Io, config: cfg.Config, env: *const std.process.Environ.Map) !?*Client {
    if (!config.imageActive()) return null;
    const ref = cfg.splitDefault(config.image.model.?) catch return null;
    if (!std.mem.eql(u8, ref.model, image.model_id)) return null;
    const provider = (config.registry orelse return null).find(ref.provider) orelse return null;
    // The dedicated image codec speaks Chat only, never Codex Responses.
    if (provider.connection.kind == .openai_codex or std.mem.eql(u8, provider.connection.base_url, cfg.providers.Id.openai_codex.baseUrl())) return null;
    const base = selection.baseUrl(provider) catch return null;
    const cache = try a.create(metadata.Cache);
    defer a.destroy(cache);
    cache.* = .{};
    if (env.get("HOME")) |home| {
        if (Store.openExisting(a, io, home)) |opened| {
            var store = opened;
            defer store.deinit();
            cache.* = metadata.load(&store.root) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => .{},
            };
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
    }
    if (!selection.available(config, cache, ref.provider)) return null;
    var own_scope = config;
    own_scope.provider = provider.connection;
    var wiping: cfg.WipingAllocator = .{ .backing = a };
    const secure = wiping.allocator();
    const key = cfg.resolveApiKey(secure, own_scope, env) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer secure.free(key);
    var context_tokens: ?u64 = null;
    if (cfg.providers.Id.fromUrl(base)) |id| {
        if (metadata.restoreEntry(cache, id, image.model_id)) |record| {
            var route = record;
            route.model.protocol = .chat;
            if (metadata.contextFor(cache, route)) |n| context_tokens = n;
        }
    }
    if (provider.patchFor(image.model_id)) |patch| {
        if (patch.context_tokens) |n| context_tokens = n;
    }
    const proxy = if (config.proxyFor(ref.provider, ref.model)) |route| try route.url(a) else null;
    defer if (proxy) |url| a.free(url);
    return Client.create(a, io, env, .{
        .base_url = base,
        .api_key = key,
        .request_timeout_ms = config.limits.request_timeout_ms,
        .proxy_url = proxy,
        .context_tokens = context_tokens,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}
