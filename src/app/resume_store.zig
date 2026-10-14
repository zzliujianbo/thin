//! Private immutable exit checkpoints. A persistent per-ID lease detects an
//! interrupted resumed process. No-log takes the same lock read-only and never
//! changes either file. Cooperative CAS, not a sandbox or fsync guarantee.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const logs = @import("log_store.zig");
const ids = @import("session_id.zig");
const codec = @import("resume_codec.zig");
const Hash = std.crypto.hash.sha2.Sha256;

fn name(buffer: []u8, id: ids.Id, suffix: []const u8) ![:0]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    return std.fmt.bufPrintSentinel(buffer, "{s}{s}", .{ id, suffix }, 0);
}

fn readFile(root: *fs.Root, dir: c_int, id: ids.Id) !?[]u8 {
    var buffer: [64]u8 = undefined;
    const path = try name(&buffer, id, ".session");
    const fd = fs.linux.openat(dir, path, fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0);
    if (fd < 0) return if (std.c._errno().* == 2) null else fs.osError();
    defer fs.closeFd(fd);
    const file = fs.fileFromFd(fd);
    const stat = try file.stat(root.io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeResumeFile;
    if (stat.size == 0 or stat.size > codec.max_file_bytes) return error.InvalidResumeLength;
    const bytes = try root.allocator.alloc(u8, @intCast(stat.size + 1));
    defer root.allocator.free(bytes);
    const n = try file.readPositionalAll(root.io, bytes, 0);
    if (n != stat.size) return error.FileChanged;
    return try root.allocator.dupe(u8, bytes[0..n]);
}

/// Fixed checkpoint names only. Do not relax the general file tool's UTF-8
/// contract just to store authenticated binary framing.
fn atomicWrite(root: *fs.Root, dir: c_int, path: [:0]const u8, bytes: []const u8, replace: bool) !void {
    var buffer: [80]u8 = undefined;
    var temp: [:0]u8 = undefined;
    var fd: c_int = -1;
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        try root.io.randomSecure(&random);
        temp = try std.fmt.bufPrintSentinel(&buffer, ".resume-tmp-{s}", .{std.fmt.bytesToHex(random, .lower)}, 0);
        fd = fs.linux.openat(dir, temp, 1 | fs.linux.create | fs.linux.exclusive | fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0o600);
        if (fd >= 0) break;
        if (std.c._errno().* != 17) return fs.osError();
    }
    if (fd < 0) return error.TempNameExhausted;
    defer fs.closeFd(fd);
    defer _ = std.c.unlinkat(dir, temp, 0);
    try fs.fileFromFd(fd).writePositionalAll(root.io, bytes, 0);
    if (std.c.fchmod(fd, 0o600) != 0) return fs.osError();
    if (replace) {
        if (std.c.renameat(dir, temp, dir, path) != 0) return fs.osError();
    } else if (std.c.linkat(dir, temp, dir, path, 0) != 0) return fs.osError();
}

