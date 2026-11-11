fn reportMessage(io: std.Io, message: []const u8) void {
    writeErr(io, message);
}

const testing = std.testing;

fn testSocketPair(fds: *[2]std.c.fd_t) c_int {
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, fds) != 0) return -1;
    if (@import("builtin").os.tag == .macos) {
        const enabled: c_int = 1;
        for (fds.*) |fd| {
            if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) {
                _ = std.c.close(fds[0]);
                _ = std.c.close(fds[1]);
                return -1;
            }
        }
    }
    return 0;
}

const Pair = struct {
    client: *Client,
    server: unix.Connection,

    fn deinit(self: *Pair) void {
        self.server.close();
        self.client.deinit();
    }

    fn closeServer(self: *Pair) void {
        self.server.close();
        self.server = unix.Connection.init(self.client.a, -1, .{ .pid = 0, .uid = 0, .gid = 0 });
    }

    /// The id the client will use for its very next request.
    fn nextId(self: *Pair) u64 {
        const id = self.client.next_req +% 1;
        return if (id == 0) 1 else id;
    }

    /// Write one reply frame with the given extra fields, then let the client
    /// read it. Single-threaded: the reply is queued before the client reads.
    fn reply(self: *Pair, id: u64, fields: []const u8) !void {
        const a = self.client.a;
        const bytes = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,{s}}}", .{ protocol.version, id, fields });
        defer a.free(bytes);
        try self.server.writeFrame(bytes, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    }

    fn replyError(self: *Pair, id: u64, code: []const u8) !void {
        const a = self.client.a;
        const bytes = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":false,\"err\":\"{s}\"}}", .{ protocol.version, id, code });
        defer a.free(bytes);
        try self.server.writeFrame(bytes, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    }
};

fn pairOf(a: std.mem.Allocator) !Pair {
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(std.testing.io, &root_buf);
    const client = try Client.init(a, std.testing.io, null, .foreground, root_buf[0..n], root_buf[0..n]);
    var fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&fds) != 0) {
        client.deinit();
        return error.SocketPairFailed;
    }
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.conn = unix.Connection.init(a, fds[0], peer);
    client.epoch = 5;
    return .{ .client = client, .server = unix.Connection.init(a, fds[1], peer) };
}

