//! Private curl transport for auxiliary JSON and explicitly proxied model SSE.
//! No shell interpolation, config discovery,
//! inherited credential environment, redirect following, or inference retries.
//! Client is single-owner/non-concurrent. As with platform/process.zig, no other
//! thread may reap its child or enable SIGCHLD auto-reaping.
const std = @import("std");
const process = @import("../platform/process.zig");
const protocol = @import("../core/protocol.zig");
const c = std.c;
const Input = @import("../platform/anonymous_input.zig").Input;

const script = "exec /usr/bin/curl --disable --config -";
const max_field = 8192;
const max_key = 16384;
/// Shared private curl transport: explicit inference routing never inherits
/// proxy/no_proxy variables. The legacy auxiliary transport seam may still
/// opt into its filtered environment for owned transport tests.
pub const StreamHead = struct { status: u16, is_sse: bool };
pub const BodySink = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, StreamHead, []const u8) anyerror!void,
    /// Recheck the original request deadline after config encoding, before spawn.
    check_fn: ?*const fn (*anyopaque) anyerror!void = null,
};

const allowed_env_names = [_][]const u8{
    "HTTP_PROXY",     "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy",     "https_proxy", "all_proxy", "no_proxy",
    // Explicit trust roots only; curl still verifies CA chain AND hostname.
    "CURL_CA_BUNDLE",
};

