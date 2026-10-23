//! Forgetting must remove deferred source plaintext even with Auto memory Off.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const mem = @import("memory.zig");
const k = @import("../core/knowledge.zig");
const Queue = @import("memory_queue.zig").Queue;

test "manual memory correction and deletion purge queued failed and uncertain source plaintext" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |remove| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        var root = try fs.Root.open(a, io, buffer[0..try tmp.dir.realPath(io, &buffer)]);
        defer root.deinit();
        var store = mem.Store.init(&root, .{});
        const entry = try store.write(a, "obsolete", "forgotten fact", null);
        defer a.free(entry.content);
        defer a.free(entry.version);
        const generation = try store.generation();
        var queue = Queue.init(&root);
        const material: k.Material = .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .generation = generation, .created_ms = 1, .sources = &.{.{ .id = 0, .kind = .user, .text = "forgotten fact in a failed extraction" }} };
        try queue.enqueue(a, material);
        try queue.mark(a, material.id, .sending);
        try queue.mark(a, material.id, .uncertain);
        if (remove) {
            try store.delete("obsolete", entry.version);
        } else {
            const replacement = try store.write(a, "obsolete", "corrected fact", entry.version);
            a.free(replacement.content);
            a.free(replacement.version);
        }
        const status = try queue.status(a);
        defer a.free(status);
        try std.testing.expectEqualStrings("", status);
        try std.testing.expectError(error.FileNotFound, root.read(a, ".thin/memory/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json", 0, 65536));
        try std.testing.expectError(error.GenerationConflict, store.writeGuarded(a, "resurrect", "forgotten fact", null, generation));
    }
}