fn serveControlUntilSnapshot(pair: *Pair, a: std.mem.Allocator) !void {
    const io = testing.io;
    var saw_settings = false;
    for (0..8) |_| {
        const bytes = (try pair.server.readFrame(.{ .io = io, .timeout_ms = 2000 })) orelse return error.TestUnexpectedResult;
        defer a.free(bytes);
        var request = try protocol.parseRequest(a, bytes);
        defer request.deinit();
        switch (request.op) {
            .snapshot => {
                try testing.expect(saw_settings);
                try pair.reply(request.id, "\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"busy\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
                return;
            },
            .settings => {
                try testing.expect(!saw_settings);
                try testing.expectEqual(@as(u64, 5), try request.u64Field("epoch"));
                saw_settings = true;
                try pair.reply(request.id, "\"available\":true,\"model\":\"m3\"");
            },
            .poll_metadata => try pair.reply(request.id, "\"changed\":false"),
            else => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

fn serveControlUntilCancel(pair: *Pair, a: std.mem.Allocator) !void {
    const io = testing.io;
    for (0..8) |_| {
        const bytes = (try pair.server.readFrame(.{ .io = io, .timeout_ms = 2_000 })) orelse return error.TestUnexpectedResult;
        defer a.free(bytes);
        var request = try protocol.parseRequest(a, bytes);
        defer request.deinit();
        switch (request.op) {
            .cancel => {
                try pair.reply(request.id, "\"accepted\":true");
                return;
            },
            .poll_metadata => try pair.reply(request.id, "\"changed\":false"),
            else => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

const WatchFrame = union(enum) { snapshot, baseline, events: u64, ack: struct { id: u64, first: u64, sequence: u64 } };

fn readWatchFrame(conn: *unix.Connection, a: std.mem.Allocator) !WatchFrame {
    const raw = (try conn.readFrame(.{ .io = testing.io, .timeout_ms = 2_000 })) orelse return error.TestUnexpectedResult;
    defer a.free(raw);
    var document = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer document.deinit();
    const object = switch (document.value) {
        .object => |value| value,
        else => return error.TestUnexpectedResult,
    };
    if (object.get("op")) |op| {
        if (!std.mem.eql(u8, switch (op) {
            .string => |name| name,
            else => return error.TestUnexpectedResult,
        }, "ack")) return error.TestUnexpectedResult;
        const id = switch (object.get("id").?) {
            .integer => |value| @as(u64, @intCast(value)),
            else => return error.TestUnexpectedResult,
        };
        const sequence = switch (object.get("sequence").?) {
            .integer => |value| @as(u64, @intCast(value)),
            else => return error.TestUnexpectedResult,
        };
        const first = if (object.get("first")) |value| switch (value) {
            .integer => |number| @as(u64, @intCast(number)),
            else => return error.TestUnexpectedResult,
        } else 0;
        return .{ .ack = .{ .id = id, .first = first, .sequence = sequence } };
    }
    const stream = object.get("stream") orelse return error.TestUnexpectedResult;
    const name = switch (stream) {
        .string => |value| value,
        else => return error.TestUnexpectedResult,
    };
    if (std.mem.eql(u8, name, "snapshot")) return .snapshot;
    if (std.mem.eql(u8, name, "baseline")) return .baseline;
    const through = switch (object.get("through") orelse return error.TestUnexpectedResult) {
        .integer => |value| @as(u64, @intCast(value)),
        else => return error.TestUnexpectedResult,
    };
    return .{ .events = through };
}

fn ackReply(conn: *unix.Connection, a: std.mem.Allocator, id: u64, epoch: u64, first: u64, sequence: u64, through: u64, ok: bool) !void {
    const bytes = if (ok)
        try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"ack\":true,\"epoch\":{d},\"first\":{d},\"sequence\":{d},\"through\":{d}}}", .{ protocol.version, id, epoch, first, sequence, through })
    else
        try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":false,\"err\":\"invalid_input\",\"ack\":true}}", .{ protocol.version, id });
    defer a.free(bytes);
    try conn.writeFrame(bytes, .{ .io = testing.io, .timeout_ms = 2_000 });
}

fn readyPage(a: std.mem.Allocator, from: u64, through: u64, entries: []const u64, text: []const u8) ![]u8 {
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(1);
    try out.field("epoch", @as(u64, 5));
    try out.field("stream", "events");
    try out.field("from", from);
    try out.beginArray("events");
    for (entries) |sequence| {
        const element = try std.fmt.allocPrint(a, "{{\"t\":\"text\",\"v\":\"{s}\",\"seq\":{d}}}", .{ text, sequence });
        defer a.free(element);
        try out.element(element);
    }
    try out.endArray();
    try out.field("through", through);
    return out.finish();
}

const InitialDamage = enum { none, snapshot, identity, project, snapshot_epoch, baseline_epoch, baseline };

fn writePeerInitial(a: std.mem.Allocator, io: std.Io, stream: *unix.Connection, id: ids.Id, project: []const u8, owner: cli.WorkerOwner, epoch: u64, damage: InitialDamage) !void {
    const wait: unix.Wait = .{ .io = io, .timeout_ms = 4_000 };
    var snapshot = protocol.Out.init(a);
    defer snapshot.deinit();
    try snapshot.ok(1);
    try snapshot.field("stream", "snapshot");
    try snapshot.field("epoch", epoch);
    try snapshot.field("through", @as(u64, 0));
    if (damage == .snapshot) {
        // Identity and epoch are present, but required memory is absent.
        try snapshot.beginObject("snapshot");
        try snapshot.field("session", id[0..]);
        try snapshot.field("project", project);
        try snapshot.field("owner", @tagName(owner));
        try snapshot.field("epoch", epoch);
        try snapshot.endObject();
    } else {
        const snapshot_id: ids.Id = if (damage == .identity) "ffffffffffffffffffffffffffffffff".* else id;
        try protocol.encodeSnapshot(&snapshot, .{ .session = snapshot_id, .project = if (damage == .project) "/wrong-project" else project, .owner = switch (owner) {
            .foreground => .foreground,
            .daemon => .daemon,
        }, .epoch = if (damage == .snapshot_epoch) epoch + 1 else epoch, .attached = true });
    }
    const snapshot_bytes = try snapshot.finish();
    defer a.free(snapshot_bytes);
    try stream.writeFrame(snapshot_bytes, wait);
    var baseline = protocol.Out.init(a);
    defer baseline.deinit();
    try baseline.ok(1);
    try baseline.field("stream", "baseline");
    try baseline.field("epoch", if (damage == .baseline_epoch) epoch + 1 else epoch);
    try baseline.field("through", @as(u64, 0));
    try baseline.field("base", @as(u64, 0));
    try baseline.beginArray("entries");
    if (damage == .baseline) {
        try baseline.element("{\"t\":\"not-an-event\"}");
    } else {
        try baseline.element("{\"t\":\"text\",\"v\":\"initial history\"}");
    }
    try baseline.endArray();
    try baseline.field("truncated", false);
    const baseline_bytes = try baseline.finish();
    defer a.free(baseline_bytes);
    try stream.writeFrame(baseline_bytes, wait);
}

fn protocolVersionPeer(a: std.mem.Allocator, io: std.Io, listener: *unix.Listener, saw_v4: *std.atomic.Value(bool), id: ids.Id, project: []const u8) void {
    const wait: unix.Wait = .{ .io = io, .timeout_ms = 4_000 };
    for (0..3) |attempt| {
        var conn = listener.accept(wait) catch return;
        defer conn.close();
        const raw = (conn.readFrame(wait) catch return) orelse return;
        defer a.free(raw);
        var request = protocol.parseRequest(a, raw) catch return;
        defer request.deinit();
        if (request.op != .hello) return;
        saw_v4.store(true, .release);
        if (attempt == 1) continue; // Close the second greeting unanswered.
        const reply = if (attempt == 0)
            std.fmt.allocPrint(a, "{{\"v\":1,\"id\":{d},\"ok\":true,\"session\":\"{s}\",\"owner\":\"foreground\",\"pid\":1,\"protocol\":1,\"watch\":true}}", .{ request.id, id[0..] }) catch return
        else
            std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"session\":\"{s}\",\"owner\":\"foreground\",\"pid\":{d},\"protocol\":{d},\"watch\":true}}", .{ protocol.version, request.id, id[0..], std.c.getpid(), protocol.version }) catch return;
        defer a.free(reply);
        conn.writeFrame(reply, wait) catch return;
        if (attempt != 2) continue;
        // Compatible worker supplies a validated snapshot and baseline, then
        // stays alive until the adopted client closes its watch.
        const attach_raw = (conn.readFrame(wait) catch return) orelse return;
        defer a.free(attach_raw);
        var attach = protocol.parseRequest(a, attach_raw) catch return;
        defer attach.deinit();
        if (attach.op != .attach) return;
        const attached = std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"epoch\":7}}", .{ protocol.version, attach.id }) catch return;
        defer a.free(attached);
        conn.writeFrame(attached, wait) catch return;
        var stream = listener.accept(wait) catch return;
        defer stream.close();
        const watch_raw = (stream.readFrame(wait) catch return) orelse return;
        defer a.free(watch_raw);
        var watch = protocol.parseRequest(a, watch_raw) catch return;
        defer watch.deinit();
        writePeerInitial(a, io, &stream, id, project, .foreground, 7, .none) catch return;
        if (stream.readFrame(wait) catch return) |extra| a.free(extra);
    }
}

const SubmitFrame = struct { id: u64, req: u64 };

fn readSubmitFrame(pair: *Pair, a: std.mem.Allocator) !SubmitFrame {
    const frame = (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(frame);
    var request = try protocol.parseRequest(a, frame);
    defer request.deinit();
    return .{ .id = request.id, .req = try request.u64Field("req") };
}

fn connectClientWithControl(a: std.mem.Allocator) !Pair {
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(std.testing.io, &root_buf);
    const client = try Client.init(a, std.testing.io, null, .connect, root_buf[0..n], root_buf[0..n]);
    var fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&fds) != 0) {
        client.deinit();
        return error.SocketPairFailed;
    }
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    return .{ .client = client, .server = unix.Connection.init(a, fds[1], peer) };
}

fn readFrameJson(pair: *Pair, a: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const frame = (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(frame);
    return std.json.parseFromSlice(std.json.Value, a, frame, .{});
}

fn expectNoFrame(pair: *Pair) !void {
    try std.testing.expectError(error.Timeout, pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 }));
}

fn adoptTestSettings(client: *Client, json: []const u8) !void {
    var doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer doc.deinit();
    try client.adoptSettings(doc.value.object);
}

const HostSettingsView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    models: []const core_config.Model,
    official: []const bool,
    disabled: []const bool,
    providers: []const picker_module.Provider,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *HostSettingsView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.models = self.models;
        state.model_context_official = self.official;
        state.model_disabled = self.disabled;
        state.model_providers = self.providers;
        state.pending_default_effort = .medium;
        // Active protection and the global switch are different facts.
        state.low_price_input = true;
        state.low_price_input_enabled = false;
        return state;
    }
};

