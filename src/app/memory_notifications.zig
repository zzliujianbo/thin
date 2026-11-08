//! Session-owned, transient Memory completion FIFO. Nodes contain values only;
//! neither evidence nor a coordinator/job allocation survives in this queue.
const std = @import("std");
const status = @import("../core/memory_status.zig");

pub const Node = struct {
    next: ?*Node = null,
    value: status.Terminal = .{ .id = 0, .result = .failed },
    emergency: bool = false,
    in_use: bool = false,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    head: ?*Node = null,
    tail: ?*Node = null,
    // Used only when allocating a reservation fails. Slots are never overwritten
    // while reserved or awaiting consumption. This cannot make an unbounded
    // number of OOM admissions observable without unbounded memory.
    emergency: [8]Node = @splat(.{ .emergency = true }),

    pub fn create(a: std.mem.Allocator) !*Queue {
        const self = try a.create(Queue);
        self.* = .{ .allocator = a };
        return self;
    }

    fn lock(self: *Queue) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    fn unlock(self: *Queue) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    /// Reserve before admission. Once reserved, terminal publication cannot OOM.
    pub fn reserve(self: *Queue) ?*Node {
        self.lock();
        defer self.unlock();
        if (self.allocator.create(Node)) |node| {
            node.* = .{};
            return node;
        } else |_| {}
        for (&self.emergency) |*node| {
            if (!node.in_use) {
                node.in_use = true;
                return node;
            }
        }
        return null;
    }

    /// Transfers an exclusively reserved node into the FIFO without allocation.
    pub fn publish(self: *Queue, node: *Node, value: status.Terminal) void {
        node.value = value;
        node.next = null;
        self.lock();
        defer self.unlock();
        if (self.tail) |tail| tail.next = node else self.head = node;
        self.tail = node;
    }

    pub fn peek(self: *Queue) ?status.Terminal {
        self.lock();
        defer self.unlock();
        return if (self.head) |node| node.value else null;
    }

    /// Nonallocating transfer. A host must push the peeked value successfully
    /// before taking it, and must be the sole consumer for that session.
    pub fn take(self: *Queue) ?status.Terminal {
        self.lock();
        defer self.unlock();
        const node = self.head orelse return null;
        self.head = node.next;
        if (self.head == null) self.tail = null;
        const value = node.value;
        self.releaseLocked(node);
        return value;
    }

    fn releaseLocked(self: *Queue, node: *Node) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&node.value));
        if (node.emergency) {
            node.next = null;
            node.in_use = false;
        } else {
            self.allocator.destroy(node);
        }
    }

    /// The Session joins every coordinator/producer before this call.
    pub fn deinit(self: *Queue) void {
        self.lock();
        while (self.head) |node| {
            self.head = node.next;
            self.releaseLocked(node);
        }
        self.tail = null;
        self.unlock();
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
        const a = self.allocator;
        a.destroy(self);
    }
};

test "completion FIFO peeks without consuming and owns full values" {
    const q = try Queue.create(std.testing.allocator);
    defer q.deinit();
    var first: status.Terminal = .{ .id = 4, .result = .saved, .saved_count = 2 };
    first.summary.append("first saved fact");
    q.publish(q.reserve().?, first);
    q.publish(q.reserve().?, .{ .id = 5, .result = .canceled, .failure = .canceled });
    try std.testing.expectEqual(@as(u64, 4), q.peek().?.id);
    try std.testing.expectEqual(@as(u64, 4), q.peek().?.id);
    const taken = q.take().?;
    try std.testing.expectEqual(@as(u32, 2), taken.saved_count);
    try std.testing.expectEqualStrings("first saved fact", taken.summary.text());
    try std.testing.expectEqual(@as(u64, 5), q.take().?.id);
    try std.testing.expect(q.peek() == null);
}

test "reserved emergency nodes survive OOM and can be reused" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const q = try Queue.create(failing.allocator());
    defer q.deinit();
    failing.fail_index = failing.alloc_index;
    for (0..q.emergency.len) |i| q.publish(q.reserve().?, .{ .id = @intCast(i + 1), .result = .failed });
    try std.testing.expect(q.reserve() == null);
    try std.testing.expectEqual(@as(u64, 1), q.take().?.id);
    q.publish(q.reserve().?, .{ .id = 9, .result = .skipped });
    for (2..10) |i| try std.testing.expectEqual(@as(u64, @intCast(i)), q.take().?.id);
    try std.testing.expect(q.take() == null);
}
