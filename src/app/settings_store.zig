//! Explicit project-only settings; no global config, archives, history or secrets.
//! Own Root by value: do not retain pointers to a movable Store.root.
//! Locks serialize cooperative writers on the SAME .thin inode only, bounded to
//! 100 attempts with 2ms sleeps. Atomic visibility is not fsync durability or a
//! security boundary against malicious same-user directory replacement.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const activity = @import("../presentation/activity.zig");

pub const file_name = "settings.json";
pub const relative_path = ".thin/settings.json";
pub const max_bytes = 1024;

fn parse(a: std.mem.Allocator, bytes: []const u8) !activity.ReasoningEffort {
    if (bytes.len > max_bytes) return error.SettingsTooLarge;
    try fs.validateText(bytes);
    // Value parsing avoids typed integer parsing accepting JSON string "1".
    // Explicit shape checks retain strict unknown/missing/type validation.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 2) return error.InvalidSettings;
    const version = parsed.value.object.get("version") orelse return error.InvalidSettings;
    if (version != .integer or version.integer != 1) return error.InvalidSettingsVersion;
    const effort = parsed.value.object.get("reasoning_effort") orelse return error.InvalidSettings;
    if (effort != .string) return error.InvalidReasoningEffort;
    const name = effort.string;
    if (std.mem.eql(u8, name, "none")) return .off;
    inline for (.{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |known| {
        if (std.mem.eql(u8, name, known)) return @field(activity.ReasoningEffort, known);
    }
    return error.InvalidReasoningEffort;
}

fn read(root: *fs.Root) !?activity.ReasoningEffort {
    const fd = fs.linux.openat(root.dir.handle, file_name, fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0);
    if (fd < 0) {
        if (std.c._errno().* == 2) return null;
        return fs.osError();
    }
    defer fs.closeFd(fd);
    const file = fs.fileFromFd(fd);
    const stat = try file.stat(root.io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max_bytes) return error.SettingsTooLarge;
    var bytes: [max_bytes + 1]u8 = undefined;
    const n = try file.readPositionalAll(root.io, &bytes, 0);
    if (n > max_bytes) return error.SettingsTooLarge;
    if (n != stat.size) return error.FileChanged;
    return try parse(root.allocator, bytes[0..n]);
}

pub const Store = struct {
    root: fs.Root,

    pub fn open(a: std.mem.Allocator, io: std.Io, project: []const u8) !Store {
        return .{ .root = try fs.Root.open(a, io, project) };
    }

    pub fn deinit(self: *Store) void {
        self.root.deinit();
        self.* = undefined;
    }

    // Allocate the lexical path BEFORE mkdir/commit; fd ownership stays local.
    fn directory(self: *Store, create: bool) !fs.Root {
        const path = try std.fs.path.join(self.root.allocator, &.{ self.root.path, ".thin" });
        errdefer self.root.allocator.free(path);
        const fd = fs.openDirectory(self.root.dir.handle, ".thin") catch |err| blk: {
            if (!create or err != error.FileNotFound) return err;
            if (std.c.mkdirat(self.root.dir.handle, ".thin", 0o700) != 0 and std.c._errno().* != 17) return fs.osError();
            break :blk try fs.openDirectory(self.root.dir.handle, ".thin");
        };
        return .{ .dir = .{ .handle = fd }, .path = path, .io = self.root.io, .allocator = self.root.allocator };
    }

    pub fn load(self: *Store) !?activity.ReasoningEffort {
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer dir.deinit();
        return read(&dir);
    }

    pub fn save(self: *Store, effort: activity.ReasoningEffort) !void {
        const name: []const u8 = switch (effort) {
            .off => "off",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
            .max => "max",
            else => return error.InvalidReasoningEffort,
        };
        var buffer: [128]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&buffer, "{{\"version\":1,\"reasoning_effort\":\"{s}\"}}\n", .{name});
        var dir = try self.directory(true);
        defer dir.deinit(); // also releases lock; same fd anchors validation/write
        var locked = false;
        for (0..100) |_| {
            if (fs.linux.flock(dir.dir.handle, 2 | 4) == 0) {
                locked = true;
                break;
            }
            const errno = std.c._errno().*;
            if (errno != 11 and errno != 4) return fs.osError();
            try std.Io.sleep(dir.io, .fromMilliseconds(2), .awake);
        }
        if (!locked) return error.SettingsStoreBusy;
        _ = try read(&dir); // refuse to repair malformed/nonregular old settings
        try dir.writeMode(file_name, bytes, true, 0o600);
        // No fallible work after atomic commit.
    }
};

fn testOpen(dir: std.Io.Dir) !Store {
    var path: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &path);
    return Store.open(std.testing.allocator, std.testing.io, path[0..n]);
}

