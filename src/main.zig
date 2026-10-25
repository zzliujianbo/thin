//! thin 程序入口：解析命令行，保留 --print 一次性模式；其它所有模式（前台交互、守护服务、
//! 连接、attach 与内部 worker）最终交给 daemon 入口的 run 处理。

const std = @import("std");
const cli = @import("app/cli.zig");
const App = @import("app/app.zig").App;
const Session = @import("app/session.zig").Session;
const Console = @import("app/console.zig").Console;
const p = @import("core/protocol.zig");
const interrupt = @import("platform/interrupt.zig");
const task = @import("core/task.zig");
const daemon = @import("daemon/entry.zig");
const ssh = @import("daemon/ssh.zig");
const text = @import("ui/text.zig");

/// 进程入口：返回值即退出码。出错时打印错误信息并返回 1；被信号中断时返回 128 + 信号号。
pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        // The output itself may be backpressured. Do not try to report an
        // interrupt by writing another message to the same blocked terminal.
        if (err == error.Canceled and interrupt.signal() != 0) return 128 + interrupt.signal();
        var buffer: [512]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "thin: {s}\nCheck ~/.thin/config.json, the configured key source, or --help. For first-time setup, run thin interactively and use /login.\n", .{@errorName(err)}) catch "thin: application error\n";
        output(init.io, .stderr(), message) catch {};
        return 1;
    };
}

/// 把 bytes 写入 file，但在独立的并发任务中执行阻塞写。主线程轮询中断信号，
/// 以便终端背压时仍能响应 Ctrl+C 而不被卡死。
pub fn output(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    // 写任务的状态与借用的 bytes 都位于调用者栈上，因此必须等待任务结束后才能返回。
    const Write = struct {
        io: std.Io,
        file: std.Io.File,
        bytes: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        // 在工作线程中运行：无论成功或失败，都通过 release 语义发布 done 标志。
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            var buffer: [4096]u8 = undefined;
            var writer = self.file.writer(self.io, &buffer);
            writer.interface.writeAll(self.bytes) catch |err| {
                self.failure = err;
                return;
            };
            writer.interface.flush() catch |err| {
                self.failure = err;
            };
        }
    };

    // 若在写入开始前已收到中断信号，直接放弃，避免向终端写入残缺内容。
    if (interrupt.signal() != 0) return error.Canceled;
    var write = Write{ .io = io, .file = file, .bytes = bytes };
    var future = try std.Io.concurrent(io, Write.run, .{&write});
    // Also joins on errors/cancellation before borrowed bytes or stack go away.
    defer future.cancel(io);

    // 以 5ms 为间隔轮询完成标志与中断信号，兼顾响应速度与 CPU 占用。
    while (!write.done.load(.acquire)) {
        if (interrupt.signal() != 0) return error.Canceled;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }

    future.await(io);
    if (interrupt.signal() != 0) return error.Canceled;
    if (write.failure) |err| return err;
}

/// 留档失败不改变任务成败或重试工具；用独立诊断提示缺失记录。
pub fn reportLogFailure(io: std.Io, app: *App) void {
    // 生产者已 join；收尾也可能发现最后一条记录的写入失败。
    app.journal.finish();
    const err = app.journal.failure() orelse return;
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "thin: session recording disabled: {s}. Records in .thin/sessions may be incomplete.\n", .{@errorName(err)}) catch return;
    output(io, .stderr(), message) catch {};
}