pub const Response = struct {
    status: u16,
    body: []const u8,

    pub fn deinit(self: Response, a: std.mem.Allocator) void {
        a.free(self.body);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: std.process.Environ.Map,
    poisoned: bool = false,
    unreaped_pid: ?c.pid_t = null,
    explicit_route: bool = false,
    proxy_url: ?[]u8 = null,
    /// Safe numeric/local-enum evidence for the latest nonstreaming request.
    /// Never retain curl stderr, response body, configuration or credentials.
    last_exit_code: ?u8 = null,
    last_error: ?anyerror = null,

    /// Owned route; null explicitly forces direct even if the parent exports
    /// proxy variables. A listed model cannot be bypassed by ambient NO_PROXY.
    pub fn initRouted(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, proxy_url: ?[]const u8) !Client {
        var filtered = std.process.Environ.Map.init(a);
        defer filtered.deinit();
        if (env.get("CURL_CA_BUNDLE")) |ca| try filtered.put("CURL_CA_BUNDLE", ca);
        var self = try init(a, io, &filtered);
        errdefer self.deinit();
        if (proxy_url) |url| {
            try validate(url, "route", "{}", 1);
            self.proxy_url = try a.dupe(u8, url);
        }
        self.explicit_route = true;
        return self;
    }

    pub fn init(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Client {
        var owned = std.process.Environ.Map.init(a);
        errdefer freeEnv(&owned);
        try owned.put("PATH", "/usr/bin:/bin");
        try owned.put("LC_ALL", "C");
        for (allowed_env_names) |name| {
            if (env.get(name)) |value| {
                if (value.len > max_field or !controlFree(value)) return error.InvalidProxyEnvironment;
                try owned.put(name, value);
            }
        }
        return .{ .allocator = a, .io = io, .env = owned };
    }

    pub fn deinit(self: *Client) void {
        self.reapOwned();
        if (self.proxy_url) |url| wipeFree(self.allocator, url);
        self.proxy_url = null;
        freeEnv(&self.env);
        self.env = std.process.Environ.Map.init(self.allocator);
        // A deinitialized client must never be usable to launch another POST.
        self.poisoned = true;
    }

    pub fn post(self: *Client, a: std.mem.Allocator, url: []const u8, key: []const u8, payload: []const u8, timeout_ms: u32, cancel: *const protocol.Cancellation) !Response {
        self.last_exit_code = null;
        self.last_error = null;
        return self.postInner(a, url, key, payload, timeout_ms, cancel) catch |err| {
            if (self.last_error == null) self.last_error = err;
            return err;
        };
    }

    fn postInner(self: *Client, a: std.mem.Allocator, url: []const u8, key: []const u8, payload: []const u8, timeout_ms: u32, cancel: *const protocol.Cancellation) !Response {
        if (self.poisoned) return error.CleanupFailed;
        try checkCancel(self.io, cancel);
        const config = try makeConfigRouted(a, url, key, payload, timeout_ms, self.explicit_route, self.proxy_url);
        defer wipeFree(a, config);
        try checkCancel(self.io, cancel);

        const result = self.runWithInput(a, config, .{
            .raw_output = true,
            .output_bytes = null,
            .timeout_ms = timeout_ms,
            .term_grace_ms = 200,
            .cleanup_timeout_ms = 5000,
        }, timeout_ms, cancel, null) catch |err| {
            self.last_error = err;
            if (err == error.CleanupFailed) return err;
            try checkCancel(self.io, cancel);
            return switch (err) {
                error.OutOfMemory, error.CleanupFailed, error.Canceled, error.Timeout => err,
                else => error.DecisionTransport,
            };
        };
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        if (result.term) |term| switch (term) {
            .exited => |code| self.last_exit_code = code,
            else => {},
        };
        return self.acceptResult(a, result, cancel);
    }

    /// Incremental HTTP body delivery on the process owner's thread. A complete
    /// SSE event is not a successful response until curl exits zero and is reaped.
    pub fn streamPost(self: *Client, a: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, payload: []const u8, timeout_ms: u32, body_limit: ?u32, sink: BodySink, cancel: *const protocol.Cancellation) !StreamHead {
        if (self.poisoned) return error.CleanupFailed;
        try checkCancel(self.io, cancel);
        const config = try makeStreamConfig(a, url, headers, payload, timeout_ms, body_limit, self.proxy_url);
        defer wipeFree(a, config);
        var parser: StreamParser = .{ .sink = sink, .body_limit = body_limit };
        try checkCancel(self.io, cancel);
        const result = try self.runWithInput(a, config, .{
            .raw_output = true,
            .stdout_sink = .{ .context = &parser, .write_fn = StreamParser.write },
            .output_bytes = null,
            .timeout_ms = timeout_ms,
            .term_grace_ms = 200,
            .cleanup_timeout_ms = 5000,
        }, timeout_ms, cancel, sink);
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        if (result.cleanup_failed or result.unreaped_pid != null) {
            self.poisoned = true;
            self.unreaped_pid = result.unreaped_pid;
            return error.CleanupFailed;
        }
        try checkCancel(self.io, cancel);
        if (result.canceled) return error.Canceled;
        if (result.timed_out) return error.Timeout;
        if (result.truncated) return error.CurlTransport;
        const term = result.term orelse return error.CurlTransport;
        switch (term) {
            .exited => |code| switch (code) {
                0 => {},
                28 => return error.Timeout,
                63 => return error.CurlResponseTooLarge,
                else => return error.CurlTransport,
            },
            else => return error.CurlTransport,
        }
        return parser.head orelse error.InvalidHttpHead;
    }

    /// Keep run on the caller's thread (notably its stdout sink). Only the
    /// bounded input producer is concurrent; it is joined before config dies.
    fn runWithInput(self: *Client, a: std.mem.Allocator, config: []const u8, options: process.Options, timeout_ms: u32, cancel: *const protocol.Cancellation, before_spawn: ?BodySink) !process.Result {
        var input = try Input.init(config);
        defer input.deinit(self.io);
        try checkCancel(self.io, cancel);
        var run_options = options;
        run_options.stdin_file = input.file();
        if (before_spawn) |sink| if (sink.check_fn) |check| try check(sink.context);
        try input.start(self.io, cancel, timeout_ms);
        const result = process.run(a, self.io, "/", script, &self.env, run_options, &input.cancellation) catch |err| {
            const producer_error = input.finish(self.io);
            try checkCancel(self.io, cancel);
            // Preserve sink/run errors when merely stopping an unfinished
            // producer; actual producer faults are never swallowed.
            if (producer_error) |input_error| if (input_error != error.Canceled) return input_error;
            return err;
        };
        errdefer {
            a.free(result.stdout);
            a.free(result.stderr);
        }
        const producer_error = input.finish(self.io);
        // Ownership failure wins even over producer failure or cancellation.
        if (result.cleanup_failed or result.unreaped_pid != null) {
            self.poisoned = true;
            self.unreaped_pid = result.unreaped_pid;
            return error.CleanupFailed;
        }
        try checkCancel(self.io, cancel);
        if (producer_error) |err| {
            // run may already have observed Io cancellation or its deadline.
            if (err != error.Canceled) return err;
            if (!result.canceled and !result.timed_out) return error.AnonymousInputFailed;
        }
        return result;
    }

    fn acceptResult(self: *Client, a: std.mem.Allocator, result: process.Result, cancel: *const protocol.Cancellation) !Response {
        // Ownership failures always win over cancellation and transport errors.
        // Never let a retry/fallback launch while a child might still be owned.
        if (result.cleanup_failed or result.unreaped_pid != null) {
            self.poisoned = true;
            self.unreaped_pid = result.unreaped_pid;
            return error.CleanupFailed;
        }
        try checkCancel(self.io, cancel);
        return parseResponse(a, result);
    }

    fn reapOwned(self: *Client) void {
        const pid = self.unreaped_pid orelse return;
        if (pid <= 1) return; // Never signal process 0/1 or a process group.
        const since = std.Io.Clock.awake.now(self.io);
        var killed = false;
        while (true) {
            var status: c_int = undefined;
            const rc = c.waitpid(pid, &status, c.W.NOHANG);
            if (rc == pid or (rc < 0 and c.errno(rc) == .CHILD)) {
                self.unreaped_pid = null;
                return; // Ownership is gone: no subsequent signal of this PID.
            }
            if (rc < 0 and c.errno(rc) != .INTR) return;
            if (rc == 0 and !killed) {
                // Only the still-owned direct child, never its cached PGID.
                _ = c.kill(pid, .KILL);
                killed = true;
            }
            if (since.untilNow(self.io, .awake).toMilliseconds() >= 5000) return;
            var fds: [0]c.pollfd = .{};
            _ = c.poll(&fds, 0, 2);
        }
    }
};

fn checkCancel(io: std.Io, cancel: *const protocol.Cancellation) !void {
    if (cancel.isRequested()) return error.Canceled;
    io.checkCancel() catch return error.Canceled;
}

fn wipeFree(a: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    a.free(bytes);
}

fn freeEnv(env: *std.process.Environ.Map) void {
    var it = env.iterator();
    // Map.put owns writable copies, although its iterator exposes const slices.
    while (it.next()) |entry| std.crypto.secureZero(u8, @constCast(entry.value_ptr.*));
    env.deinit();
}

fn controlFree(bytes: []const u8) bool {
    const view = std.unicode.Utf8View.init(bytes) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 32 or (cp >= 127 and cp <= 159)) return false;
    }
    return true;
}

