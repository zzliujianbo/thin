//! Bounded nonsecret selection state, independent of diagnostic JSONL/history.
//! Atomic visibility/CAS for cooperative writers, not fsync or a same-user sandbox.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const fs = @import("../platform/filesystem.zig");
const ids = @import("session_id.zig");
const logs = @import("log_store.zig");
const activity = @import("../presentation/activity.zig");

pub const max_bytes = 4096;
const model_limit = 512;
const Hash = std.crypto.hash.sha2.Sha256;

/// Fixed-size owned data: safe to publish/enqueue with no allocation or borrows.
pub const Snapshot = struct {
    model_buffer: [model_limit]u8 = @splat(0),
    model_len: u16 = 0,
    endpoint: [64]u8,
    provider: ?cfg.providers.Id,
    protocol: p.Protocol,
    effort: ?activity.ReasoningEffort,
    /// Unknown fixed wire options can be restored only from identical current
    /// local options; their raw strings are never stored here.
    effort_hash: ?[64]u8 = null,

    pub fn model(self: *const Snapshot) []const u8 {
        return self.model_buffer[0..self.model_len];
    }

    pub const View = struct {
        model: []const u8,
        endpoint: []const u8,
        provider: ?cfg.providers.Id,
        protocol: p.Protocol,
        effort: ?activity.ReasoningEffort,
        effort_hash: ?[]const u8,
    };

    pub fn view(self: *const Snapshot) View {
        return .{ .model = self.model(), .endpoint = &self.endpoint, .provider = self.provider, .protocol = self.protocol, .effort = self.effort, .effort_hash = if (self.effort_hash) |*hash| hash else null };
    }
};

pub fn endpoint(url: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    Hash.hash(url, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn setModel(snapshot: *Snapshot, name: []const u8) !void {
    if (name.len == 0 or name.len > model_limit) return error.InvalidSelectionModel;
    try fs.validateText(name);
    for (name) |byte| if (byte < 32 or byte == 127) return error.InvalidSelectionModel;
    @memcpy(snapshot.model_buffer[0..name.len], name);
    snapshot.model_len = @intCast(name.len);
}

fn knownEffort(effort: activity.ReasoningEffort) bool {
    return switch (effort) {
        .off, .minimal, .low, .medium, .high, .xhigh, .max => true,
        else => false,
    };
}

pub fn capture(config: cfg.Config) !Snapshot {
    const effort = activity.ReasoningEffort.fromName(config.model.reasoning_effort);
    var snapshot: Snapshot = .{
        .endpoint = endpoint(config.provider.base_url),
        .provider = config.provider.kind orelse cfg.providers.Id.fromUrl(config.provider.base_url),
        .protocol = config.model.protocol,
        .effort = if (knownEffort(effort)) effort else null,
        .effort_hash = if (!knownEffort(effort) and config.model.reasoning_effort != null) endpoint(config.model.reasoning_effort.?) else null,
    };
    try setModel(&snapshot, config.model.name);
    return snapshot;
}

pub fn encode(writer: *std.Io.Writer, id: ids.Id, snapshot: *const Snapshot) !void {
    if (!ids.valid(id)) return error.InvalidSessionID;
    try std.json.Stringify.value(.{
        .version = 1,
        .session = @as([]const u8, &id),
        .provider = snapshot.provider,
        .endpoint = @as([]const u8, &snapshot.endpoint),
        .model = snapshot.model(),
        .protocol = snapshot.protocol,
        .effort = snapshot.effort,
        .effort_hash = snapshot.view().effort_hash,
    }, .{}, writer);
}

fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidSelection;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8, expected_id: ids.Id) !Snapshot {
    if (!ids.valid(expected_id)) return error.InvalidSessionID;
    if (bytes.len > max_bytes) return error.SelectionTooLarge;
    try fs.validateText(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 8) return error.InvalidSelection;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidSelection;
    if (version != .integer or version.integer != 1) return error.InvalidSelectionVersion;
    const id = try string(object.get("session") orelse return error.InvalidSelection);
    if (!std.mem.eql(u8, id, &expected_id)) return error.SelectionIdentityMismatch;
    const fingerprint = try string(object.get("endpoint") orelse return error.InvalidSelection);
    if (fingerprint.len != 64) return error.InvalidSelection;
    for (fingerprint) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidSelection;
    const service = object.get("provider") orelse return error.InvalidSelection;
    const effort = object.get("effort") orelse return error.InvalidSelection;
    const effort_hash = object.get("effort_hash") orelse return error.InvalidSelection;
    const protocol = try string(object.get("protocol") orelse return error.InvalidSelection);
    var snapshot: Snapshot = .{
        .endpoint = undefined,
        .provider = if (service == .null) null else std.meta.stringToEnum(cfg.providers.Id, try string(service)) orelse return error.InvalidSelection,
        .protocol = std.meta.stringToEnum(p.Protocol, protocol) orelse return error.InvalidSelection,
        .effort = if (effort == .null) null else std.meta.stringToEnum(activity.ReasoningEffort, try string(effort)) orelse return error.InvalidSelection,
    };
    if (snapshot.effort) |level| if (!knownEffort(level)) return error.InvalidSelection;
    if (effort_hash != .null) {
        if (snapshot.effort != null) return error.InvalidSelection;
        const hash = try string(effort_hash);
        if (hash.len != 64) return error.InvalidSelection;
        for (hash) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidSelection;
        snapshot.effort_hash = hash[0..64].*;
    }
    @memcpy(&snapshot.endpoint, fingerprint);
    try setModel(&snapshot, try string(object.get("model") orelse return error.InvalidSelection));
    return snapshot;
}

fn filename(buffer: []u8, id: ids.Id) ![:0]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    return std.fmt.bufPrintSentinel(buffer, "{s}.selection.json", .{id}, 0);
}

