//! Anchored durable outbox. Only explicit retry may replay failed/uncertain work.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const knowledge = @import("../core/knowledge.zig");
const memory = @import("memory.zig");
pub const State = enum { queued, sending, failed, uncertain, done };
const Job = struct { schema: u8 = 1, id: []const u8, state: State, material: ?knowledge.Material };
const Stored = struct { job: Job, charge: usize };
/// Reserve every active job's longest state, without discounting disk whitespace.
/// This is also the admission contract for readers: unsafe old files fail closed.
fn capacityCharge(a: std.mem.Allocator, job: Job, actual_bytes: usize) !usize {
    const encoded = try std.json.Stringify.valueAlloc(a, job, .{});
    const headroom = if (job.state == .done) 0 else "uncertain".len - @tagName(job.state).len;
    const charged = @max(actual_bytes, encoded.len + headroom);
    if (charged > max_file_bytes) return error.FileTooLarge;
    return charged;
}
pub const max_jobs = 32;
pub const max_file_bytes = 65536;
pub const max_active_bytes = 524288;
extern "c" fn fsync(c_int) c_int;
pub const Queue = struct {
    root: *fs.Root,
    worker_fd: ?c_int = null,
    /// Caller owns the returned fd and must keep it open until worker shutdown.
    /// Never unlink this lease file: its inode is the cross-process authority.
    pub fn acquireWorker(self: *Queue, _: std.mem.Allocator) !c_int {
        if (self.worker_fd != null) return error.Busy;
        const thin = try child(self.root.dir.handle, ".thin", true);
        defer fs.closeFd(thin);
        const store = try child(thin, memory.directory_name, true);
        defer fs.closeFd(store);
        const fd = fs.linux.openat(store, memory.owner_name, 2 | fs.linux.create | fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0o600);
        if (fd < 0) return fs.osError();
        errdefer fs.closeFd(fd);
        if ((try fs.fileFromFd(fd).stat(self.root.io)).kind != .file) return error.NotRegularFile;
        while (fs.linux.flock(fd, 2 | 4) != 0) {
            const e = std.c._errno().*;
            if (e == 4) continue;
            if (e == 11) return error.Busy;
            return fs.osError();
        }
        self.worker_fd = fd;
        return fd;
    }
    /// Only the exclusive worker may interpret previous sending jobs as crashed.
    /// Recovery never queues or replays them. Call once after acquiring the lease.
    pub fn recover(self: *Queue, a: std.mem.Allocator) !void {
        if (self.worker_fd == null) return error.WorkerLeaseRequired;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.deinit();
        for (try self.loadAll(&dir, temp)) |stored| {
            if (stored.job.state != .sending) continue;
            var next = stored.job;
            next.state = .uncertain;
            try self.publish(&dir, temp, next, true);
        }
    }
    pub fn init(root: *fs.Root) Queue {
        return .{ .root = root };
    }
    fn lock(self: *Queue) !c_int {
        const fd = try fs.openDirectory(self.root.dir.handle, ".");
        errdefer fs.closeFd(fd);
        while (fs.linux.flock(fd, 2 | 4) != 0) {
            const e = std.c._errno().*;
            if (e == 4) continue;
            if (e != 11) return fs.osError();
            try std.Io.sleep(self.root.io, .fromMilliseconds(2), .awake);
        }
        return fd;
    }
    fn tryLock(self: *Queue) !c_int {
        const fd = try fs.openDirectory(self.root.dir.handle, ".");
        errdefer fs.closeFd(fd);
        if (fs.linux.flock(fd, 2 | 4) != 0) {
            const e = std.c._errno().*;
            if (e == 11 or e == 4) return error.Busy;
            return fs.osError();
        }
        return fd;
    }
    fn directory(self: *Queue, create: bool) !fs.Root {
        const thin = try child(self.root.dir.handle, ".thin", create);
        defer fs.closeFd(thin);
        const store = try child(thin, memory.directory_name, create);
        defer fs.closeFd(store);
        const fd = try child(store, memory.jobs_name, create);
        errdefer fs.closeFd(fd);
        return .{ .dir = .{ .handle = fd }, .io = self.root.io, .allocator = self.root.allocator, .path = try std.fs.path.join(self.root.allocator, &.{ self.root.path, ".thin", memory.directory_name, memory.jobs_name }) };
    }
    fn loadAll(_: *Queue, dir: *fs.Root, a: std.mem.Allocator) ![]Stored {
        var jobs: std.ArrayList(Stored) = .empty;
        var total: usize = 0;
        var it = dir.dir.iterate();
        while (try it.next(dir.io)) |item| {
            // Unpublished atomic-write temporaries have no authority.
            if (std.mem.startsWith(u8, item.name, ".thin-tmp-")) continue;
            if (!std.mem.endsWith(u8, item.name, ".json")) return error.InvalidJobStorage;
            const id = item.name[0 .. item.name.len - 5];
            try validId(id);
            if (jobs.items.len >= max_jobs) return error.QueueFull;
            const bytes = try dir.readBinary(a, item.name, max_file_bytes);
            const parsed = try std.json.parseFromSlice(Job, a, bytes, .{ .allocate = .alloc_always });
            const job = parsed.value;
            if (job.schema != 1 or !std.mem.eql(u8, job.id, id)) return error.InvalidJobStorage;
            if (job.state == .done) {
                if (job.material != null) return error.InvalidJobStorage;
            } else {
                const material = job.material orelse return error.InvalidJobStorage;
                try validMaterial(material);
                if (!std.mem.eql(u8, job.id, material.id)) return error.InvalidJobStorage;
            }
            const charge = try capacityCharge(a, job, bytes.len);
            total += charge;
            if (total > max_active_bytes) return error.QueueFull;
            try jobs.append(a, .{ .job = job, .charge = charge });
        }
        std.mem.sort(Stored, jobs.items, {}, struct {
            fn less(_: void, x: Stored, y: Stored) bool {
                return std.mem.order(u8, x.job.id, y.job.id) == .lt;
            }
        }.less);
        return jobs.items;
    }
    fn publish(self: *Queue, dir: *fs.Root, a: std.mem.Allocator, job: Job, overwrite: bool) !void {
        const text = try std.json.Stringify.valueAlloc(a, job, .{});
        var total = try capacityCharge(a, job, text.len);
        var count: usize = 1;
        for (try self.loadAll(dir, a)) |stored| {
            if (overwrite and std.mem.eql(u8, stored.job.id, job.id)) continue;
            total += stored.charge;
            count += 1;
        }
        if (count > max_jobs or total > max_active_bytes) return error.QueueFull;
        const name = try std.fmt.allocPrintSentinel(a, "{s}.json", .{job.id}, 0);
        try dir.writeMode(name, text, overwrite, 0o600);
        const fd = fs.linux.openat(dir.dir.handle, name, fs.linux.nofollow | fs.linux.cloexec, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);
        if (fsync(fd) != 0 or fsync(dir.dir.handle) != 0) return fs.osError();
    }
    pub fn enqueue(self: *Queue, a: std.mem.Allocator, material: knowledge.Material) !void {
        try self.enqueueImpl(a, material, false);
    }
    /// Completion-time admission must not wait on another root transaction.
    pub fn tryEnqueue(self: *Queue, a: std.mem.Allocator, material: knowledge.Material) !void {
        try self.enqueueImpl(a, material, true);
    }
    fn enqueueImpl(self: *Queue, a: std.mem.Allocator, material: knowledge.Material, nonblocking: bool) !void {
        try validMaterial(material);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const fd = if (nonblocking) try self.tryLock() else try self.lock();
        defer fs.closeFd(fd);
        var store = @import("memory.zig").Store.init(self.root, .{});
        if (try store.generationLocked() != material.generation) return error.GenerationConflict;
        var dir = try self.directory(true);
        defer dir.deinit();
        const jobs = try self.loadAll(&dir, temp);
        for (jobs) |stored| if (std.mem.eql(u8, stored.job.id, material.id)) return;
        const next: Job = .{ .id = material.id, .state = .queued, .material = material };
        var total = try capacityCharge(temp, next, 0);
        for (jobs) |stored| total += stored.charge;
        var count = jobs.len;
        // Evict only receipts, never active source material. Select the complete
        // eviction plan before mutating anything; QueueFull preserves all jobs.
        var evict: usize = 0;
        for (jobs) |stored| {
            if (count < max_jobs and total <= max_active_bytes) break;
            if (stored.job.state != .done) continue;
            count -= 1;
            total -= stored.charge;
            evict += 1;
        }
        if (count >= max_jobs or total > max_active_bytes) return error.QueueFull;
        for (jobs) |stored| {
            if (evict == 0) break;
            if (stored.job.state != .done) continue;
            const name = try std.fmt.allocPrintSentinel(temp, "{s}.json", .{stored.job.id}, 0);
            if (std.c.unlinkat(dir.dir.handle, name, 0) != 0) return fs.osError();
            evict -= 1;
        }
        if (fsync(dir.dir.handle) != 0) return fs.osError();
        try self.publish(&dir, temp, next, false);
    }
    pub fn pending(self: *Queue, a: std.mem.Allocator) ![]const knowledge.Material {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return a.alloc(knowledge.Material, 0);
            return err;
        };
        defer dir.deinit();
        const jobs = try self.loadAll(&dir, a);
        var out: std.ArrayList(knowledge.Material) = .empty;
        for (jobs) |stored| {
            if (stored.job.state == .queued) try out.append(a, stored.job.material.?);
        }
        return out.toOwnedSlice(a);
    }
    pub fn mark(self: *Queue, a: std.mem.Allocator, id: []const u8, state: State) !void {
        try self.transition(a, id, state, false);
    }
    pub fn retry(self: *Queue, a: std.mem.Allocator, id: []const u8) !void {
        try self.transition(a, id, .queued, true);
    }
    fn transition(self: *Queue, a: std.mem.Allocator, id: []const u8, state: State, explicit: bool) !void {
        try validId(id);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = try self.directory(false);
        defer dir.deinit();
        for (try self.loadAll(&dir, temp)) |stored| {
            const old = stored.job;
            if (!std.mem.eql(u8, old.id, id)) continue;
            if (explicit) {
                if (old.state != .failed and old.state != .uncertain) return error.InvalidJobTransition;
            } else {
                const allowed = switch (old.state) {
                    .queued => state == .sending or state == .failed or state == .done,
                    .sending => state == .done or state == .uncertain or state == .failed,
                    .failed, .uncertain => state == .done,
                    .done => false,
                };
                if (!allowed) return error.InvalidJobTransition;
            }
            var next = old;
            next.state = state;
            if (state == .done) next.material = null;
            try self.publish(&dir, temp, next, true);
            return;
        }
        return error.FileNotFound;
    }
    pub fn status(self: *Queue, a: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return a.dupe(u8, "");
            return err;
        };
        defer dir.deinit();
        var out: std.ArrayList(u8) = .empty;
        for (try self.loadAll(&dir, temp)) |stored| {
            try out.appendSlice(temp, try std.fmt.allocPrint(temp, "{s} {s}\n", .{ stored.job.id, @tagName(stored.job.state) }));
        }
        return a.dupe(u8, out.items);
    }
};
fn child(fd: c_int, name: [*:0]const u8, create: bool) !c_int {
    return fs.openDirectory(fd, name) catch |err| {
        if (err != error.FileNotFound or !create) return err;
        if (std.c.mkdirat(fd, name, 0o700) != 0 and std.c._errno().* != 17) return fs.osError();
        if (fsync(fd) != 0) return fs.osError();
        return fs.openDirectory(fd, name);
    };
}
fn validId(id: []const u8) !void {
    if (id.len != 64) return error.InvalidJobId;
    for (id) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return error.InvalidJobId;
}
fn validMaterial(m: knowledge.Material) !void {
    try validId(m.id);
    if (m.sources.len > knowledge.max_sources or m.related.len > 8) return error.InvalidMaterial;
    var bytes: usize = 0;
    for (m.sources, 0..) |source, i| {
        if (source.text.len == 0 or source.text.len > knowledge.max_source_bytes) return error.InvalidMaterial;
        try fs.validateText(source.text);
        for (m.sources[0..i]) |prior| if (prior.id == source.id) return error.InvalidMaterial;
        bytes += source.text.len;
    }
    if (bytes > knowledge.max_material_bytes) return error.InvalidMaterial;
    for (m.related) |r| {
        try @import("memory.zig").validTopic(r.topic);
        if (r.topic.len > 40 or r.content.len > knowledge.max_content_bytes) return error.InvalidMaterial;
        try validId(r.version);
        try fs.validateText(r.content);
    }
}

