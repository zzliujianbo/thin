const Progress = struct { len: usize, bytes: usize, outstanding: usize };

fn progress(bridge: *Bridge) Progress {
    bridge.lock();
    defer bridge.unlock();
    return .{ .len = bridge.len, .bytes = bridge.bytes, .outstanding = bridge.outstanding };
}

fn multibyteBody(a: std.mem.Allocator) ![]u8 {
    const len = 201 * 1024;
    std.debug.assert(len % 3 == 0);
    const body = try a.alloc(u8, len);
    var at: usize = 0;
    while (at < body.len) : (at += 3) @memcpy(body[at..][0..3], "\xe5\xad\x97");
    return body;
}

const Drained = struct { parts: usize, bytes: usize };

const BodyProducer = struct {
    host_: r.Host,
    cancel: *p.Cancellation,
    body: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,

    fn run(self: *BodyProducer) !void {
        defer self.done.store(true, .release);
        self.host_.emit_fn(self.host_.context, .{ .text = self.body }, self.cancel) catch |err| {
            self.err = err;
        };
    }
};

fn drainBody(bridge: *Bridge, expected: []const u8, kind: Bridge.BodyKind) !Drained {
    const t = std.testing;
    var seen: usize = 0;
    var parts: usize = 0;
    while (bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        const part = switch (kind) {
            .text => if (item.event == .text) item.event.text else return error.WrongEvent,
            .reasoning => if (item.event == .reasoning) item.event.reasoning else return error.WrongEvent,
        };
        try t.expect(part.len <= item_budget);
        try t.expect(!item.display_truncated);
        try t.expect(item.canonical_complete);
        try t.expectEqual(part.len, item.storage.len);
        if (part.len > 0) {
            const lo = @intFromPtr(item.storage.ptr);
            try t.expect(@intFromPtr(part.ptr) >= lo);
            try t.expect(@intFromPtr(part.ptr) + part.len <= lo + item.storage.len);
        }
        try t.expect(std.unicode.utf8ValidateSlice(part));
        try t.expect(seen + part.len <= expected.len);
        try t.expect(std.mem.eql(u8, part, expected[seen..][0..part.len]));
        seen += part.len;
        parts += 1;
    }
    try t.expectEqual(expected.len, seen);
    return .{ .parts = parts, .bytes = seen };
}
