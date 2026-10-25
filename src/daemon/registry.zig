//! Per-UID session registry and the only live-endpoint probe used by the
//! daemon, the foreground client and the worker spawner.
//!
//! The registry is a *rebuildable* index, never a lease: an entry is written
//! atomically into the private session directory described by `~/.thin`, and
//! liveness is proven only by connecting to the endpoint and checking the
//! kernel-reported peer credentials against the worker's `hello` reply. No
//! entry is ever deleted to authorize a resume and the project resume-lock is
//! never touched here.

const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const unix = @import("unix.zig");
const protocol = @import("protocol.zig");
const cli = @import("../app/cli.zig");
const ids = @import("../app/session_id.zig");

const c = std.c;
const linux = std.os.linux;

extern "c" fn fsync(c_int) c_int;

/// Page size for `list`; the only hard bound on registry output. There is no
/// limit on the number of sessions/projects, only on one response.
pub const max_page = 64;
/// Upper bound on index directories/files scanned for one query. Exceeding it
/// is reported, never silently truncated.
pub const max_scan_entries: usize = 4096;
pub const max_project_bytes: usize = 4096;
pub const max_index_bytes: usize = 8 * 1024;
pub const max_state_bytes: usize = 32;
const index_version: u16 = 1;
const index_suffix = ".json";

/// One index entry. Borrowed for `register`; returned owned by `resolve`
/// (and by `list`) and then released with `freeRecord`/`freeRecords`.
pub const Record = struct {
    id: ids.Id,
    project: []const u8,
    endpoint: []const u8,
    owner: cli.WorkerOwner,
    owner_instance: []const u8,
    state: []const u8,
    pid: u32,
    generation: u64,
    /// Index publication time (0 for a caller-built record before registering).
    updated_ms: u64 = 0,
};

/// Release a record returned by `resolve`/`list`. Accepts a const pointer so a
/// caller's `const` binding does not force a mutability cast.
pub fn freeRecord(a: std.mem.Allocator, record: *const Record) void {
    a.free(@constCast(record.project));
    a.free(@constCast(record.endpoint));
    a.free(@constCast(record.owner_instance));
    a.free(@constCast(record.state));
}

pub fn freeRecords(a: std.mem.Allocator, records: []const Record) void {
    for (records) |*record| freeRecord(a, record);
    a.free(@constCast(records));
}

/// Kernel-verified `hello` identity. `peer_pid` comes from SO_PEERCRED, so
/// `pid == peer_pid` proves the endpoint is served by that very process.
pub const Hello = struct {
    session: ids.Id,
    owner: cli.WorkerOwner,
    pid: u32,
    peer_pid: u32,
    peer_uid: u32,
    protocol: u16,
};

