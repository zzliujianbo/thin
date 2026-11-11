//! Secret process stdin: Linux memfd, Darwin bounded concurrent pipe producer.
//! No pathname or argv ever contains the input. A started Input must remain at
//! the same address, and its borrowed bytes must live until finish/deinit joins.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../core/protocol.zig");
const c = std.c;
const Io = std.Io;
const WriteError = error{ Canceled, Timeout, AnonymousInputFailed };

pub const Input = struct {
    fd: c.fd_t,
    write_fd: c.fd_t = -1,
    bytes: []const u8,
    cancellation: protocol.Cancellation = .{},
    future: ?Io.Future(WriteError!void) = null,

    /// config may include a zero-filled tail retained by the owner for wiping.
    /// Accepted curl fields are NUL-free; only the written prefix is input.
    pub fn init(config: []const u8) !Input {
        const length = std.mem.indexOfScalar(u8, config, 0) orelse config.len;
        const bytes = config[0..length];
        if (builtin.os.tag == .linux) {
            // Keep the existing Linux syscall path: do not introduce a newer
            // glibc memfd_create symbol requirement into Linux products.
            const linux = std.os.linux;
            const rc = linux.memfd_create("thin-decision", linux.MFD.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return error.AnonymousInputFailed;
            const fd: c.fd_t = @intCast(rc);
            errdefer {
                wipeMemfd(fd, bytes.len);
                _ = c.close(fd);
            }
            var offset: usize = 0;
            while (offset < bytes.len) {
                // Positional writes preserve stdin's initial shared offset.
                const n = c.pwrite(fd, bytes[offset..].ptr, bytes.len - offset, @intCast(offset));
                switch (c.errno(n)) {
                    .SUCCESS => {
                        if (n == 0) return error.AnonymousInputFailed;
                        offset += @intCast(n);
                    },
                    .INTR => continue,
                    else => return error.AnonymousInputFailed,
                }
            }
            return .{ .fd = fd, .bytes = bytes };
        }
        if (builtin.os.tag != .macos) @compileError("unsupported anonymous input platform");

        var fds: [2]c.fd_t = undefined;
        if (c.pipe(&fds) != 0) return error.AnonymousInputFailed;
        errdefer {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
        }
        // This is not atomic CLOEXEC. Darwin spawn must use its default-close
        // policy / explicit FD allowlist, also excluding this producer's end.
        for (&fds) |*fd| {
            if (fd.* <= 2) {
                const moved = c.fcntl(fd.*, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
                if (moved < 0) return error.AnonymousInputFailed;
                _ = c.close(fd.*);
                fd.* = moved;
            } else if (c.fcntl(fd.*, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) {
                return error.AnonymousInputFailed;
            }
        }
        const flags = c.fcntl(fds[1], c.F.GETFL);
        if (flags < 0 or c.fcntl(fds[1], c.F.SETFL, flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) < 0)
            return error.AnonymousInputFailed;
        // Per-descriptor Darwin protection, not a process-wide signal handler
        // or a thread signal mask that could leak across Io worker migration.
        if (c.fcntl(fds[1], c.F.SETNOSIGPIPE, @as(c_int, 1)) < 0)
            return error.AnonymousInputFailed;
        // Reader stays blocking for curl. No bytes are written until start;
        // writing a large config synchronously here would deadlock pre-spawn.
        return .{ .fd = fds[0], .write_fd = fds[1], .bytes = bytes };
    }

    pub fn file(self: *const Input) Io.File {
        return .{ .handle = self.fd, .flags = .{ .nonblocking = false } };
    }

    /// Call immediately before process.run, passing &self.cancellation to run.
    /// Producer failures cancel only this request, never the parent's token.
    pub fn start(self: *Input, io: Io, parent: *const protocol.Cancellation, timeout_ms: u32) !void {
        self.cancellation.parent = parent;
        if (builtin.os.tag == .macos) {
            self.future = try Io.concurrent(io, produce, .{ self, io, Io.Clock.awake.now(io), timeout_ms });
        }
    }

    fn produce(self: *Input, io: Io, since: Io.Timestamp, timeout_ms: u32) WriteError!void {
        defer self.closeWriter(); // EOF on success, also close on every error.
        errdefer self.cancellation.cancel();
        var offset: usize = 0;
        while (offset < self.bytes.len) {
            if (self.cancellation.isRequested()) return error.Canceled;
            try io.checkCancel();
            if (since.untilNow(io, .awake).toMilliseconds() >= timeout_ms) return error.Timeout;
            const count = @min(self.bytes.len - offset, 16 * 1024);
            const n = c.write(self.write_fd, self.bytes[offset..].ptr, count);
            switch (c.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return error.AnonymousInputFailed;
                    offset += @intCast(n);
                },
                .INTR => continue, // Recheck cancellation/deadline on every retry.
                .AGAIN => try Io.sleep(io, .fromMilliseconds(2), .awake),
                // Includes EPIPE: SETNOSIGPIPE prevents process termination.
                else => return error.AnonymousInputFailed,
            }
        }
    }

    /// Only after process.run has returned (its stdin_file borrow has ended).
    /// Cancel AND join even on success; an incomplete producer is not success.
    /// Caller must inspect the returned error before accepting a process result.
    pub fn finish(self: *Input, io: Io) ?WriteError {
        if (builtin.os.tag == .macos) {
            var failure: ?WriteError = null;
            if (self.future) |*future| {
                failure = if (future.cancel(io)) |_| null else |err| err;
                self.future = null;
            }
            // Stop/join before closing the borrowed reader: synthesizing EPIPE
            // here could otherwise mask run's timeout or sink cancellation.
            // The parent retains this end until run's borrow ends; a stalled
            // producer is still bounded by its own deadline/cancellation.
            self.closeWriter();
            if (self.fd >= 0) _ = c.close(self.fd);
            self.fd = -1;
            return failure;
        }
        return null;
    }

    fn closeWriter(self: *Input) void {
        if (self.write_fd >= 0) _ = c.close(self.write_fd);
        self.write_fd = -1;
    }

    pub fn deinit(self: *Input, io: Io) void {
        _ = self.finish(io);
        if (self.fd < 0) return;
        if (builtin.os.tag == .linux) wipeMemfd(self.fd, self.bytes.len);
        _ = c.close(self.fd);
        self.fd = -1;
    }
};

fn wipeMemfd(fd: c.fd_t, length: usize) void {
    var zeros: [4096]u8 = @splat(0);
    var offset: usize = 0;
    while (offset < length) {
        const count = @min(zeros.len, length - offset);
        const n = c.pwrite(fd, &zeros, count, @intCast(offset));
        switch (c.errno(n)) {
            .SUCCESS => {
                if (n == 0) break;
                offset += @intCast(n);
            },
            .INTR => continue,
            else => break,
        }
    }
    // Always truncate, including when a best-effort overwrite failed.
    while (c.errno(c.ftruncate(fd, 0)) == .INTR) {}
}

test "Darwin anonymous input streams beyond pipe capacity with protected descriptors" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var input = try Input.init(bytes);
    defer input.deinit(io);
    for ([_]c.fd_t{ input.fd, input.write_fd }) |fd| {
        try std.testing.expect(fd > 2);
        try std.testing.expect(c.fcntl(fd, c.F.GETFD) & c.FD_CLOEXEC != 0);
    }
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    try std.testing.expect(c.fcntl(input.fd, c.F.GETFL) & nonblock == 0);
    try std.testing.expect(c.fcntl(input.write_fd, c.F.GETFL) & nonblock != 0);
    try std.testing.expectEqual(@as(c_int, 1), c.fcntl(input.write_fd, c.F.GETNOSIGPIPE));
    var cancel: protocol.Cancellation = .{};
    try input.start(io, &cancel, 2000);
    // Native blocking consumer runs concurrently with the producer, as curl
    // does. Producer error/deadline closes its end, so this also terminates.
    var buffer: [8192]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = c.read(input.fd, &buffer, buffer.len);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return error.TestReadFailed;
        }
        if (n == 0) break;
        const count: usize = @intCast(n);
        try std.testing.expect(total + count <= bytes.len);
        try std.testing.expectEqualSlices(u8, bytes[total..][0..count], buffer[0..count]);
        total += count;
    }
    try std.testing.expectEqual(bytes.len, total);
    try std.testing.expectEqual(@as(?WriteError, null), input.finish(io));
    try std.testing.expectEqual(@as(c.fd_t, -1), input.fd);
    try std.testing.expectEqual(@as(c.fd_t, -1), input.write_fd);
    try std.testing.expect(!cancel.isRequested());
}