fn readJsonFrame(conn: *unix.Connection, a: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const frame = (try conn.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(frame);
    return std.json.parseFromSlice(std.json.Value, a, frame, .{});
}

fn expectNoFrameOn(conn: *unix.Connection) !void {
    try std.testing.expectError(error.Timeout, conn.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 }));
}

const AttachEnv = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    home: []u8,
    runtime: []u8,
    project: []u8,

    fn init(a: std.mem.Allocator) !AttachEnv {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const base = buf[0..n];
        const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
        errdefer a.free(home);
        const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
        errdefer a.free(runtime);
        const project = try std.fmt.allocPrint(a, "{s}/project", .{base});
        errdefer a.free(project);
        try tmp.dir.createDir(testing.io, "home", .fromMode(0o700));
        try tmp.dir.createDir(testing.io, "runtime", .fromMode(0o700));
        // A resumable history must be a real private checkpoint namespace:
        // 0700 sessions directory plus the `*` ignore marker.
        _ = try tmp.dir.createDirPathStatus(testing.io, "project/.thin/sessions", .fromMode(0o700));
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "project/.thin/sessions/.gitignore",
            .data = "*\n",
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("XDG_RUNTIME_DIR", runtime);
        return .{ .tmp = tmp, .env = env, .home = home, .runtime = runtime, .project = project };
    }

    fn deinit(self: *AttachEnv, a: std.mem.Allocator) void {
        self.env.deinit();
        a.free(self.home);
        a.free(self.runtime);
        a.free(self.project);
        self.tmp.cleanup();
    }
};

