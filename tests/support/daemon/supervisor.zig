const c = std.c;

fn testWait() unix.Wait {
    return .{ .io = std.testing.io, .timeout_ms = 5_000 };
}

fn controlRoundTrip(supervisor: *Supervisor, client: *unix.Connection, frame: []const u8) ![]u8 {
    const wait = testWait();
    const start = std.Io.Clock.awake.now(wait.io);
    try client.writeFrame(frame, wait);
    while (true) {
        if (start.untilNow(wait.io, .awake).toMilliseconds() >= wait.timeout_ms) return error.Timeout;
        supervisor.serveTick();
        const remaining = @as(i64, wait.timeout_ms) - start.untilNow(wait.io, .awake).toMilliseconds();
        if (remaining <= 0) return error.Timeout;
        const reply = client.readFrame(.{ .io = wait.io, .timeout_ms = @intCast(@min(remaining, 10)) }) catch |err| switch (err) {
            error.Timeout, error.Interrupted => continue,
            else => return err,
        };
        return reply orelse error.ConnectionClosed;
    }
}

fn setupOpFrame(allocator: std.mem.Allocator, id: u64, op: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"v\":{d},\"id\":{d},\"op\":\"{s}\"{s}}}", .{ protocol.version, id, op, body });
}

const TestRig = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    reg: registry.Registry,
    workers: spawn.Workers,
    lock: unix.Lock,
    listener: unix.Listener,
    supervisor: Supervisor,
    base: []u8,
    home: []u8,
    runtime: []u8,
    project: []u8,
    elsewhere: []u8,

    fn create(a: std.mem.Allocator, io: std.Io) !*TestRig {
        const rig = try a.create(TestRig);
        errdefer a.destroy(rig);
        rig.* = undefined;
        rig.tmp = std.testing.tmpDir(.{});
        errdefer rig.tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try rig.tmp.dir.realPath(io, &path_buf);
        rig.base = try a.dupe(u8, path_buf[0..n]);
        errdefer a.free(rig.base);
        try rig.tmp.dir.createDir(io, "home", .default_dir);
        try rig.tmp.dir.createDir(io, "runtime", .fromMode(0o700));
        try rig.tmp.dir.createDir(io, "project", .default_dir);
        try rig.tmp.dir.createDir(io, "elsewhere", .default_dir);
        rig.home = try std.fmt.allocPrint(a, "{s}/home", .{rig.base});
        errdefer a.free(rig.home);
        rig.runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{rig.base});
        errdefer a.free(rig.runtime);
        rig.project = try std.fmt.allocPrint(a, "{s}/project", .{rig.base});
        errdefer a.free(rig.project);
        rig.elsewhere = try std.fmt.allocPrint(a, "{s}/elsewhere", .{rig.base});
        errdefer a.free(rig.elsewhere);

        rig.env = std.process.Environ.Map.init(a);
        errdefer rig.env.deinit();
        try rig.env.put("HOME", rig.home);
        try rig.env.put("XDG_RUNTIME_DIR", rig.runtime);

        rig.reg = try registry.Registry.init(a, io, &rig.env);
        errdefer rig.reg.deinit();
        rig.workers = try spawn.Workers.init(a, io, &rig.env);
        errdefer rig.workers.deinit();
        rig.lock = try unix.Lock.acquire(a, rig.reg.runtimeDirectory(), daemon_lock);
        errdefer rig.lock.release();
        rig.listener = try unix.Listener.bind(a, rig.reg.runtimeDirectory(), daemon_socket, .{ .lock = &rig.lock });
        errdefer rig.listener.deinit();
        rig.supervisor = Supervisor{
            .allocator = a,
            .io = io,
            .environ = &rig.env,
            .registry = &rig.reg,
            .workers = &rig.workers,
            .listener = &rig.listener,
            .auto_refresh_models = false,
        };
        return rig;
    }

    fn deinit(self: *TestRig, a: std.mem.Allocator) void {
        self.supervisor.deinit();
        self.listener.deinit();
        self.lock.release();
        self.workers.deinit();
        self.reg.deinit();
        self.env.deinit();
        a.free(self.home);
        a.free(self.runtime);
        a.free(self.project);
        a.free(self.elsewhere);
        a.free(self.base);
        self.tmp.cleanup();
        a.destroy(self);
    }

    fn connect(self: *TestRig, a: std.mem.Allocator) !unix.Connection {
        const me: u32 = @intCast(c.geteuid());
        return unix.connect(a, self.listener.socketPath(), me, testWait());
    }
};

fn publishTestRecord(a: std.mem.Allocator, reg: *registry.Registry, id: ids.Id, project: []const u8, instance: []const u8) ![]u8 {
    const endpoint = try std.fmt.allocPrint(a, "{s}/workers/{s}.sock", .{ reg.runtimeDirectory().path, instance });
    errdefer a.free(endpoint);
    try reg.register(.{
        .id = id,
        .project = project,
        .endpoint = endpoint,
        .owner = .daemon,
        .owner_instance = instance,
        .state = "running",
        .pid = 4242,
        .generation = 1,
    });
    return endpoint;
}

fn writeTestCheckpoint(a: std.mem.Allocator, io: std.Io, project: []const u8, id: ids.Id) !void {
    try writeTestSessionsFile(a, io, project, id, ".session");
}

fn writeTestDiagnostic(a: std.mem.Allocator, io: std.Io, project: []const u8, id: ids.Id) !void {
    try writeTestSessionsFile(a, io, project, id, ".log");
}

fn writeTestSessionsFile(a: std.mem.Allocator, io: std.Io, project: []const u8, id: ids.Id, suffix: []const u8) !void {
    var root = try fs.Root.open(a, io, project);
    defer root.deinit();
    const dir = try logs.openCheckpointDirectory(&root);
    defer fs.closeFd(dir);
    var buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buffer, "{s}{s}", .{ id, suffix }, 0);
    const fd = fs.openAt(dir, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    if (fd < 0) return fs.osError();
    defer fs.closeFd(fd);
    try fs.fileFromFd(fd).writePositionalAll(io, "{}", 0);
}

fn ownedCreated(a: std.mem.Allocator, project: []const u8, id: ids.Id, endpoint: []const u8) !Created {
    const project_copy = try a.dupe(u8, project);
    errdefer a.free(project_copy);
    return .{ .id = id, .project = project_copy, .endpoint = try a.dupe(u8, endpoint) };
}
