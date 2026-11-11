//! Codex credentials live only in the protected global config. The Manager is
//! heap-owned and must outlive every CredentialSource and client clone.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const auth = @import("../core/codex_auth.zig");
const device = @import("codex_device.zig");
const store_mod = @import("auth_store.zig");

const call_limit: u32 = 15_000;
const login_limit: u32 = 15 * 60_000;
const refresh_margin_ms: i64 = 5 * 60_000;
const verification_url = "https://auth.openai.com/codex/device";

pub const DevicePrompt = struct { verification_url: []const u8, user_code: []const u8 };
pub const DeviceSink = struct {
    context: ?*anyopaque = null,
    pending_fn: ?*const fn (?*anyopaque, DevicePrompt) anyerror!void = null,
};

// Private seam for offline tests. No response bodies or secrets go to diagnostics.
const Wire = struct {
    context: ?*anyopaque = null,
    begin: *const fn (?*anyopaque, std.mem.Allocator, std.Io, ?*const p.Cancellation, u32) anyerror!device.DeviceState,
    poll: *const fn (?*anyopaque, std.mem.Allocator, std.Io, *const device.DeviceState, ?*const p.Cancellation, u32) anyerror!device.PollResult,
    refresh: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8, ?*const p.Cancellation, u32) anyerror!device.TokenSet,
    account: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
};
fn wireBegin(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, c: ?*const p.Cancellation, t: u32) !device.DeviceState {
    return device.beginDevice(a, io, c, t);
}
fn wirePoll(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, s: *const device.DeviceState, c: ?*const p.Cancellation, t: u32) !device.PollResult {
    return device.pollDevice(a, io, s, c, t);
}
fn wireRefresh(_: ?*anyopaque, a: std.mem.Allocator, io: std.Io, token: []const u8, c: ?*const p.Cancellation, t: u32) !device.TokenSet {
    return device.refresh(a, io, token, c, t);
}
fn wireAccount(_: ?*anyopaque, a: std.mem.Allocator, token: []const u8) ![]u8 {
    return device.accountId(a, token);
}
const production_wire: Wire = .{ .begin = wireBegin, .poll = wirePoll, .refresh = wireRefresh, .account = wireAccount };

const Deadline = struct {
    io: std.Io,
    start: i64,
    duration: u32,
    fn init(io: std.Io, duration: u32) Deadline {
        return .{ .io = io, .start = @intCast(std.Io.Clock.awake.now(io).toMilliseconds()), .duration = duration };
    }
    fn remaining(self: Deadline) u32 {
        const now: i64 = @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
        const elapsed: u64 = @intCast(@max(0, now -| self.start));
        if (elapsed >= self.duration) return 0;
        return self.duration - @as(u32, @intCast(elapsed));
    }
    fn callTime(self: Deadline) !u32 {
        const left = self.remaining();
        if (left == 0) return error.OAuthTimeout;
        return @min(left, call_limit);
    }
};
fn checkCancel(cancel: ?*const p.Cancellation) !void {
    if (cancel) |c| if (c.isRequested()) return error.Cancelled;
}
fn wait(io: std.Io, deadline: Deadline, cancel: ?*const p.Cancellation, duration: u32) !void {
    var left = duration;
    while (left > 0) {
        try checkCancel(cancel);
        const remaining = deadline.remaining();
        if (remaining == 0) return error.OAuthTimeout;
        const step = @min(left, @min(remaining, 100));
        try std.Io.sleep(io, .fromMilliseconds(step), .awake);
        left -= step;
    }
    try checkCancel(cancel);
    if (deadline.remaining() == 0) return error.OAuthTimeout;
}
fn headerValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 16384) return false;
    for (value) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}
fn provider(config: cfg.Config, alias: []const u8) !cfg.NamedProvider {
    const registry = config.registry orelse return error.MissingRegistry;
    const result = registry.find(alias) orelse return error.CodexProviderNotFound;
    if (result.connection.kind != .openai_codex or
        !std.mem.eql(u8, result.connection.base_url, cfg.providers.Id.openai_codex.baseUrl()) or
        result.connection.api_key != null or result.connection.api_key_env.len != 0)
        return error.InvalidCodexProvider;
    return result;
}
fn credential(config: cfg.Config, alias: []const u8) !cfg.CodexCredential {
    const result = (try provider(config, alias)).connection.codex_oauth orelse return error.CodexCredentialMissing;
    if (!headerValue(result.access_token) or result.refresh_token.len == 0 or result.expires_at_ms <= 0)
        return error.InvalidCodexCredential;
    return result;
}
fn tokensCredential(tokens: device.TokenSet) cfg.CodexCredential {
    return .{ .access_token = tokens.access_token, .refresh_token = tokens.refresh_token, .expires_at_ms = tokens.expires_at_ms };
}