fn readBytes(io: std.Io, fd: c_int, name: [:0]const u8, buffer: *[max_bytes + 1]u8) !?[]const u8 {
    const file_fd = fs.linux.openat(fd, name, fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0);
    if (file_fd < 0) return if (std.c._errno().* == 2) null else fs.osError();
    defer fs.closeFd(file_fd);
    const file = fs.fileFromFd(file_fd);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeSelectionFile;
    if (stat.size > max_bytes) return error.SelectionTooLarge;
    const n = try file.readPositionalAll(io, buffer, 0);
    if (n > max_bytes) return error.SelectionTooLarge;
    if (n != stat.size) return error.FileChanged;
    return buffer[0..n];
}

pub fn load(root: *fs.Root, id: ids.Id) !Snapshot {
    var name_buffer: [64]u8 = undefined;
    const name = try filename(&name_buffer, id);
    const fd = logs.openExistingDirectory(root) catch |err| return if (err == error.FileNotFound) error.SelectionNotFound else err;
    defer fs.closeFd(fd);
    var buffer: [max_bytes + 1]u8 = undefined;
    const bytes = (try readBytes(root.io, fd, name, &buffer)) orelse return error.SelectionNotFound;
    return parse(root.allocator, bytes, id);
}

/// Adopt the existing sidecar CAS baseline when continuing the SAME session.
/// Full resume authenticates its independent checkpoint, not this metadata.
pub fn existingDigest(root: *fs.Root, id: ids.Id) !?[32]u8 {
    var name_buffer: [64]u8 = undefined;
    const name = try filename(&name_buffer, id);
    const fd = try logs.openExistingDirectory(root);
    defer fs.closeFd(fd);
    var buffer: [max_bytes + 1]u8 = undefined;
    const bytes = (try readBytes(root.io, fd, name, &buffer)) orelse return null;
    var digest: [32]u8 = undefined;
    Hash.hash(bytes, &digest, .{});
    return digest;
}

pub const Writer = struct {
    expected: ?[32]u8 = null,

    /// Writer thread only, on the exact directory already owned by log_store.
    pub fn save(self: *Writer, root: *fs.Root, directory_fd: c_int, id: ids.Id, snapshot: *const Snapshot) !void {
        var encoded: [max_bytes]u8 = undefined;
        var output = std.Io.Writer.fixed(&encoded);
        try encode(&output, id, snapshot);
        const bytes = output.buffered();
        var next_digest: [32]u8 = undefined;
        Hash.hash(bytes, &next_digest, .{});
        var name_buffer: [64]u8 = undefined;
        const name = try filename(&name_buffer, id);
        var dir = fs.Root{
            .dir = .{ .handle = try fs.openDirectory(directory_fd, ".") },
            .path = "", // Only the fixed relative filename is accepted below.
            .allocator = root.allocator,
            .io = root.io,
        };
        // Borrowed lexical path; close only the independently opened fd.
        defer fs.closeFd(dir.dir.handle);
        var locked = false;
        for (0..100) |_| {
            if (fs.linux.flock(dir.dir.handle, 2 | 4) == 0) {
                locked = true;
                break;
            }
            const errno = std.c._errno().*;
            if (errno != 11 and errno != 4) return fs.osError();
            try std.Io.sleep(root.io, .fromMilliseconds(2), .awake);
        }
        if (!locked) return error.SelectionStoreBusy;
        const stat = try fs.fileFromFd(dir.dir.handle).stat(root.io);
        if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeLogDirectory;
        var existing: [max_bytes + 1]u8 = undefined;
        const old = try readBytes(root.io, dir.dir.handle, name, &existing);
        if (self.expected) |expected| {
            var digest: [32]u8 = undefined;
            Hash.hash(old orelse return error.SelectionConflict, &digest, .{});
            if (!std.mem.eql(u8, &expected, &digest)) return error.SelectionConflict;
        } else if (old != null) return error.SelectionConflict;
        dir.writeMode(name, bytes, self.expected != null, 0o600) catch |err| return if (err == error.PathAlreadyExists) error.SelectionConflict else err;
        self.expected = next_digest;
    }
};

