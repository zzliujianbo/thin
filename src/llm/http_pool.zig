//! Linux-only, bounded preflight for std.http.Client's idle pool. Never probes
//! used connections, consumes peer bytes, waits for socket data, or replays POSTs.
//! A peer can still close after this check; that remains an ordinary failure.
const std = @import("std");
const Io = std.Io;

pub const idle_limit_ms = 30_000;
const max_idle = 32; // std.http.Client's default pool bound; do not grow it here.
const Poll = *const fn ([]std.c.pollfd) c_int;

pub fn expired(last: ?Io.Timestamp, now: Io.Timestamp) bool {
    const before = last orelse return true; // Untracked idle sockets are not fresh.
    const age = @as(i128, now.nanoseconds) - @as(i128, before.nanoseconds);
    return age < 0 or age >= @as(i128, idle_limit_ms) * std.time.ns_per_ms;
}

fn nativePoll(fds: []std.c.pollfd) c_int {
    return std.c.poll(fds.ptr, @intCast(fds.len), 0);
}

pub fn prune(client: *std.http.Client, last: ?Io.Timestamp, now: Io.Timestamp) !void {
    return pruneWith(client, last, now, nativePoll);
}

/// The injected check is for deterministic offline fault tests only. All pool
/// changes remain under its mutex; destroy only after unlinking owned free nodes.
pub fn pruneWith(client: *std.http.Client, last: ?Io.Timestamp, now: Io.Timestamp, check: Poll) !void {
    const pool = &client.connection_pool;
    try pool.mutex.lock(client.io);
    defer pool.mutex.unlock(client.io);
    if (pool.free_size > max_idle or pool.free_len > max_idle) return error.ConnectionPoolLimit;

    var entries: [max_idle]*std.http.Client.Connection = undefined;
    var fds: [max_idle]std.c.pollfd = undefined;
    var len: usize = 0;
    var next = pool.free.first;
    while (next) |node| : (len += 1) {
        if (len == max_idle) return error.ConnectionPoolLimit;
        const connection: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
        next = node.next;
        entries[len] = connection;
        // Readability (including EOF/TLS control records) is suspicious on an
        // idle HTTP connection. Never request POLLOUT: healthy sockets are writable.
        fds[len] = .{ .fd = connection.stream_reader.stream.socket.handle, .events = std.c.POLL.IN, .revents = 0 };
    }
    if (len == 0) return;
    const all = expired(last, now);
    // No retry even on EINTR: inability to check conservatively drops idle nodes.
    const checked = if (all) false else check(fds[0..len]) >= 0;
    for (entries[0..len], fds[0..len]) |connection, fd| {
        const buffered = connection.reader().bufferedLen() != 0 or connection.stream_reader.interface.bufferedLen() != 0;
        if (!all and checked and fd.revents == 0 and !buffered and !connection.closing) continue;
        pool.free.remove(&connection.pool_node);
        pool.free_len -= 1;
        connection.destroy(client.io);
    }
}

test "idle expiry has exact boundary regression and overflow safe clock arithmetic" {
    const start: Io.Timestamp = .fromNanoseconds(100 * std.time.ns_per_ms);
    try std.testing.expect(expired(null, start));
    try std.testing.expect(!expired(start, start));
    try std.testing.expect(!expired(start, .fromNanoseconds(start.nanoseconds + (idle_limit_ms - 1) * std.time.ns_per_ms)));
    try std.testing.expect(expired(start, .fromNanoseconds(start.nanoseconds + idle_limit_ms * std.time.ns_per_ms)));
    try std.testing.expect(expired(start, .fromNanoseconds(start.nanoseconds - 1)));
    try std.testing.expect(expired(.fromNanoseconds(std.math.minInt(i96)), .fromNanoseconds(std.math.maxInt(i96))));
}

fn unexpectedPoll(_: []std.c.pollfd) c_int {
    @panic("empty free pool must not be polled");
}

test "empty idle sweep never visits used nodes and invalid pool bounds fail closed" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var active: std.DoublyLinkedList.Node = .{};
    client.connection_pool.used.append(&active);
    defer client.connection_pool.used.remove(&active);
    try pruneWith(&client, null, .zero, unexpectedPoll);
    try std.testing.expectEqual(&active, client.connection_pool.used.first.?);
    client.connection_pool.free_size = max_idle + 1;
    try std.testing.expectError(error.ConnectionPoolLimit, pruneWith(&client, null, .zero, unexpectedPoll));
}