/// Live status used by the daemon `list` merge. `unknown` means the endpoint
/// answered `hello` but not `snapshot`; it is still a live owner.
pub const Probe = struct {
    live: bool = false,
    pid: u32 = 0,
    busy: bool = false,
    pending_permission: bool = false,
    attached: bool = false,
    state: State = .dead,

    pub const State = enum { dead, idle, running, waiting_approval, unknown };
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    uid: u32,
    runtime: unix.Directory,
    /// Anchored fd of `<HOME>/.thin/session-index`; never re-resolved by path.
    index_fd: c.fd_t,
    index_path: []u8,
    /// Set when a `list` scan stopped at the bounded index window. The caller
    /// must surface this; entries are still an explicit partial view, never a
    /// silently complete session total.
    list_truncated: bool = false,
    mutex: std.Io.Mutex = .init,

    /// Resolve the runtime directory and open/create the private index root.
    /// `$XDG_RUNTIME_DIR`/`HOME` come only from the supplied environment map.
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !Registry {
        const uid: u32 = @intCast(c.getuid());
        const runtime = try unix.Directory.resolve(a, environ, uid);
        errdefer {
            var moved = runtime;
            moved.deinit();
        }

        const home = environ.get("HOME") orelse return error.NoHomeDirectory;
        try validateAbsolutePath(home);

        const opened = try openHomeIndex(a, io, home, uid);
        return .{
            .allocator = a,
            .io = io,
            .uid = uid,
            .runtime = runtime,
            .index_fd = opened.fd,
            .index_path = opened.path,
        };
    }

    pub fn deinit(self: *Registry) void {
        fs.closeFd(self.index_fd);
        self.index_fd = -1;
        self.allocator.free(self.index_path);
        self.index_path = &.{};
        self.runtime.deinit();
        self.* = undefined;
    }

    pub fn runtimeDirectory(self: *const Registry) *const unix.Directory {
        return &self.runtime;
    }

    /// True when the most recent `list` hit the bounded scan window.
    pub fn wasTruncated(self: *const Registry) bool {
        return self.list_truncated;
    }

    /// Publish one entry. Paths in the record must already describe this
    /// registry's runtime directory; the write is a temp-file + rename so a
    /// reader never sees a partial file and a planted symlink is never followed.
    pub fn register(self: *Registry, record: Record) !void {
        if (!ids.valid(record.id)) return error.InvalidSessionID;
        try validateAbsolutePath(record.project);
        if (record.project.len > max_project_bytes) return error.InvalidInput;
        if (!std.unicode.utf8ValidateSlice(record.project)) return error.InvalidInput;
        if (!std.unicode.utf8ValidateSlice(record.endpoint)) return error.InvalidInput;
        try self.validateEndpoint(record.owner_instance, record.endpoint);
        if (record.state.len == 0 or record.state.len > max_state_bytes) return error.InvalidInput;
        for (record.state) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidInput;
        if (record.pid <= 1) return error.InvalidInput;

        const key = projectKey(record.project);

        var file_buf: [64]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&file_buf, "{s}{s}", .{ record.id[0..], index_suffix });

        const bytes = try self.encode(record, key);
        defer self.allocator.free(bytes);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const key_fd = try self.openKeyDir(key, true);
        defer fs.closeFd(key_fd);
        try atomicReplace(self.allocator, self.io, key_fd, file_name, bytes);
    }

    /// Find the unique entry for `id` (optionally restricted to one project).
    /// Same id under several projects is ambiguous and refused, never guessed.
    pub fn resolve(self: *Registry, a: std.mem.Allocator, id: ids.Id, project: ?[]const u8) !?Record {
        if (!ids.valid(id)) return error.InvalidSessionID;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (project) |proj| {
            if (!std.unicode.utf8ValidateSlice(proj)) return error.InvalidInput;
            if (proj.len > max_project_bytes) return error.InvalidInput;
            const key = projectKey(proj);
            return try self.readOne(a, id, key, proj);
        }

        var found: ?Record = null;
        var iter = KeyIterator.init(self);
        while (try iter.next()) |key| {
            const maybe = try self.readOne(a, id, key, null);
            var record = maybe orelse continue;
            if (found != null) {
                freeRecord(a, &record);
                var previous = found.?;
                freeRecord(a, &previous);
                return error.AmbiguousSession;
            }
            found = record;
        }
        return found;
    }

    /// Bounded, deterministic listing across every project key directory.
    /// `running_only` filters on a live endpoint probe, never on pid or index,
    /// and every returned record carries the *probe* state instead of the state
    /// text frozen into the index at registration time. The index is never
    /// rewritten here.
    pub fn list(self: *Registry, a: std.mem.Allocator, running_only: bool, page: usize) ![]Record {
        var all: std.ArrayList(Record) = .empty;
        errdefer {
            freeRecords(a, all.items);
            all.deinit(a);
        }

        var scanned: usize = 0;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.list_truncated = false;
            scan: {
                var keys = KeyIterator.init(self);
                while (keys.next() catch |err| switch (err) {
                    error.TooManySessions => {
                        self.list_truncated = true;
                        break :scan;
                    },
                    else => return err,
                }) |key| {
                    const key_fd = self.openKeyDir(key, false) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    };
                    defer fs.closeFd(key_fd);
                    const dir: std.Io.Dir = .{ .handle = key_fd };
                    var it = dir.iterate();
                    while (it.next(self.io) catch return error.Unavailable) |entry| {
                        scanned += 1;
                        if (scanned > max_scan_entries) {
                            self.list_truncated = true;
                            break :scan;
                        }
                        if (entry.kind != .file) continue;
                        if (entry.name.len != 32 + index_suffix.len) continue;
                        if (!std.mem.endsWith(u8, entry.name, index_suffix)) continue;
                        const id_text = entry.name[0..32];
                        if (!ids.valid(id_text[0..32].*)) continue;
                        const id: ids.Id = id_text[0..32].*;
                        const stored = (self.readOneLocked(a, id, key, key_fd, null) catch continue) orelse continue;
                        var record = stored;
                        // One kernel+hello verified probe decides both visibility
                        // and the state the caller displays; it never starts a
                        // Runtime and never takes the controller role.
                        const live_state = self.probeUnlocked(record, probe_timeout_ms).state;
                        if (!probeVisible(live_state, running_only)) {
                            freeRecord(a, &record);
                            continue;
                        }
                        const owned_state = a.dupe(u8, stateLabel(live_state)) catch |err| {
                            freeRecord(a, &record);
                            return err;
                        };
                        a.free(@constCast(record.state));
                        record.state = owned_state;
                        all.append(a, record) catch |err| {
                            freeRecord(a, &record);
                            return err;
                        };
                    }
                }
            }
        }

        std.mem.sort(Record, all.items, {}, recordLessThan);
        const start = if (page > all.items.len / max_page) all.items.len else page * max_page;
        const end = @min(start + max_page, all.items.len);
        const result = try a.alloc(Record, end - start);
        @memcpy(result, all.items[start..end]);
        // Only keep ownership of the returned page.
        for (all.items[0..start]) |*record| freeRecord(a, record);
        for (all.items[end..]) |*record| freeRecord(a, record);
        all.deinit(a);
        return result;
    }

    /// Remove one index entry (best effort, no lease semantics). A stale entry
    /// that cannot be removed never authorizes or blocks a resume.
    pub fn unpublish(self: *Registry, id: ids.Id, project: ?[]const u8) !void {
        if (!ids.valid(id)) return error.InvalidSessionID;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (project) |proj| {
            if (!std.unicode.utf8ValidateSlice(proj)) return error.InvalidInput;
            const key = projectKey(proj);
            try self.unlinkOne(id, key);
            return;
        }
        var keys = KeyIterator.init(self);
        while (try keys.next()) |key| try self.unlinkOne(id, key);
    }

    fn unlinkOne(self: *Registry, id: ids.Id, key: [32]u8) !void {
        const key_fd = self.openKeyDir(key, false) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer fs.closeFd(key_fd);
        var buf: [64]u8 = undefined;
        const name_z = try std.fmt.bufPrintSentinel(&buf, "{s}{s}", .{ id[0..], index_suffix }, 0);
        if (c.unlinkat(key_fd, name_z, 0) != 0) {
            if (std.c._errno().* == 2) return;
            return fs.osError();
        }
    }

    /// True only when the endpoint is served by the exact live worker described
    /// by the record. A live pid or an index entry alone is never enough.
    pub fn isLive(self: *Registry, record: Record, timeout_ms: u32) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.isLiveUnlocked(record, timeout_ms);
    }

    fn isLiveUnlocked(self: *Registry, record: Record, timeout_ms: u32) bool {
        if (!self.endpointMatches(record.owner_instance, record.endpoint)) return false;
        const greeting = self.client().hello(record.endpoint, timeout_ms) catch return false;
        if (!std.mem.eql(u8, &greeting.session, &record.id)) return false;
        if (greeting.owner != record.owner) return false;
        if (greeting.protocol != protocol.version) return false;
        // The kernel pid of the socket peer must be the pid the worker claims;
        // a recycled pid or a different process at the path cannot pass this.
        if (greeting.pid != greeting.peer_pid) return false;
        if (greeting.pid != record.pid) return false;
        return true;
    }

    /// `hello` + optional `snapshot` for list/attach display. Never starts a
    /// Runtime and never takes the controller role.
    pub fn probe(self: *Registry, record: Record, timeout_ms: u32) Probe {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.probeUnlocked(record, timeout_ms);
    }

    fn probeUnlocked(self: *Registry, record: Record, timeout_ms: u32) Probe {
        var result: Probe = .{};
        if (!self.endpointMatches(record.owner_instance, record.endpoint)) return result;

        var conn = unix.connect(self.allocator, record.endpoint, self.uid, .{
            .io = self.io,
            .timeout_ms = timeout_ms,
        }) catch return result;
        defer conn.close();

        const greeting = self.client().exchangeHello(&conn, timeout_ms) catch return result;
        if (!std.mem.eql(u8, &greeting.session, &record.id) or greeting.owner != record.owner) return result;
        if (greeting.protocol != protocol.version or greeting.pid != greeting.peer_pid) return result;
        if (greeting.pid != record.pid) return result;
        result.live = true;
        result.pid = greeting.pid;
        result.state = .unknown;

        var reply = self.client().exchange(&conn, 2, "snapshot", timeout_ms) catch return result;
        defer reply.deinit();
        const object = switch (reply.value) {
            .object => |object| object,
            else => return result,
        };
        // `protocol.encodeSnapshot` publishes every probe field inside the
        // nested `snapshot` object, so a usable reply stays `unknown` here.
        applySnapshotProbe(&result, object);
        return result;
    }

    fn endpointMatches(self: *const Registry, owner_instance: []const u8, endpoint: []const u8) bool {
        if (!validOwnerInstance(owner_instance)) return false;
        if (endpoint.len > unix.max_socket_path_len) return false;
        var expected_buf: [unix.max_socket_path_len + 1]u8 = undefined;
        const expected = std.fmt.bufPrint(&expected_buf, "{s}/workers/{s}.sock", .{
            self.runtime.path, owner_instance,
        }) catch return false;
        return std.mem.eql(u8, expected, endpoint);
    }

    fn validateEndpoint(self: *const Registry, owner_instance: []const u8, endpoint: []const u8) !void {
        if (!validOwnerInstance(owner_instance)) return error.InvalidInput;
        if (!self.endpointMatches(owner_instance, endpoint)) return error.InvalidInput;
    }

    // -- encoding --------------------------------------------------------- --

    fn encode(self: *Registry, record: Record, key: [32]u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;
        try w.print("{{\"v\":{d},\"id\":", .{index_version});
        try writeString(w, record.id[0..]);
        try w.writeAll(",\"project\":");
        try writeString(w, record.project);
        try w.writeAll(",\"project_key\":");
        try writeString(w, &key);
        try w.writeAll(",\"owner\":");
        try writeString(w, @tagName(record.owner));
        try w.writeAll(",\"owner_instance\":");
        try writeString(w, record.owner_instance);
        try w.writeAll(",\"endpoint\":");
        try writeString(w, record.endpoint);
        try w.writeAll(",\"state\":");
        try writeString(w, record.state);
        const now_ms: u64 = @intCast(@max(0, std.Io.Clock.real.now(self.io).toMilliseconds()));
        const updated = if (record.updated_ms == 0) now_ms else record.updated_ms;
        try w.print(",\"updated_ms\":{d},\"generation\":{d},\"pid\":{d}}}", .{
            updated, record.generation, record.pid,
        });
        if (out.written().len > max_index_bytes) return error.InvalidInput;
        return self.allocator.dupe(u8, out.written());
    }

    // -- reading --------------------------------------------------------- --

    fn readOne(self: *Registry, a: std.mem.Allocator, id: ids.Id, key: [32]u8, project: ?[]const u8) !?Record {
        const key_fd = self.openKeyDir(key, false) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer fs.closeFd(key_fd);
        return self.readOneLocked(a, id, key, key_fd, project);
    }

    fn readOneLocked(self: *Registry, a: std.mem.Allocator, id: ids.Id, key: [32]u8, key_fd: c.fd_t, project: ?[]const u8) !?Record {
        var name_buf: [64]u8 = undefined;
        const name_z = try std.fmt.bufPrintSentinel(&name_buf, "{s}{s}", .{ id[0..], index_suffix }, 0);
        const fd = fs.linux.openat(key_fd, name_z, fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0);
        if (fd < 0) return if (std.c._errno().* == 2) null else fs.osError();
        defer fs.closeFd(fd);

        if (!isRegularFd(fd)) return null;
        var buffer: [max_index_bytes]u8 = undefined;
        const n = fs.fileFromFd(fd).readPositionalAll(self.io, &buffer, 0) catch return null;
        if (n == 0) return null;

        return self.decode(a, buffer[0..n], id, key, project) catch null;
    }

    fn decode(self: *Registry, a: std.mem.Allocator, bytes: []const u8, id: ids.Id, key: [32]u8, project: ?[]const u8) !Record {
        const doc = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch return error.ProtocolError;
        defer doc.deinit();
        const object = switch (doc.value) {
            .object => |object| object,
            else => return error.ProtocolError,
        };

        const version_value = object.get("v") orelse return error.ProtocolError;
        if (jsonU64(version_value) != index_version) return error.ProtocolError;

        const id_text = jsonString(object.get("id")) orelse return error.ProtocolError;
        if (id_text.len != 32 or !std.mem.eql(u8, id_text, id[0..])) return error.ProtocolError;

        const project_text = jsonString(object.get("project")) orelse return error.ProtocolError;
        try validateAbsolutePath(project_text);
        if (project_text.len > max_project_bytes or !std.unicode.utf8ValidateSlice(project_text)) return error.ProtocolError;
        if (project) |expected| if (!std.mem.eql(u8, expected, project_text)) return error.ProtocolError;

        const key_text = jsonString(object.get("project_key")) orelse return error.ProtocolError;
        if (!std.mem.eql(u8, key_text, &key)) return error.ProtocolError;

        const owner_text = jsonString(object.get("owner")) orelse return error.ProtocolError;
        const owner = std.meta.stringToEnum(cli.WorkerOwner, owner_text) orelse return error.ProtocolError;

        const instance = jsonString(object.get("owner_instance")) orelse return error.ProtocolError;
        if (!validOwnerInstance(instance)) return error.ProtocolError;

        const endpoint = jsonString(object.get("endpoint")) orelse return error.ProtocolError;
        if (!std.unicode.utf8ValidateSlice(endpoint)) return error.ProtocolError;
        if (!self.endpointMatches(instance, endpoint)) return error.ProtocolError;

        const state = jsonString(object.get("state")) orelse return error.ProtocolError;
        if (state.len == 0 or state.len > max_state_bytes) return error.ProtocolError;
        for (state) |byte| if (byte < 0x21 or byte > 0x7e) return error.ProtocolError;

        const pid_value = jsonU64(object.get("pid") orelse return error.ProtocolError);
        if (pid_value <= 1 or pid_value > std.math.maxInt(u32)) return error.ProtocolError;
        const generation = jsonU64(object.get("generation") orelse return error.ProtocolError);
        const updated_ms = jsonU64(object.get("updated_ms") orelse return error.ProtocolError);

        const record: Record = .{
            .id = id,
            .project = try a.dupe(u8, project_text),
            .endpoint = try a.dupe(u8, endpoint),
            .owner = owner,
            .owner_instance = try a.dupe(u8, instance),
            .state = try a.dupe(u8, state),
            .pid = @intCast(pid_value),
            .generation = generation,
            .updated_ms = updated_ms,
        };
        return record;
    }

    // -- endpoint probing ------------------------------------------------- --

    fn client(self: *Registry) EndpointClient {
        return .init(self.allocator, self.io, self.uid);
    }

    // -- index directories ------------------------------------------------- --

    fn openKeyDir(self: *Registry, key: [32]u8, create: bool) !c.fd_t {
        var buf: [33]u8 = undefined;
        @memcpy(buf[0..32], &key);
        buf[32] = 0;
        if (create) return ensurePrivateDir(self.allocator, self.index_fd, buf[0..32], self.uid);
        return fs.openDirectory(self.index_fd, buf[0..32 :0]);
    }

    const KeyIterator = struct {
        registry: *Registry,
        it: std.Io.Dir.Iterator,
        scanned: usize = 0,

        fn init(registry: *Registry) KeyIterator {
            const dir: std.Io.Dir = .{ .handle = registry.index_fd };
            return .{ .registry = registry, .it = dir.iterate() };
        }

        fn next(self: *KeyIterator) !?([32]u8) {
            while (true) {
                const entry = (try self.it.next(self.registry.io)) orelse return null;
                self.scanned += 1;
                if (self.scanned > max_scan_entries) return error.TooManySessions;
                if (entry.kind != .directory) continue;
                if (entry.name.len != 32 or !ids.valid(entry.name[0..32].*)) continue;
                return entry.name[0..32].*;
            }
        }
    };
};

