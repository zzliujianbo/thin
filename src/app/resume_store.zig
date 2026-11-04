//! Bounded checkpoints with atomic publication and cooperative writer leases.
//! Reads ignore old markers/digests. Each complete read captures the next write's
//! CAS baseline. Read-only leases do not acquire writer locks, so an active
//! session remains viewable. Digests detect writes; they do not authenticate.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const logs = @import("log_store.zig");
const ids = @import("session_id.zig");
const codec = @import("resume_codec.zig");
const Hash = std.crypto.hash.sha2.Sha256;

extern "c" fn fsync(c_int) c_int;

fn fsyncFd(fd: c_int) !void {
    while (true) {
        if (fsync(fd) == 0) return;
        if (std.c._errno().* == 4) continue; // EINTR
        return fs.osError();
    }
}

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
    if (stat.kind != .file) return error.UnsafeResumeFile;
    if (stat.size == 0 or stat.size > codec.max_file_bytes) return error.InvalidResumeLength;
    const bytes = try root.allocator.alloc(u8, @intCast(stat.size + 1));
    defer root.allocator.free(bytes);
    const n = try file.readPositionalAll(root.io, bytes, 0);
    if (n != stat.size) return error.FileChanged;
    return try root.allocator.dupe(u8, bytes[0..n]);
}

const session_metadata = @import("../core/session_metadata.zig");
pub const Summary = session_metadata.SavedSession;

fn readTitle(root: *fs.Root, dir: c_int, id: ids.Id) session_metadata.Title {
    var filename: [64]u8 = undefined;
    const path = name(&filename, id, ".title") catch return .{};
    const fd = fs.linux.openat(dir, path, fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0);
    if (fd < 0) return .{};
    defer fs.closeFd(fd);
    const file = fs.fileFromFd(fd);
    const stat = file.stat(root.io) catch return .{};
    if (stat.kind != .file or stat.size == 0 or stat.size > 256) return .{};
    var bytes: [257]u8 = undefined;
    const n = file.readPositionalAll(root.io, &bytes, 0) catch return .{};
    if (n != stat.size) return .{};
    return session_metadata.Title.fromText(bytes[0..n]);
}

/// List checkpoint metadata in this project only. No checkpoint content is read,
/// and a missing namespace stays missing. Candidate metadata is inspected
/// relative to the validated directory without following final symlinks.
pub fn list(root: *fs.Root, allocator: std.mem.Allocator) ![]Summary {
    const fd = logs.openExistingDirectory(root) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Summary, 0),
        else => return err,
    };
    defer fs.closeFd(fd);
    const dir: std.Io.Dir = .{ .handle = fd };
    var iterator = dir.iterate();
    var items: std.ArrayList(Summary) = .empty;
    errdefer items.deinit(allocator);
    while (try iterator.next(root.io)) |entry| {
        if (entry.name.len != 40 or !std.mem.endsWith(u8, entry.name, ".session")) continue;
        const id: ids.Id = entry.name[0..32].*;
        if (!ids.valid(id)) continue;
        const stat = dir.statFile(root.io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) continue;
        try items.append(allocator, .{ .id = id, .modified_ms = @intCast(stat.mtime.toMilliseconds()), .title = readTitle(root, fd, id) });
    }
    std.mem.sort(Summary, items.items, {}, struct {
        fn less(_: void, a: Summary, b: Summary) bool {
            if (a.modified_ms != b.modified_ms) return a.modified_ms > b.modified_ms;
            return std.mem.order(u8, &a.id, &b.id) == .lt;
        }
    }.less);
    return items.toOwnedSlice(allocator);
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
    // Data must be durable before the directory entry publishes the name.
    try fsyncFd(fd);
    if (replace) {
        if (std.c.renameat(dir, temp, dir, path) != 0) return fs.osError();
    } else if (std.c.linkat(dir, temp, dir, path, 0) != 0) return fs.osError();
    try fsyncFd(dir);
}