fn validate(url: []const u8, key: []const u8, payload: []const u8, timeout_ms: u32) !void {
    if (key.len == 0 or key.len > max_key or !controlFree(key)) return error.InvalidKey;
    if (url.len == 0 or url.len > max_field or !controlFree(url) or
        std.mem.indexOfAny(u8, url, " \\") != null) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or
        uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null) return error.InvalidUrl;
    if (timeout_ms == 0) return error.InvalidTimeout;
    if (payload.len == 0 or payload[0] == '@' or
        !std.unicode.utf8ValidateSlice(payload)) return error.InvalidPayload;
    // curl's config escape alphabet is smaller than JSON's: it accepts \n,
    // \r and \t, but NOT JSON's \b, \f or \u0000. Never silently change a body.
    for (payload) |byte| {
        if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') return error.InvalidPayload;
    }
}

fn field(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.writeAll(name);
    try w.writeAll(" = ");
    try std.json.Stringify.value(value, .{}, w);
    try w.writeAll("\n");
}

/// One fixed allocation, no writer growth or stale reallocations of secrets.
/// Returned allocation (including unused capacity) is always wiped by caller.
fn makeConfigRouted(a: std.mem.Allocator, url: []const u8, key: []const u8, payload: []const u8, timeout_ms: u32, explicit_route: bool, proxy_url: ?[]const u8) ![]u8 {
    try validate(url, key, payload, timeout_ms);
    const prefix = "authorization: Bearer ";
    var size: usize = 0;
    for ([_]usize{ url.len, prefix.len, key.len, payload.len, if (proxy_url) |u| u.len else 0 }) |n| size = std.math.add(usize, size, n) catch return error.OutOfMemory;
    const capacity = std.math.add(usize, std.math.mul(usize, size, 6) catch return error.OutOfMemory, 4096) catch return error.OutOfMemory;
    const buffer = try a.alloc(u8, capacity);
    errdefer wipeFree(a, buffer);
    // Initialize unused bytes as well; no stale allocator content enters stdin.
    @memset(buffer, 0);
    var w = std.Io.Writer.fixed(buffer);
    try w.writeAll(
        "silent\nhttp1.1\ngloboff\nretry = 0\n" ++
            "proto = \"=http,https\"\nproto-redir = \"=https\"\n" ++
            "user-agent = \"thin\"\nrequest = \"POST\"\n" ++
            "header = \"content-type: application/json\"\nheader = \"accept: application/json\"\n",
    );
    if (explicit_route) try writeRoute(&w, proxy_url);
    try field(&w, "url", url);
    var header: [prefix.len + max_key]u8 = undefined;
    defer std.crypto.secureZero(u8, &header);
    @memcpy(header[0..prefix.len], prefix);
    @memcpy(header[prefix.len..][0..key.len], key);
    try field(&w, "header", header[0 .. prefix.len + key.len]);
    try field(&w, "data-binary", payload);
    var time: [32]u8 = undefined;
    const total = try std.fmt.bufPrint(&time, "{d}.{d:0>3}", .{ timeout_ms / 1000, timeout_ms % 1000 });
    try field(&w, "max-time", total);
    const connect_ms = @min(timeout_ms, 10000);
    const connect = try std.fmt.bufPrint(&time, "{d}.{d:0>3}", .{ connect_ms / 1000, connect_ms % 1000 });
    try field(&w, "connect-timeout", connect);
    try field(&w, "write-out", "\n%{http_code}");
    // Preserve the original allocation for wiping/freeing, and pass only the
    // written prefix to anonymous stdin (the first zero is not curl config).
    // Every accepted field is NUL-free, so this delimiter is unambiguous.
    return buffer;
}