/// Default per-probe budget for registry-driven liveness checks.
pub const probe_timeout_ms: u32 = 200;

fn recordLessThan(_: void, left: Record, right: Record) bool {
    const order = std.mem.order(u8, left.project, right.project);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, left.id[0..], right.id[0..]) == .lt;
}

pub fn projectKey(project: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project, &digest, .{});
    return std.fmt.bytesToHex(digest[0..16].*, .lower);
}

fn validOwnerInstance(instance: []const u8) bool {
    if (instance.len == 0 or instance.len > 32) return false;
    for (instance) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn validateAbsolutePath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_project_bytes) return error.InvalidInput;
    if (std.mem.findScalar(u8, path, 0) != null) return error.InvalidInput;
    if (!std.fs.path.isAbsolute(path)) return error.InvalidInput;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidInput;
}

fn isRegularFd(fd: c.fd_t) bool {
    var st: linux.Statx = undefined;
    if (c.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &st) != 0) return false;
    return st.mode & linux.S.IFMT == linux.S.IFREG;
}

fn openExistingDirectory(a: std.mem.Allocator, path: []const u8) !c.fd_t {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const st = statAt(-100, z.ptr) catch |err| return err;
    if (st.mode & linux.S.IFMT != linux.S.IFDIR) return error.NotDirectory;
    return fs.openDirectory(-100, z.ptr);
}

