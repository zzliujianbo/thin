//! Private curl transport for auxiliary JSON and explicitly proxied model SSE.
//! No shell interpolation, config discovery,
//! inherited credential environment, redirect following, or inference retries.
//! Client is single-owner/non-concurrent. As with platform/process.zig, no other
//! thread may reap its child or enable SIGCHLD auto-reaping.
const std = @import("std");
const process = @import("../platform/process.zig");
const protocol = @import("../core/protocol.zig");
const c = std.c;
const linux = std.os.linux;

const script = "exec /usr/bin/curl --disable --config -";
const max_body = 65536;
const max_payload = 256 * 1024;
const max_field = 8192;
const max_key = 16384;
const max_config = 2 * 1024 * 1024;
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
        var input = try Input.init(config);
        defer input.deinit();
        try checkCancel(self.io, cancel);

        const result = process.run(a, self.io, "/", script, &self.env, .{
            .stdin_file = .{ .handle = input.fd, .flags = .{ .nonblocking = false } },
            .raw_output = true,
            // process splits the combined budget equally across stdout/stderr.
            // Reserve the full body + four-byte status suffix on stdout.
            .output_bytes = 2 * (max_body + 4),
            .timeout_ms = timeout_ms,
            .term_grace_ms = 200,
            .cleanup_timeout_ms = 5000,
        }, cancel) catch |err| {
            self.last_error = err;
            try checkCancel(self.io, cancel);
            return if (err == error.OutOfMemory) error.OutOfMemory else error.DecisionTransport;
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
    pub fn streamPost(self: *Client, a: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, payload: []const u8, timeout_ms: u32, body_limit: u32, sink: BodySink, cancel: *const protocol.Cancellation) !StreamHead {
        if (self.poisoned) return error.CleanupFailed;
        try checkCancel(self.io, cancel);
        const config = try makeStreamConfig(a, url, headers, payload, timeout_ms, body_limit, self.proxy_url);
        defer wipeFree(a, config);
        var input = try Input.init(config);
        defer input.deinit();
        var parser: StreamParser = .{ .sink = sink, .body_limit = body_limit };
        try checkCancel(self.io, cancel);
        if (sink.check_fn) |check| try check(sink.context);
        const result = try process.run(a, self.io, "/", script, &self.env, .{
            .stdin_file = .{ .handle = input.fd, .flags = .{ .nonblocking = false } },
            .raw_output = true,
            .stdout_sink = .{ .context = &parser, .write_fn = StreamParser.write },
            .output_bytes = 8192,
            .timeout_ms = timeout_ms,
            .term_grace_ms = 200,
            .cleanup_timeout_ms = 5000,
        }, cancel);
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
            const rc = c.waitpid(pid, &status, linux.W.NOHANG);
            if (rc == pid or (rc < 0 and std.posix.errno(rc) == .CHILD)) {
                self.unreaped_pid = null;
                return; // Ownership is gone: no subsequent signal of this PID.
            }
            if (rc < 0 and std.posix.errno(rc) != .INTR) return;
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
    if (payload.len == 0 or payload.len > max_payload or payload[0] == '@' or
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
fn makeConfig(a: std.mem.Allocator, url: []const u8, key: []const u8, payload: []const u8, timeout_ms: u32) ![]u8 {
    return makeConfigRouted(a, url, key, payload, timeout_ms, false, null);
}

fn makeConfigRouted(a: std.mem.Allocator, url: []const u8, key: []const u8, payload: []const u8, timeout_ms: u32, explicit_route: bool, proxy_url: ?[]const u8) ![]u8 {
    try validate(url, key, payload, timeout_ms);
    const prefix = "authorization: Bearer ";
    const capacity = 6 * (url.len + prefix.len + key.len + payload.len + (if (proxy_url) |u| u.len else @as(usize, 0))) + 4096;
    if (capacity > max_config) return error.InvalidPayload;
    const buffer = try a.alloc(u8, capacity);
    errdefer wipeFree(a, buffer);
    // Initialize unused bytes as well; no stale allocator content enters memfd.
    @memset(buffer, 0);
    var w = std.Io.Writer.fixed(buffer);
    try w.writeAll(
        "silent\nhttp1.1\ngloboff\nretry = 0\nmax-filesize = 65536\n" ++
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
    // written prefix to memfd (the first trailing zero is not curl config).
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

fn makeStreamConfig(a: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, payload: []const u8, timeout_ms: u32, body_limit: u32, proxy_url: ?[]const u8) ![]u8 {
    // The main model may have a much larger input than the auxiliary codec.
    // This is a transport byte bound, not an invented model context capacity.
    if (payload.len == 0 or payload.len > 32 * 1024 * 1024 or payload[0] == '@' or !std.unicode.utf8ValidateSlice(payload)) return error.InvalidPayload;
    for (payload) |byte| if (byte < 32 and byte != '\n' and byte != '\r' and byte != '\t') return error.InvalidPayload;
    try validate(url, "validated-separately", "{}", timeout_ms);
    if (body_limit == 0 or headers.len > 16) return error.InvalidPayload;
    var header_bytes: usize = 0;
    for (headers) |h| {
        if (h.name.len == 0 or h.name.len > 128 or h.value.len > max_key + 32 or !controlFree(h.value)) return error.InvalidHeader;
        if (!headerName(h.name)) return error.InvalidHeader;
        header_bytes += h.name.len + h.value.len + 2;
    }
    if (proxy_url) |proxy| try validate(proxy, "route", "{}", 1);
    const capacity = 6 * (url.len + payload.len + header_bytes + (if (proxy_url) |u| u.len else @as(usize, 0))) + 4096;
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
    try field(&w, "max-filesize", try std.fmt.bufPrint(&number, "{d}", .{body_limit}));
    return buffer;
}

/// curl decodes HTTP transfer framing, but only the final origin header is
/// accepted here. CONNECT headers are suppressed and interim heads are bounded.
const StreamParser = struct {
    sink: BodySink,
    body_limit: usize,
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
        if (body.len > self.body_limit - self.body_bytes) return error.CurlResponseTooLarge;
        self.body_bytes += body.len;
        try self.sink.write_fn(self.sink.context, self.head.?, body);
    }
};

const Input = struct {
    fd: c.fd_t,
    length: usize,

    fn init(config: []const u8) !Input {
        const length = std.mem.indexOfScalar(u8, config, 0) orelse config.len;
        const rc = linux.memfd_create("thin-decision", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.DecisionTransport;
        var self: Input = .{ .fd = @intCast(rc), .length = length };
        errdefer self.deinit();
        var offset: usize = 0;
        while (offset < length) {
            // Positional writes leave the shared stdin offset at zero.
            const n = linux.pwrite(self.fd, config[offset..].ptr, length - offset, @intCast(offset));
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return error.DecisionTransport;
                    offset += n;
                },
                .INTR => continue,
                else => return error.DecisionTransport,
            }
        }
        return self;
    }

    fn deinit(self: *Input) void {
        var zeros: [4096]u8 = @splat(0);
        var offset: usize = 0;
        while (offset < self.length) {
            const count = @min(zeros.len, self.length - offset);
            const n = linux.pwrite(self.fd, &zeros, count, @intCast(offset));
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) break;
                    offset += n;
                },
                .INTR => continue,
                else => break,
            }
        }
        // Truncate even if an overwrite unexpectedly failed. No durable file
        // ever existed; closing releases the anonymous inode after child exit.
        while (linux.errno(linux.ftruncate(self.fd, 0)) == .INTR) {}
        _ = c.close(self.fd);
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
    if (bytes.len < 4 or bytes.len - 4 > max_body or result.stdout_bytes != bytes.len) return error.DecisionTransport;
    const suffix = bytes[bytes.len - 4 ..];
    if (suffix[0] != '\n') return error.DecisionTransport;
    for (suffix[1..]) |digit| if (!std.ascii.isDigit(digit)) return error.DecisionTransport;
    const status = std.fmt.parseInt(u16, suffix[1..], 10) catch return error.DecisionTransport;
    if (status < 100) return error.DecisionTransport;
    return .{ .status = status, .body = try a.dupe(u8, bytes[0 .. bytes.len - 4]) };
}

fn fakeResult(bytes: []const u8) process.Result {
    return .{ .stdout = bytes, .stderr = "untrusted server diagnostics", .stdout_bytes = bytes.len, .stderr_bytes = 28, .truncated = false, .term = .{ .exited = 0 } };
}

test "decision config quotes backslashes unicode and never interpolates script" {
    const a = std.testing.allocator;
    const key = "test-key-\\\"中文";
    const payload = "{\"text\":\"中文\\u4f60\\n\\\\\"}\n";
    const buffer = try makeConfig(a, "https://example.invalid/api", key, payload, 1250);
    defer wipeFree(a, buffer);
    const config = buffer[0..std.mem.indexOfScalar(u8, buffer, 0).?];
    try std.testing.expectEqualStrings("exec /usr/bin/curl --disable --config -", script);
    try std.testing.expect(std.mem.indexOf(u8, script, key) == null);
    try std.testing.expect(std.mem.indexOf(u8, config, "authorization: Bearer test-key-\\\\\\\"中文") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "max-time = \"1.250\"") != null);
    var lines = std.mem.splitScalar(u8, config, '\n');
    var found = false;
    while (lines.next()) |line| {
        const prefix = "data-binary = ";
        if (std.mem.startsWith(u8, line, prefix)) {
            const decoded = try std.json.parseFromSlice([]const u8, a, line[prefix.len..], .{});
            defer decoded.deinit();
            try std.testing.expectEqualStrings(payload, decoded.value);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "decision validation rejects controls URL ambiguity and config metasyntax" {
    const payload = "{}";
    for ([_][]const u8{ "file:///etc/passwd", "https://u:p@example.invalid/", "https://example.invalid/?", "https://example.invalid/#", "https://example.invalid/\n", "https://", "https://example.invalid\\evil/" }) |url| {
        try std.testing.expectError(error.InvalidUrl, validate(url, "fake", payload, 1000));
    }
    for ([_][]const u8{ "", "key\r\nheader: injection", "key\x00", "key\x7f", "key\xc2\x85" }) |key| {
        try std.testing.expectError(error.InvalidKey, validate("https://example.invalid/", key, payload, 1000));
    }
    for ([_][]const u8{ "", "@/etc/passwd", "\x00", "\x08", "\x0c", "\xff" }) |body| {
        try std.testing.expectError(error.InvalidPayload, validate("https://example.invalid/", "fake", body, 1000));
    }
    try std.testing.expectError(error.InvalidTimeout, validate("http://example.invalid/", "fake", payload, 0));
    try validate("http://127.0.0.1:1234/api", "fake", "{\n\t\"ok\":true\r\n}", 1);
}

test "decision response exact suffix status errors overflow and incomplete rejection" {
    const a = std.testing.allocator;
    const original = "{\"text\":\"\\u4f60中文\"}\x00\xff\n";
    const response = try parseResponse(a, fakeResult(original ++ "\n200"));
    defer response.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings(original, response.body);
    const denied = try parseResponse(a, fakeResult("denied\n403"));
    defer denied.deinit(a);
    try std.testing.expectEqual(@as(u16, 403), denied.status);
    for ([_][]const u8{ "", "200", "body200", "x\n20", "x\n2a0", "x\n000", "x\n200\n" }) |bytes| {
        try std.testing.expectError(error.DecisionTransport, parseResponse(a, fakeResult(bytes)));
    }
    var result = fakeResult("partial\n200");
    result.truncated = true;
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, result));
    result.truncated = false;
    result.term = .{ .exited = 18 };
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, result));
    result.term = null;
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, result));
    result.timed_out = true;
    try std.testing.expectError(error.Timeout, parseResponse(a, result));
    result.cleanup_failed = true;
    try std.testing.expectError(error.CleanupFailed, parseResponse(a, result));
    const oversized = try a.alloc(u8, max_body + 5);
    defer a.free(oversized);
    @memset(oversized, 'x');
    @memcpy(oversized[oversized.len - 4 ..], "\n200");
    try std.testing.expectError(error.DecisionTransport, parseResponse(a, fakeResult(oversized)));
    @memcpy(oversized[max_body..][0..4], "\n200");
    const at_limit = try parseResponse(a, fakeResult(oversized[0 .. max_body + 4]));
    defer at_limit.deinit(a);
    try std.testing.expectEqual(@as(usize, max_body), at_limit.body.len);
}

