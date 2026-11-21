//! Narrow, single-attempt OpenAI Codex device authorization wire protocol.
//! The account claim is routing metadata, not a verified identity.
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const WipingAllocator = cfg.WipingAllocator;
const curl = @import("../llm/curl_http.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const official_verification_url = "https://auth.openai.com/codex/device";
const usercode_url = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const poll_url = "https://auth.openai.com/api/accounts/deviceauth/token";
const token_url = "https://auth.openai.com/oauth/token";
const redirect_uri = "https://auth.openai.com/deviceauth/callback";
const max_body = 512 * 1024;
const max_secret = 64 * 1024;
const max_token = 16 * 1024;
const max_depth = 32;
const device_lifetime_ms = 15 * 60 * 1000;
const max_expires_seconds = 365 * 24 * 60 * 60;

fn wipeFree(a: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    a.rawFree(bytes, .of(u8), @returnAddress());
}

pub const TokenSet = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    pub fn deinit(self: *TokenSet, a: Allocator) void {
        wipeFree(a, self.access_token);
        wipeFree(a, self.refresh_token);
        self.* = undefined;
    }
};

pub const DeviceState = struct {
    device_auth_id: []u8,
    user_code: []u8,
    verification_url: []const u8 = official_verification_url,
    interval_ms: u32,
    expires_at_ms: i64,
    pub fn deinit(self: *DeviceState, a: Allocator) void {
        wipeFree(a, self.device_auth_id);
        wipeFree(a, self.user_code);
        self.* = undefined;
    }
};

pub const PollResult = union(enum) { pending, slow_down, success: TokenSet };