const OpenedIndex = struct { fd: c.fd_t, path: []u8 };

/// Walk HOME without following symlinks, then create/verify the private
/// `session-index` root. Ordinary HOME may be 0755; only these subdirectories
/// are required to be 0700. Metadata paths are not UNIX socket paths, so the
/// 107-byte AF_UNIX limit does not apply here.
fn openHomeIndex(a: std.mem.Allocator, io: std.Io, home: []const u8, uid: u32) !OpenedIndex {
    var fd = try openExistingDirectory(a, "/");
    var parts = std.mem.tokenizeScalar(u8, home, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            fs.closeFd(fd);
            return error.InvalidPath;
        }
        const z = try a.dupeSentinel(u8, part, 0);
        defer a.free(z);
        const next = fs.openDirectory(fd, z.ptr) catch |err| {
            fs.closeFd(fd);
            return err;
        };
        fs.closeFd(fd);
        fd = next;
    }
    const thin_fd = ensurePrivateDir(a, fd, ".thin", uid) catch |err| {
        fs.closeFd(fd);
        return err;
    };
    fs.closeFd(fd);
    const index_fd = ensurePrivateDir(a, thin_fd, "session-index", uid) catch |err| {
        fs.closeFd(thin_fd);
        return err;
    };
    fs.closeFd(thin_fd);
    errdefer fs.closeFd(index_fd);

    const dir: std.Io.Dir = .{ .handle = index_fd };
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buffer) catch |err| {
        fs.closeFd(index_fd);
        return err;
    };
    return .{ .fd = index_fd, .path = try a.dupe(u8, buffer[0..n]) };
}

fn statAt(dir_fd: c.fd_t, path_z: [*:0]const u8) !linux.Statx {
    var result: linux.Statx = undefined;
    if (c.statx(dir_fd, path_z, linux.AT.SYMLINK_NOFOLLOW, linux.STATX.BASIC_STATS, &result) != 0) return fs.osError();
    return result;
}