fn testRoot(a: std.mem.Allocator, dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    return fs.Root.open(a, std.testing.io, buffer[0..try dir.realPath(std.testing.io, &buffer)]);
}
fn testMaterial(a: std.mem.Allocator, n: usize) !knowledge.Material {
    return .{ .id = try std.fmt.allocPrint(a, "{x:0>64}", .{n}), .generation = 0, .created_ms = 1, .sources = &.{.{ .id = 0, .kind = .user, .text = "source" }} };
}

test "queue stale enqueue after manual write or delete cannot recreate forgotten sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |remove| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root = try testRoot(a, tmp.dir);
        defer root.deinit();
        var store = @import("memory.zig").Store.init(&root, .{});
        const first = try store.write(a, "obsolete", "fact", null);
        var m = try testMaterial(a, 1);
        m.generation = try store.generation();
        var q = Queue.init(&root);
        try q.enqueue(a, m);
        if (remove) {
            try store.delete("obsolete", first.version);
        } else {
            _ = try store.write(a, "obsolete", "correction", first.version);
        }
        try std.testing.expectEqualStrings("", try q.status(a));
        // Deterministic delayed extraction, after mutation AND outbox purge.
        try std.testing.expectError(error.GenerationConflict, q.enqueue(a, m));
        try std.testing.expectEqualStrings("", try q.status(a));
        const path = try std.fmt.allocPrint(a, ".thin/memory/jobs/{s}.json", .{m.id});
        try std.testing.expectError(error.FileNotFound, root.readBinary(a, path, max_file_bytes));
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, tmp.dir);
    defer root.deinit();
    var q = Queue.init(&root);
    var stale = try testMaterial(a, 2);
    stale.generation = 1;
    try std.testing.expectError(error.GenerationConflict, q.enqueue(a, stale));
    try std.testing.expectError(error.FileNotFound, q.directory(false));
}