test "settings missing is lazy and roundtrips with private modes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    try std.testing.expectEqual(@as(?activity.ReasoningEffort, null), try store.load());
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(store.root.dir.handle, ".thin"));
    for ([_]activity.ReasoningEffort{ .off, .minimal, .low, .medium, .high, .xhigh, .max }) |effort| {
        try store.save(effort);
        try std.testing.expectEqual(effort, (try store.load()).?);
    }
    const ds = try tmp.dir.statFile(std.testing.io, ".thin", .{});
    const st = try tmp.dir.statFile(std.testing.io, relative_path, .{});
    try std.testing.expectEqual(@as(u32, 0o700), ds.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), st.permissions.toMode() & 0o777);
    try std.testing.expectError(error.InvalidReasoningEffort, store.save(.unspecified));
    try std.testing.expectError(error.InvalidReasoningEffort, store.save(.unknown));
}

test "settings strict schema legacy and malformed rollback" {
    try std.testing.expectEqual(activity.ReasoningEffort.off, try parse(std.testing.allocator, "{\"version\":1,\"reasoning_effort\":\"none\"}"));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    try store.save(.off);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = relative_path, .data = "{\"version\":1,\"reasoning_effort\":\"none\"}" });
    try std.testing.expectEqual(activity.ReasoningEffort.off, (try store.load()).?);
    try store.save((try store.load()).?);
    const canonical = try store.root.read(std.testing.allocator, relative_path, 0, max_bytes);
    defer std.testing.allocator.free(canonical.data);
    try std.testing.expectEqualStrings("{\"version\":1,\"reasoning_effort\":\"off\"}\n", canonical.data);
    for ([_][]const u8{
        "{}",                                               "{",                                                            "null",                                                       "{\"version\":1}",                                                           "{\"reasoning_effort\":\"off\"}",
        "{\"version\":2,\"reasoning_effort\":\"off\"}",     "{\"version\":1.0,\"reasoning_effort\":\"off\"}",               "{\"version\":true,\"reasoning_effort\":\"off\"}",            "{\"version\":\"1\",\"reasoning_effort\":\"off\"}",                          "{\"version\":1,\"reasoning_effort\":false}",
        "{\"version\":1,\"reasoning_effort\":\"unknown\"}", "{\"version\":1,\"reasoning_effort\":\"off\",\"model\":\"x\"}", "{\"version\":1,\"version\":1,\"reasoning_effort\":\"off\"}", "{\"version\":1,\"reasoning_effort\":\"off\",\"reasoning_effort\":\"off\"}", "\xff",
        "\x00",
    }) |bad| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = relative_path, .data = bad });
        if (store.load()) |_| return error.ExpectedInvalidSettings else |_| {}
        if (store.save(.high)) |_| return error.ExpectedInvalidSettings else |_| {}
        var dir = try store.directory(false);
        defer dir.deinit();
        const fd = fs.linux.openat(dir.dir.handle, file_name, fs.linux.nofollow | fs.linux.cloexec, 0);
        try std.testing.expect(fd >= 0);
        defer fs.closeFd(fd);
        var buffer: [max_bytes + 1]u8 = undefined;
        const n = try fs.fileFromFd(fd).readPositionalAll(std.testing.io, &buffer, 0);
        try std.testing.expectEqualStrings(bad, buffer[0..n]);
    }
}

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;