/// Create-if-missing plus verify: real directory, owned by `uid`, exactly 0700.
/// An owned permissive mode is tightened; a foreign owner or symlink is refused.
fn ensurePrivateDir(a: std.mem.Allocator, parent: c.fd_t, name: []const u8, uid: u32) !c.fd_t {
    if (name.len == 0 or name.len > 255) return error.InvalidInput;
    if (std.mem.findScalar(u8, name, 0) != null or std.mem.findScalar(u8, name, '/') != null) return error.InvalidInput;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidInput;
    const z = try a.dupeSentinel(u8, name, 0);
    defer a.free(z);

    if (c.mkdirat(parent, z.ptr, 0o700) != 0) {
        const errno = std.c._errno().*;
        if (errno != 17) return fs.osError();
    }
    const fd = try fs.openDirectory(parent, z.ptr);
    errdefer fs.closeFd(fd);

    var st: linux.Statx = undefined;
    if (c.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &st) != 0) return fs.osError();
    if (st.mode & linux.S.IFMT != linux.S.IFDIR) return error.NotDirectory;
    if (st.uid != uid) return error.NotOwned;
    if (st.mode & 0o777 != 0o700) {
        if (c.fchmod(fd, 0o700) != 0) return fs.osError();
        if (c.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &st) != 0) return fs.osError();
        if (st.mode & 0o777 != 0o700) return error.InsecurePermissions;
    }
    return fd;
}

fn atomicReplace(a: std.mem.Allocator, io: std.Io, dir: c.fd_t, name: []const u8, bytes: []const u8) !void {
    var name_buf: [80]u8 = undefined;
    const name_z = try std.fmt.bufPrintSentinel(&name_buf, "{s}", .{name}, 0);
    var temp_buf: [80]u8 = undefined;
    var temp: [:0]u8 = undefined;
    var fd: c.fd_t = -1;
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        temp = try std.fmt.bufPrintSentinel(&temp_buf, ".tmp-{s}", .{std.fmt.bytesToHex(random, .lower)}, 0);
        fd = fs.linux.openat(
            dir,
            temp,
            1 | fs.linux.create | fs.linux.exclusive | fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock,
            0o600,
        );
        if (fd >= 0) break;
        if (std.c._errno().* != 17) return fs.osError();
    }
    if (fd < 0) return error.TempNameExhausted;
    defer fs.closeFd(fd);
    defer _ = c.unlinkat(dir, temp, 0);

    try fs.fileFromFd(fd).writePositionalAll(io, bytes, 0);
    if (c.fchmod(fd, 0o600) != 0) return fs.osError();
    try fsyncFd(fd);
    if (c.renameat(
        dir,
        temp,
        dir,
        name_z,
    ) != 0) return fs.osError();
    try fsyncFd(dir);
    _ = a;
}

fn fsyncFd(fd: c.fd_t) !void {
    while (true) {
        if (fsync(fd) == 0) return;
        if (std.c._errno().* == 4) continue; // EINTR
        return fs.osError();
    }
}

fn jsonU64(value: std.json.Value) u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else 0,
        else => 0,
    };
}

/// One pending approval is present only when the snapshot carries a non-null
/// approval id. This is the only field that may produce `waiting_approval`.
fn pendingApproval(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .null => false,
        .integer => |id| id != 0,
        .float => |id| id != 0,
        .string => |text| text.len != 0 and !std.mem.eql(u8, text, "null"),
        else => false,
    };
}

/// Probe fields of one `snapshot` reply, read from the nested object the wire
/// actually sends.
const SnapshotProbe = struct {
    busy: bool,
    pending_permission: bool,
    attached: bool,
    state: Probe.State,
};

/// Read the nested `"snapshot": {...}` object of one snapshot reply. `null`
/// means the reply carried no usable snapshot (missing or wrong-typed object,
/// or a `busy` flag that is not a bool), so the caller must keep `unknown`
/// rather than reporting a live owner as idle/running by default.
fn readSnapshotProbe(object: std.json.ObjectMap) ?SnapshotProbe {
    const nested = switch (object.get("snapshot") orelse return null) {
        .object => |value| value,
        else => return null,
    };
    const busy = jsonBool(nested.get("busy")) orelse return null;
    // The wire publishes the pending approval id as `pending` (null when no
    // approval is waiting); a missing/`null` id is never "waiting".
    const pending = pendingApproval(nested.get("pending"));
    return .{
        .busy = busy,
        .pending_permission = pending,
        .attached = jsonBool(nested.get("attached")) orelse false,
        .state = probeState(busy, pending),
    };
}

/// Apply one snapshot reply to an already `hello`-verified probe. Without a
/// usable nested snapshot the probe keeps the `unknown` state set after
/// `hello`; nothing is ever inferred from the index or from a default.
fn applySnapshotProbe(result: *Probe, object: std.json.ObjectMap) void {
    const snapshot = readSnapshotProbe(object) orelse return;
    result.busy = snapshot.busy;
    result.pending_permission = snapshot.pending_permission;
    result.attached = snapshot.attached;
    result.state = snapshot.state;
}

/// Probe state from the two independent owner flags: a waiting approval wins
/// over a busy task because it is the condition a reattached viewer must see and
/// answer.
pub fn probeState(busy: bool, pending_permission: bool) Probe.State {
    if (pending_permission) return .waiting_approval;
    if (busy) return .running;
    return .idle;
}

/// State text returned for one probed record. `dead` is reported as
/// `unreachable`, the word the daemon `list` reply already uses, and a live
/// owner whose snapshot timed out stays `unknown` rather than being guessed as
/// running or idle.
pub fn stateLabel(state: Probe.State) []const u8 {
    return switch (state) {
        .dead => "unreachable",
        .idle => "idle",
        .running => "running",
        .waiting_approval => "waiting_approval",
        .unknown => "unknown",
    };
}