test "queue reserves longest state at exact file and aggregate boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, tmp.dir);
    defer root.deinit();
    var q = Queue.init(&root);
    const escaped = try a.alloc(u8, 4096);
    @memset(escaped, '\\'); // Legal text, expanded to two bytes by JSON.
    var sources: [6]knowledge.Evidence = undefined;
    for (&sources, 0..) |*source, i| source.* = .{ .id = @intCast(i), .kind = .user, .text = escaped };
    var m = try testMaterial(a, 0);
    m.sources = &sources;
    var related: [5]knowledge.Related = undefined;
    for (&related) |*r| r.* = .{ .category = .project, .topic = "topic", .version = m.id, .content = escaped[0..1700] };
    related[4].content = "x";
    m.related = &related;
    const initial = try std.json.Stringify.valueAlloc(a, Job{ .id = m.id, .state = .queued, .material = m }, .{});
    const padding = try a.alloc(u8, max_file_bytes - 3 - initial.len + 1);
    @memset(padding, 'x');
    related[4].content = padding;
    for (0..8) |i| {
        m.id = (try testMaterial(a, i)).id;
        try q.enqueue(a, m);
    }
    var dir = try q.directory(false);
    defer dir.deinit();
    var total: usize = 0;
    for (try q.loadAll(&dir, a)) |stored| {
        try std.testing.expectEqual(max_file_bytes, stored.charge);
        total += stored.charge;
    }
    try std.testing.expectEqual(max_active_bytes, total);
    try std.testing.expectError(error.QueueFull, q.enqueue(a, try testMaterial(a, 99)));
    const id = (try testMaterial(a, 0)).id;
    try q.mark(a, id, .sending);
    try std.testing.expectError(error.InvalidJobTransition, q.mark(a, id, .queued));
    try q.mark(a, id, .uncertain);
    const second = (try testMaterial(a, 1)).id;
    try q.mark(a, second, .sending);
    const lease = try q.acquireWorker(a);
    defer fs.closeFd(lease);
    try q.recover(a);
    try std.testing.expectEqual(@as(usize, 6), (try q.pending(a)).len);
    const status = try q.status(a);
    try std.testing.expect(std.mem.find(u8, status, "sending") == null);
    try std.testing.expect(std.mem.find(u8, status, "uncertain") != null);
    total = 0;
    for (try q.loadAll(&dir, a)) |stored| total += stored.charge;
    try std.testing.expectEqual(max_active_bytes, total);
    // An encoded queued file may fit, yet lack space for its future state.
    const larger = try a.alloc(u8, padding.len + 1);
    @memset(larger, 'x');
    related[4].content = larger;
    m.id = (try testMaterial(a, 100)).id;
    try std.testing.expectError(error.FileTooLarge, q.enqueue(a, m));
}