fn busyResumePeer(a: std.mem.Allocator, io: std.Io, listener: *unix.Listener, id: ids.Id) !void {
    const wait: unix.Wait = .{ .io = io, .timeout_ms = 4_000 };
    var conn = try listener.accept(wait);
    defer conn.close();
    const hello_raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(hello_raw);
    var hello = try protocol.parseRequest(a, hello_raw);
    defer hello.deinit();
    try testing.expectEqual(protocol.Op.hello, hello.op);
    const reply = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"session\":\"{s}\",\"owner\":\"daemon\",\"pid\":{d},\"protocol\":{d},\"watch\":true}}", .{ protocol.version, hello.id, id, std.c.getpid(), protocol.version });
    defer a.free(reply);
    try conn.writeFrame(reply, wait);
    const attach_raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(attach_raw);
    var attach = try protocol.parseRequest(a, attach_raw);
    defer attach.deinit();
    try testing.expectEqual(protocol.Op.attach, attach.op);
    try testing.expect(try attach.requiredBool("write"));
    try testing.expect(!try attach.requiredBool("takeover"));
    const busy = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":false,\"err\":\"busy\"}}", .{ protocol.version, attach.id });
    defer a.free(busy);
    try conn.writeFrame(busy, wait);
    if (try conn.readFrame(wait)) |extra| {
        a.free(extra);
        return error.TestUnexpectedResult;
    }
}

