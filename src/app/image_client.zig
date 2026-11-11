//! Independent, opt-in image HTTP service. Construction never launches a request.
const std = @import("std");
const cfg = @import("../core/config.zig");
const image = @import("../core/image.zig");
const p = @import("../core/protocol.zig");
const codec = @import("../llm/image_codec.zig");
const http = @import("../llm/decision_http.zig");

pub const Options = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8 = image.model_id,
    request_timeout_ms: u32,
    proxy_url: ?[]const u8 = null,
    context_tokens: ?u64 = null,
};

pub const Client = struct {
    backing: std.mem.Allocator,
    wiping: cfg.WipingAllocator,
    io: std.Io,
    endpoint: []u8,
    key: []u8,
    timeout_ms: u32,
    context_tokens: ?u64,
    transport: http.Client,

    pub fn create(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, options: Options) !*Client {
        if (!std.mem.eql(u8, options.model, image.model_id)) return error.InvalidImageModel;
        try validateUrl(options.base_url);
        if (options.proxy_url) |url| try validateUrl(url);
        if (!validText(options.api_key, 16384)) return error.InvalidApiKey;
        if (options.request_timeout_ms == 0) return error.InvalidTimeout;
        if (options.context_tokens == 0) return error.ImageContextTooLarge;
        const self = try a.create(Client);
        self.backing = a;
        self.wiping = .{ .backing = a };
        const owned = self.wiping.allocator();
        errdefer {
            var final_wipe: cfg.WipingAllocator = .{ .backing = a };
            final_wipe.allocator().destroy(self);
        }
        self.key = try owned.dupe(u8, options.api_key);
        errdefer owned.free(self.key);
        self.endpoint = try std.fmt.allocPrint(owned, "{s}/chat/completions", .{std.mem.trimEnd(u8, options.base_url, "/")});
        errdefer owned.free(self.endpoint);
        self.transport = try http.Client.initRouted(owned, io, env, options.proxy_url);
        self.io = io;
        self.timeout_ms = options.request_timeout_ms;
        self.context_tokens = options.context_tokens;
        return self;
    }

    /// Independent image owner for a child Runtime. Copies the already frozen
    /// endpoint/key/timeout and filtered CA/route transport; no environment key
    /// resolution and no shared mutable curl process state.
    pub fn clone(self: *const Client) !*Client {
        if (self.isPoisoned()) return error.CleanupFailed;
        const a = self.backing;
        const copy = try a.create(Client);
        copy.backing = a;
        copy.wiping = .{ .backing = a };
        const owned = copy.wiping.allocator();
        errdefer {
            var final_wipe: cfg.WipingAllocator = .{ .backing = a };
            final_wipe.allocator().destroy(copy);
        }
        copy.key = try owned.dupe(u8, self.key);
        errdefer owned.free(copy.key);
        copy.endpoint = try owned.dupe(u8, self.endpoint);
        errdefer owned.free(copy.endpoint);
        copy.transport = try http.Client.initRouted(owned, self.io, &self.transport.env, self.transport.proxy_url);
        copy.io = self.io;
        copy.timeout_ms = self.timeout_ms;
        copy.context_tokens = self.context_tokens;
        return copy;
    }

    /// Success destroys self. CleanupFailed retains a poisoned, retryable owner;
    /// callers must not clear the pointer or release its allocator/I/O lifetime.
    pub fn deinit(self: *Client) error{CleanupFailed}!void {
        self.transport.deinit();
        const owned = self.wiping.allocator();
        owned.free(self.key);
        self.key = &.{};
        owned.free(self.endpoint);
        self.endpoint = &.{};
        if (self.transport.unreaped_pid != null) return error.CleanupFailed;
        var wiping: cfg.WipingAllocator = .{ .backing = self.backing };
        wiping.allocator().destroy(self);
    }

    pub fn service(self: *Client) image.Service {
        return .{ .context = self, .inspect_fn = inspect, .check_fn = check };
    }
    pub fn isPoisoned(self: *const Client) bool {
        return self.transport.poisoned;
    }
    fn check(raw: *anyopaque) !void {
        const self: *Client = @ptrCast(@alignCast(raw));
        if (self.isPoisoned()) return error.CleanupFailed;
    }

    fn inspect(raw: *anyopaque, output_allocator: std.mem.Allocator, input: image.Input, cancel: *const p.Cancellation) !image.Output {
        const self: *Client = @ptrCast(@alignCast(raw));
        try check(raw);
        const start = std.Io.Clock.awake.now(self.io);
        // Wipe at rawFree even in safety builds, including curl's temporary
        // config, Bearer, encoded image, JSON response and parser allocations.
        var wiping: cfg.WipingAllocator = .{ .backing = output_allocator };
        const a = wiping.allocator();
        var sink: Sink = .{ .a = a, .io = self.io, .start = start, .timeout_ms = self.timeout_ms, .cancel = cancel };
        defer sink.body.deinit(a);
        try sink.checkNow();
        const payload = try codec.encode(a, input, self.context_tokens);
        defer a.free(payload);
        try sink.checkNow();
        const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{self.key});
        defer a.free(bearer);
        const head = self.transport.streamPost(a, self.endpoint, &.{
            .{ .name = "authorization", .value = bearer },
            .{ .name = "accept", .value = "application/json" },
        }, payload, try sink.remaining(), codec.max_response_bytes, .{ .context = &sink, .write_fn = Sink.write, .check_fn = Sink.check }, cancel) catch |err| {
            if (self.isPoisoned() or err == error.CleanupFailed) return error.CleanupFailed;
            try sink.checkNow();
            return err;
        };
        try sink.checkNow();
        if (head.status < 200 or head.status >= 300 or head.is_sse) return error.ImageHttpResponse;
        const decoded = try codec.decode(a, sink.body.items);
        defer a.free(decoded.text);
        try sink.checkNow();
        const text = try output_allocator.dupe(u8, decoded.text);
        errdefer output_allocator.free(text);
        try sink.checkNow();
        return .{ .text = text, .usage = decoded.usage };
    }
};