/// `running_only` keeps exactly the records with real work in flight: a busy
/// snapshot or a pending approval. A live owner whose snapshot timed out is
/// still listed as `unknown` (never as running); idle and dead records are
/// dropped.
pub fn probeVisible(state: Probe.State, running_only: bool) bool {
    if (!running_only) return true;
    return switch (state) {
        .running, .waiting_approval, .unknown => true,
        .idle, .dead => false,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    return switch (value orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

/// Minimal read-only `hello`/`snapshot` client for one endpoint. It never
/// attaches, never takes an epoch and never submits anything.
const EndpointClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    uid: u32,

    fn init(a: std.mem.Allocator, io: std.Io, uid: u32) EndpointClient {
        return .{ .allocator = a, .io = io, .uid = uid };
    }

    fn hello(self: EndpointClient, endpoint: []const u8, timeout_ms: u32) !Hello {
        var conn = unix.connect(self.allocator, endpoint, self.uid, .{
            .io = self.io,
            .timeout_ms = timeout_ms,
        }) catch return error.Unavailable;
        defer conn.close();
        return self.exchangeHello(&conn, timeout_ms);
    }

    fn exchangeHello(self: EndpointClient, conn: *unix.Connection, timeout_ms: u32) !Hello {
        var doc = try self.exchange(conn, 1, "hello", timeout_ms);
        defer doc.deinit();
        const object = switch (doc.value) {
            .object => |object| object,
            else => return error.ProtocolError,
        };
        const session_text = jsonString(object.get("session")) orelse return error.ProtocolError;
        if (session_text.len != 32) return error.ProtocolError;
        const session: ids.Id = session_text[0..32].*;
        if (!ids.valid(session)) return error.ProtocolError;

        const owner_text = jsonString(object.get("owner")) orelse return error.ProtocolError;
        const owner = std.meta.stringToEnum(cli.WorkerOwner, owner_text) orelse return error.ProtocolError;

        const pid_value = jsonU64(object.get("pid") orelse return error.ProtocolError);
        if (pid_value <= 1 or pid_value > std.math.maxInt(u32)) return error.ProtocolError;
        const proto_value = jsonU64(object.get("protocol") orelse return error.ProtocolError);
        if (proto_value != protocol.version) return error.ProtocolError;

        return .{
            .session = session,
            .owner = owner,
            .pid = @intCast(pid_value),
            .peer_pid = @intCast(conn.peer.pid),
            .peer_uid = conn.peer.uid,
            .protocol = @intCast(proto_value),
        };
    }

    const Reply = struct {
        value: std.json.Value,
        doc: std.json.Parsed(std.json.Value),
        fn deinit(self: *Reply) void {
            self.doc.deinit();
            self.* = undefined;
        }
    };

    fn exchange(self: EndpointClient, conn: *unix.Connection, request_id: u64, op: []const u8, timeout_ms: u32) !Reply {
        var req_buf: [160]u8 = undefined;
        const request = if (std.mem.eql(u8, op, "hello"))
            try std.fmt.bufPrint(&req_buf, "{{\"v\":{d},\"id\":{d},\"op\":\"hello\",\"view\":\"viewer\"}}", .{ protocol.version, request_id })
        else
            try std.fmt.bufPrint(&req_buf, "{{\"v\":{d},\"id\":{d},\"op\":\"{s}\"}}", .{ protocol.version, request_id, op });

        const wait: unix.Wait = .{ .io = self.io, .timeout_ms = timeout_ms };
        try conn.writeFrame(request, wait);
        const frame = (try conn.readFrame(wait)) orelse return error.ConnectionClosed;
        defer self.allocator.free(frame);
        if (!std.unicode.utf8ValidateSlice(frame)) return error.ProtocolError;

        const doc = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{ .allocate = .alloc_always }) catch return error.ProtocolError;
        errdefer doc.deinit();
        const object = switch (doc.value) {
            .object => |object| object,
            else => return error.ProtocolError,
        };
        if (jsonU64(object.get("v") orelse return error.ProtocolError) != protocol.version) return error.ProtocolError;
        if (jsonU64(object.get("id") orelse return error.ProtocolError) != request_id) return error.ProtocolError;
        const ok = jsonBool(object.get("ok")) orelse return error.ProtocolError;
        if (!ok) return error.Unavailable;
        return .{ .value = doc.value, .doc = doc };
    }
};

/// Public readiness probe used by the worker spawner.
pub fn helloEndpoint(a: std.mem.Allocator, io: std.Io, uid: u32, endpoint: []const u8, timeout_ms: u32) !Hello {
    return EndpointClient.init(a, io, uid).hello(endpoint, timeout_ms);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    home_path: []u8,
    runtime_base: []u8,

    fn init(a: std.mem.Allocator) !TestEnv {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const base = buf[0..n];
        const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
        errdefer a.free(home);
        try tmp.dir.createDir(testing.io, "home", .default_dir);
        const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
        errdefer a.free(runtime);
        try tmp.dir.createDir(testing.io, "runtime", .fromMode(0o700));

        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("XDG_RUNTIME_DIR", runtime);
        return .{ .tmp = tmp, .env = env, .home_path = home, .runtime_base = runtime };
    }

    fn deinit(self: *TestEnv, a: std.mem.Allocator) void {
        self.env.deinit();
        a.free(self.home_path);
        a.free(self.runtime_base);
        self.tmp.cleanup();
    }
};

fn testRecord(registry: *const Registry, id: ids.Id, project: []const u8, instance: []const u8) !Record {
    const endpoint = try std.fmt.allocPrint(testing.allocator, "{s}/workers/{s}.sock", .{
        registry.runtime.path, instance,
    });
    return .{
        .id = id,
        .project = try testing.allocator.dupe(u8, project),
        .endpoint = endpoint,
        .owner = .foreground,
        .owner_instance = try testing.allocator.dupe(u8, instance),
        .state = try testing.allocator.dupe(u8, "running"),
        .pid = 4242,
        .generation = 1,
    };
}

test "registry publishes schema v1 id strings and resolves across projects" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);

    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    {
        var st: linux.Statx = undefined;
        try testing.expectEqual(@as(c_int, 0), c.statx(registry.index_fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &st));
        try testing.expectEqual(@as(u16, 0o700), @as(u16, @intCast(st.mode & 0o777)));
    }

    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const project = "/tmp/project-one";
    var record = try testRecord(&registry, id, project, "aaaaaaaaaaaaaaaa");
    defer freeRecord(a, &record);
    try registry.register(record);

    // On-disk schema: `id` is a 32-hex JSON string, not an array of numbers.
    const key = projectKey(project);
    var key_z_buf: [33]u8 = undefined;
    @memcpy(key_z_buf[0..32], &key);
    key_z_buf[32] = 0;
    const key_fd = try fs.openDirectory(registry.index_fd, key_z_buf[0..32 :0]);
    defer fs.closeFd(key_fd);
    var file_z_buf: [64]u8 = undefined;
    const file_z = try std.fmt.bufPrintSentinel(&file_z_buf, "{s}.json", .{id[0..]}, 0);
    const fd = fs.linux.openat(key_fd, file_z, fs.linux.nofollow | fs.linux.nonblock | fs.linux.cloexec, 0);
    try testing.expect(fd >= 0);
    defer fs.closeFd(fd);
    var raw_buf: [4096]u8 = undefined;
    const n = try fs.fileFromFd(fd).readPositionalAll(testing.io, &raw_buf, 0);
    const raw = raw_buf[0..n];
    try testing.expect(std.mem.indexOf(u8, raw, "\"id\":\"0123456789abcdef0123456789abcdef\"") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"v\":1") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "\"owner\":\"foreground\"") != null);

    const resolved = (try registry.resolve(a, id, project)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = resolved;
        freeRecord(a, &owned);
    }
    try testing.expectEqual(id, resolved.id);
    try testing.expectEqualStrings(project, resolved.project);
    try testing.expectEqual(cli.WorkerOwner.foreground, resolved.owner);

    // Same id in another project must be refused as ambiguous, not guessed.
    var other = try testRecord(&registry, id, "/tmp/project-two", "bbbbbbbbbbbbbbbb");
    defer freeRecord(a, &other);
    try registry.register(other);
    try testing.expectError(error.AmbiguousSession, registry.resolve(a, id, null));
    const scoped = (try registry.resolve(a, id, project)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = scoped;
        freeRecord(a, &owned);
    }
    try testing.expectEqualStrings(project, scoped.project);

    const page = try registry.list(a, false, 0);
    defer freeRecords(a, page);
    try testing.expectEqual(@as(usize, 2), page.len);

    // A hostile page index (UI/RPC supplied) must clamp to an empty tail page
    // instead of overflowing `page * max_page`.
    const past_end = try registry.list(a, false, std.math.maxInt(usize));
    defer freeRecords(a, past_end);
    try testing.expectEqual(@as(usize, 0), past_end.len);

    try registry.unpublish(id, "/tmp/project-two");
    const remaining = (try registry.resolve(a, id, null)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = remaining;
        freeRecord(a, &owned);
    }
    try testing.expectEqualStrings(project, remaining.project);
    try registry.unpublish(id, project);
    const after = try registry.resolve(a, id, null);
    if (after) |value| {
        var owned = value;
        freeRecord(a, &owned);
        return error.TestUnexpectedResult;
    }
}

