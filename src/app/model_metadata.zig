//! Official-only, best-effort context-window metadata. No credentials or response
//! bodies are persisted. The caller owns cancellation and the overall deadline.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const providers = @import("../core/providers.zig");
const catalog = @import("provider_catalog.zig");

pub const file_name = "model-metadata.json";
pub const max_body_bytes = 512 * 1024;
pub const max_cache_bytes = 16 * 1024;

/// Allocation-free lexical preflight. Count containers, scalar tokens and keys;
/// JSON syntax (including escape validity and duplicate fields) is still checked
/// by the parser. Quoted punctuation cannot consume the structural budget.
fn boundJson(bytes: []const u8, limit: usize) !void {
    if (bytes.len > limit) return error.MetadataTooLarge;
    var stack: [32]u8 = undefined;
    var depth: usize = 0;
    var nodes: usize = 0;
    var quoted = false;
    var escaped = false;
    var scalar = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                quoted = false;
            }
            continue;
        }
        switch (c) {
            '{', '[' => {
                if (depth == stack.len) return error.MetadataTooDeep;
                stack[depth] = c;
                depth += 1;
                nodes += 1;
                scalar = false;
            },
            '}', ']' => {
                if (depth == 0 or stack[depth - 1] != (if (c == '}') @as(u8, '{') else '[')) return error.InvalidMetadata;
                depth -= 1;
                scalar = false;
            },
            '"' => {
                quoted = true;
                nodes += 1;
                scalar = false;
            },
            ' ', '\t', '\r', '\n', ',', ':' => scalar = false,
            else => {
                if (!scalar) nodes += 1;
                scalar = true;
            },
        }
        if (nodes > 32768) return error.MetadataTooComplex;
    }
    if (quoted or depth != 0) return error.InvalidMetadata;
}
const max_tokens = 16 * 1024 * 1024;
const Tokens = [catalog.entries.len]?u32;
pub const Cache = struct {
    attempted: u8 = 0,
    tokens: Tokens = @splat(null),
};
pub const Claim = struct { cache: Cache, mask: u8 };

pub fn bit(id: providers.Id) u8 {
    return @as(u8, 1) << @intCast(@backingInt(id));
}
const all_mask: u8 = blk: {
    var mask: u8 = 0;
    for (providers.Id.all) |id| mask |= bit(id);
    break :blk mask;
};

fn capacity(value: std.json.Value) !?u32 {
    return switch (value) {
        .null => null,
        .integer => |n| if (n > 0 and n <= max_tokens) @intCast(n) else error.InvalidMetadata,
        else => error.InvalidMetadata,
    };
}

/// Only context_window denotes the total context; no input/output heuristic.
/// Unknown model IDs are validated but never added to the local catalog.
pub fn parseProvider(a: std.mem.Allocator, body: []const u8, id: providers.Id) !Tokens {
    try boundJson(body, max_body_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_body_bytes });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;
    if (parsed.value.object.get("object")) |kind| {
        if (kind != .string or !std.mem.eql(u8, kind.string, "list")) return error.InvalidMetadata;
    }
    const data = parsed.value.object.get("data") orelse return error.InvalidMetadata;
    if (data != .array or data.array.items.len > 512) return error.InvalidMetadata;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var result: Tokens = @splat(null);
    for (data.array.items) |record| {
        if (record != .object) return error.InvalidMetadata;
        const name = record.object.get("id") orelse return error.InvalidMetadata;
        if (name != .string or name.string.len == 0 or name.string.len > 256) return error.InvalidMetadata;
        for (name.string) |c| if (c < 0x20 or c == 0x7f) return error.InvalidMetadata;
        const entry = try seen.getOrPut(a, name.string);
        if (entry.found_existing) return error.InvalidMetadata;
        const n = if (record.object.get("context_window")) |v| try capacity(v) else null;
        for (catalog.entries, 0..) |model, i| {
            if (model.provider == id and std.mem.eql(u8, model.model.name, name.string)) result[i] = n;
        }
    }
    return result;
}