fn headerName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    return true;
}

fn writeRoute(w: *std.Io.Writer, proxy_url: ?[]const u8) !void {
    try field(w, "proxy", proxy_url orelse "");
    try field(w, "noproxy", if (proxy_url == null) "*" else "");
}

fn makeStreamConfig(a: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, payload: []const u8, timeout_ms: u32, body_limit: ?u32, proxy_url: ?[]const u8) ![]u8 {
    if (payload.len == 0 or payload[0] == '@' or !std.unicode.utf8ValidateSlice(payload)) return error.InvalidPayload;
    for (payload) |byte| if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') return error.InvalidPayload;
    try validate(url, "validated-separately", "{}", timeout_ms);
    if (body_limit != null and body_limit.? == 0 or headers.len > 16) return error.InvalidPayload;
    var header_bytes: usize = 0;
    for (headers) |h| {
        if (h.name.len == 0 or h.name.len > 128 or h.value.len > max_key + 32 or !controlFree(h.value)) return error.InvalidHeader;
        if (!headerName(h.name)) return error.InvalidHeader;
        header_bytes = std.math.add(usize, header_bytes, h.name.len) catch return error.OutOfMemory;
        header_bytes = std.math.add(usize, header_bytes, h.value.len) catch return error.OutOfMemory;
        header_bytes = std.math.add(usize, header_bytes, 2) catch return error.OutOfMemory;
    }
    if (proxy_url) |proxy| try validate(proxy, "route", "{}", 1);
    var size: usize = 0;
    for ([_]usize{ url.len, payload.len, header_bytes, if (proxy_url) |u| u.len else 0 }) |n| size = std.math.add(usize, size, n) catch return error.OutOfMemory;
    const capacity = std.math.add(usize, std.math.mul(usize, size, 6) catch return error.OutOfMemory, 4096) catch return error.OutOfMemory;
    const buffer = try a.alloc(u8, capacity);
    errdefer wipeFree(a, buffer);
    @memset(buffer, 0);
    var w = std.Io.Writer.fixed(buffer);
    try w.writeAll("silent\nhttp1.1\ngloboff\nretry = 0\ninclude\nsuppress-connect-headers\nno-buffer\n" ++
        "proto = \"=http,https\"\nproto-redir = \"=https\"\nuser-agent = \"thin\"\nrequest = \"POST\"\n" ++
        "header = \"content-type: application/json\"\nheader = \"accept-encoding: identity\"\n");
    try writeRoute(&w, proxy_url);
    try field(&w, "url", url);
    var header: [max_key + 162]u8 = undefined;
    defer std.crypto.secureZero(u8, &header);
    for (headers) |h| try field(&w, "header", try std.fmt.bufPrint(&header, "{s}: {s}", .{ h.name, h.value }));
    try field(&w, "data-binary", payload);
    var number: [32]u8 = undefined;
    try field(&w, "max-time", try std.fmt.bufPrint(&number, "{d}.{d:0>3}", .{ timeout_ms / 1000, timeout_ms % 1000 }));
    const connect_ms = @min(timeout_ms, 10000);
    try field(&w, "connect-timeout", try std.fmt.bufPrint(&number, "{d}.{d:0>3}", .{ connect_ms / 1000, connect_ms % 1000 }));
    if (body_limit) |limit| try field(&w, "max-filesize", try std.fmt.bufPrint(&number, "{d}", .{limit}));
    return buffer;
}