pub const Lease = struct {
    directory_fd: c_int,
    lock_fd: c_int,
    id: ids.Id,
    expected: ?[32]u8,
    writable: bool,

    pub fn deinit(self: *Lease) void {
        if (self.lock_fd >= 0) fs.closeFd(self.lock_fd);
        fs.closeFd(self.directory_fd);
        self.* = undefined;
    }

    /// Writable opens take an exclusive writer lock. On SessionInUse, use
    /// open(..., false) to view history without a lock or permission to save.
    pub fn open(root: *fs.Root, id: ids.Id, writable: bool) !Lease {
        if (!ids.valid(id)) return error.InvalidSessionID;
        const dir = logs.openExistingDirectory(root) catch |err| return if (err == error.FileNotFound) error.ResumeNotFound else err;
        errdefer fs.closeFd(dir);
        if (!writable) return .{ .directory_fd = dir, .lock_fd = -1, .id = id, .expected = null, .writable = false };
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, id, ".resume-lock");
        const fd = fs.linux.openat(dir, path, 2 | fs.linux.create | fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0o600);
        if (fd < 0) return fs.osError();
        errdefer fs.closeFd(fd);
        const stat = try fs.fileFromFd(fd).stat(root.io);
        if (stat.kind != .file) return error.UnsafeResumeFile;
        if (fs.linux.flock(fd, 2 | 4) != 0) return if (std.c._errno().* == 11) error.SessionInUse else fs.osError();
        return .{ .directory_fd = dir, .lock_fd = fd, .id = id, .expected = null, .writable = true };
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
        return .{ .directory_fd = dir, .lock_fd = fd, .id = id, .expected = null, .writable = true };
    }

    pub fn load(self: *Lease, root: *fs.Root) ![]u8 {
        const bytes = (try readFile(root, self.directory_fd, self.id)) orelse return error.ResumeNotFound;
        var digest: [32]u8 = undefined;
        Hash.hash(bytes, &digest, .{});
        self.expected = digest;
        return bytes;
    }

    pub fn getTitle(self: *const Lease, root: *fs.Root) session_metadata.Title {
        return readTitle(root, self.directory_fd, self.id);
    }

    /// Only a successfully saved or loaded checkpoint may acquire a sidecar.
    pub fn saveTitle(self: *Lease, root: *fs.Root, title: session_metadata.Title) !void {
        if (!self.writable) return error.ResumeReadOnly;
        if (self.expected == null) return error.ResumeNotFound;
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, self.id, ".title");
        try atomicWrite(root, self.directory_fd, path, title.text(), true);
    }

    pub fn save(self: *Lease, root: *fs.Root, bytes: []const u8) !void {
        if (!self.writable) return error.ResumeReadOnly;
        if (bytes.len == 0 or bytes.len > codec.max_file_bytes) return error.InvalidResumeLength;
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
        self.expected = digest;
    }
};

/// Join outcome, not the poll clock. `done == false` is the only timeout:
/// a failure observed after the worker returns is that failure.
pub fn classifySave(done: bool, failure: ?anyerror) !void {
    if (!done) return error.ResumeSaveTimeout;
    if (failure) |err| return err;
}

/// Exit save on a worker so the caller can keep polling signals. The poll
/// window is not the outcome: cancel/join runs first, and only a worker that
/// is still unfinished after that join is `ResumeSaveTimeout`. A slow disk
/// that finishes during the join is success. Bytes and Root stay alive until
/// the join. A failed save never causes model or tool retries.
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
    const start = std.Io.Clock.awake.now(root.io);
    while (!work.done.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(root.io)).toMilliseconds() >= 1000) break;
        try std.Io.sleep(root.io, .fromMilliseconds(2), .awake);
    }
    // Join before classifying. await does not request cancellation, so a slow
    // write that outlasts the poll can still publish successfully.
    // ResumeSaveTimeout is only when the worker is still unfinished after that join.
    future.await(root.io);
    return classifySave(work.done.load(.acquire), work.failure);
}

test "resume save classification waits for the worker result" {
    try classifySave(true, null);
    try std.testing.expectError(error.ResumeConflict, classifySave(true, error.ResumeConflict));
    try std.testing.expectError(error.Canceled, classifySave(true, error.Canceled));
    try std.testing.expectError(error.ResumeSaveTimeout, classifySave(false, null));
    try std.testing.expectError(error.ResumeSaveTimeout, classifySave(false, error.ResumeConflict));
}

fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}
const test_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
test "resume listing is read only sorted and ignores invalid entries" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const empty = try list(&root, a);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));

    const second: ids.Id = "fedcba9876543210fedcba9876543210".*;
    var first_lease = try Lease.create(&root, test_id);
    defer first_lease.deinit();
    try first_lease.save(&root, "first");
    var second_lease = try Lease.create(&root, second);
    defer second_lease.deinit();
    try second_lease.save(&root, "second");
    const dir = first_lease.directory_fd;
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("0123456789abcdef0123456789abcdef.session", dir, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.session"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.session", 0o700));
    try std.testing.expectEqual(@as(c_int, 0), mkfifoat(dir, "cccccccccccccccccccccccccccccccc.session", 0o600));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", dir, "dddddddddddddddddddddddddddddddd.session"));
    const equal_times = [2]std.c.timespec{ .{ .sec = 100, .nsec = 0 }, .{ .sec = 100, .nsec = 0 } };
    try std.testing.expectEqual(@as(c_int, 0), std.c.utimensat(dir, test_id ++ ".session", &equal_times, 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.utimensat(dir, second ++ ".session", &equal_times, 0));
    const unreadable = fs.linux.openat(dir, test_id ++ ".session", fs.linux.nofollow | fs.linux.cloexec, 0);
    if (unreadable < 0) return fs.osError();
    defer fs.closeFd(unreadable);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(unreadable, 0));
    const junk = fs.linux.openat(dir, "INVALID.session", 1 | fs.linux.create | fs.linux.exclusive | fs.linux.cloexec, 0o600);
    if (junk < 0) return fs.osError();
    fs.closeFd(junk);
    const result = try list(&root, a);
    defer a.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(i64, 100_000), result[0].modified_ms);
    try std.testing.expectEqual(result[0].modified_ms, result[1].modified_ms);
    try std.testing.expectEqualSlices(u8, &test_id, &result[0].id);
    try std.testing.expectEqualSlices(u8, &second, &result[1].id);
    const later_times = [2]std.c.timespec{ .{ .sec = 200, .nsec = 0 }, .{ .sec = 200, .nsec = 0 } };
    try std.testing.expectEqual(@as(c_int, 0), std.c.utimensat(dir, second ++ ".session", &later_times, 0));
    const later = try list(&root, a);
    defer a.free(later);
    try std.testing.expectEqual(@as(usize, 2), later.len);
    try std.testing.expectEqualSlices(u8, &second, &later[0].id);
    try std.testing.expectEqual(@as(i64, 200_000), later[0].modified_ms);
    try std.testing.expectEqualSlices(u8, &test_id, &later[1].id);
}

test "title sidecars are optional bounded and do not change checkpoint order" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const second: ids.Id = "fedcba9876543210fedcba9876543210".*;
    var first = try Lease.create(&root, test_id);
    defer first.deinit();
    try std.testing.expectError(error.ResumeNotFound, first.saveTitle(&root, session_metadata.Title.fromText("early")));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(root.io, ".thin/sessions/" ++ test_id ++ ".title", .{}));
    try first.save(&root, "one");
    var other = try Lease.create(&root, second);
    defer other.deinit();
    try other.save(&root, "two");
    const before = try list(&root, a);
    defer a.free(before);
    try std.testing.expectEqualStrings("", first.getTitle(&root).text());
    try first.saveTitle(&root, session_metadata.Title.fromText("中文标题"));
    var reader = try Lease.open(&root, test_id, false);
    defer reader.deinit();
    try std.testing.expectEqualStrings("中文标题", reader.getTitle(&root).text());
    try std.testing.expectError(error.ResumeReadOnly, reader.saveTitle(&root, session_metadata.Title.fromText("no")));
    try std.testing.expectEqualStrings("中文标题", first.getTitle(&root).text());
    const after = try list(&root, a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, &before[0].id, &after[0].id);
    try std.testing.expectEqualSlices(u8, &before[1].id, &after[1].id);
    try std.testing.expectEqual(before[0].modified_ms, after[0].modified_ms);
    for (after) |item| {
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, &item.id, &test_id)) "中文标题" else "", item.title.text());
    }
    try tmp.dir.writeFile(root.io, .{ .sub_path = ".thin/sessions/" ++ test_id ++ ".title", .data = "\xff" });
    try std.testing.expectEqualStrings("", reader.getTitle(&root).text());
    const invalid = try list(&root, a);
    defer a.free(invalid);
    for (invalid) |item| try std.testing.expectEqualStrings("", item.title.text());
    try tmp.dir.deleteFile(root.io, ".thin/sessions/" ++ test_id ++ ".title");
    const missing = try list(&root, a);
    defer a.free(missing);
    for (missing) |item| try std.testing.expectEqualStrings("", item.title.text());
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", first.directory_fd, test_id ++ ".title"));
    try std.testing.expectEqualStrings("", reader.getTitle(&root).text());
}