/// Isolated client, fixed official URL, no redirects or credential discovery.
/// The borrowed caller key is not mutated; the owned header copy is wiped.
pub fn fetch(a: std.mem.Allocator, io: std.Io, id: providers.Id, key: ?[]const u8) !Tokens {
    const url = try std.fmt.allocPrint(a, "{s}/models", .{id.baseUrl()});
    defer a.free(url);
    const body = try fetchUrl(a, io, url, key);
    defer a.free(body);
    return parseProvider(a, body, id);
}

/// Private transport seam for owned loopback tests. Production callers can only
/// reach it through fetch's fixed official endpoint, never through user URLs.
fn fetchUrl(a: std.mem.Allocator, io: std.Io, url: []const u8, key: ?[]const u8) ![]u8 {
    var credentials: providers.Credentials = .{};
    if (key) |k| credentials.set(.deepseek, k);
    try credentials.validate();
    const authorization = if (key) |k| try std.fmt.allocPrint(a, "Bearer {s}", .{k}) else null;
    defer if (authorization) |header| {
        std.crypto.secureZero(u8, header);
        a.free(header);
    };
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (authorization) |header| .{ .override = header } else .omit,
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer request.deinit();
    try request.sendBodiless();
    var head: [8192]u8 = undefined;
    var response = try request.receiveHead(&head);
    if (response.head.status != .ok) return error.MetadataHttpStatus;
    if (response.head.content_length) |size| if (size > max_body_bytes) return error.MetadataTooLarge;
    var transfer: [8192]u8 = undefined;
    const body = try response.reader(&transfer).allocRemaining(a, .limited(max_body_bytes));
    errdefer a.free(body);
    switch (request.reader.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => return error.IncompleteMetadata,
        else => {},
    }
    return body;
}

const Record = struct { selector: []const u8, context_window: ?u32 };
const Document = struct { version: u32, attempted: u8, records: []const Record };

fn parseCache(a: std.mem.Allocator, bytes: []const u8) !Cache {
    try boundJson(bytes, max_cache_bytes);
    var parsed = try std.json.parseFromSlice(Document, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_cache_bytes });
    defer parsed.deinit();
    const doc = parsed.value;
    if (doc.version != 1 or doc.attempted & ~all_mask != 0 or doc.records.len > catalog.entries.len) return error.InvalidMetadata;
    var result: Cache = .{ .attempted = doc.attempted };
    var seen: [catalog.entries.len]bool = @splat(false);
    for (doc.records) |record| {
        if (record.context_window) |n| if (n == 0 or n > max_tokens) return error.InvalidMetadata;
        const index = for (catalog.entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.selector, record.selector)) break i;
        } else return error.InvalidMetadata;
        if (seen[index]) return error.InvalidMetadata;
        seen[index] = true;
        result.tokens[index] = record.context_window;
    }
    return result;
}

/// Anchored, no-follow, nonblocking open; reject nonregular files before reading.
pub fn load(root: *fs.Root) !Cache {
    const fd = fs.linux.openat(root.dir.handle, file_name, fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0);
    if (fd < 0) {
        if (std.c._errno().* == 2) return .{};
        return fs.osError();
    }
    defer fs.closeFd(fd);
    const file = fs.fileFromFd(fd);
    const stat = try file.stat(root.io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max_cache_bytes) return error.MetadataTooLarge;
    const buffer = try root.allocator.alloc(u8, max_cache_bytes + 1);
    defer root.allocator.free(buffer);
    const len = try file.readPositionalAll(root.io, buffer, 0);
    if (len > max_cache_bytes) return error.MetadataTooLarge;
    if (len != stat.size) return error.FileChanged;
    return parseCache(root.allocator, buffer[0..len]);
}

fn lock(root: *fs.Root) !c_int {
    const fd = try fs.openDirectory(root.dir.handle, ".");
    errdefer fs.closeFd(fd);
    for (0..100) |_| {
        if (fs.linux.flock(fd, 2 | 4) == 0) return fd;
        const errno = std.c._errno().*;
        if (errno != 11 and errno != 4) return fs.osError();
        try std.Io.sleep(root.io, .fromMilliseconds(2), .awake);
    }
    return error.MetadataStoreBusy;
}

