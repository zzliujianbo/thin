//! Exclusive control-client owner and bounded UI handoff. This task may wait
//! for a control reply; the separate subscription receiver keeps reading and
//! the TUI never waits for this task. No callbacks or borrowed arenas cross
//! threads. Queue admission and remote completion are distinct operations.
const std = @import("std");
const Client = @import("client.zig").Client;
const action = @import("../ui/remote_action.zig");
const session = @import("../ui/session_client.zig");
const Cancellation = @import("../core/protocol.zig").Cancellation;
const Wakeup = @import("../platform/wakeup.zig").Wakeup;
const AckRanges = @import("stream_receiver.zig").AckRanges;

pub const View = struct {
    generation: u64,
    revision: u64,
    watermark: u64,
    projection: *Client.Projection,
    /// Only an ordered stream snapshot can settle a running display. A control
    /// reply may update configuration, but cannot jump over queued terminal.
    ordered: bool,
};
pub const Display = struct {
    generation: u64,
    value: union(enum) { event: session.Item, view: View },

    pub fn bytes(self: Display) usize {
        return switch (self.value) {
            .event => |item| item.storage.len + @sizeOf(Display),
            .view => |view| view.projection.arena.queryCapacity() + @sizeOf(Display),
        };
    }
    pub fn deinit(self: *Display) void {
        switch (self.value) {
            .event => |*item| item.deinit(),
            .view => |view| view.projection.deinit(),
        }
    }
};
pub const Completed = struct {
    completion: action.Completion,
    view: ?View,

    pub fn deinit(self: *Completed) void {
        self.completion.deinit();
        if (self.view) |view| view.projection.deinit();
    }
};