fn closeOnlyPeer(a: std.mem.Allocator, io: std.Io, listener: *unix.Listener, id: ids.Id) !void {
    const wait: unix.Wait = .{ .io = io, .timeout_ms = 4_000 };
    var conn = try listener.accept(wait);
    defer conn.close();
    const hello_raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(hello_raw);
    var hello = try protocol.parseRequest(a, hello_raw);
    defer hello.deinit();
    try testing.expectEqual(protocol.Op.hello, hello.op);
    const greeting = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"session\":\"{s}\",\"owner\":\"foreground\",\"pid\":{d},\"protocol\":{d},\"watch\":true}}", .{ protocol.version, hello.id, id, std.c.getpid(), protocol.version });
    defer a.free(greeting);
    try conn.writeFrame(greeting, wait);
    const attach_raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(attach_raw);
    var attach = try protocol.parseRequest(a, attach_raw);
    defer attach.deinit();
    try testing.expectEqual(protocol.Op.attach, attach.op);
    try testing.expect(!try attach.requiredBool("takeover"));
    const attached = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"epoch\":7}}", .{ protocol.version, attach.id });
    defer a.free(attached);
    try conn.writeFrame(attached, wait);
    const close_raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(close_raw);
    var close = try protocol.parseRequest(a, close_raw);
    defer close.deinit();
    try testing.expectEqual(protocol.Op.close, close.op);
    try testing.expectEqual(@as(u64, 7), try close.u64Field("epoch"));
    const reply = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"accepted\":true}}", .{ protocol.version, close.id });
    defer a.free(reply);
    try conn.writeFrame(reply, wait);
}

const CandidatePeerCase = enum { good, record_pid, hello_pid, owner, watch_gone, watch_eof, watch_reject, watch_timeout, snapshot, snapshot_identity, snapshot_project, snapshot_epoch, baseline_epoch, baseline };