test "registry rejects records outside the runtime endpoint shape" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    const id: ids.Id = "ffffffffffffffffffffffffffffffff".*;
    var record = try testRecord(&registry, id, "/tmp/project", "cccccccccccccccc");
    // Swap the endpoint for one outside `<runtime>/workers`.
    a.free(record.endpoint);
    record.endpoint = try a.dupe(u8, "/tmp/elsewhere.sock");
    defer freeRecord(a, &record);
    try testing.expectError(error.InvalidInput, registry.register(record));

    // Non-hex owner-instance is also refused before publication.
    a.free(record.endpoint);
    record.endpoint = try a.dupe(u8, "/tmp/elsewhere.sock");
    a.free(record.owner_instance);
    record.owner_instance = try a.dupe(u8, "NOTHEX");
    try testing.expectError(error.InvalidInput, registry.register(record));
}

test "registry keeps liveness independent of pid and index entry" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    // An index record whose endpoint does not exist must never appear live,
    // even though its pid belongs to a real process and the file exists.
    const id: ids.Id = "11111111111111111111111111111111".*;
    var record = try testRecord(&registry, id, "/tmp/project", "dddddddddddddddd");
    defer freeRecord(a, &record);
    try registry.register(record);
    try testing.expect(!registry.isLive(record, 20));
    try testing.expectEqual(Probe.State.dead, registry.probe(record, 20).state);

    // A mismatched instance/endpoint pair is refused without any connection.
    var forged = record;
    forged.owner_instance = "eeeeeeeeeeeeeeee";
    try testing.expect(!registry.isLive(forged, 20));
}

test "list reports probed state instead of the frozen index text" {
    const a = testing.allocator;
    var test_env = try TestEnv.init(a);
    defer test_env.deinit(a);
    var registry = try Registry.init(a, testing.io, &test_env.env);
    defer registry.deinit();

    const id: ids.Id = "22222222222222222222222222222222".*;
    // The index says "running" for every entry; only the probe may correct it.
    var record = try testRecord(&registry, id, "/tmp/project", "ffffffffffffffff");
    defer freeRecord(a, &record);
    try testing.expectEqualStrings("running", record.state);
    try registry.register(record);

    // No endpoint exists, so both listings must report `unreachable`; a dead
    // record is never surfaced as running and is excluded from `--running`.
    {
        const page = try registry.list(a, false, 0);
        defer freeRecords(a, page);
        try testing.expectEqual(@as(usize, 1), page.len);
        try testing.expectEqualStrings("unreachable", page[0].state);
        try testing.expectEqualStrings("/tmp/project", page[0].project);
    }
    {
        const page = try registry.list(a, true, 0);
        defer freeRecords(a, page);
        try testing.expectEqual(@as(usize, 0), page.len);
    }

    // The display state was never written back to the index.
    try testing.expectEqualStrings("running", record.state);
    const resolved = (try registry.resolve(a, id, null)) orelse return error.TestUnexpectedResult;
    defer {
        var owned = resolved;
        freeRecord(a, &owned);
    }
    try testing.expectEqualStrings("running", resolved.state);
}

test "probe state labels and running filter are explicit" {
    // Idle and dead are never presented as work in flight; a live owner whose
    // snapshot timed out stays explicitly unknown.
    try testing.expectEqualStrings("running", stateLabel(.running));
    try testing.expectEqualStrings("waiting_approval", stateLabel(.waiting_approval));
    try testing.expectEqualStrings("idle", stateLabel(.idle));
    try testing.expectEqualStrings("unknown", stateLabel(.unknown));
    try testing.expectEqualStrings("unreachable", stateLabel(.dead));

    try testing.expect(probeVisible(.running, true));
    try testing.expect(probeVisible(.waiting_approval, true));
    try testing.expect(probeVisible(.unknown, true));
    try testing.expect(!probeVisible(.idle, true));
    try testing.expect(!probeVisible(.dead, true));

    inline for (std.meta.tags(Probe.State)) |state| try testing.expect(probeVisible(state, false));
}