test "decision environment allowlist cancellation and poison reject before spawn" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "http://127.0.0.1:1");
    try env.put("no_proxy", "localhost,127.0.0.1");
    try env.put("CURL_CA_BUNDLE", "/fixture/ephemeral-ca.pem");
    try env.put("LD_PRELOAD", "/fake/preload");
    try env.put("HOME", "/fake/home");
    try env.put("CURL_CONFIG", "/fake/config");
    try env.put("API_KEY", "fake-secret");
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    try std.testing.expectEqual(@as(usize, 5), client.env.count());
    try std.testing.expectEqualStrings("/fixture/ephemeral-ca.pem", client.env.get("CURL_CA_BUNDLE").?);
    try std.testing.expectEqualStrings("/usr/bin:/bin", client.env.get("PATH").?);
    try std.testing.expectEqualStrings("C", client.env.get("LC_ALL").?);
    try std.testing.expectEqualStrings("localhost,127.0.0.1", client.env.get("no_proxy").?);
    var cancel: protocol.Cancellation = .{};
    cancel.cancel();
    // Invalid request is deliberate: cancellation/poison must win first.
    try std.testing.expectError(error.Canceled, client.post(a, "", "", "", 0, &cancel));
    client.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, client.post(a, "", "", "", 0, &cancel));
    try env.put("HTTP_PROXY", "http://bad\nproxy");
    try std.testing.expectError(error.InvalidProxyEnvironment, Client.init(a, std.testing.io, &env));
}

