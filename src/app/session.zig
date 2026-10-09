//! 交互会话的应用层所有者：允许先显示 TUI，再通过本地授权配置创建 App。
//! TUI 只看 Connection 回调，不持有配置文件或凭证存储逻辑。

const std = @import("std");
const cfg = @import("../core/config.zig");
const r = @import("../core/runtime.zig");
const App = @import("app.zig").App;
const Store = @import("auth_store.zig").Store;
const tui = @import("../ui/tui.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    project: []const u8,
    host: r.Host,
    trusted: bool,
    logging: bool = true,
    store: Store,
    pending: ?std.json.Parsed(cfg.Config) = null,
    app: ?*App = null,

    /// 只做本地初始化；缺少凭证时保持 pending，不发起试探请求。
    pub fn init(a: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, project: []const u8, host: r.Host, trusted: bool) !Session {
        const home = environ.get("HOME") orelse return error.MissingHome;
        var self: Session = .{
            .allocator = a,
            .io = io,
            .environ = environ,
            .project = project,
            .host = host,
            .trusted = trusted,
            .store = try Store.open(a, io, home),
        };
        errdefer self.deinit();
        self.pending = try self.store.loadOrInitialize();

        const key = cfg.resolveApiKey(a, self.pending.?.value, environ) catch |err| {
            if (err == error.ApiKeyNotFound) return self;
            return err;
        };
        defer {
            std.crypto.secureZero(u8, key);
            a.free(key);
        }
        const parsed = self.pending.?;
        self.pending = null;
        self.app = try App.initConfigured(a, io, environ, project, host, trusted, parsed);
        return self;
    }

    /// 必须等 TUI 取消并 join worker 后再释放；Connection 不得比 Session 活得更久。
    pub fn deinit(self: *Session) void {
        if (self.app) |app| app.deinit();
        if (self.pending) |*pending| cfg.release(pending);
        self.store.deinit();
        self.* = undefined;
    }

    /// main 在进入 TUI 前设置，也应用于之后 /auth 创建的候选 App。
    pub fn setLogging(self: *Session, enabled: bool) void {
        self.logging = enabled;
        if (self.app) |app| app.setLogging(enabled);
    }

    pub fn connection(self: *Session) tui.Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure };
    }

    fn current(raw: *anyopaque) tui.Connection.State {
        const self: *Session = @ptrCast(@alignCast(raw));
        const config = if (self.app) |app| app.config.value else self.pending.?.value;
        return .{
            .runtime = if (self.app) |app| &app.runtime else null,
            .model = config.model.name,
            .base_url = config.provider.base_url,
            .logging_enabled = self.logging,
            .log_error = if (self.app) |app| app.journal.failure() else null,
        };
    }

    fn configure(raw: *anyopaque, key: []const u8) !void {
        const self: *Session = @ptrCast(@alignCast(raw));
        if (self.app != null) return error.AlreadyConfigured;
        var next = self.pending.?.value;
        next.provider.api_key_env = "";
        next.provider.api_key = key;
        try cfg.validate(next);

        // 候选配置拥有独立字符串；借用的按键缓冲区在回调返回后会被 TUI 擦除。
        // 固定容量避免增长时释放含密钥的旧缓冲区；退出时擦除整块分配。
        const encoded = try self.allocator.alloc(u8, cfg.max_config_bytes);
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        var writer = std.Io.Writer.fixed(encoded);
        std.json.Stringify.value(next, .{}, &writer) catch return error.ConfigTooLarge;
        const owned = try cfg.parse(self.allocator, encoded[0..writer.end]);
        const candidate = try App.initConfigured(self.allocator, self.io, self.environ, self.project, self.host, self.trusted, owned);
        errdefer candidate.deinit();
        candidate.setLogging(self.logging);

        // 先完成本地对象构建和落盘，再发布 ready。保存失败不激活半配置会话。
        try self.store.save(candidate.config.value);
        if (self.pending) |*pending| cfg.release(pending);
        self.pending = null;
        self.app = candidate;
    }
};

// 全部使用临时 HOME/项目与假密钥；仅构造 HTTP 客户端，绝不调用它。
test "pending session activates locally without a request and protects auth from tools" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buffer);
    const home = path_buffer[0..path_len];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, io, &env, home, .{}, false);
    defer session.deinit();
    const connection = session.connection();
    try std.testing.expect(connection.current().runtime == null);
    try connection.configure("fake-inline-session-key");
    try std.testing.expect(connection.current().runtime != null);
    try std.testing.expect(std.mem.find(u8, session.app.?.runtime.system, "fake-inline-session-key") == null);
    try std.testing.expectEqual(@as(usize, 0), session.app.?.runtime.messages().len);
    try std.testing.expectError(error.AlreadyConfigured, connection.configure("replacement"));

    // 重开会话可使用已保存的内联凭证；仍然不发送网络请求。
    var reopened = try Session.init(a, io, &env, home, .{}, false);
    defer reopened.deinit();
    try std.testing.expect(reopened.connection().current().runtime != null);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const call: @import("../core/protocol.zig").ToolCall = .{
        .id = "read-auth",
        .name = "read_file",
        .arguments = "{\"path\":\".thin/config.json\"}",
    };
    const executor = session.app.?.executor.executor();
    try std.testing.expectError(error.ProtectedAuthFile, executor.prepare_fn(executor.context, arena.allocator(), call));
    const aliases = [_][]const u8{ ".thin//./config.json", session.app.?.auth_path };
    for (aliases) |path| {
        var cancel = @import("../core/protocol.zig").Cancellation{};
        try std.testing.expectError(error.ProtectedAuthFile, session.app.?.executor.execute(arena.allocator(), .{ .read_file = .{ .path = path } }, &cancel));
        try std.testing.expectError(error.ProtectedAuthFile, session.app.?.executor.execute(arena.allocator(), .{ .write_file = .{ .path = path, .content = "no", .overwrite = true } }, &cancel));
    }
}

test "configuration conflict does not publish an app" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buffer);
    const home = path_buffer[0..path_len];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.init(a, io, &env, home, .{}, false);
    defer session.deinit();
    // 模拟用户在 TUI 输入期间从另一进程修改配置；不得被保存动作覆盖。
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = "changed externally" });
    if (session.connection().configure("fake-key")) |_| {
        return error.ExpectedConflict;
    } else |_| {}
    try std.testing.expect(session.connection().current().runtime == null);
    const bytes = try tmp.dir.readFileAlloc(io, ".thin/config.json", a, .limited(1024));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("changed externally", bytes);
}
