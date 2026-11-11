fn freeEntry(a: std.mem.Allocator, entry: Entry) void {
    a.free(entry.content);
    a.free(entry.version);
}

fn testRoot(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buffer);
    return Root.open(a, io, buffer[0..n]);
}

fn competingWrite(store: *Store, expected: []const u8, text: []const u8) !bool {
    const a = std.heap.page_allocator;
    const result = store.write(a, "topic", text, expected) catch |err| {
        if (err == error.VersionConflict) return false;
        return err;
    };
    defer freeEntry(a, result);
    return true;
}

extern "c" fn fork() c_int;

extern "c" fn waitpid(c_int, *c_int, c_int) c_int;

extern "c" fn _exit(c_int) noreturn;