test "decision anonymous input begins at zero CLOEXEC and wipes then truncates" {
    const a = std.testing.allocator;
    const config = try makeConfig(a, "https://example.invalid/", "fake-test-key", "{}", 100);
    defer wipeFree(a, config);
    var input = try Input.init(config);
    const duplicate = c.fcntl(input.fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (duplicate < 0) {
        input.deinit();
        return error.TestDuplicateFailed;
    }
    defer _ = c.close(duplicate);
    const cloexec: c_int = 1;
    const flags = c.fcntl(input.fd, c.F.GETFD);
    var bytes: [6]u8 = undefined;
    const n = c.read(input.fd, &bytes, bytes.len);
    input.deinit();
    try std.testing.expect(flags & cloexec != 0);
    try std.testing.expectEqual(@as(isize, 6), n);
    try std.testing.expectEqualStrings("silent", &bytes);
    const end = linux.lseek(duplicate, 0, linux.SEEK.END);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(end));
    try std.testing.expectEqual(@as(u64, 0), end);
}

test "decision cleanup failure without PID is sticky even over cancellation" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    var cancel: protocol.Cancellation = .{};
    cancel.cancel();
    var result = fakeResult("{}\n200");
    result.cleanup_failed = true;
    try std.testing.expectError(error.CleanupFailed, client.acceptResult(a, result, &cancel));
    try std.testing.expect(client.poisoned and client.unreaped_pid == null);
    try std.testing.expectError(error.CleanupFailed, client.post(a, "", "", "", 0, &cancel));
}