pub const Communication = struct {
    pub const command_capacity = 8;
    pub const display_capacity = 64;
    pub const display_budget = 8 * 1024 * 1024;
    client: *Client,
    a: std.mem.Allocator,
    io: std.Io,
    stop: Cancellation = .{},
    wake: Wakeup,
    ready: Wakeup,
    future: ?std.Io.Future(void) = null,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    requests: [command_capacity]?*action.Owned = @splat(null),
    request_head: usize = 0,
    request_count: usize = 0,
    completions: [command_capacity]?Completed = @splat(null),
    completion_head: usize = 0,
    completion_count: usize = 0,
    outstanding: usize = 0,
    next_ticket: u64 = 0,
    displays: [display_capacity]?Display = @splat(null),
    display_head: usize = 0,
    display_count: usize = 0,
    display_bytes: usize = 0,
    failure: ?anyerror = null,
    /// Bounded, nonblocking UI admission of already-displayed ranges. Adjacent
    /// ranges coalesce; a hole is never bridged and never reduced to a max.
    ack_epoch: u64 = 0,
    ack_ranges: AckRanges = .{},
    /// Leading ranges already handed to the subscription owner. Entries before
    /// this index are frozen so the receiver's proof cannot be rewritten.
    ack_accepted: usize = 0,

    // The following fields belong exclusively to the communication task.
    generation: u64 = 1,
    identity: Identity,
    revision: u64,
    stream_revision: u64,
    pending_view: ?Display = null,
    pending_event: ?Display = null,
    command_inflight: bool = false,
    hold_configuration: bool = false,
    deferred_failure: ?anyerror = null,

    const Identity = struct {
        session_id: ?[32]u8,
        epoch: u64,
        launcher: u64,
        fn of(client: *Client) Identity {
            return .{ .session_id = client.session, .epoch = client.epoch, .launcher = std.hash.Wyhash.hash(0, client.launcher) };
        }
    };

    /// Caller must not touch client until deinit joins this owner. It may use a
    /// previously exported immutable Projection for the first UI frame.
    pub fn start(client: *Client) !*Communication {
        const a = client.a;
        const self = try a.create(Communication);
        errdefer a.destroy(self);
        var wake = try Wakeup.init();
        errdefer wake.deinit();
        var ready = try Wakeup.init();
        errdefer ready.deinit();
        self.* = .{ .client = client, .a = a, .io = client.io, .wake = wake, .ready = ready, .identity = Identity.of(client), .revision = client.publication_revision, .stream_revision = client.stream_publication_revision };
        client.wait_cancel = &self.stop;
        client.wait_progress_context = self;
        client.wait_progress_fn = progress;
        errdefer {
            client.wait_cancel = null;
            client.wait_progress_context = null;
            client.wait_progress_fn = null;
        }
        self.future = try std.Io.concurrent(client.io, run, .{self});
        return self;
    }

    fn lock(self: *Communication) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }
    fn unlock(self: *Communication) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    /// Normal commands cannot consume the two slots reserved for stop/approval
    /// barriers. Accepted requests retain capacity through completion removal.
    pub fn submit(self: *Communication, generation: u64, epoch: u64, value: action.Action) !u64 {
        const urgent = switch (value) {
            .cancel, .cancel_clear, .confirming, .approve => true,
            else => false,
        };
        const limit: usize = if (urgent) command_capacity else command_capacity - 2;
        self.lock();
        const rejected: ?anyerror = if (self.stop.isRequested()) error.Canceled else if (self.outstanding >= limit) error.QueueFull else if (self.next_ticket == std.math.maxInt(u64)) error.TicketExhausted else null;
        if (rejected) |err| {
            self.unlock();
            return err;
        }
        self.next_ticket += 1;
        const ticket = self.next_ticket;
        self.outstanding += 1;
        self.unlock();
        errdefer {
            self.lock();
            self.outstanding -= 1;
            self.unlock();
        }
        const request = try action.Owned.create(self.a, ticket, generation, epoch, value);
        errdefer request.deinit();
        self.lock();
        if (self.stop.isRequested()) {
            self.unlock();
            return error.Canceled;
        }
        self.requests[(self.request_head + self.request_count) % command_capacity] = request;
        self.request_count += 1;
        self.unlock();
        self.wake.notify();
        return ticket;
    }

    pub fn popCompletion(self: *Communication) ?Completed {
        self.lock();
        defer self.unlock();
        if (self.completion_count == 0) return null;
        const result = self.completions[self.completion_head].?;
        self.completions[self.completion_head] = null;
        self.completion_head = (self.completion_head + 1) % command_capacity;
        self.completion_count -= 1;
        self.outstanding -= 1;
        return result;
    }

    pub fn popDisplay(self: *Communication) !?Display {
        self.lock();
        if (self.display_count == 0) {
            const failure = self.failure;
            self.failure = null;
            self.unlock();
            if (failure) |err| return err;
            return null;
        }
        const result = self.displays[self.display_head].?;
        self.displays[self.display_head] = null;
        self.display_head = (self.display_head + 1) % display_capacity;
        self.display_count -= 1;
        self.display_bytes -= result.bytes();
        self.unlock();
        self.wake.notify();
        return result;
    }

    pub fn buffered(self: *Communication) bool {
        self.lock();
        defer self.unlock();
        return self.display_count != 0;
    }

    /// Cumulative prefix admission retained for existing callers.
    pub fn acknowledge(self: *Communication, epoch: u64, sequence: u64) !void {
        return self.acknowledgeRange(epoch, 0, sequence);
    }

    /// Nonblocking selective ACK admission for the UI thread: no RPC, no socket
    /// write and no wait for an owner reply. A stale epoch belongs to a replaced
    /// view and is refused, not recorded. A full set refuses rather than drops,
    /// so the UI keeps its exact display proof for retry.
    pub fn acknowledgeRange(self: *Communication, epoch: u64, first: u64, last: u64) !void {
        if (last == 0) return;
        if (first != 0 and first > last) return error.InvalidInput;
        self.lock();
        const rejected: ?anyerror = if (self.stop.isRequested()) error.Canceled else if (epoch == 0) error.StaleControl else null;
        if (rejected) |err| {
            self.unlock();
            return err;
        }
        if (self.ack_epoch != epoch) {
            // The previous epoch's ranges belong to the view that was replaced.
            self.ack_epoch = epoch;
            self.ack_ranges.clear();
            self.ack_accepted = 0;
        }
        self.ack_ranges.insert(first, last, self.ack_accepted) catch {
            self.unlock();
            return error.QueueFull;
        };
        self.unlock();
        self.wake.notify();
    }

    /// Forward admitted ranges to the subscription owner. Never called on the
    /// UI thread and never while a control reply owns the connection, so a
    /// delayed cancel/approval reply cannot hold display proof hostage and a
    /// head-of-line ACK failure cannot block those controls.
    fn forwardAck(self: *Communication) void {
        while (true) {
            self.lock();
            if (self.ack_accepted >= self.ack_ranges.len) {
                self.ack_ranges.clear();
                self.ack_accepted = 0;
                self.unlock();
                return;
            }
            const epoch = self.ack_epoch;
            const range = self.ack_ranges.items[self.ack_accepted];
            self.unlock();
            self.client.admitAckRange(epoch, range.first, range.last) catch |err| switch (err) {
                // The view/epoch is gone or the admission was malformed; its
                // proof can never apply again, so only this dead epoch's queue
                // is discarded.
                error.StaleControl, error.InvalidInput => {
                    self.lock();
                    self.ack_ranges.clear();
                    self.ack_accepted = 0;
                    self.unlock();
                    return;
                },
                // A reconnecting stream or its full range set is backpressure:
                // keep the exact proof here and retry on a later round.
                error.Unavailable, error.QueueFull => return,
            };
            self.lock();
            defer self.unlock();
            if (self.ack_epoch != epoch) return;
            self.ack_accepted += 1;
        }
    }

    fn takeRequest(self: *Communication) ?*action.Owned {
        self.lock();
        defer self.unlock();
        if (self.request_count == 0) return null;
        const request = self.requests[self.request_head].?;
        self.requests[self.request_head] = null;
        self.request_head = (self.request_head + 1) % command_capacity;
        self.request_count -= 1;
        return request;
    }

    fn synchronizeIdentity(self: *Communication) void {
        const identity = Identity.of(self.client);
        if (!std.meta.eql(identity, self.identity)) {
            self.identity = identity;
            self.generation +%= 1;
            if (self.generation == 0) self.generation = 1;
        }
    }

    fn view(self: *Communication, ordered: bool) !View {
        const projection = try self.client.exportProjection();
        errdefer projection.deinit();
        if (projection.arena.queryCapacity() > display_budget - @sizeOf(Display)) return error.InputTooLarge;
        return .{ .generation = self.generation, .revision = self.client.publication_revision, .watermark = if (ordered) self.client.cursor else self.client.cache_floor, .projection = projection, .ordered = ordered };
    }

    fn execute(self: *Communication, request: *action.Owned) void {
        self.command_inflight = true;
        // These mutations are idle-only at the UI/owner boundary. Keep their
        // configuration private until the matching completion; the independent
        // receiver still owns and bounds incoming frames during the save.
        self.hold_configuration = switch (request.action) {
            .configure, .model, .effort, .cycle_effort, .preference, .setting, .decision, .image, .proxy, .proxy_address, .refresh_models => true,
            else => false,
        };
        defer {
            self.command_inflight = false;
            self.hold_configuration = false;
        }
        var completed: Completed = .{ .completion = .{ .request = request }, .view = null };
        if (request.generation != self.generation) {
            completed.completion.failure = error.StaleControl;
        } else {
            completed.completion.value = self.client.perform(request.epoch, request.action) catch |err| failed: {
                completed.completion.failure = err;
                break :failed .none;
            };
        }
        self.synchronizeIdentity();
        completed.view = self.view(false) catch null;
        if (completed.view == null and completed.completion.failure == null) {
            // The operation may already be committed. This error must not cause
            // automatic resubmission, especially for submit/settings actions.
            completed.completion.failure = error.PublicationUnavailable;
        }
        self.lock();
        std.debug.assert(self.completion_count < command_capacity);
        self.completions[(self.completion_head + self.completion_count) % command_capacity] = completed;
        self.completion_count += 1;
        self.unlock();
        self.ready.notify();
    }

    fn publish(self: *Communication, item: Display) bool {
        self.lock();
        defer self.unlock();
        if (item.value == .event and self.display_count != 0) {
            const tail = &self.displays[(self.display_head + self.display_count - 1) % display_capacity].?;
            if (tail.generation == item.generation and tail.value == .event) {
                const before = tail.bytes();
                const allowance = tail.value.event.storage.len + (display_budget - self.display_bytes);
                if (tail.value.event.appendText(&item.value.event, allowance) catch false) {
                    self.display_bytes = self.display_bytes - before + tail.bytes();
                    var consumed = item;
                    consumed.deinit();
                    self.ready.notify();
                    return true;
                }
            }
        }
        if (self.display_count == display_capacity or item.bytes() > display_budget - self.display_bytes) return false;
        self.displays[(self.display_head + self.display_count) % display_capacity] = item;
        self.display_count += 1;
        self.display_bytes += item.bytes();
        self.ready.notify();
        return true;
    }

    fn flushPending(self: *Communication) bool {
        if (self.pending_view) |view_| {
            if (!self.publish(view_)) return false;
            self.pending_view = null;
        }
        if (self.pending_event) |event| {
            if (!self.publish(event)) return false;
            self.pending_event = null;
        }
        return true;
    }

    fn produce(self: *Communication) !bool {
        // A new launcher/session must not become visible mid-command. Its
        // matching completion publishes the identity first; old-view stream
        // work may still progress while the identity remains unchanged.
        if (self.command_inflight and (self.hold_configuration or !std.meta.eql(Identity.of(self.client), self.identity))) return false;
        if (!self.flushPending()) return false;
        var event = try self.client.nextDisplay();
        errdefer if (event) |*item| item.deinit();
        self.synchronizeIdentity();
        if (self.revision != self.client.publication_revision) {
            const ordered = self.stream_revision != self.client.stream_publication_revision;
            const projection = try self.view(ordered);
            self.pending_view = .{ .generation = self.generation, .value = .{ .view = projection } };
            self.revision = self.client.publication_revision;
            self.stream_revision = self.client.stream_publication_revision;
        }
        if (event) |item| self.pending_event = .{ .generation = self.generation, .value = .{ .event = item } };
        return self.flushPending();
    }

    /// Control waits still service already-received stream frames. No control
    /// recursion, UI callback, reconnect, or unbounded work is allowed here.
    fn progress(raw: ?*anyopaque) !void {
        const self: *Communication = @ptrCast(@alignCast(raw orelse return));
        if (self.deferred_failure != null) return;
        // The ACK rides its own bound watch socket, so a control reply that is
        // still outstanding cannot delay retiring already-displayed events.
        self.forwardAck();
        for (0..64) |_| {
            const room = self.produce() catch |err| {
                // A malformed consumed frame must not disappear merely because
                // it arrived during an unrelated control wait.
                self.deferred_failure = err;
                return;
            };
            if (!room) break;
            if (self.client.pending.items.len == 0 and !(if (self.client.stream) |stream| stream.buffered() else false)) break;
        }
    }

    fn run(self: *Communication) void {
        self.loop() catch |err| {
            self.stop.cancel();
            self.lock();
            self.failure = err;
            self.unlock();
            self.ready.notify();
        };
    }

    fn applyDeferredFailure(self: *Communication) void {
        const err = self.deferred_failure orelse return;
        self.deferred_failure = null;
        self.client.dropDisplayView();
        self.synchronizeIdentity();
        self.lock();
        self.failure = err;
        self.unlock();
        self.ready.notify();
    }

    fn loop(self: *Communication) !void {
        var metadata_at: i128 = 0;
        while (!self.stop.isRequested()) {
            self.wake.drain();
            self.applyDeferredFailure();
            self.forwardAck();
            // At most one control action per round; even a full display queue
            // cannot prevent its reserved cancellation/completion channel.
            if (self.takeRequest()) |request| self.execute(request);
            if (self.stop.isRequested()) break;
            self.applyDeferredFailure();
            var room = true;
            for (0..64) |_| {
                room = self.produce() catch |err| failed: {
                    self.client.dropDisplayView();
                    self.synchronizeIdentity();
                    self.lock();
                    self.failure = err;
                    self.unlock();
                    self.ready.notify();
                    break :failed false;
                };
                if (!room or (self.client.pending.items.len == 0 and
                    !(if (self.client.stream) |stream| stream.buffered() else false))) break;
            }
            self.forwardAck();
            const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
            if (now >= metadata_at and (self.client.conn != null or self.client.control != null)) {
                _ = self.client.perform(self.client.epoch, .{ .poll_metadata = false }) catch {};
                metadata_at = now + 250;
            }
            var descriptors = [_]std.c.pollfd{
                .{ .fd = self.wake.fd, .events = std.os.linux.POLL.IN, .revents = 0 },
                .{ .fd = if (room) (if (self.client.stream) |stream| stream.ready.fd else -1) else -1, .events = std.os.linux.POLL.IN, .revents = 0 },
            };
            const local = room and (self.client.pending.items.len != 0 or if (self.client.stream) |stream| stream.buffered() else false);
            const result = std.c.poll(&descriptors, descriptors.len, if (local) 0 else 30);
            if (result < 0 and std.c._errno().* != @backingInt(std.os.linux.E.INTR)) return error.Transport;
        }
    }

    /// Return exclusive Client ownership to the caller only after join. Worker
    /// shutdown/receipt policy remains the caller's existing responsibility.
    pub fn deinit(self: *Communication) void {
        self.stop.cancel();
        self.wake.notify();
        if (self.future) |*future| future.await(self.io);
        self.client.wait_cancel = null;
        self.client.wait_progress_context = null;
        self.client.wait_progress_fn = null;
        for (self.requests) |request| if (request) |owned| owned.deinit();
        for (&self.completions) |*completion| if (completion.*) |*owned| owned.deinit();
        for (&self.displays) |*display| if (display.*) |*owned| owned.deinit();
        if (self.pending_view) |*owned| owned.deinit();
        if (self.pending_event) |*owned| owned.deinit();
        self.wake.deinit();
        self.ready.deinit();
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
        self.a.destroy(self);
    }
};

