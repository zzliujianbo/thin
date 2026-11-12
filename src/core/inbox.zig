//! Single-session pending input. No callbacks are made under the lock.
const std = @import("std");
const Cancellation = @import("protocol.zig").Cancellation;
const Allocator = std.mem.Allocator;
pub const Kind = enum { steering, follow_up };
pub const Entry = struct {
    id: u64,
    kind: Kind,
    text: []u8,
    allocator: Allocator,
    pub fn deinit(self: *Entry) void {
        std.crypto.secureZero(u8, self.text);
        // Allocator.free poisons bytes before rawFree in safety builds. This
        // fixed u8 allocation has no resize/remap path: release at rawFree so
        // the owning allocator actually receives the wiped buffer.
        self.allocator.rawFree(self.text, .of(u8), @returnAddress());
        self.* = undefined;
    }
};
pub const Lease = struct { id: u64, kind: Kind, text: []const u8 };
pub const Preview = struct {
    id: u64 = 0,
    kind: Kind = .steering,
    bytes: [96]u8 = @splat(0),
    len: usize = 0,
    pub fn text(self: *const Preview) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Snapshot = struct {
    revision: u64,
    steering: usize = 0,
    follow_up: usize = 0,
    newest_id: ?u64 = null,
    newest_bytes: usize = 0,
    paused: bool,
    confirming: bool,
    active: bool,
    epoch: u64,
    previews: [16]Preview = @splat(.{}),
    preview_count: usize = 0,
};
pub const Inbox = struct {
    const Slot = struct { entry: Entry, leased: bool = false, tombstone: bool = false };
    mutex: std.atomic.Value(bool) = .init(false),
    slots: std.ArrayList(?Slot) = .empty,
    slots_allocator: ?Allocator = null,
    next_id: u64 = 0,
    revision: u64 = 0,
    epoch: u64 = 0,
    paused: bool = false,
    confirming: bool = false,
    active: bool = false,
    sealed: bool = true,

    fn lock(self: *Inbox) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Inbox) void {
        self.mutex.store(false, .release);
    }
    // Saturation is fail-closed: enqueue/confirm cannot reuse an identity.
    fn changed(self: *Inbox) void {
        self.revision +|= 1;
    }
    fn eligible(self: *Inbox) bool {
        return !self.paused and !self.confirming;
    }
    fn pending(self: *Inbox, kind: Kind) ?usize {
        var index: ?usize = null;
        for (self.slots.items, 0..) |slot, i| if (slot) |s| {
            if (s.leased or s.tombstone or s.entry.kind != kind) continue;
            if (index == null or s.entry.id < self.slots.items[index.?].?.entry.id) index = i;
        };
        return index;
    }
    /// Existing UI/session delivery: a sealed run may still queue the next
    /// round, so no run-gate is applied here.
    pub fn enqueue(self: *Inbox, a: Allocator, kind: Kind, text: []const u8) !u64 {
        return self.enqueueInternal(a, kind, text, false);
    }
    /// Job-side delivery for a run that is already executing: it is accepted
    /// only while the same run is open (begun and not sealed). The check and the
    /// slot commit share the Inbox lock with `sealTask`, so either the message
    /// is queued first (and the seal fails) or the seal wins (and delivery is
    /// refused) — never a delivered message that no child will ever consume.
    /// Epoch 0 means no run has begun yet, where a pre-spawn message is allowed.
    pub fn enqueueForRun(self: *Inbox, a: Allocator, kind: Kind, text: []const u8) !u64 {
        return self.enqueueInternal(a, kind, text, true);
    }
    fn enqueueInternal(self: *Inbox, a: Allocator, kind: Kind, text: []const u8, require_open_run: bool) !u64 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '/' or trimmed[0] == '!' or std.mem.findScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidInput;
        var entry = Entry{ .id = 0, .kind = kind, .text = try a.dupe(u8, text), .allocator = a };
        errdefer entry.deinit();
        self.lock();
        defer self.unlock();
        if (require_open_run and self.epoch != 0 and (!self.active or self.sealed)) return error.RunSealed;
        if (self.next_id == std.math.maxInt(u64) or self.revision == std.math.maxInt(u64)) return error.IdentityExhausted;
        var index: ?usize = null;
        for (self.slots.items, 0..) |slot, i| if (slot == null) {
            index = i;
            break;
        };
        if (index == null) {
            const slots_allocator = self.slots_allocator orelse a;
            try self.slots.append(slots_allocator, null);
            self.slots_allocator = slots_allocator;
            index = self.slots.items.len - 1;
        }
        self.next_id += 1;
        entry.id = self.next_id;
        self.slots.items[index.?] = .{ .entry = entry };
        self.changed();
        return entry.id;
    }
    pub fn snapshot(self: *Inbox) Snapshot {
        self.lock();
        defer self.unlock();
        var result = Snapshot{ .revision = self.revision, .paused = self.paused, .confirming = self.confirming, .active = self.active, .epoch = self.epoch };
        // Counts cover the entire queue; previews remain display-only.
        for (self.slots.items) |slot| if (slot) |s| {
            if (s.leased or s.tombstone) continue;
            if (s.entry.kind == .steering) result.steering += 1 else result.follow_up += 1;
            if (result.newest_id == null or s.entry.id > result.newest_id.?) {
                result.newest_id = s.entry.id;
                result.newest_bytes = s.entry.text.len;
            }
        };
        // ID-order previews; value owned, UTF-8 scalar aligned.
        var after: u64 = 0;
        for (0..16) |_| {
            var best: ?usize = null;
            for (self.slots.items, 0..) |slot, i| if (slot) |s| {
                if (s.leased or s.tombstone or s.entry.id <= after) continue;
                if (best == null or s.entry.id < self.slots.items[best.?].?.entry.id) best = i;
            };
            const s = self.slots.items[best orelse break].?;
            after = s.entry.id;
            var preview = &result.previews[result.preview_count];
            preview.id = s.entry.id;
            preview.kind = s.entry.kind;
            var n = @min(preview.bytes.len, s.entry.text.len);
            while (n < s.entry.text.len and n > 0 and s.entry.text[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(preview.bytes[0..n], s.entry.text[0..n]);
            preview.len = n;
            result.preview_count += 1;
        }
        return result;
    }
    pub fn withdraw(self: *Inbox, expected_id: u64) ?Entry {
        self.lock();
        defer self.unlock();
        for (self.slots.items) |*slot| if (slot.*) |s| {
            if (s.entry.id != expected_id or s.leased or s.tombstone) continue;
            slot.* = null;
            self.changed();
            return s.entry;
        };
        return null;
    }
    fn claim(self: *Inbox, next: bool) ?Lease {
        self.lock();
        defer self.unlock();
        if (!self.eligible() or (if (next) self.active else (!self.active or self.sealed))) return null;
        const i = self.pending(.steering) orelse (if (next) self.pending(.follow_up) else null) orelse return null;
        const s = &self.slots.items[i].?;
        s.leased = true;
        self.changed();
        return .{ .id = s.entry.id, .kind = s.entry.kind, .text = s.entry.text };
    }
    pub fn claimSteering(self: *Inbox) ?Lease {
        return self.claim(false);
    }
    pub fn claimNext(self: *Inbox) ?Lease {
        return self.claim(true);
    }
    pub fn commit(self: *Inbox, lease: Lease) ?Entry {
        self.lock();
        defer self.unlock();
        for (self.slots.items) |*slot| if (slot.*) |*s| {
            if (s.entry.id != lease.id or !s.leased) continue;
            var entry = s.entry;
            const dead = s.tombstone;
            slot.* = null;
            self.changed();
            if (dead) {
                entry.deinit();
                return null;
            }
            return entry;
        };
        return null;
    }
    pub fn restore(self: *Inbox, lease: Lease) void {
        self.lock();
        defer self.unlock();
        for (self.slots.items) |*slot| if (slot.*) |*s| {
            if (s.entry.id != lease.id or !s.leased) continue;
            if (s.tombstone) {
                s.entry.deinit();
                slot.* = null;
            } else s.leased = false;
            self.changed();
            return;
        };
    }
    pub fn hasSteering(self: *Inbox) bool {
        self.lock();
        defer self.unlock();
        return self.active and !self.sealed and self.eligible() and self.pending(.steering) != null;
    }
    pub fn beginTool(self: *Inbox) bool {
        self.lock();
        defer self.unlock();
        return !self.confirming and !(self.active and !self.sealed and self.eligible() and self.pending(.steering) != null);
    }
    pub fn beginRun(self: *Inbox) void {
        self.lock();
        defer self.unlock();
        self.active = true;
        self.sealed = false;
        self.epoch +|= 1;
        self.changed();
    }
    pub fn sealTask(self: *Inbox) bool {
        self.lock();
        defer self.unlock();
        if (self.eligible() and self.pending(.steering) != null) return false;
        self.sealed = true;
        self.changed();
        return true;
    }
    pub fn finishRun(self: *Inbox, success: bool) void {
        self.lock();
        defer self.unlock();
        self.active = false;
        self.sealed = true;
        if (!success) self.paused = true;
        self.changed();
    }
    pub fn pauseClaims(self: *Inbox, value: bool) void {
        self.lock();
        defer self.unlock();
        if (self.confirming != value) {
            self.confirming = value;
            self.changed();
        }
    }
    pub fn pause(self: *Inbox) void {
        self.setPaused(true);
    }
    pub fn @"resume"(self: *Inbox) void {
        self.setPaused(false);
    }
    fn setPaused(self: *Inbox, value: bool) void {
        self.lock();
        defer self.unlock();
        if (self.paused != value) {
            self.paused = value;
            self.changed();
        }
    }
    pub fn cancelClear(self: *Inbox, expected_revision: u64, cancel: *Cancellation) bool {
        self.lock();
        defer self.unlock();
        if (!self.confirming or self.revision != expected_revision or self.revision == std.math.maxInt(u64)) return false;
        cancel.cancel();
        for (self.slots.items) |*slot| if (slot.*) |*s| {
            if (s.leased) s.tombstone = true else {
                s.entry.deinit();
                slot.* = null;
            }
        };
        self.paused = true;
        self.confirming = false;
        self.changed();
        return true;
    }
    pub fn deinit(self: *Inbox) void {
        self.lock();
        defer self.unlock();
        for (self.slots.items) |*slot| if (slot.*) |*s| {
            std.debug.assert(!s.leased);
            s.entry.deinit();
            slot.* = null;
        };
        if (self.slots_allocator) |a| self.slots.deinit(a);
        self.slots = .empty;
        self.slots_allocator = null;
    }
};