test "decision deinit reaps only its owned direct child and clears PID" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    const pid = c.fork();
    if (pid < 0) return error.TestForkFailed;
    if (pid == 0) c._exit(0);
    // Transfer ownership before any fallible assertion. Deferred deinit owns
    // cleanup, including on failure; never use a cached PGID/PID after reap.
    client.unreaped_pid = pid;
    var result = fakeResult("{}\n200");
    result.unreaped_pid = pid;
    var cancel: protocol.Cancellation = .{};
    try std.testing.expectError(error.CleanupFailed, client.acceptResult(a, result, &cancel));
    try std.testing.expect(client.poisoned);
    client.deinit();
    try std.testing.expectEqual(@as(?c.pid_t, null), client.unreaped_pid);
    var status: c_int = undefined;
    const rc = c.waitpid(pid, &status, linux.W.NOHANG);
    try std.testing.expect(rc < 0 and std.posix.errno(rc) == .CHILD);
}

fn allocationCase(a: std.mem.Allocator) !void {
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "http://127.0.0.1:1");
    var client = try Client.init(a, std.testing.io, &env);
    defer client.deinit();
    const config = try makeConfig(a, "https://example.invalid/", "fake-\\\"key", "{\"text\":\"中文\\u4f60\"}", 11000);
    defer wipeFree(a, config);
    try std.testing.expect(std.mem.indexOf(u8, config, "connect-timeout = \"10.000\"") != null);
    const response = try parseResponse(a, fakeResult("{\"ok\":true}\n200"));
    defer response.deinit(a);
}