test "unconsumed body is one latest append while views and control events retain order" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
    defer client.deinit();
    var owner: Communication = .{ .client = client, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = Communication.Identity.of(client), .revision = 0, .stream_revision = 0 };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    defer for (&owner.displays) |*slot| if (slot.*) |*display| display.deinit();
    for (0..1600) |_| try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "x" }) } }));
    try std.testing.expectEqual(@as(usize, 1), owner.display_count);
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .state = .calling_model }) } }));
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "after" }) } }));
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .view = try owner.view(true) } }));
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "view-after" }) } }));
    try std.testing.expect(owner.publish(.{ .generation = 2, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "new-generation" }) } }));
    try std.testing.expectEqual(@as(usize, 6), owner.display_count);
    for (0..6) |index| {
        var display = (try owner.popDisplay()).?;
        defer display.deinit();
        switch (index) {
            0 => try std.testing.expectEqual(@as(usize, 1600), display.value.event.event.text.len),
            1 => try std.testing.expect(display.value.event.event == .state),
            2 => try std.testing.expectEqualStrings("after", display.value.event.event.text),
            3 => try std.testing.expect(display.value == .view),
            4 => try std.testing.expectEqualStrings("view-after", display.value.event.event.text),
            5 => try std.testing.expectEqual(@as(u64, 2), display.generation),
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), owner.display_bytes);
    for (0..Communication.display_capacity - 1) |_| try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .state = .calling_model }) } }));
    for (0..2) |_| try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "tail" }) } }));
    try std.testing.expectEqual(Communication.display_capacity, owner.display_count);
    const last = (owner.display_head + owner.display_count - 1) % Communication.display_capacity;
    try std.testing.expectEqualStrings("tailtail", owner.displays[last].?.value.event.event.text);
}

