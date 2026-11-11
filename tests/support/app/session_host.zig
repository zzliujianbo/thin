const App = @import("app.zig").App;

const session_client = @import("../ui/session_client.zig");

const JobKind = std.meta.FieldType(task.Job, .kind);

fn dispatchJson(host: *SessionHost, a: std.mem.Allocator, json: []const u8, connection: u64) ![]u8 {
    var request = try protocol.parseRequest(a, json);
    defer request.deinit();
    return host.dispatch(a, &request, connection, true);
}

const ThinkingTaskFixture = struct {
    io: std.Io,
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(u32) = .init(0),
    old_after_release: std.atomic.Value(bool) = .init(false),
    second_new: std.atomic.Value(bool) = .init(false),
    read_ok: std.atomic.Value(bool) = .init(false),

    fn call(raw: *anyopaque, _: std.mem.Allocator, req: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *ThinkingTaskFixture = @ptrCast(@alignCast(raw));
        const count = self.calls.fetchAdd(1, .acq_rel);
        if (req.purpose != .normal) return error.UnexpectedModelRound;
        if (count == 0) {
            if (!std.mem.eql(u8, req.reasoning_effort orelse "", "low")) return error.WrongFirstEffort;
            self.entered.store(true, .release);
            const start = std.Io.Clock.awake.now(self.io);
            while (!self.release.load(.acquire)) {
                if (start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() > 5000) return error.TestTimeout;
                if (req.cancellation) |cancel| if (cancel.isRequested()) return error.Canceled;
                std.atomic.spinLoopHint();
            }
            self.old_after_release.store(std.mem.eql(u8, req.reasoning_effort orelse "", "low"), .release);
            return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "read-1", .name = "read_file", .arguments = "{\"path\":\"thinking-fixture.txt\"}" } }} }, .finish = .tool_calls } };
        }
        if (count != 1) return error.UnexpectedModelRound;
        self.second_new.store(std.mem.eql(u8, req.reasoning_effort orelse "", "high"), .release);
        for (req.messages) |message| for (message.blocks) |block| {
            if (block == .tool_result and std.mem.eql(u8, block.tool_result.call_id, "read-1")) {
                self.read_ok.store(!block.tool_result.is_error and std.mem.indexOf(u8, block.tool_result.text, "owned fixture") != null, .release);
            }
        };
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} }, .finish = .stop } };
    }
};

fn waitThinkingFlag(host: *SessionHost, flag: *std.atomic.Value(bool), pump: bool) !void {
    const start = std.Io.Clock.awake.now(host.io);
    while (!flag.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(host.io)).toMilliseconds() > 5000) return error.TestTimeout;
        if (pump) host.pump(0);
        std.atomic.spinLoopHint();
    }
}

const MemoryQueueFixture = struct {
    values: []const @import("../core/memory_status.zig").Terminal,
    cursor: usize = 0,

    fn peekMemoryCompletion(self: *MemoryQueueFixture) ?@import("../core/memory_status.zig").Terminal {
        return if (self.cursor < self.values.len) self.values[self.cursor] else null;
    }
    fn takeMemoryCompletion(self: *MemoryQueueFixture) ?@import("../core/memory_status.zig").Terminal {
        const value = self.peekMemoryCompletion() orelse return null;
        self.cursor += 1;
        return value;
    }
};

const BackgroundFixture = struct {
    first: background_status.Terminal,
    second: background_status.Terminal,
    taken: ?background_status.Id = null,
    first_pending: bool = true,
    second_pending: bool = true,
    switch_on_peek: bool = false,
    second_is_head: bool = false,
    head_at_take_was_second: bool = false,

    fn peekBackgroundCompletion(self: *BackgroundFixture) ?background_status.Terminal {
        if (self.second_is_head and self.second_pending) return self.second;
        if (self.first_pending) {
            const terminal = self.first;
            // The next job completes after this peek has selected its result.
            if (self.switch_on_peek) self.second_is_head = true;
            return terminal;
        }
        return if (self.second_pending) self.second else null;
    }
    fn takeBackgroundCompletion(self: *BackgroundFixture, id: background_status.Id) void {
        self.head_at_take_was_second = self.second_is_head and self.second_pending;
        self.taken = id;
        if (std.mem.eql(u8, id.slice(), self.first.id.slice())) {
            self.first_pending = false;
        } else if (std.mem.eql(u8, id.slice(), self.second.id.slice())) {
            self.second_pending = false;
        }
    }
};