test "decision config environment and response allocation failures preserve ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

const StreamTestSink = struct {
    data: std.ArrayList(u8) = .empty,
    head: ?StreamHead = null,
    fn write(raw: *anyopaque, head: StreamHead, bytes: []const u8) !void {
        const self: *StreamTestSink = @ptrCast(@alignCast(raw));
        self.head = head;
        try self.data.appendSlice(std.testing.allocator, bytes);
    }
};

test "curl stream origin headers interim responses and every split deliver exact body" {
    const wire = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nX_Valid: yes\r\n\r\ndata: 中文\n\n";
    for (0..wire.len + 1) |split| {
        var sink: StreamTestSink = .{};
        defer sink.data.deinit(std.testing.allocator);
        var parser: StreamParser = .{ .body_limit = 100, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
        try StreamParser.write(&parser, wire[0..split]);
        try StreamParser.write(&parser, wire[split..]);
        try std.testing.expectEqual(@as(u16, 200), parser.head.?.status);
        try std.testing.expect(parser.head.?.is_sse);
        try std.testing.expectEqualStrings("data: 中文\n\n", sink.data.items);
    }
}

test "curl stream bounds and ambiguous malformed headers fail closed" {
    const heads = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\ncontent-type: text/plain\r\n\r\n",
        "HTTP/1.1 101 Switching\r\n\r\n",
        "HTTP/1.1 999 Strange\r\n\r\n",
        "HTTP/1.1 200 OK\r\n folded: no\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX: a\x00b\r\n\r\n",
    };
    var sink: StreamTestSink = .{};
    defer sink.data.deinit(std.testing.allocator);
    for (heads) |head| {
        var parser: StreamParser = .{ .body_limit = 2, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
        try std.testing.expectError(error.InvalidHttpHead, StreamParser.write(&parser, head));
    }
    var parser: StreamParser = .{ .body_limit = 2, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
    try std.testing.expectError(error.CurlResponseTooLarge, StreamParser.write(&parser, "HTTP/1.1 200 OK\r\n\r\nabc"));
    try std.testing.expectEqual(@as(usize, 0), sink.data.items.len);
    var huge: [65537]u8 = @splat('x');
    var large: StreamParser = .{ .body_limit = 2, .sink = .{ .context = &sink, .write_fn = StreamTestSink.write } };
    try std.testing.expectError(error.InvalidHttpHead, StreamParser.write(&large, &huge));
}

fn streamAllocationCase(a: std.mem.Allocator) !void {
    const headers = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer fake-\\\"key" }};
    const config = try makeStreamConfig(a, "https://origin.invalid/v1/messages", &headers, "{\"x\":\"中文\\n\"}", 11000, 1024, "http://127.0.0.1:7890");
    defer wipeFree(a, config);
    try std.testing.expect(std.mem.indexOf(u8, config, "proxy = \"http://127.0.0.1:7890\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "noproxy = \"\"") != null);
}

test "explicit inference routes ignore ambient proxy and no_proxy and clone trust roots" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HTTPS_PROXY", "bad\nproxy");
    try env.put("NO_PROXY", "*");
    try env.put("CURL_CA_BUNDLE", "/owned/fake-ca");
    var direct = try Client.initRouted(std.testing.allocator, std.testing.io, &env, null);
    defer direct.deinit();
    try std.testing.expect(direct.explicit_route and direct.proxy_url == null);
    try std.testing.expect(direct.env.get("HTTPS_PROXY") == null and direct.env.get("NO_PROXY") == null);
    const config = try makeConfigRouted(std.testing.allocator, "https://origin.invalid/", "fake", "{}", 1000, true, null);
    defer wipeFree(std.testing.allocator, config);
    try std.testing.expect(std.mem.indexOf(u8, config, "proxy = \"\"\nnoproxy = \"*\"") != null);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, streamAllocationCase, .{});
}