/// 主流程：解析参数，处理 --help/--version；--print 在本文件完成，其余模式交给 daemon 入口。
fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try cli.parse(args);
    if (options.help) {
        try output(init.io, .stdout(), cli.help);
        return 0;
    }
    if (options.version) {
        try output(init.io, .stdout(), @import("app/version.zig").text ++ "\n");
        return 0;
    }

    if (options.ssh_owner) |owner| try ssh.initializeConnection(init.gpa, init.environ_map, owner);
    defer if (options.ssh_owner != null) ssh.close();

    // 只有前台/connect/attach 需要真正的终端；daemon 与内部 worker 必须能在无 TTY 下运行。
    // 管道或重定向场景仍必须使用 --print。
    if (requiresInteractiveTty(options) and (std.c.isatty(0) != 1 or std.c.isatty(1) != 1)) return error.TtyRequiredUsePrint;
    try text.initLocale(); // Before application I/O or worker threads.

    var cancellation = p.Cancellation{};
    if (options.prompt) |prompt| {
        // --print 分支：单次任务，只输出最终已提交的回答。
        var console = Console{ .allocator = init.gpa };
        defer console.deinit();
        const app = try App.init(init.gpa, init.io, init.environ_map, ".", console.host());
        defer app.deinit();
        app.setLogging(options.logging);

        var guard = try interrupt.Guard.install();
        defer guard.deinit();

        var job = task.Job{ .runtime = &app.runtime, .cancel = &cancellation, .prompt = prompt };
        var future = try std.Io.concurrent(init.io, task.Job.run, .{&job});
        // 退出时先取消任务再等待其结束，确保 worker 不会在 app/console 释放后仍访问它们。
        defer {
            cancellation.cancel();
            future.await(init.io);
        }

        // 轮询等待任务完成，并把中断信号转换为取消请求。
        while (!job.done.load(.acquire)) {
            if (interrupt.signal() != 0) cancellation.cancel();
            try std.Io.sleep(init.io, .fromMilliseconds(5), .awake);
        }
        future.await(init.io);

        reportLogFailure(init.io, app);
        const terminal = try job.result();

        if (terminal.status == .success) {
            // 辅助 Memory 阶段收到的 SIGINT 已被 finalize 消费为辅助取消，必须先消费掉它才能输出冻结的主结果。
            if (interrupt.signal() == @backingInt(std.c.SIG.INT) and
                app.memory_coordinator.failure.load(.acquire) == @intFromError(error.Canceled)) interrupt.clear();
            // 提示信息走 stderr，保证 stdout 只包含模型的回答内容。
            if (console.fallback) try output(init.io, .stderr(), "thin: Responses explicitly unsupported; using Chat for this process.\n");
            if (console.denied > 0) try output(init.io, .stderr(), "thin: tool calls were denied by the host.\n");

            // 对回答做清洗并限制为 256 KiB，与 Console 中的截断上限保持一致。
            const safe = try text.sanitize(init.gpa, console.answer.items, 256 * 1024);
            defer init.gpa.free(safe);
            try output(init.io, .stdout(), safe);
            if (console.clipped) try output(init.io, .stdout(), "\n[display clipped; model history unchanged]");
            try output(init.io, .stdout(), "\n");
            if (app.memory_coordinator.failure.load(.acquire) != 0) {
                try output(init.io, .stderr(), "thin: auxiliary Memory finalization did not succeed; no automatic replay will occur.\n");
            }
            // 辅助 Memory 取消只影响辅助状态，不改写已完成主任务的成功退出码。
            return 0;
        }

        // 失败或取消时，把终止状态、错误名与模型失败类型拼成一行写入 stderr。
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.writeAll("thin: ");
        try @import("presentation.zig").failure.write(&writer, @tagName(terminal.status), terminal.detail, terminal.model_failure, terminal.http_status);
        try writer.writeByte('\n');
        const message = writer.buffered();

        // 退出码约定：收到信号时为 128+信号号；否则取消为 130，其他失败为 1。
        const code: u8 = if (terminal.status == .canceled) (if (interrupt.signal() != 0) 128 + interrupt.signal() else 130) else 1;

        output(init.io, .stderr(), message) catch |err| {
            // A failed Runtime (especially uncertain process cleanup) must not
            // become a canceled success-path merely because reporting stopped.
            if (interrupt.signal() != 0) return code;
            return err;
        };
        return code;
    }

    // 所有交互/守护/连接/attach/worker 分支统一交给 daemon 入口；
    // --print 分支已在上方完整处理，行为未变。前台默认不自动拉起守护服务。
    const code = try daemon.run(init, options);
    if (options.ssh_owner != null) try ssh.finish(code);
    return code;
}

pub fn exitCodeAfterRecording(code: u8, signal: u8) u8 {
    // Persistence adds a post-TUI interval. Honor a signal during that interval
    // without hiding an already failed (especially poisoned) exit.
    return if (code == 0 and signal != 0) 128 + signal else code;
}

test "resume exit persistence honors late signals without masking prior failures" {
    try std.testing.expectEqual(@as(u8, 0), exitCodeAfterRecording(0, 0));
    try std.testing.expectEqual(@as(u8, 130), exitCodeAfterRecording(0, 2));
    try std.testing.expectEqual(@as(u8, 143), exitCodeAfterRecording(0, 15));
    try std.testing.expectEqual(@as(u8, 1), exitCodeAfterRecording(1, 15));
}

/// 是否需要终端：--print 与 daemon/worker 不要求 TTY，仅交互前台/connect/attach 要求。
fn requiresInteractiveTty(options: cli.Options) bool {
    return options.prompt == null and options.ssh_owner == null and options.mode.requiresTty();
}

test "interactive tty gate excludes print daemon and worker modes" {
    const id = "0123456789abcdef0123456789abcdef";
    const socket = "/run/user/1000/thin/workers/session.sock";

    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{"thin"})));
    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{ "thin", "--resume", id })));
    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{ "thin", "--connect" })));
    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{ "thin", "--attach", id })));

    // 无 TTY 也必须能进入：一次性输出、守护服务与内部 worker。
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--print", "go" })));
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--daemon" })));
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--internal-worker", socket, id, "daemon" })));
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--internal-worker", socket, id, "foreground", "--worker-resume" })));
}

/// TUI/worker 已 join 所有 producer 并恢复终端属性后，由交互入口调用。
pub fn reportResume(init: std.process.Init, session: *Session) void {
    const saved = session.saveOnExit() catch |err| {
        var buffer: [256]u8 = undefined;
        const warning = std.fmt.bufPrint(&buffer, "thin: full conversation was NOT saved for resume: {s}. No resume command is available for this exit.\n", .{@errorName(err)}) catch return;
        output(init.io, .stderr(), warning) catch {};
        return;
    };
    if (!saved or interrupt.signal() != 0) return;
    const command = @import("app/resume_command.zig").format(init.gpa, session.session_id) catch {
        output(init.io, .stderr(), "thin: checkpoint saved, but a safe copyable resume command could not be produced.\n") catch {};
        return;
    };
    defer init.gpa.free(command);
    output(init.io, .stdout(), command) catch {};
}