const MetadataOwnerIdleSpy = struct {
    count: usize = 0,
    values: [3]bool = @splat(false),

    fn poll(context: *anyopaque, idle: bool) bool {
        const self: *MetadataOwnerIdleSpy = @ptrCast(@alignCast(context));
        if (self.count < self.values.len) self.values[self.count] = idle;
        self.count += 1;
        return idle;
    }
};

fn parseJson(a: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, frame, .{ .allocate = .alloc_always });
}

fn snapshotRevision(a: std.mem.Allocator, frame: []const u8) !u64 {
    // The reply root is `{v,id,ok,snapshot:{...}}`; the queue revision lives in
    // the nested snapshot object. Parse the whole frame strictly so a malformed
    // or duplicated field fails the assertion instead of being guessed.
    var parsed = std.json.parseFromSlice(std.json.Value, a, frame, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidSnapshot;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidSnapshot,
    };
    switch (root.get("ok") orelse return error.InvalidSnapshot) {
        .bool => |ok| if (!ok) return error.InvalidSnapshot,
        else => return error.InvalidSnapshot,
    }
    const snapshot = switch (root.get("snapshot") orelse return error.InvalidSnapshot) {
        .object => |object| object,
        else => return error.InvalidSnapshot,
    };
    const revision = switch (snapshot.get("queue_revision") orelse return error.InvalidSnapshot) {
        .integer => |value| value,
        else => return error.InvalidSnapshot,
    };
    if (revision < 0) return error.InvalidSnapshot;
    return @intCast(revision);
}

const FakeLimitsView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    limits: cfg.Limits,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *FakeLimitsView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.limits = self.limits;
        return state;
    }
};

const SettingSink = struct {
    calls: usize = 0,
    last_key: ?tui.Connection.Setting = null,
    last_value: bool = false,

    fn set(context: *anyopaque, key: tui.Connection.Setting, enabled: bool) anyerror!void {
        const self: *SettingSink = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last_key = key;
        self.last_value = enabled;
    }
};

fn settingsFieldIs(frame: []const u8, name: []const u8, value: u64) !bool {
    var buf: [96]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "\"{s}\":{d},", .{ name, value });
    return std.mem.indexOf(u8, frame, needle) != null;
}

const ProxySink = struct {
    calls: usize = 0,
    name_len: usize = 0,
    name: [128]u8 = undefined,
    last_enabled: bool = false,

    fn set(context: *anyopaque, name: []const u8, enabled: bool) anyerror!void {
        const self: *ProxySink = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.name_len = @min(name.len, self.name.len);
        @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
        self.last_enabled = enabled;
    }

    fn recorded(self: *const ProxySink) []const u8 {
        return self.name[0..self.name_len];
    }
};

const FakeProxyView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    configured: bool,
    names: []const []const u8,
    address: ?[]const u8 = null,
    port: u16 = 0,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *FakeProxyView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.proxy_configured = self.configured;
        state.proxy_models = self.names;
        state.proxy_address = self.address;
        state.proxy_port = self.port;
        return state;
    }
};

const ProxyAddressSink = struct {
    calls: usize = 0,
    len: usize = 0,
    value: [cfg.max_proxy_endpoint_bytes]u8 = undefined,
    fail: bool = false,

    fn set(context: *anyopaque, value: []const u8) anyerror!void {
        const self: *ProxyAddressSink = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.len = @min(value.len, self.value.len);
        @memcpy(self.value[0..self.len], value[0..self.len]);
        if (self.fail) return error.InvalidProxyEndpoint;
    }

    fn recorded(self: *const ProxyAddressSink) []const u8 {
        return self.value[0..self.len];
    }
};

const ProxyViewSink = struct {
    view: FakeProxyView,
    sink: *ProxyAddressSink,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *ProxyViewSink = @ptrCast(@alignCast(context));
        return FakeProxyView.current(@ptrCast(&self.view));
    }

    fn set(context: *anyopaque, value: []const u8) anyerror!void {
        const self: *ProxyViewSink = @ptrCast(@alignCast(context));
        return ProxyAddressSink.set(self.sink, value);
    }
};

const FakeCatalogView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    models: []const cfg.Model,
    providers: []const tui.ModelProvider,
    levels: activity.EffortSet,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *FakeCatalogView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.models = self.models;
        state.decision_models = self.models;
        state.image_models = self.models;
        state.model_providers = self.providers;
        state.effort_levels = self.levels;
        return state;
    }
};

fn parseWholeReply(a: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, frame, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}
