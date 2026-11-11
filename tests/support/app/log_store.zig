fn testRoot(dir: std.Io.Dir) !filesystem.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return filesystem.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}

fn expectContent(root: *filesystem.Root, path: []const u8, expected: []const u8) !void {
    const result = try root.read(std.testing.allocator, path, 0, 4096);
    defer std.testing.allocator.free(result.data);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings(expected, result.data);
}

fn partialWriteFailure(_: ?*anyopaque, file: std.Io.File, _: []const u8, _: []const []const u8, _: usize, offset: u64) std.Io.File.WritePositionalError!usize {
    try file.writePositionalAll(std.testing.io, "{", offset);
    return error.NoSpaceLeft;
}

fn regularStatFailure(_: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
    const stat = try file.stat(std.testing.io);
    if (stat.kind == .file and stat.size == 0) return error.Unexpected;
    return stat;
}

fn jsonlCount(root: *filesystem.Root) !usize {
    var dir = try root.dir.openDir(root.io, ".thin/sessions", .{ .iterate = true });
    defer dir.close(root.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(root.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".jsonl")) count += 1;
    }
    return count;
}

fn openFdCount() !usize {
    const path = if (@import("builtin").os.tag == .macos) "/dev/fd" else "/proc/self/fd";
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
