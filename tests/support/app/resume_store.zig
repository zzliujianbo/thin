fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}

const test_id: ids.Id = "0123456789abcdef0123456789abcdef".*;

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