const Response = struct {
    status: u16,
    body: []u8,
    fn deinit(self: Response, a: Allocator) void {
        wipeFree(a, self.body);
    }
};
const Endpoint = enum { begin, poll, token };
const Content = enum { json, form };
const Transport = struct {
    context: ?*anyopaque,
    post_fn: *const fn (?*anyopaque, Allocator, Io, Endpoint, Content, []const u8, ?*const p.Cancellation, u32) anyerror!Response,
    now_fn: *const fn (?*anyopaque, Io) i64,
    fn post(self: Transport, a: Allocator, io: Io, endpoint: Endpoint, content: Content, body: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !Response {
        return self.post_fn(self.context, a, io, endpoint, content, body, cancel, timeout);
    }
    fn now(self: Transport, io: Io) i64 {
        return self.now_fn(self.context, io);
    }
};
// One immutable choice of route per login (including the exchange), or refresh.
// OAuth endpoints share an HTTPS origin and are not model-scoped.
pub fn initClient(a: Allocator, io: Io, env: *const std.process.Environ.Map, proxy: ?cfg.ProxyConfig) !curl.Client {
    const url = if (proxy) |configured| try configured.url(a) else null;
    defer if (url) |owned| a.free(owned);
    return curl.Client.initModel(a, io, env, usercode_url, url, true);
}

const Http = struct {
    client: *curl.Client,
    // Private test seam; production operations always use the fixed endpoints.
    urls: [3][]const u8 = .{ usercode_url, poll_url, token_url },

    fn transport(self: *Http) Transport {
        return .{ .context = self, .post_fn = realPost, .now_fn = realNow };
    }
};
fn realNow(_: ?*anyopaque, io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

pub fn beginDevice(a: Allocator, client: *curl.Client, cancel: ?*const p.Cancellation, timeout_ms: u32) !DeviceState {
    var http: Http = .{ .client = client };
    return beginWith(http.transport(), a, client.io, cancel, timeout_ms);
}
pub fn pollDevice(a: Allocator, client: *curl.Client, device: *const DeviceState, cancel: ?*const p.Cancellation, timeout_ms: u32) !PollResult {
    var http: Http = .{ .client = client };
    return pollWith(http.transport(), a, client.io, device, cancel, timeout_ms);
}
pub fn refresh(a: Allocator, client: *curl.Client, refresh_token: []const u8, cancel: ?*const p.Cancellation, timeout_ms: u32) !TokenSet {
    var http: Http = .{ .client = client };
    return refreshWith(http.transport(), a, client.io, refresh_token, cancel, timeout_ms);
}

fn validSecret(s: []const u8) bool {
    return s.len > 0 and s.len <= max_secret;
}
fn checkCancel(cancel: ?*const p.Cancellation) !void {
    if (cancel) |c| if (c.isRequested()) return error.Canceled;
}
fn addMillis(now: i64, ms: i64) !i64 {
    return std.math.add(i64, now, ms) catch error.InvalidResponse;
}
fn beginWith(t: Transport, a: Allocator, io: Io, cancel: ?*const p.Cancellation, timeout: u32) !DeviceState {
    if (timeout == 0) return error.InvalidTimeout;
    const response = try t.post(a, io, .begin, .json, "{\"client_id\":\"" ++ client_id ++ "\"}", cancel, timeout);
    defer response.deinit(a);
    if (response.status < 200 or response.status >= 300) return error.DeviceRequestFailed;
    var parsed = try parse(a, response.body);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const id = try stringField(root, "device_auth_id");
    const code = try stringField(root, "user_code");
    const interval_value = root.get("interval") orelse return error.InvalidResponse;
    const seconds = switch (interval_value) {
        .integer => |n| if (n >= 0 and n <= 86400) @as(u32, @intCast(n)) else return error.InvalidResponse,
        .string => |s| std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t\r\n"), 10) catch return error.InvalidResponse,
        else => return error.InvalidResponse,
    };
    if (seconds > 86400) return error.InvalidResponse;
    const owned_id = try a.dupe(u8, id);
    errdefer wipeFree(a, owned_id);
    const owned_code = try a.dupe(u8, code);
    errdefer wipeFree(a, owned_code);
    return .{ .device_auth_id = owned_id, .user_code = owned_code, .interval_ms = @max(1000, seconds * 1000), .expires_at_ms = try addMillis(t.now(io), device_lifetime_ms) };
}
fn pollWith(t: Transport, a: Allocator, io: Io, device: *const DeviceState, cancel: ?*const p.Cancellation, timeout: u32) !PollResult {
    if (timeout == 0) return error.InvalidTimeout;
    if (!validSecret(device.device_auth_id) or !validSecret(device.user_code)) return error.InvalidDeviceState;
    if (t.now(io) >= device.expires_at_ms) return error.DeviceExpired;
    try checkCancel(cancel);
    const start = Io.Clock.awake.now(io);
    var wiping = WipingAllocator{ .backing = a };
    const temp = wiping.allocator();
    const body = try std.json.Stringify.valueAlloc(temp, .{ .device_auth_id = device.device_auth_id, .user_code = device.user_code }, .{});
    defer wipeFree(temp, body);
    const response = try t.post(a, io, .poll, .json, body, cancel, try remaining(io, start, timeout));
    defer response.deinit(a);
    if (response.status < 200 or response.status >= 300) {
        if (response.status < 400 or response.status == 407 or response.status >= 500) return error.DevicePollFailed;
        const code = parseError(a, response.body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (code) |v| {
            defer wipeFree(a, v);
            if (std.mem.eql(u8, v, "access_denied") or std.mem.eql(u8, v, "authorization_declined")) return error.DeviceDenied;
            if (std.mem.eql(u8, v, "expired_token") or std.mem.eql(u8, v, "deviceauth_expired")) return error.DeviceExpired;
            if (std.mem.eql(u8, v, "slow_down")) return .slow_down;
            if (std.mem.eql(u8, v, "deviceauth_authorization_pending") or std.mem.eql(u8, v, "authorization_pending")) return .pending;
        }
        if (response.status == 403 or response.status == 404) return .pending;
        return error.DevicePollFailed;
    }
    var parsed = try parse(a, response.body);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const code = try stringField(root, "authorization_code");
    const verifier = try stringField(root, "code_verifier");
    const form = try formEncode(temp, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", client_id }, .{ "code", code }, .{ "code_verifier", verifier }, .{ "redirect_uri", redirect_uri } });
    defer wipeFree(temp, form);
    try checkCancel(cancel);
    const token_response = try t.post(a, io, .token, .form, form, cancel, try remaining(io, start, timeout));
    defer token_response.deinit(a);
    return .{ .success = try parseToken(a, token_response, t.now(io)) };
}
fn refreshWith(t: Transport, a: Allocator, io: Io, token: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !TokenSet {
    if (timeout == 0) return error.InvalidTimeout;
    if (!validSecret(token)) return error.InvalidToken;
    try checkCancel(cancel);
    const start = Io.Clock.awake.now(io);
    var wiping = WipingAllocator{ .backing = a };
    const temp = wiping.allocator();
    const form = try formEncode(temp, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client_id }, .{ "refresh_token", token } });
    defer wipeFree(temp, form);
    const response = try t.post(a, io, .token, .form, form, cancel, try remaining(io, start, timeout));
    defer response.deinit(a);
    // No cancellation check here: a complete rotated token must reach its owner.
    return parseToken(a, response, t.now(io));
}

const Pair = struct { []const u8, []const u8 };
fn formEncode(a: Allocator, pairs: []const Pair) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const hex = "0123456789ABCDEF";
    for (pairs, 0..) |pair, i| {
        if (i != 0) try out.append(a, '&');
        inline for (0..2) |part| {
            if (part == 1) try out.append(a, '=');
            for (pair[part]) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '*') try out.append(a, c) else if (c == ' ') try out.append(a, '+') else {
                    try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
                }
            }
        }
    }
    return out.toOwnedSlice(a);
}