const Sink = struct {
    a: std.mem.Allocator,
    io: std.Io,
    start: std.Io.Timestamp,
    timeout_ms: u32,
    cancel: *const p.Cancellation,
    body: std.ArrayList(u8) = .empty,

    fn remaining(self: *Sink) !u32 {
        const elapsed = self.start.untilNow(self.io, .awake).toMilliseconds();
        if (elapsed >= self.timeout_ms) return error.Timeout;
        return self.timeout_ms - @as(u32, @intCast(@max(0, elapsed)));
    }
    fn checkNow(self: *Sink) !void {
        if (self.cancel.isRequested()) return error.Canceled;
        self.io.checkCancel() catch return error.Canceled;
        _ = try self.remaining();
    }
    fn check(raw: *anyopaque) !void {
        const self: *Sink = @ptrCast(@alignCast(raw));
        try self.checkNow();
    }
    fn write(raw: *anyopaque, head: http.StreamHead, bytes: []const u8) !void {
        const self: *Sink = @ptrCast(@alignCast(raw));
        try self.checkNow();
        if (head.status < 200 or head.status >= 300 or head.is_sse) return error.ImageHttpResponse;
        if (bytes.len > codec.max_response_bytes -| self.body.items.len) return error.ImageResponseTooLarge;
        try self.body.appendSlice(self.a, bytes);
    }
};

fn validText(bytes: []const u8, max: usize) bool {
    if (bytes.len == 0 or bytes.len > max or std.mem.trim(u8, bytes, " \t\r\n").len == 0) return false;
    var view = std.unicode.Utf8View.init(bytes) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (cp < 32 or (cp >= 127 and cp <= 159)) return false;
    return true;
}
fn validateUrl(url: []const u8) !void {
    if (!validText(url, 8192) or std.mem.indexOfAny(u8, url, " \\") != null) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidUrl;
}