pub const Lease = struct {
    directory_fd: c_int,
    lock_fd: c_int,
    id: ids.Id,
    expected: ?[32]u8,
    writable: bool,
    active: bool = false,

    pub fn deinit(self: *Lease) void {
        fs.closeFd(self.lock_fd);
        fs.closeFd(self.directory_fd);
        self.* = undefined;
    }

    /// Existing-only open, bounded one-shot lock acquisition. Authentication and
    /// runtime validation must succeed before activate() changes the marker.
    pub fn open(root: *fs.Root, id: ids.Id, writable: bool) !Lease {
        if (!ids.valid(id)) return error.InvalidSessionID;
        const dir = logs.openExistingDirectory(root) catch |err| return if (err == error.FileNotFound) error.ResumeNotFound else err;
        errdefer fs.closeFd(dir);
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, id, ".resume-lock");
        const fd = fs.linux.openat(dir, path, (if (writable) @as(c_int, 2) else 0) | fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0);
        if (fd < 0) return if (std.c._errno().* == 2) error.ResumeNotFound else fs.osError();
        errdefer fs.closeFd(fd);
        const file = fs.fileFromFd(fd);
        const stat = try file.stat(root.io);
        if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeResumeFile;
        if (fs.linux.flock(fd, 2 | 4) != 0) return if (std.c._errno().* == 11) error.SessionInUse else fs.osError();
        var marker: [34]u8 = undefined;
        const n = try file.readPositionalAll(root.io, &marker, 0);
        if (n != 33 or marker[0] != 'C') return error.ResumeNotClosed;
        return .{ .directory_fd = dir, .lock_fd = fd, .id = id, .expected = marker[1..33].*, .writable = writable };
    }

    /// Fresh IDs only. The lock is never unlinked or replaced; its inode remains
    /// the cooperative ownership anchor across atomic checkpoint replacements.
    pub fn create(root: *fs.Root, id: ids.Id) !Lease {
        if (!ids.valid(id)) return error.InvalidSessionID;
        const dir = try logs.openCheckpointDirectory(root);
        errdefer fs.closeFd(dir);
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, id, ".resume-lock");
        const fd = fs.linux.openat(dir, path, 2 | fs.linux.create | fs.linux.exclusive | fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0o600);
        if (fd < 0) return fs.osError();
        errdefer fs.closeFd(fd);
        if (std.c.fchmod(fd, 0o600) != 0) return fs.osError();
        if (fs.linux.flock(fd, 2 | 4) != 0) return error.SessionInUse;
        var marker: [33]u8 = @splat(0);
        marker[0] = 'A';
        try fs.fileFromFd(fd).writePositionalAll(root.io, &marker, 0);
        return .{ .directory_fd = dir, .lock_fd = fd, .id = id, .expected = null, .writable = true, .active = true };
    }

    pub fn load(self: *const Lease, root: *fs.Root) ![]u8 {
        const bytes = (try readFile(root, self.directory_fd, self.id)) orelse return error.ResumeNotFound;
        errdefer root.allocator.free(bytes);
        var digest: [32]u8 = undefined;
        Hash.hash(bytes, &digest, .{});
        if (self.expected == null or !std.mem.eql(u8, &digest, &self.expected.?)) return error.ResumeConflict;
        return bytes;
    }

    pub fn activate(self: *Lease, root: *fs.Root) !void {
        if (!self.writable or self.active) return;
        // Before any new work can start. A crash/poison/failed final write leaves
        // A, so the older healthy checkpoint cannot masquerade as current state.
        try fs.fileFromFd(self.lock_fd).writePositionalAll(root.io, "A", 0);
        self.active = true;
    }

    pub fn save(self: *Lease, root: *fs.Root, bytes: []const u8) !void {
        if (!self.writable) return error.ResumeReadOnly;
        if (bytes.len == 0 or bytes.len > codec.max_file_bytes) return error.InvalidResumeLength;
        try self.activate(root);
        const old = try readFile(root, self.directory_fd, self.id);
        defer if (old) |value| root.allocator.free(value);
        if (self.expected) |expected| {
            var digest: [32]u8 = undefined;
            Hash.hash(old orelse return error.ResumeConflict, &digest, .{});
            if (!std.mem.eql(u8, &digest, &expected)) return error.ResumeConflict;
        } else if (old != null) return error.ResumeConflict;
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, self.id, ".session");
        try atomicWrite(root, self.directory_fd, path, bytes, self.expected != null);
        var digest: [32]u8 = undefined;
        Hash.hash(bytes, &digest, .{});
        // Publish clean LAST. Partial/canceled writes cannot mark older bytes
        // clean for a newer generation. No fsync durability is implied.
        try fs.fileFromFd(self.lock_fd).writePositionalAll(root.io, &digest, 1);
        try fs.fileFromFd(self.lock_fd).writePositionalAll(root.io, "C", 0);
        self.expected = digest;
        self.active = false;
    }
};