test "settings rejects oversized symlink directory FIFO and unsafe thin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    try store.save(.off);
    const oversized: [max_bytes + 1]u8 = @splat(' ');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = relative_path, .data = &oversized });
    try std.testing.expectError(error.SettingsTooLarge, store.load());
    try std.testing.expectError(error.SettingsTooLarge, store.save(.high));
    var dir = try store.directory(false);
    defer dir.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(dir.dir.handle, file_name, 0));
    try std.testing.expectEqual(@as(?activity.ReasoningEffort, null), try store.load());
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", dir.dir.handle, file_name));
    try std.testing.expectError(error.SymlinkNotAllowed, store.load());
    try std.testing.expectError(error.SymlinkNotAllowed, store.save(.high));
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(dir.dir.handle, file_name, 0));
    try std.testing.expectEqual(@as(c_int, 0), mkfifoat(dir.dir.handle, file_name, 0o600));
    try std.testing.expectError(error.NotRegularFile, store.load());
    try std.testing.expectError(error.NotRegularFile, store.save(.high));
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(dir.dir.handle, file_name, 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(dir.dir.handle, file_name, 0o700));
    try std.testing.expectError(error.NotRegularFile, store.load());
    try std.testing.expectError(error.NotRegularFile, store.save(.high));

    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    var unsafe_store = try testOpen(other.dir);
    defer unsafe_store.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat(".", other.dir.handle, ".thin"));
    try std.testing.expectError(error.NotDir, unsafe_store.load());
    try std.testing.expectError(error.NotDir, unsafe_store.save(.off));
}

test "settings bounded same inode lock and existing directory policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, ".thin", 0o755));
    const fd = try fs.openDirectory(tmp.dir.handle, ".thin");
    defer fs.closeFd(fd);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(fd, 0o755));
    try store.save(.off);
    try std.testing.expectEqual(@as(c_int, 0), fs.linux.flock(fd, 2 | 4));
    try std.testing.expectError(error.SettingsStoreBusy, store.save(.max));
    try std.testing.expectEqual(activity.ReasoningEffort.off, (try store.load()).?);
    try std.testing.expectEqual(@as(c_int, 0), fs.linux.flock(fd, 8));
    try store.save(.max);
    const st = try tmp.dir.statFile(std.testing.io, ".thin", .{});
    try std.testing.expectEqual(@as(u32, 0o755), st.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(fd, file_name, 0o644, 0));
    try store.save(.low);
    const mode = try tmp.dir.statFile(std.testing.io, relative_path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), mode.permissions.toMode() & 0o777);
}

fn partialWriteFailure(_: ?*anyopaque, file: std.Io.File, _: []const u8, _: []const []const u8, _: usize, offset: u64) std.Io.File.WritePositionalError!usize {
    try file.writePositionalAll(std.testing.io, "{", offset);
    return error.NoSpaceLeft;
}

fn fdCount() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(std.testing.io)) |_| n += 1;
    return n;
}

test "settings partial write rollback cleans temps fds and releases lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    try store.save(.medium);
    var vtable = store.root.io.vtable.*;
    store.root.io.vtable = &vtable;
    vtable.fileWritePositional = partialWriteFailure;
    const before = try fdCount();
    for (0..8) |_| try std.testing.expectError(error.NoSpaceLeft, store.save(.high));
    try std.testing.expectEqual(before, try fdCount());
    try std.testing.expectEqual(activity.ReasoningEffort.medium, (try store.load()).?);
    var thin = try tmp.dir.openDir(std.testing.io, ".thin", .{ .iterate = true });
    defer thin.close(std.testing.io);
    var it = thin.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings(file_name, entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    vtable.fileWritePositional = std.testing.io.vtable.fileWritePositional;
    try store.save(.high);
}

test "settings project replacement remains inode anchored and duplicate survives store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
    var project = try tmp.dir.openDir(std.testing.io, "project", .{});
    defer project.close(std.testing.io);
    var store = try testOpen(project);
    try store.save(.low);
    try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(tmp.dir.handle, "project", tmp.dir.handle, "retired"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
    var activation = Store{ .root = try store.root.duplicate() };
    defer activation.deinit();
    store.deinit();
    try std.testing.expectEqual(activity.ReasoningEffort.low, (try activation.load()).?);
    try activation.save(.max);
    const replacement = try fs.openDirectory(tmp.dir.handle, "project");
    defer fs.closeFd(replacement);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(replacement, ".thin"));
    const old = try project.statFile(std.testing.io, relative_path, .{});
    try std.testing.expect(old.kind == .file);
}

test "settings allocation failure before mkdir leaves missing directory untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original = store.root.allocator;
    store.root.allocator = failing.allocator();
    defer store.root.allocator = original;
    try std.testing.expectError(error.OutOfMemory, store.save(.off));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(store.root.dir.handle, ".thin"));
}