test "resume store atomic private writes concurrent read-only view and interrupted owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    try std.testing.expectError(error.ResumeNotFound, Lease.open(&root, test_id, false));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    {
        var lease = try Lease.create(&root, test_id);
        defer lease.deinit();
        try std.testing.expectEqual(@as(u64, 0), (try fs.fileFromFd(lease.lock_fd).stat(root.io)).size);
        try lease.save(&root, "fake authenticated bytes\x00\xff");
        try std.testing.expectEqual(@as(u64, 0), (try fs.fileFromFd(lease.lock_fd).stat(root.io)).size);
        try std.testing.expectError(error.SessionInUse, Lease.open(&root, test_id, true));
        var view = try Lease.open(&root, test_id, false);
        defer view.deinit();
        const bytes = try view.load(&root);
        defer root.allocator.free(bytes);
        try std.testing.expectEqualStrings("fake authenticated bytes\x00\xff", bytes);
        try std.testing.expectError(error.ResumeReadOnly, view.save(&root, "never"));
    }
    {
        var lease = try Lease.open(&root, test_id, false);
        defer lease.deinit();
        const bytes = try lease.load(&root);
        defer root.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, "fake authenticated bytes\x00\xff", bytes);
        try std.testing.expect(!lease.writable);
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
        try std.testing.expect(lease.writable);
        // Release ownership without a final save.
    }
    var recovered = try Lease.open(&root, test_id, true);
    defer recovered.deinit();
    const recovered_bytes = try recovered.load(&root);
    defer root.allocator.free(recovered_bytes);
    try std.testing.expectEqualStrings("fake authenticated bytes\x00\xff", recovered_bytes);
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
    try std.testing.expectError(error.ResumeConflict, lease.save(&root, "next"));
    const changed = try lease.load(&root);
    defer root.allocator.free(changed);
    try std.testing.expectEqualStrings("changed", changed);
    try lease.save(&root, "next");
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
test "resume store ignores arbitrary legacy markers and permission bits at load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    {
        var lease = try Lease.create(&root, test_id);
        defer lease.deinit();
        try lease.save(&root, "complete JSON-shaped history");
        try fs.fileFromFd(lease.lock_fd).writePositionalAll(root.io, "Aobsolete digest", 0);
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(lease.lock_fd, 0o644));
        const fd = fs.linux.openat(lease.directory_fd, test_id ++ ".session", fs.linux.nofollow | fs.linux.cloexec, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(fd, 0o644));
    }
    var resumed = try Lease.open(&root, test_id, true);
    defer resumed.deinit();
    for ([_][]const u8{ "Aobsolete digest", "Cwrong digest", "arbitrary marker" }) |marker| {
        try fs.fileFromFd(resumed.lock_fd).writePositionalAll(root.io, marker, 0);
        const bytes = try resumed.load(&root);
        defer root.allocator.free(bytes);
        try std.testing.expectEqualStrings("complete JSON-shaped history", bytes);
    }
    try resumed.save(&root, "next complete history");
    const updated = try resumed.load(&root);
    defer root.allocator.free(updated);
    try std.testing.expectEqualStrings("next complete history", updated);
    const stat = try tmp.dir.statFile(root.io, ".thin/sessions/" ++ test_id ++ ".session", .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