/// Exit-only asynchronous I/O: the serialized owned bytes and Root stay alive
/// until cancel/join. No Runtime/config/key is borrowed by the worker. A failed
/// save is separate from task success and never causes model/tool retries.
pub fn saveFinal(root: *fs.Root, id: ids.Id, existing: ?*Lease, bytes: []const u8) !void {
    const Work = struct {
        root: *fs.Root,
        id: ids.Id,
        existing: ?*Lease,
        bytes: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            self.save() catch |err| {
                self.failure = err;
            };
        }
        fn save(self: *@This()) !void {
            if (self.existing) |lease| return lease.save(self.root, self.bytes);
            var lease = try Lease.create(self.root, self.id);
            defer lease.deinit();
            try lease.save(self.root, self.bytes);
        }
    };
    var work = Work{ .root = root, .id = id, .existing = existing, .bytes = bytes };
    var future = try std.Io.concurrent(root.io, Work.run, .{&work});
    defer future.cancel(root.io);
    const start = std.Io.Clock.awake.now(root.io);
    var timed_out = false;
    while (!work.done.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(root.io)).toMilliseconds() >= 1000) {
            timed_out = true;
            break;
        }
        try std.Io.sleep(root.io, .fromMilliseconds(2), .awake);
    }
    // Join before deciding. A slow write is often not an Io cancellation point,
    // so returning here used to report ResumeSaveTimeout and then wait in defer
    // while the worker published a clean checkpoint. The caller would withhold
    // the resume command for a save that had actually finished.
    if (timed_out) future.cancel(root.io) else future.await(root.io);
    return classifySave(work.done.load(.acquire), work.failure);
}

/// Timeout only if the worker is still unpublished after join. A finished save
/// keeps its real error, or success when the clean marker was published.
fn classifySave(done: bool, failure: ?anyerror) !void {
    if (failure) |err| return err;
    if (!done) return error.ResumeSaveTimeout;
}

fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}
const test_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
test "resume store clean exit lock private files no-log and interrupted owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    try std.testing.expectError(error.ResumeNotFound, Lease.open(&root, test_id, false));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    {
        var lease = try Lease.create(&root, test_id);
        defer lease.deinit();
        try lease.save(&root, "fake authenticated bytes\x00\xff");
        try std.testing.expectError(error.SessionInUse, Lease.open(&root, test_id, false));
    }
    {
        var lease = try Lease.open(&root, test_id, false);
        defer lease.deinit();
        const bytes = try lease.load(&root);
        defer root.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, "fake authenticated bytes\x00\xff", bytes);
        try lease.activate(&root); // read-only, zero mutations
        try std.testing.expect(!lease.active);
        try std.testing.expectError(error.ResumeReadOnly, lease.save(&root, "different"));
    }
    for ([_][]const u8{ ".session", ".resume-lock" }) |suffix| {
        const path = try std.fmt.allocPrint(root.allocator, ".thin/sessions/{s}{s}", .{ test_id, suffix });
        defer root.allocator.free(path);
        const stat = try tmp.dir.statFile(root.io, path, .{});
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    }
    {
        var lease = try Lease.open(&root, test_id, true);
        defer lease.deinit();
        try lease.activate(&root);
        // Simulate death, without a final save.
    }
    try std.testing.expectError(error.ResumeNotClosed, Lease.open(&root, test_id, true));
}

test "resume save join reports a finished checkpoint instead of a stale timeout" {
    try classifySave(true, null);
    try std.testing.expectError(error.NoSpaceLeft, classifySave(true, error.NoSpaceLeft));
    try std.testing.expectError(error.Canceled, classifySave(true, error.Canceled));
    try std.testing.expectError(error.ResumeSaveTimeout, classifySave(false, null));
}

test "resume store detects changed snapshot and refuses unsafe paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var lease = try Lease.create(&root, test_id);
    defer lease.deinit();
    try lease.save(&root, "original");
    const path = ".thin/sessions/" ++ test_id ++ ".session";
    try tmp.dir.writeFile(root.io, .{ .sub_path = path, .data = "changed" });
    try std.testing.expectError(error.ResumeConflict, lease.load(&root));
    try std.testing.expectError(error.ResumeConflict, lease.save(&root, "next"));
    try tmp.dir.deleteFile(root.io, path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", lease.directory_fd, test_id ++ ".session"));
    if (lease.load(&root)) |bytes| {
        root.allocator.free(bytes);
        return error.AcceptedSymlink;
    } else |_| {}
    try tmp.dir.deleteFile(root.io, path);
    if (mkfifoat(lease.directory_fd, test_id ++ ".session", 0o600) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.UnsafeResumeFile, lease.load(&root));
}
extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