const test_id: ids.Id = "0123456789abcdef0123456789abcdef".*;

fn fixtureSnapshot() !Snapshot {
    return capture(.{ .provider = .{ .base_url = "https://opencode.ai/zen/go/v1" }, .model = .{ .name = "gpt-5.6-luna", .protocol = .responses, .context_tokens = 1050000, .reasoning_effort = "high" } });
}

fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}

test "selection strict schema owns metadata and binds the exact session identity" {
    var snapshot = try fixtureSnapshot();
    var buffer: [max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encode(&writer, test_id, &snapshot);
    const restored = try parse(std.testing.allocator, writer.buffered(), test_id);
    try std.testing.expectEqualStrings(snapshot.model(), restored.model());
    try std.testing.expectEqual(cfg.providers.Id.opencode_go, restored.provider.?);
    try std.testing.expectEqual(activity.ReasoningEffort.high, restored.effort.?);
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "https://") == null);
    try std.testing.expectError(error.SelectionIdentityMismatch, parse(std.testing.allocator, writer.buffered(), "1123456789abcdef0123456789abcdef".*));
    for ([_][]const u8{ "{}", "[]", "{\"version\":1,\"version\":1}", "\xff" }) |invalid| {
        if (parse(std.testing.allocator, invalid, test_id)) |_| return error.AcceptedInvalidSelection else |_| {}
    }
    const tail = writer.buffered()["{\"version\":1".len..];
    for ([_][]const u8{ "{\"version\":2", "{\"version\":\"1\"", "{\"version\":1.0", "{\"extra\":0,\"version\":1" }) |prefix| {
        const invalid = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, tail });
        defer std.testing.allocator.free(invalid);
        if (parse(std.testing.allocator, invalid, test_id)) |_| return error.AcceptedInvalidSelection else |_| {}
    }
    @memset(&buffer, 'x');
    try std.testing.expectEqualStrings("gpt-5.6-luna", restored.model());
}

test "selection persistence is private atomic CAS and refuses unsafe files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    try std.testing.expectError(error.SelectionNotFound, load(&root, test_id));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    var log = logs.Store.init(std.testing.allocator, &root, .{});
    defer log.deinit();
    try log.pinSessionID(test_id);
    try log.start();
    var writer: Writer = .{};
    var snapshot = try fixtureSnapshot();
    try writer.save(&root, log.logs_fd.?, test_id, &snapshot);
    var loaded = try load(&root, test_id);
    try std.testing.expectEqualStrings("gpt-5.6-luna", loaded.model());
    snapshot.effort = .max;
    try writer.save(&root, log.logs_fd.?, test_id, &snapshot);
    loaded = try load(&root, test_id);
    try std.testing.expectEqual(activity.ReasoningEffort.max, loaded.effort.?);
    const path = ".thin/sessions/" ++ test_id ++ ".selection.json";
    const stat = try tmp.dir.statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    var other: Writer = .{};
    try std.testing.expectError(error.SelectionConflict, other.save(&root, log.logs_fd.?, test_id, &snapshot));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "{}" });
    try std.testing.expectError(error.SelectionConflict, writer.save(&root, log.logs_fd.?, test_id, &snapshot));
    try tmp.dir.deleteFile(std.testing.io, path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("../absent", log.logs_fd.?, test_id ++ ".selection.json"));
    if (load(&root, test_id)) |_| return error.AcceptedSymlink else |_| {}
    if (writer.save(&root, log.logs_fd.?, test_id, &snapshot)) |_| return error.AcceptedSymlink else |_| {}
    try tmp.dir.deleteFile(std.testing.io, path);
    const name = test_id ++ ".selection.json";
    if (mkfifoat(log.logs_fd.?, name, 0o600) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.UnsafeSelectionFile, load(&root, test_id));
}

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