fn save(root: *fs.Root, cache: Cache) !void {
    var records: [catalog.entries.len]Record = undefined;
    for (catalog.entries, 0..) |entry, i| records[i] = .{ .selector = entry.selector, .context_window = cache.tokens[i] };
    const bytes = try root.allocator.alloc(u8, max_cache_bytes);
    defer root.allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try std.json.Stringify.value(Document{ .version = 1, .attempted = cache.attempted, .records = &records }, .{}, &writer);
    try writer.writeByte('\n');
    try root.writeMode(file_name, bytes[0..writer.end], true, 0o600);
}

/// Persist the attempt before network work, even if the worker later fails.
pub fn claim(root: *fs.Root, requested: u8, manual: bool) !Claim {
    if (requested & ~all_mask != 0) return error.InvalidMetadata;
    const fd = try lock(root);
    defer fs.closeFd(fd);
    var cache = try load(root);
    const mask = requested & (if (manual) all_mask else ~cache.attempted);
    if (mask != 0) {
        cache.attempted |= mask;
        try save(root, cache);
    }
    return .{ .cache = cache, .mask = mask };
}

/// Reload under lock: unsuccessful providers and attempt flags remain intact.
pub fn commit(root: *fs.Root, succeeded: u8, tokens: Tokens) !Cache {
    if (succeeded & ~all_mask != 0) return error.InvalidMetadata;
    const fd = try lock(root);
    defer fs.closeFd(fd);
    var cache = try load(root);
    for (catalog.entries, 0..) |entry, i| {
        if (succeeded & bit(entry.provider) == 0) continue;
        if (tokens[i]) |n| if (n == 0 or n > max_tokens) return error.InvalidMetadata;
        cache.tokens[i] = tokens[i];
    }
    if (succeeded != 0) try save(root, cache);
    return cache;
}

test "metadata lexical limits precede allocation and respect quoted escapes" {
    const a = std.testing.allocator;
    var buffer: [2048]u8 = undefined;
    for ([_]usize{ 31, 32 }) |levels| {
        var w = std.Io.Writer.fixed(&buffer);
        try w.writeAll("{\"data\":[],\"unknown\":");
        for (0..levels) |_| try w.writeByte('[');
        try w.writeAll("null");
        for (0..levels) |_| try w.writeByte(']');
        try w.writeByte('}');
        if (levels == 31) {
            _ = try parseProvider(a, buffer[0..w.end], .deepseek);
        } else {
            // A zero-capacity allocator proves this rejects before JSON allocation.
            var fixed = std.heap.FixedBufferAllocator.init(&.{});
            try std.testing.expectError(error.MetadataTooDeep, parseProvider(fixed.allocator(), buffer[0..w.end], .deepseek));
            try std.testing.expectError(error.MetadataTooDeep, parseCache(fixed.allocator(), buffer[0..w.end]));
        }
    }
    const quoted =
        \\{"data":[],"extra":{"text":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\\\"{}","next":true}}
    ;
    _ = try parseProvider(a, quoted, .deepseek);
    try std.testing.expectError(error.DuplicateField, parseProvider(a, "{\"data\":[],\"extra\":{\"x\":1,\"x\":2}}", .deepseek));
    try std.testing.expectError(error.DuplicateField, parseCache(a, "{\"version\":1,\"version\":1,\"attempted\":0,\"records\":[]}"));
    try std.testing.expectError(error.InvalidMetadata, boundJson("{\"x\":\"unterminated", max_body_bytes));
    try std.testing.expectError(error.InvalidMetadata, boundJson("{]", max_body_bytes));
    const many = try a.alloc(u8, 2 * 32768 + 1);
    defer a.free(many);
    many[0] = '[';
    for (0..32768) |i| {
        many[1 + 2 * i] = '0';
        many[2 + 2 * i] = if (i == 32767) ']' else ',';
    }
    many[many.len - 3] = ']';
    try boundJson(many[0 .. many.len - 2], max_body_bytes);
    many[many.len - 3] = ',';
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    try std.testing.expectError(error.MetadataTooComplex, parseProvider(fixed.allocator(), many, .deepseek));
}