fn candidatePeer(a: std.mem.Allocator, io: std.Io, listener: *unix.Listener, id: ids.Id, project: []const u8, owner: cli.WorkerOwner, behavior: CandidatePeerCase) !void {
    const wait: unix.Wait = .{ .io = io, .timeout_ms = 9_000 };
    var conn = try listener.accept(wait);
    defer conn.close();
    const hello_raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(hello_raw);
    var hello = try protocol.parseRequest(a, hello_raw);
    defer hello.deinit();
    try testing.expectEqual(protocol.Op.hello, hello.op);
    const actual_pid: u32 = @intCast(std.c.getpid());
    const advertised_pid = if (behavior == .hello_pid) actual_pid + 1 else actual_pid;
    const advertised_owner = if (behavior == .owner) (if (owner == .daemon) "foreground" else "daemon") else @tagName(owner);
    const reply = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"session\":\"{s}\",\"owner\":\"{s}\",\"pid\":{d},\"protocol\":{d},\"watch\":true}}", .{ protocol.version, hello.id, id, advertised_owner, advertised_pid, protocol.version });
    defer a.free(reply);
    try conn.writeFrame(reply, wait);
    if (behavior == .record_pid or behavior == .hello_pid or behavior == .owner) {
        if (try conn.readFrame(wait)) |unexpected| {
            a.free(unexpected);
            return error.TestUnexpectedResult;
        }
        return;
    }
    const attach_raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(attach_raw);
    var attach = try protocol.parseRequest(a, attach_raw);
    defer attach.deinit();
    try testing.expectEqual(protocol.Op.attach, attach.op);
    try testing.expect(try attach.requiredBool("write"));
    try testing.expect(!try attach.requiredBool("takeover"));
    if (behavior == .watch_gone) try testing.expectEqual(@as(c_int, 0), std.c.unlinkat(listener.dir_fd, listener.name_z, 0));
    const attached = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"epoch\":7}}", .{ protocol.version, attach.id });
    defer a.free(attached);
    try conn.writeFrame(attached, wait);
    if (behavior == .watch_gone) {
        if (try conn.readFrame(wait)) |unexpected| {
            a.free(unexpected);
            return error.TestUnexpectedResult;
        }
        return;
    }
    var stream = try listener.accept(wait);
    defer stream.close();
    const watch_raw = (try stream.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(watch_raw);
    var watch = try protocol.parseRequest(a, watch_raw);
    defer watch.deinit();
    try testing.expectEqual(protocol.Op.watch, watch.op);
    try testing.expectEqual(@as(u64, 7), try watch.u64Field("epoch"));
    switch (behavior) {
        .watch_eof => stream.close(),
        .watch_reject => try stream.writeFrame("{\"v\":4,\"id\":1,\"ok\":false,\"err\":\"unavailable\"}", wait),
        .watch_timeout => {},
        else => try writePeerInitial(a, io, &stream, id, project, owner, 7, switch (behavior) {
            .snapshot => .snapshot,
            .snapshot_identity => .identity,
            .snapshot_project => .project,
            .snapshot_epoch => .snapshot_epoch,
            .baseline_epoch => .baseline_epoch,
            .baseline => .baseline,
            else => .none,
        }),
    }
    if (behavior == .good) {
        if (try stream.readFrame(wait)) |unexpected| {
            a.free(unexpected);
            return error.TestUnexpectedResult;
        }
    } else if (try conn.readFrame(wait)) |unexpected| {
        a.free(unexpected);
        return error.TestUnexpectedResult;
    }
}

fn checkpointFor(fixture: *AttachEnv, id: ids.Id) !void {
    var name: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&name, "project/.thin/sessions/{s}.session", .{id});
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "complete checkpoint" });
}

fn registryOwnerPeer(a: std.mem.Allocator, io: std.Io, listener: *unix.Listener, id: ids.Id, stop: *p.Cancellation, contacted: *std.atomic.Value(bool)) !void {
    const wait: unix.Wait = .{ .io = io, .timeout_ms = 9_000, .cancel = stop };
    var conn = listener.accept(wait) catch |err| switch (err) {
        error.Canceled => return,
        else => return err,
    };
    defer conn.close();
    contacted.store(true, .release);
    const raw = (try conn.readFrame(wait)) orelse return;
    defer a.free(raw);
    var hello = try protocol.parseRequest(a, raw);
    defer hello.deinit();
    try testing.expectEqual(protocol.Op.hello, hello.op);
    const reply = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,\"session\":\"{s}\",\"owner\":\"daemon\",\"pid\":{d},\"protocol\":{d},\"watch\":true}}", .{ protocol.version, hello.id, id, std.c.getpid(), protocol.version });
    defer a.free(reply);
    try conn.writeFrame(reply, wait);
}

fn createResumePeer(a: std.mem.Allocator, io: std.Io, conn: *unix.Connection, id: ids.Id, project: []const u8, endpoint: []const u8) !void {
    const wait: unix.Wait = .{ .io = io, .timeout_ms = 9_000 };
    const raw = (try conn.readFrame(wait)) orelse return error.TestUnexpectedResult;
    defer a.free(raw);
    var request = try protocol.parseRequest(a, raw);
    defer request.deinit();
    try testing.expectEqual(protocol.Op.create, request.op);
    try testing.expectEqualStrings(project, try request.stringField("project", 4096));
    try testing.expectEqualStrings(&id, try request.stringField("resume", 32));
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(request.id);
    try out.field("endpoint", endpoint);
    try out.field("session", id[0..]);
    const bytes = try out.finish();
    defer a.free(bytes);
    try conn.writeFrame(bytes, wait);
}