test "probe state reads the pending approval id the wire actually publishes" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(2);
    try protocol.encodeSnapshot(&out, .{
        .session = id,
        .project = "/tmp/project",
        .owner = .daemon,
        .busy = true,
        .pending_permission = 7,
    });
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    defer doc.deinit();
    const object = doc.value.object.get("snapshot").?.object;

    // The approval id travels as `pending`; reading any other name reported a
    // permanently idle session even while a command waited for approval.
    try testing.expect(object.get("pending_permission") == null);
    try testing.expect(pendingApproval(object.get("pending")));
    try testing.expectEqual(Probe.State.waiting_approval, probeState(true, pendingApproval(object.get("pending"))));

    // A busy task without an approval id is running, not waiting.
    try testing.expect(!pendingApproval(.null));
    try testing.expect(!pendingApproval(null));
    try testing.expectEqual(Probe.State.running, probeState(true, false));
    try testing.expectEqual(Probe.State.idle, probeState(false, false));
}

/// One whole reply frame parsed the way `EndpointClient.exchange` consumes it:
/// the envelope (`v`, `id`, `ok`) must be exact, not merely present.
const TestFrame = struct {
    doc: std.json.Parsed(std.json.Value),
    root: std.json.ObjectMap,

    fn deinit(self: *TestFrame) void {
        self.doc.deinit();
        self.* = undefined;
    }
};

fn parseTestFrame(a: std.mem.Allocator, bytes: []const u8, request_id: u64) !TestFrame {
    try testing.expect(std.unicode.utf8ValidateSlice(bytes));
    var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
    errdefer doc.deinit();
    const root = switch (doc.value) {
        .object => |object| object,
        else => return error.ProtocolError,
    };
    try testing.expectEqual(@as(u64, protocol.version), jsonU64(root.get("v") orelse return error.ProtocolError));
    try testing.expectEqual(request_id, jsonU64(root.get("id") orelse return error.ProtocolError));
    try testing.expect(jsonBool(root.get("ok")) orelse return error.ProtocolError);
    return .{ .doc = doc, .root = root };
}

/// Apply one whole snapshot reply to a probe that `hello` already confirmed
/// live, exactly as `probeUnlocked` does.
fn probeFromReply(a: std.mem.Allocator, bytes: []const u8) !Probe {
    var frame = try parseTestFrame(a, bytes, 2);
    defer frame.deinit();
    var probe: Probe = .{ .live = true, .pid = 4242, .state = .unknown };
    applySnapshotProbe(&probe, frame.root);
    return probe;
}

test "probe reads the nested snapshot object a real reply carries" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;

    const Case = struct { busy: bool, pending: ?u64, state: Probe.State };
    const cases = [_]Case{
        .{ .busy = true, .pending = null, .state = .running },
        .{ .busy = false, .pending = null, .state = .idle },
        .{ .busy = false, .pending = 7, .state = .waiting_approval },
    };
    for (cases) |case| {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.ok(2);
        try protocol.encodeSnapshot(&out, .{
            .session = id,
            .project = "/tmp/project",
            .owner = .daemon,
            .busy = case.busy,
            .pending_permission = case.pending,
            .attached = true,
        });
        const bytes = try out.finish();
        defer a.free(bytes);

        // The root object never carries a probe field; only `snapshot` does.
        var frame = try parseTestFrame(a, bytes, 2);
        defer frame.deinit();
        try testing.expect(frame.root.get("busy") == null);
        try testing.expect(frame.root.get("snapshot") != null);

        const probe = try probeFromReply(a, bytes);
        try testing.expect(probe.live);
        try testing.expectEqual(@as(u32, 4242), probe.pid);
        try testing.expectEqual(case.busy, probe.busy);
        try testing.expectEqual(case.pending != null, probe.pending_permission);
        try testing.expect(probe.attached);
        try testing.expectEqual(case.state, probe.state);
        // This is what `/ls --running` renders: only real work stays listed.
        try testing.expectEqual(case.state != .idle, probeVisible(probe.state, true));
    }
}

test "probe stays unknown when the reply has no usable snapshot" {
    const a = testing.allocator;
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;

    // 1. `ok` reply with no nested `snapshot` object at all.
    var bare = protocol.Out.init(a);
    defer bare.deinit();
    try bare.ok(2);
    const bare_bytes = try bare.finish();
    defer a.free(bare_bytes);
    const bare_probe = try probeFromReply(a, bare_bytes);
    try testing.expect(bare_probe.live);
    try testing.expectEqual(Probe.State.unknown, bare_probe.state);
    try testing.expect(!bare_probe.busy);
    try testing.expect(!bare_probe.pending_permission);
    try testing.expect(!bare_probe.attached);

    // 2. `snapshot` present but not an object.
    var wrong_type = protocol.Out.init(a);
    defer wrong_type.deinit();
    try wrong_type.ok(2);
    try wrong_type.field("snapshot", @as(?u8, null));
    const wrong_type_bytes = try wrong_type.finish();
    defer a.free(wrong_type_bytes);
    try testing.expectEqual(Probe.State.unknown, (try probeFromReply(a, wrong_type_bytes)).state);

    // 3. Nested object whose `busy` flag is not a bool: never default to idle.
    var bad_busy = protocol.Out.init(a);
    defer bad_busy.deinit();
    try bad_busy.ok(2);
    try bad_busy.beginObject("snapshot");
    try bad_busy.field("busy", @as(?u8, null));
    try bad_busy.field("pending", @as(?u64, null));
    try bad_busy.field("attached", true);
    try bad_busy.endObject();
    const bad_busy_bytes = try bad_busy.finish();
    defer a.free(bad_busy_bytes);
    const bad_busy_probe = try probeFromReply(a, bad_busy_bytes);
    try testing.expectEqual(Probe.State.unknown, bad_busy_probe.state);
    try testing.expect(!bad_busy_probe.busy);

    // 4. A real encoded snapshot with `busy` stripped keeps `unknown` too.
    var stripped = protocol.Out.init(a);
    defer stripped.deinit();
    try stripped.ok(2);
    try stripped.beginObject("snapshot");
    try stripped.field("session", id[0..]);
    try stripped.field("attached", true);
    try stripped.endObject();
    const stripped_bytes = try stripped.finish();
    defer a.free(stripped_bytes);
    try testing.expectEqual(Probe.State.unknown, (try probeFromReply(a, stripped_bytes)).state);
}