test "inflight session switch cannot publish a new identity before completion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
    defer client.deinit();
    var owner: Communication = .{ .client = client, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = Communication.Identity.of(client), .revision = client.publication_revision, .stream_revision = client.stream_publication_revision, .command_inflight = true };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    owner.hold_configuration = true;
    client.publication_revision += 1;
    try std.testing.expect(!try owner.produce());
    try std.testing.expectEqual(@as(usize, 0), owner.display_count);
    owner.hold_configuration = false;
    client.epoch += 1;
    try std.testing.expect(!try owner.produce());
    try std.testing.expectEqual(@as(usize, 0), owner.display_count);
    try std.testing.expectEqual(@as(u64, 1), owner.generation);
    owner.command_inflight = false;
    try std.testing.expect(try owner.produce());
    var display = (try owner.popDisplay()).?;
    defer display.deinit();
    try std.testing.expectEqual(@as(u64, 2), display.generation);
    try std.testing.expectEqual(client.epoch, display.value.view.projection.snapshot.control_epoch);
}

test "UI ACK admission coalesces adjacent ranges, keeps holes and never sends a control RPC" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
    defer client.deinit();
    var owner: Communication = .{ .client = client, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = Communication.Identity.of(client), .revision = 0, .stream_revision = 0 };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);

    try std.testing.expectError(error.StaleControl, owner.acknowledge(0, 5));
    try std.testing.expectError(error.InvalidInput, owner.acknowledgeRange(3, 9, 4));
    try owner.acknowledgeRange(3, 10, 20);
    try owner.acknowledgeRange(3, 21, 30);
    try owner.acknowledgeRange(3, 40, 50);
    try owner.acknowledgeRange(3, 0, 9);
    owner.lock();
    try std.testing.expectEqual(@as(u64, 3), owner.ack_epoch);
    try std.testing.expectEqual(@as(usize, 2), owner.ack_ranges.len);
    try std.testing.expectEqual(AckRanges.Range{ .first = 0, .last = 30 }, owner.ack_ranges.items[0]);
    try std.testing.expectEqual(AckRanges.Range{ .first = 40, .last = 50 }, owner.ack_ranges.items[1]);
    owner.unlock();
    // The client has no live epoch in this fixture, so the admitted ranges are
    // dropped as stale instead of being recorded against a foreign view.
    owner.forwardAck();
    owner.lock();
    try std.testing.expectEqual(@as(usize, 0), owner.ack_ranges.len);
    try std.testing.expectEqual(@as(usize, 0), owner.ack_accepted);
    owner.unlock();
    owner.stop.cancel();
    try std.testing.expectError(error.Canceled, owner.acknowledgeRange(3, 60, 70));
}
