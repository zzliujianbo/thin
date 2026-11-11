fn testOpen(dir: std.Io.Dir) !Store {
    var path: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &path);
    return Store.open(std.testing.allocator, std.testing.io, path[0..n]);
}

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
