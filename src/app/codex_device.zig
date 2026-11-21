//! Single-attempt OpenAI Codex browser authorization and token exchange.
//! The account claim is routing metadata, not a verified identity.
const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const WipingAllocator = cfg.WipingAllocator;
const curl = @import("../llm/curl_http.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const authorize_url = "https://auth.openai.com/oauth/authorize";
const max_callback_bytes = @import("../core/codex_login.zig").max_callback_bytes;
const token_url = "https://auth.openai.com/oauth/token";
const redirect_uri = "http://localhost:1455/auth/callback";
const max_body = 512 * 1024;
const max_secret = 64 * 1024;
const max_token = 16 * 1024;
const max_depth = 32;
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

pub const BrowserAuth = struct {
    verifier: [43]u8,
    state: [32]u8,

    pub fn init(self: *BrowserAuth, io: Io) !void {
        // Independent random values: state is public, the verifier never leaves
        // this process until a matching redirect is presented for exchange.
        var entropy: [48]u8 = undefined;
        defer std.crypto.secureZero(u8, &entropy);
        try io.randomSecure(&entropy);
        _ = std.base64.url_safe_no_pad.Encoder.encode(&self.verifier, entropy[0..32]);
        self.state = std.fmt.bytesToHex(entropy[32..].*, .lower);
    }

    pub fn deinit(self: *BrowserAuth) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    pub fn authorizeUrl(self: *const BrowserAuth, a: Allocator) ![]u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&self.verifier, &hash, .{});
        var encoded: [43]u8 = undefined;
        const challenge = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &hash);
        const query = try formEncode(a, &.{
            .{ "response_type", "code" },                        .{ "client_id", client_id },               .{ "redirect_uri", redirect_uri },
            .{ "scope", "openid profile email offline_access" }, .{ "code_challenge", challenge },          .{ "code_challenge_method", "S256" },
            .{ "state", &self.state },                           .{ "id_token_add_organizations", "true" }, .{ "codex_cli_simplified_flow", "true" },
            .{ "originator", "thin" },
        });
        defer wipeFree(a, query);
        return std.mem.concat(a, u8, &.{ authorize_url, "?", query });
    }

    // Decode into the caller's wipeable buffer. Split before decoding so an
    // escaped '&' or '=' is data, not a second parameter. Validate even fields
    // that the exchange ignores, including aliases of duplicate names.
    pub fn callbackCode(self: *const BrowserAuth, a: Allocator, callback: []u8) ![]const u8 {
        const prefix = redirect_uri ++ "?";
        if (callback.len > max_callback_bytes or !std.mem.startsWith(u8, callback, prefix)) return error.InvalidOAuthCallback;
        var fields: std.StringHashMapUnmanaged(void) = .empty;
        defer fields.deinit(a);
        var code: ?[]const u8 = null;
        var matched = false;
        var rest = callback[prefix.len..];
        while (true) {
            const end = std.mem.findScalar(u8, rest, '&') orelse rest.len;
            const field = rest[0..end];
            const eq = std.mem.findScalar(u8, field, '=') orelse return error.InvalidOAuthCallback;
            const key = try decodeField(field[0..eq]);
            const value = try decodeField(field[eq + 1 ..]);
            if (key.len == 0 or (try fields.getOrPut(a, key)).found_existing) return error.InvalidOAuthCallback;
            if (std.mem.eql(u8, key, "error")) return error.InvalidOAuthCallback;
            if (std.mem.eql(u8, key, "state")) matched = std.mem.eql(u8, value, &self.state);
            if (std.mem.eql(u8, key, "code") and value.len != 0) code = value;
            if (end == rest.len) break;
            rest = rest[end + 1 ..];
        }
        if (!matched) return error.InvalidOAuthCallback;
        return code orelse error.InvalidOAuthCallback;
    }
};

fn decodeField(raw: []u8) ![]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < raw.len) : (n += 1) {
        const byte = raw[i];
        i += 1;
        raw[n] = switch (byte) {
            '%' => decoded: {
                if (raw.len - i < 2) return error.InvalidOAuthCallback;
                const hi = std.fmt.charToDigit(raw[i], 16) catch return error.InvalidOAuthCallback;
                const lo = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidOAuthCallback;
                i += 2;
                const c = (hi << 4) | lo;
                if (c < 0x20 or c > 0x7e) return error.InvalidOAuthCallback;
                break :decoded c;
            },
            '+' => ' ',
            // RFC 3986 query bytes after splitting field separators. Reject raw
            // whitespace, fragments, backslashes and non-ASCII URL spellings.
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '!', '$', '\'', '(', ')', '*', ',', ';', '=', ':', '@', '/', '?' => byte,
            else => return error.InvalidOAuthCallback,
        };
    }
    return raw[0..n];
}

const Response = struct {
    status: u16,
    body: []u8,
    fn deinit(self: Response, a: Allocator) void {
        wipeFree(a, self.body);
    }
};
const Transport = struct {
    context: ?*anyopaque,
    post_fn: *const fn (?*anyopaque, Allocator, Io, []const u8, ?*const p.Cancellation, u32) anyerror!Response,
    now_fn: *const fn (?*anyopaque, Io) i64,
    fn post(self: Transport, a: Allocator, io: Io, body: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !Response {
        return self.post_fn(self.context, a, io, body, cancel, timeout);
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
    return curl.Client.initModel(a, io, env, token_url, url, true);
}

const Http = struct {
    client: *curl.Client,
    // Private test seam; production operations always use the fixed endpoints.
    url: []const u8 = token_url,

    fn transport(self: *Http) Transport {
        return .{ .context = self, .post_fn = realPost, .now_fn = realNow };
    }
};
fn realNow(_: ?*anyopaque, io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

pub fn exchange(a: Allocator, client: *curl.Client, code: []const u8, verifier: []const u8, cancel: ?*const p.Cancellation, timeout_ms: u32) !TokenSet {
    var http: Http = .{ .client = client };
    return exchangeWith(http.transport(), a, client.io, code, verifier, cancel, timeout_ms);
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
fn exchangeWith(t: Transport, a: Allocator, io: Io, code: []const u8, verifier: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !TokenSet {
    if (timeout == 0) return error.InvalidTimeout;
    try checkCancel(cancel);
    const start = Io.Clock.awake.now(io);
    var wiping = WipingAllocator{ .backing = a };
    const temp = wiping.allocator();
    const form = try formEncode(temp, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", client_id }, .{ "code", code }, .{ "code_verifier", verifier }, .{ "redirect_uri", redirect_uri } });
    defer wipeFree(temp, form);
    try checkCancel(cancel);
    const response = try t.post(a, io, form, cancel, try remaining(io, start, timeout));
    defer response.deinit(a);
    return parseToken(a, response, t.now(io));
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
    const response = try t.post(a, io, form, cancel, try remaining(io, start, timeout));
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

fn realPost(raw: ?*anyopaque, a: Allocator, _: Io, body: []const u8, cancel: ?*const p.Cancellation, timeout: u32) !Response {
    const http: *Http = @ptrCast(@alignCast(raw.?));
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };
    const uncanceled: p.Cancellation = .{};
    var wiping = WipingAllocator{ .backing = a };
    const temp = wiping.allocator();
    const response = try http.client.request(temp, http.url, &headers, body, timeout, max_body, cancel orelse &uncanceled);
    defer response.deinit(temp);
    // Only the returned body outlives the wiping allocator. Do not recheck
    // cancellation after a completed response: the refresh token may rotate.
    return .{ .status = response.status, .body = try a.dupe(u8, response.body) };
}