// Reject deep nesting before handing untrusted JSON to the recursive parser.
fn checkDepth(bytes: []const u8) !void {
    if (bytes.len > max_body) return error.ResponseTooLarge;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') in_string = false;
        } else switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return error.InvalidResponse;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidResponse;
                depth -= 1;
            },
            else => {},
        }
    }
    if (depth != 0 or in_string) return error.InvalidResponse;
}
const Parsed = struct {
    wiping: *WipingAllocator,
    value: std.json.Value,
    tree: std.json.Parsed(std.json.Value),
    backing: Allocator,
    fn deinit(self: *Parsed) void {
        self.tree.deinit();
        self.backing.destroy(self.wiping);
    }
};
fn parse(a: Allocator, bytes: []const u8) !Parsed {
    try checkDepth(bytes);
    const wiping = try a.create(WipingAllocator);
    errdefer a.destroy(wiping);
    wiping.* = .{ .backing = a };
    const tree = std.json.parseFromSlice(std.json.Value, wiping.allocator(), bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = max_body }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    return .{ .wiping = wiping, .value = tree.value, .tree = tree, .backing = a };
}
fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidResponse;
}
fn stringField(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.InvalidResponse;
    if (v != .string or !validSecret(v.string)) return error.InvalidResponse;
    return v.string;
}
fn parseError(a: Allocator, body: []const u8) !?[]u8 {
    var parsed = try parse(a, body);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const e = root.get("error") orelse return null;
    const s = switch (e) {
        .string => |v| v,
        .object => |v| try stringField(v, "code"),
        else => return null,
    };
    if (!validSecret(s)) return null;
    return try a.dupe(u8, s);
}
fn parseToken(a: Allocator, response: Response, now: i64) !TokenSet {
    if (response.status < 200 or response.status >= 300) return error.TokenRequestFailed;
    var parsed = try parse(a, response.body);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const access = try stringField(root, "access_token");
    const refresh_token = try stringField(root, "refresh_token");
    if (access.len > max_token or refresh_token.len > max_token) return error.InvalidResponse;
    const lifetime = root.get("expires_in") orelse return error.InvalidResponse;
    if (lifetime != .integer or lifetime.integer <= 0 or lifetime.integer > max_expires_seconds) return error.InvalidResponse;
    const expires = try addMillis(now, lifetime.integer * 1000);
    const owned_access = try a.dupe(u8, access);
    errdefer wipeFree(a, owned_access);
    const owned_refresh = try a.dupe(u8, refresh_token);
    return .{ .access_token = owned_access, .refresh_token = owned_refresh, .expires_at_ms = expires };
}

/// Extract an unverified routing claim; this does not authenticate the JWT.
pub fn accountId(a: Allocator, access_token: []const u8) ![]u8 {
    if (!validSecret(access_token)) return error.InvalidToken;
    var parts = std.mem.splitScalar(u8, access_token, '.');
    const header = parts.next() orelse return error.InvalidToken;
    const payload = parts.next() orelse return error.InvalidToken;
    const signature = parts.next() orelse return error.InvalidToken;
    if (header.len == 0 or signature.len == 0 or parts.next() != null or payload.len == 0) return error.InvalidToken;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return error.InvalidToken;
    if (size > max_body) return error.InvalidToken;
    const decoded = try a.alloc(u8, size);
    defer wipeFree(a, decoded);
    decoder.decode(decoded, payload) catch return error.InvalidToken;
    var parsed = try parse(a, decoded);
    defer parsed.deinit();
    const root = try object(parsed.value);
    const auth = try object(root.get("https://api.openai.com/auth") orelse return error.InvalidToken);
    const id = try stringField(auth, "chatgpt_account_id");
    if (id.len > 128) return error.InvalidToken;
    for (id) |c| if (c < 0x21 or c > 0x7e) return error.InvalidToken;
    return a.dupe(u8, id);
}

fn remaining(io: Io, start: Io.Timestamp, timeout: u32) !u32 {
    const elapsed = @max(0, start.untilNow(io, .awake).toMilliseconds());
    if (elapsed >= timeout) return error.Timeout;
    return timeout - @as(u32, @intCast(elapsed));
}

fn realPost(raw: ?*anyopaque, a: Allocator, _: Io, endpoint: Endpoint, content: Content, body: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !Response {
    const http: *Http = @ptrCast(@alignCast(raw.?));
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = if (content == .json) "application/json" else "application/x-www-form-urlencoded" },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };
    const uncanceled: p.Cancellation = .{};
    var wiping = WipingAllocator{ .backing = a };
    const temp = wiping.allocator();
    const response = try http.client.request(temp, http.urls[@backingInt(endpoint)], &headers, body, timeout, max_body, cancel orelse &uncanceled);
    defer response.deinit(temp);
    // Only the returned body outlives the wiping allocator. Do not recheck
    // cancellation after a completed response: the refresh token may rotate.
    return .{ .status = response.status, .body = try a.dupe(u8, response.body) };
}