test "Darwin stalled input is bounded and parent cancellation is not mutated" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const bytes = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var input = try Input.init(bytes);
    defer input.deinit(io);
    var parent: protocol.Cancellation = .{};
    try input.start(io, &parent, 10);
    if (input.future) |*future| try std.testing.expectError(error.Timeout, future.await(io));
    try std.testing.expect(input.cancellation.isRequested());
    try std.testing.expect(!parent.isRequested());
    try std.testing.expectEqual(@as(?WriteError, error.Timeout), input.finish(io));

    var stopped = try Input.init(bytes);
    defer stopped.deinit(io);
    try stopped.start(io, &parent, 2000);
    // No consumer: an input larger than pipe capacity cannot have completed.
    try std.testing.expectEqual(@as(?WriteError, error.Canceled), stopped.finish(io));
    try std.testing.expect(!parent.isRequested());

    var canceled = try Input.init(bytes);
    defer canceled.deinit(io);
    parent.cancel();
    try canceled.start(io, &parent, 2000);
    try std.testing.expectEqual(@as(?WriteError, error.Canceled), canceled.finish(io));
}

test "Darwin closed anonymous input peer is a producer failure not SIGPIPE" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var input = try Input.init("secret");
    defer input.deinit(io);
    _ = c.close(input.fd);
    input.fd = -1;
    var parent: protocol.Cancellation = .{};
    try input.start(io, &parent, 2000);
    if (input.future) |*future| try std.testing.expectError(error.AnonymousInputFailed, future.await(io));
    try std.testing.expectEqual(@as(?WriteError, error.AnonymousInputFailed), input.finish(io));
    try std.testing.expect(!parent.isRequested());
}
