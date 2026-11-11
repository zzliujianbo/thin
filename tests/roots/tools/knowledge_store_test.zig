const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const memory = @import("memory.zig");
const knowledge = @import("../core/knowledge.zig");
const repo = @import("knowledge_store.zig");
const id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
fn rootFor(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !fs.Root {
    var buf: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    return fs.Root.open(a, io, buf[0..n]);
}
