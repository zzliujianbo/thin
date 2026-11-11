fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}

fn expectWriterWaiting(journal: *Journal) !void {
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (@atomicLoad(std.Io.Event, &journal.wake, .acquire) != .waiting) {
        try std.testing.expectEqual(null, journal.failure());
        try std.testing.expect(start.untilNow(std.testing.io, .awake).toMilliseconds() < 1000);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
}

fn canceledWriterWait(_: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
    return error.Canceled;
}

const CloseoutProducers = struct {
    const n = 12;
    journal: *Journal,
    sink: diagnostics.Sink,
    dropped: std.atomic.Value(bool) = .init(false),
    go: std.atomic.Value(bool) = .init(false),
    primary_started: std.atomic.Value(bool) = .init(false),
    aux_started: std.atomic.Value(bool) = .init(false),
    primary_done: std.atomic.Value(bool) = .init(false),
    aux_done: std.atomic.Value(bool) = .init(false),
    aux_ok: bool = false,
    ids: [n]u64 = undefined,

    // A bounded handshake ensures failures cannot strand a join.
    fn wait(flag: *std.atomic.Value(bool), io: std.Io) bool {
        for (0..5000) |_| {
            if (flag.load(.acquire)) return true;
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch return false;
        }
        return false;
    }

    fn run(self: *CloseoutProducers) void {
        // The primary thread holds producer_mutex throughout this call.
        self.sink.emit(.{ .stage = .memory_finalize });
        self.dropped.store(true, .release);
        if (!wait(&self.go, self.journal.root.io)) return;
        for (&self.ids, 0..) |*id, i| {
            id.* = self.sink.next();
            self.sink.emit(.{ .stage = .memory_finalize, .phase = .begin, .span_id = id.* });
            self.sink.emit(.{ .stage = .memory_finalize, .phase = .end, .span_id = id.* });
            if (i == 0) {
                self.aux_started.store(true, .release);
                if (!wait(&self.primary_started, self.journal.root.io)) return;
            }
        }
        self.aux_done.store(true, .release);
        self.aux_ok = wait(&self.primary_done, self.journal.root.io);
    }
};