// The fingerprint captures the whole credential, not merely its expiry. This
// detects a parallel refresh or login while permitting unrelated setting edits.
fn baseline(config: cfg.Config, alias: []const u8) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const registry = config.registry orelse return error.MissingRegistry;
    if (registry.find(alias)) |entry| {
        _ = try provider(config, alias);
        if (entry.connection.codex_oauth) |c| {
            hash.update("credential-present\x00");
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, @intCast(c.access_token.len), .little);
            hash.update(&len);
            hash.update(c.access_token);
            std.mem.writeInt(u64, &len, @intCast(c.refresh_token.len), .little);
            hash.update(&len);
            hash.update(c.refresh_token);
            std.mem.writeInt(i64, &len, c.expires_at_ms, .little);
            hash.update(&len);
            hash.update(if (c.refresh_pending) "\x01" else "\x00");
        } else hash.update("credential-absent\x00");
    } else hash.update("credential-absent\x00");
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

// Copy only the declaration list; borrowed token bytes remain alive until save.
// No model is invented for a newly declared official provider.
fn merge(a: std.mem.Allocator, config: *cfg.Config, alias: []const u8, value: cfg.CodexCredential, allow_add: bool) ![]cfg.NamedProvider {
    const registry = config.registry orelse return error.MissingRegistry;
    const exists = registry.find(alias) != null;
    if (exists) _ = try provider(config.*, alias) else if (!allow_add) return error.CodexProviderNotFound;
    const copy = try a.alloc(cfg.NamedProvider, registry.providers.len + @as(usize, if (exists) 0 else 1));
    errdefer a.free(copy);
    @memcpy(copy[0..registry.providers.len], registry.providers);
    if (exists) {
        for (copy) |*entry| if (std.mem.eql(u8, entry.name, alias)) {
            entry.connection.codex_oauth = value;
        };
    } else {
        copy[registry.providers.len] = .{ .name = alias, .connection = .{
            .base_url = cfg.providers.Id.openai_codex.baseUrl(),
            .kind = .openai_codex,
            .codex_oauth = value,
        } };
    }
    config.registry.?.providers = copy;
    if (config.selected_provider) |selected| if (std.mem.eql(u8, selected, alias)) {
        config.provider.codex_oauth = value;
    };
    return copy;
}

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: store_mod.Store,
    wire: Wire = production_wire,
    // Private offline fault injection; production never sets this hook.
    before_refresh_save: ?*const fn (bool) anyerror!void = null,
    /// Minimum device polling interval. Production keeps the protocol's 1s;
    /// focused tests use a short interval instead of sleeping.
    min_poll_interval_ms: u32 = 1000,

    pub fn init(a: std.mem.Allocator, io: std.Io, home: []const u8, env: *const std.process.Environ.Map) !*Manager {
        _ = env; // Deliberately do not inspect HOME, Pi credentials or other ambient state.
        const self = try a.create(Manager);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .io = io, .store = try store_mod.Store.open(a, io, home) };
        return self;
    }
    pub fn deinit(self: *Manager) void {
        const a = self.allocator;
        self.store.deinit();
        a.destroy(self);
    }
    pub fn source(self: *Manager) auth.CredentialSource {
        return .{ .context = self, .acquire_fn = acquireCallback };
    }
    fn acquireCallback(ctx: ?*anyopaque, a: std.mem.Allocator, alias: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !auth.RequestCredential {
        const self: *Manager = @ptrCast(@alignCast(ctx orelse return error.MissingCredentialSource));
        return self.acquire(a, alias, cancel, timeout);
    }
    fn acquire(self: *Manager, a: std.mem.Allocator, alias: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !auth.RequestCredential {
        const deadline = Deadline.init(self.io, timeout);
        try checkCancel(cancel);
        // Copy the Store value, not its owned root: each concurrent operation gets
        // an independent CAS baseline while retaining the same anchored dir fd.
        var local = self.store;
        local.expected_version = null;
        _ = try deadline.callTime();
        var tx = try local.beginTransaction(cancel, deadline.remaining());
        defer tx.deinit();
        try checkCancel(cancel);
        _ = try deadline.callTime();
        var parsed = try tx.loadLatest();
        defer cfg.release(&parsed);
        try checkCancel(cancel);
        _ = try deadline.callTime();
        const current = try credential(parsed.value, alias);
        if (current.refresh_pending) return error.OAuthReauthenticationRequired;
        const now: i64 = @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
        var rotated: ?device.TokenSet = null;
        defer if (rotated) |*value| value.deinit(self.allocator);
        var access: []const u8 = current.access_token;
        var refresh: []const u8 = current.refresh_token;
        if (current.expires_at_ms -| now <= refresh_margin_ms) {
            // Allocate the declaration copy before the potentially rotating request.
            var intent = current;
            intent.refresh_pending = true;
            const copy = try merge(self.allocator, &parsed.value, alias, intent, false);
            defer self.allocator.free(copy);
            try checkCancel(cancel);
            _ = try deadline.callTime();
            // Persist intent under the same flock before the refresh token can leave.
            // Even an ambiguous write error must never lead to a POST.
            if (self.before_refresh_save) |hook| hook(true) catch return error.OAuthCommitFailed;
            tx.saveLatest(parsed.value) catch return error.OAuthCommitFailed;
            try checkCancel(cancel);
            const call_timeout = try deadline.callTime();
            rotated = self.wire.refresh(self.wire.context, self.allocator, self.io, current.refresh_token, cancel, call_timeout) catch {
                try checkCancel(cancel);
                return error.OAuthRefreshFailed;
            };
            const new = tokensCredential(rotated.?);
            if (!headerValue(new.access_token) or new.refresh_token.len == 0 or new.expires_at_ms <= 0)
                return error.OAuthRefreshFailed;
            for (copy) |*entry| if (std.mem.eql(u8, entry.name, alias)) {
                entry.connection.codex_oauth = new;
            };
            if (parsed.value.selected_provider) |selected| if (std.mem.eql(u8, selected, alias)) {
                parsed.value.provider.codex_oauth = new;
            };
            // Once rotation succeeded, publish it before observing cancellation.
            // A failed write is terminal; never reuse the possibly rotated token.
            if (self.before_refresh_save) |hook| hook(false) catch return error.OAuthCommitFailed;
            tx.saveLatest(parsed.value) catch return error.OAuthCommitFailed;
            access = rotated.?.access_token;
            refresh = rotated.?.refresh_token;
        }
        try checkCancel(cancel);
        if (deadline.remaining() == 0) return error.OAuthTimeout;
        if (!headerValue(access)) return error.InvalidCodexCredential;
        const account = self.wire.account(self.wire.context, a, access) catch return error.InvalidCodexAccount;
        errdefer {
            std.crypto.secureZero(u8, account);
            a.free(account);
        }
        if (!headerValue(account)) return error.InvalidCodexAccount;
        const owned = try a.dupe(u8, access);
        errdefer {
            std.crypto.secureZero(u8, owned);
            a.free(owned);
        }
        const owned_refresh = try a.dupe(u8, refresh);
        return .{ .access_token = owned, .account_id = account, .redaction_refresh_token = owned_refresh };
    }

    pub fn login(self: *Manager, provider_name: []const u8, cancel: *const p.Cancellation, sink: DeviceSink) !void {
        if (provider_name.len == 0 or provider_name.len > 64) return error.InvalidCodexProvider;
        for (provider_name) |c| if (c <= 0x20 or c >= 0x7f or c == '/' or c == '\\') return error.InvalidCodexProvider;
        const deadline = Deadline.init(self.io, login_limit);
        try checkCancel(cancel);
        var local = self.store;
        local.expected_version = null;
        var initial_tx = try local.beginTransaction(cancel, try deadline.callTime());
        checkCancel(cancel) catch |err| {
            initial_tx.deinit();
            return err;
        };
        _ = deadline.callTime() catch |err| {
            initial_tx.deinit();
            return err;
        };
        var before = initial_tx.loadLatest() catch |err| {
            initial_tx.deinit();
            return err;
        };
        defer cfg.release(&before);
        checkCancel(cancel) catch |err| {
            initial_tx.deinit();
            return err;
        };
        _ = deadline.callTime() catch |err| {
            initial_tx.deinit();
            return err;
        };
        const fingerprint = baseline(before.value, provider_name) catch |err| {
            initial_tx.deinit();
            return err;
        };
        initial_tx.deinit();
        var state = self.wire.begin(self.wire.context, self.allocator, self.io, cancel, try deadline.callTime()) catch {
            try checkCancel(cancel);
            return error.OAuthDeviceFailed;
        };
        defer state.deinit(self.allocator);
        if (!std.mem.eql(u8, state.verification_url, verification_url) or !headerValue(state.user_code)) return error.InvalidDevicePrompt;
        try checkCancel(cancel);
        if (sink.pending_fn) |callback| try callback(sink.context, .{ .verification_url = verification_url, .user_code = state.user_code });
        var interval = @max(state.interval_ms, self.min_poll_interval_ms);
        while (true) {
            const real_now: i64 = @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
            if (state.expires_at_ms <= real_now) return error.OAuthDeviceExpired;
            try wait(self.io, deadline, cancel, interval);
            const now: i64 = @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
            if (state.expires_at_ms <= now) return error.OAuthDeviceExpired;
            const result = self.wire.poll(self.wire.context, self.allocator, self.io, &state, cancel, try deadline.callTime()) catch {
                try checkCancel(cancel);
                return error.OAuthDeviceFailed;
            };
            switch (result) {
                .pending => {},
                .slow_down => interval +|= 5000,
                .success => |tokens_value| {
                    var tokens = tokens_value;
                    defer tokens.deinit(self.allocator);
                    // Exchange has succeeded: commit with a separate bounded wait,
                    // ignoring cancellation until rotation is safely persisted.
                    var tx = try local.beginTransaction(null, call_limit);
                    defer tx.deinit();
                    var latest = try tx.loadLatest();
                    defer cfg.release(&latest);
                    const latest_fingerprint = try baseline(latest.value, provider_name);
                    if (!std.mem.eql(u8, &fingerprint, &latest_fingerprint)) return error.OAuthLoginConflict;
                    const copy = try merge(self.allocator, &latest.value, provider_name, tokensCredential(tokens), true);
                    defer self.allocator.free(copy);
                    tx.saveLatest(latest.value) catch return error.OAuthCommitFailed;
                    try checkCancel(cancel);
                    return;
                },
            }
        }
    }
};