/// curl decodes HTTP transfer framing, but only the final origin header is
/// accepted here. CONNECT headers are suppressed and interim heads are bounded.
const StreamParser = struct {
    sink: BodySink,
    body_limit: ?u32,
    body_bytes: usize = 0,
    header_bytes: usize = 0,
    head_count: u8 = 0,
    buffer: [65536]u8 = undefined,
    used: usize = 0,
    head: ?StreamHead = null,

    fn write(raw: *anyopaque, bytes: []const u8) !void {
        const self: *StreamParser = @ptrCast(@alignCast(raw));
        var offset: usize = 0;
        while (self.head == null and offset < bytes.len) : (offset += 1) {
            if (self.header_bytes == self.buffer.len) return error.InvalidHttpHead;
            self.buffer[self.used] = bytes[offset];
            self.used += 1;
            self.header_bytes += 1;
            if (self.used >= 4 and std.mem.endsWith(u8, self.buffer[0..self.used], "\r\n\r\n")) {
                self.head_count += 1;
                if (self.head_count > 8) return error.InvalidHttpHead;
                var lines = std.mem.splitSequence(u8, self.buffer[0 .. self.used - 4], "\r\n");
                const status_line = lines.next() orelse return error.InvalidHttpHead;
                if (status_line.len < 12 or (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 "))) return error.InvalidHttpHead;
                if (status_line.len > 12 and status_line[12] != ' ') return error.InvalidHttpHead;
                for (status_line[9..12]) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidHttpHead;
                const status = try std.fmt.parseInt(u16, status_line[9..12], 10);
                if (status < 100 or status > 599 or status == 101) return error.InvalidHttpHead;
                var is_sse = false;
                var seen_type = false;
                while (lines.next()) |line| {
                    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHttpHead;
                    if (colon == 0) return error.InvalidHttpHead;
                    if (!headerName(line[0..colon])) return error.InvalidHttpHead;
                    for (line[colon + 1 ..]) |byte| if ((byte < 32 and byte != '\t') or byte == 127) return error.InvalidHttpHead;
                    if (std.ascii.eqlIgnoreCase(line[0..colon], "content-type")) {
                        if (seen_type) return error.InvalidHttpHead;
                        seen_type = true;
                        var types = std.mem.splitScalar(u8, line[colon + 1 ..], ';');
                        is_sse = std.ascii.eqlIgnoreCase(std.mem.trim(u8, types.first(), " \t"), "text/event-stream");
                    }
                }
                self.used = 0;
                if (status >= 200) self.head = .{ .status = status, .is_sse = is_sse };
            }
        }
        if (offset == bytes.len) return;
        const body = bytes[offset..];
        if (self.body_limit) |limit| if (body.len > @as(usize, limit) -| self.body_bytes) return error.CurlResponseTooLarge;
        self.body_bytes = std.math.add(usize, self.body_bytes, body.len) catch return error.OutOfMemory;
        try self.sink.write_fn(self.sink.context, self.head.?, body);
    }
};

fn parseResponse(a: std.mem.Allocator, result: process.Result) !Response {
    if (result.cleanup_failed or result.unreaped_pid != null) return error.CleanupFailed;
    if (result.canceled) return error.Canceled;
    if (result.timed_out) return error.Timeout;
    if (result.truncated) return error.DecisionTransport;
    const term = result.term orelse return error.DecisionTransport;
    switch (term) {
        .exited => |code| if (code != 0) return error.DecisionTransport,
        else => return error.DecisionTransport,
    }
    const bytes = result.stdout;
    if (bytes.len < 4 or result.stdout_bytes != bytes.len) return error.DecisionTransport;
    const suffix = bytes[bytes.len - 4 ..];
    if (suffix[0] != '\n') return error.DecisionTransport;
    for (suffix[1..]) |digit| if (!std.ascii.isDigit(digit)) return error.DecisionTransport;
    const status = std.fmt.parseInt(u16, suffix[1..], 10) catch return error.DecisionTransport;
    if (status < 100) return error.DecisionTransport;
    return .{ .status = status, .body = try a.dupe(u8, bytes[0 .. bytes.len - 4]) };
}
