fn freeEntry(a: std.mem.Allocator, entry: Entry) void {
    a.free(entry.content);
}

fn testRoot(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buffer);
    return Root.open(a, io, buffer[0..n]);
}

fn competingWrite(store: *Store, text: []const u8) !bool {
    const a = std.heap.page_allocator;
    const result = try store.replace(a, "topic", text);
    defer freeEntry(a, result);
    return true;
}

extern "c" fn fork() c_int;

extern "c" fn waitpid(c_int, *c_int, c_int) c_int;

extern "c" fn _exit(c_int) noreturn;