test "queue charges legal disk whitespace and fails closed on unsafe old capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, tmp.dir);
    defer root.deinit();
    var q = Queue.init(&root);
    for (0..8) |i| try q.enqueue(a, try testMaterial(a, i));
    var dir = try q.directory(false);
    defer dir.deinit();
    for (try q.loadAll(&dir, a)) |stored| {
        const text = try std.json.Stringify.valueAlloc(a, stored.job, .{});
        const padded = try a.alloc(u8, max_file_bytes);
        @memset(padded, ' ');
        @memcpy(padded[0..text.len], text);
        const name = try std.fmt.allocPrint(a, "{s}.json", .{stored.job.id});
        try dir.writeMode(name, padded, true, 0o600);
    }
    try std.testing.expectEqual(@as(usize, 8), (try q.pending(a)).len);
    try std.testing.expectError(error.QueueFull, q.enqueue(a, try testMaterial(a, 99)));
    for (try q.loadAll(&dir, a)) |stored| try std.testing.expectEqual(max_file_bytes, stored.charge);
    const id = (try testMaterial(a, 0)).id;
    try q.mark(a, id, .sending);
    const lease = try q.acquireWorker(a);
    defer fs.closeFd(lease);
    try q.recover(a);
    try std.testing.expectEqual(@as(usize, 7), (try q.pending(a)).len);
    _ = try q.status(a);
    // Inject an old-format over-capacity aggregate. Neither readers nor writers
    // repair it, discard active sources, or requeue already-sent material.
    const m = try testMaterial(a, 99);
    const text = try std.json.Stringify.valueAlloc(a, Job{ .id = m.id, .state = .sending, .material = m }, .{});
    const padded = try a.alloc(u8, max_file_bytes);
    @memset(padded, ' ');
    @memcpy(padded[0..text.len], text);
    const name = try std.fmt.allocPrint(a, "{s}.json", .{m.id});
    try dir.writeMode(name, padded, false, 0o600);
    try std.testing.expectError(error.QueueFull, q.status(a));
    try std.testing.expectError(error.QueueFull, q.pending(a));
    try std.testing.expectError(error.QueueFull, q.recover(a));
    try std.testing.expectError(error.QueueFull, q.mark(a, m.id, .done));
    try std.testing.expectEqualSlices(u8, padded, try dir.readBinary(a, name, max_file_bytes));
}