test "metadata deep oversized and duplicate caches remain untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const oversized = try std.testing.allocator.alloc(u8, max_cache_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    var deep: [66]u8 = undefined;
    @memset(deep[0..33], '[');
    @memset(deep[33..], ']');
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = &deep, .err = error.MetadataTooDeep },
        .{ .body = oversized, .err = error.MetadataTooLarge },
        .{ .body = "{\"version\":1,\"version\":1,\"attempted\":0,\"records\":[]}", .err = error.DuplicateField },
        .{ .body = "{\"version\":", .err = error.InvalidMetadata },
    };
    for (cases) |case| {
        try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = case.body });
        const before = try root.dir.statFile(root.io, file_name, .{});
        try std.testing.expectError(case.err, claim(&root, all_mask, true));
        try std.testing.expectError(case.err, commit(&root, all_mask, @splat(null)));
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
        const result = try root.read(std.testing.allocator, file_name, 0, max_body_bytes);
        defer std.testing.allocator.free(result.data);
        try std.testing.expectEqualStrings(case.body, result.data);
    }
}

// One owned loopback connection per fixture. No environment routing or real key.
fn serveMetadata(io: std.Io, server: *std.Io.net.Server, response: []const u8, cleaned: *std.atomic.Value(bool)) !void {
    defer cleaned.store(true, .release);
    var stream = try server.accept(io);
    defer stream.close(io);
    var buffer: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = stream.reader(io, &buffer);
    var suffix: u32 = 0;
    var count: usize = 0;
    while (suffix != 0x0d0a0d0a) {
        if (count == buffer.len) return error.TestHeadersTooLarge;
        suffix = (suffix << 8) | try reader.interface.takeByte();
        count += 1;
    }
    var output: [1024]u8 = undefined;
    var writer = stream.writer(io, &output);
    try writer.interface.writeAll(response);
    try writer.interface.flush();
}

test "metadata loopback transport success redirects size short body and cleanup" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const close_head = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";
    const streamed_oversized = try a.alloc(u8, close_head.len + max_body_bytes + 1);
    defer a.free(streamed_oversized);
    @memcpy(streamed_oversized[0..close_head.len], close_head);
    @memset(streamed_oversized[close_head.len..], ' ');
    const cases = [_]struct { response: []const u8, err: ?anyerror }{
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"data\":[]}", .err = null },
        .{ .response = "HTTP/1.1 302 Found\r\nLocation: /not-followed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .err = error.MetadataHttpStatus },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 524289\r\nConnection: close\r\n\r\n", .err = error.MetadataTooLarge },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{}", .err = error.IncompleteMetadata },
        .{ .response = streamed_oversized, .err = error.StreamTooLong },
    };
    for (cases) |case| {
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/models", .{server.socket.address.getPort()});
        defer a.free(url);
        var cleaned = std.atomic.Value(bool).init(false);
        var worker = try std.Io.concurrent(io, serveMetadata, .{ io, &server, case.response, &cleaned });
        defer worker.cancel(io) catch {};
        if (case.err) |err| {
            try std.testing.expectError(err, fetchUrl(a, io, url, "synthetic-test-key"));
        } else {
            const body = try fetchUrl(a, io, url, null);
            defer a.free(body);
            _ = try parseProvider(a, body, .deepseek);
        }
        try worker.await(io);
        try std.testing.expect(cleaned.load(.acquire));
    }
}

fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const len = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..len]);
}

test "metadata uses only context_window and exact provider raw names" {
    const a = std.testing.allocator;
    const body =
        \\{"object":"list","data":[{"id":"deepseek-flash","context_window":12345,"max_tokens":2},{"id":"deepseek-v4-pro","max_tokens":8192,"input_tokens":100000,"output_tokens":3}]}
    ;
    const values = try parseProvider(a, body, .deepseek);
    try std.testing.expectEqual(@as(?u32, 12345), values[0]);
    try std.testing.expectEqual(@as(?u32, null), values[1]);
    for (try parseProvider(a, body, .opencode_go)) |v| try std.testing.expect(v == null);
    const absent = try parseProvider(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":null}]}", .deepseek);
    for (absent) |v| try std.testing.expect(v == null);
    const shared = "{\"data\":[{\"id\":\"minimax-m2.7\",\"context_window\":204800}]}";
    const zen = try parseProvider(a, shared, .opencode_zen);
    try std.testing.expectEqual(@as(?u32, 204800), zen[2]);
    try std.testing.expect(zen[5] == null);
}

