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

extern "c" fn mkfifoat(c_int, [*:0]const u8, c.mode_t) c_int;

fn expectResolveError(registry: *Registry, id: ids.Id, project: []const u8, expected: anyerror) !void {
    try testing.expectError(expected, registry.resolve(testing.allocator, id, project));
    try testing.expectError(expected, registry.resolve(testing.allocator, id, null));
}

fn resolveAllocationCase(a: std.mem.Allocator, registry: *Registry, id: ids.Id, project: ?[]const u8) !void {
    var record = (try registry.resolve(a, id, project)) orelse return error.TestUnexpectedResult;
    defer freeRecord(a, &record);
}

fn ambiguousAllocationCase(a: std.mem.Allocator, registry: *Registry, id: ids.Id) !void {
    if (registry.resolve(a, id, null)) |maybe| {
        if (maybe) |value| {
            var record = value;
            freeRecord(a, &record);
        }
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.AmbiguousSession => {},
        else => return err,
    }
}

fn listAllocationCase(a: std.mem.Allocator, registry: *Registry) !void {
    const page = try registry.list(a, false, 0);
    defer freeRecords(a, page);
    try testing.expectEqual(@as(usize, 1), page.len);
}

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

fn probeFromReply(a: std.mem.Allocator, bytes: []const u8) !Probe {
    var frame = try parseTestFrame(a, bytes, 2);
    defer frame.deinit();
    var probe: Probe = .{ .live = true, .pid = 4242, .state = .unknown };
    applySnapshotProbe(&probe, frame.root);
    return probe;
}
