const NotificationTestFixture = struct {
    tmp: std.testing.TmpDir,
    queue: *notifications.Queue,
    owner: *Coordinator,

    fn init(io: std.Io) !@This() {
        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path: [4096]u8 = undefined;
        var root = try fs.Root.open(a, io, path[0..try tmp.dir.realPath(io, &path)]);
        defer root.deinit();
        var config = try cfg.clone(a, .{
            .provider = .{ .base_url = "http://fixture.invalid", .api_key = "fixture-key" },
            .selected_provider = "local",
            .model = .{ .name = "fixture", .protocol = .chat, .context_tokens = 32768, .output_tokens = 8192 },
            .limits = .{ .low_price_input = false },
        });
        defer cfg.release(&config);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        const queue = try notifications.Queue.create(a);
        errdefer queue.deinit();
        const owner = try Coordinator.create(a, io, &root, config.value, &env);
        owner.bindNotifications(queue);
        return .{ .tmp = tmp, .queue = queue, .owner = owner };
    }

    fn deinit(self: *@This()) void {
        self.owner.deinit();
        self.queue.deinit();
        self.tmp.cleanup();
    }

    fn enqueue(owner: *Coordinator, text: []const u8) !u64 {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var capture: k.Capture = .{ .allocator = arena.allocator() };
        capture.add(.user, text);
        return owner.enqueueCopy(&capture, .chat, .{});
    }

    fn waitBool(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
        const start = std.Io.Clock.awake.now(io);
        while (!flag.load(.acquire)) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.TestTimeout;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }

    fn waitGate(io: std.Io, flag: *const std.atomic.Value(u8)) !void {
        const start = std.Io.Clock.awake.now(io);
        while (flag.load(.acquire) == 0) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 2000) return error.TestTimeout;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
    }
};