test "metadata rejects invalid IDs capacities duplicate IDs and shapes" {
    const bad = [_][]const u8{
        "[]",                                                      "{}",                                                 "{\"data\":{}}",                                          "{\"data\":[{}]}",
        "{\"data\":[{\"id\":\"\"}]}",                              "{\"data\":[{\"id\":\"x\"},{\"id\":\"x\"}]}",         "{\"data\":[{\"id\":\"x\",\"context_window\":0}]}",       "{\"data\":[{\"id\":\"x\",\"context_window\":-1}]}",
        "{\"data\":[{\"id\":\"x\",\"context_window\":16777217}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":1.5}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":\"100\"}]}",
    };
    for (bad) |body| try std.testing.expectError(error.InvalidMetadata, parseProvider(std.testing.allocator, body, .deepseek));
    try std.testing.expectError(error.DuplicateField, parseProvider(std.testing.allocator, "{\"data\":[],\"data\":[]}", .deepseek));
}

test "metadata body list and ID bounds are enforced" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, max_body_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.MetadataTooLarge, parseProvider(a, oversized, .deepseek));
    var buffer: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[");
    for (0..513) |i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"id\":\"model-{d}\"}}", .{i});
    }
    try writer.writeAll("]}");
    try std.testing.expectError(error.InvalidMetadata, parseProvider(a, buffer[0..writer.end], .deepseek));
    writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[{\"id\":\"");
    for (0..257) |_| try writer.writeByte('a');
    try writer.writeAll("\"}]}");
    try std.testing.expectError(error.InvalidMetadata, parseProvider(a, buffer[0..writer.end], .deepseek));
}

test "metadata private roundtrip claims once and merges only successful providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try testRoot(tmp.dir);
    defer first.deinit();
    var second = try testRoot(tmp.dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(u8, 0), (try load(&first)).attempted);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&first, 0, false)).mask);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, file_name, .{}));
    try std.testing.expectEqual(all_mask, (try claim(&first, all_mask, false)).mask);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&second, all_mask, false)).mask);
    try std.testing.expectEqual(bit(.deepseek), (try claim(&second, bit(.deepseek), true)).mask);
    var tokens: Tokens = @splat(1000);
    _ = try commit(&first, all_mask, tokens);
    tokens = @splat(null);
    tokens[0] = 2000;
    const cache = try commit(&second, bit(.deepseek), tokens);
    try std.testing.expectEqual(all_mask, cache.attempted);
    try std.testing.expectEqual(@as(?u32, 2000), cache.tokens[0]);
    try std.testing.expect(cache.tokens[1] == null);
    try std.testing.expectEqual(@as(?u32, 1000), cache.tokens[2]);
    try std.testing.expectEqualDeep(cache, try load(&first));
    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    _ = try commit(&first, 0, @splat(null));
    try std.testing.expectEqual(stat.inode, (try tmp.dir.statFile(std.testing.io, file_name, .{})).inode);
}

test "metadata malformed cache is never overwritten and selectors are validated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const bad = [_][]const u8{
        "{\"version\":2,\"attempted\":0,\"records\":[]}",
        "{\"version\":1,\"attempted\":128,\"records\":[]}",
        "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"unknown\",\"context_window\":1}]}",
        "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":0}]}",
        "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":1},{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":2}]}",
    };
    for (bad) |body| {
        try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = body });
        try std.testing.expectError(error.InvalidMetadata, claim(&root, all_mask, true));
        try std.testing.expectError(error.InvalidMetadata, commit(&root, all_mask, @splat(null)));
        const result = try root.read(std.testing.allocator, file_name, 0, max_body_bytes);
        defer std.testing.allocator.free(result.data);
        try std.testing.expectEqualStrings(body, result.data);
    }
    const reordered = try parseCache(std.testing.allocator, "{\"version\":1,\"attempted\":0,\"records\":[{\"selector\":\"opencode-go/minimax-m2.7\",\"context_window\":42},{\"selector\":\"deepseek/deepseek-flash\",\"context_window\":99}]}");
    try std.testing.expectEqual(@as(?u32, 42), reordered.tokens[5]);
    try std.testing.expectEqual(@as(?u32, 99), reordered.tokens[0]);
}
