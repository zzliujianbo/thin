//! Linux/Intel Darwin application PTY acceptance. Never opens the user's terminal.
//! 中文：应用级 PTY 验收驱动，只使用 openpty 创建的伪终端，不打开用户自己的终端。

const std = @import("std");
const builtin = @import("builtin");
const darwin = builtin.os.tag == .macos;
const c = std.c;
const abi = @import("../platform/terminal_abi.zig");
const posix_terminal = @import("../platform/posix_terminal.zig");
const openpty = abi.openpty;
const regular = @import("regular_screen.zig");
const spinner_theme = @import("../ui/theme.zig");

// libc 符号声明：fork/exec、信号、进程组与 PTY 控制相关函数。
extern "c" fn fork() c_int;
extern "c" fn signal(c_int, *const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

/// 由信号处理器置位的中断标志；acquire/release 保证驱动循环能及时看到它。
var interrupted: std.atomic.Value(bool) = .init(false);

/// 信号处理器：只写原子标志，保持 async-signal-safe。
fn onSignal(_: c_int) callconv(.c) void {
    interrupted.store(true, .release);
}

extern "c" fn setsid() c_int;
extern "c" fn getsid(c_int) c_int;
extern "c" fn tcsetpgrp(c_int, c_int) c_int;
extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn dup2(c_int, c_int) c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
/// 创建 0700 且属于本 UID 的独占目录；模板必须以 6 个 X 结尾。
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
extern "c" fn kill(c_int, c_int) c_int;
extern "c" fn getpgid(c_int) c_int;

/// 返回单调时钟的毫秒数；时钟读取失败时返回 0。
fn now() i64 {
    var t: c.timespec = undefined;
    // Target libc CLOCK_MONOTONIC: Linux=1, Darwin=6.
    if (c.clock_gettime(.MONOTONIC, &t) != 0) return 0;
    return t.sec * 1000 + @divTrunc(t.nsec, 1000000);
}

/// 断言辅助：条件不成立时返回 AcceptanceFailed。
fn check(ok: bool) !void {
    if (!ok) return error.AcceptanceFailed;
}

const frame_begin = "\x1b[?2026h";
const frame_end = "\x1b[?2026l";
const frame_ack = "\x1b[?25h";
const Frame = struct { begin: usize, end: usize, complete: bool };
const ComposerKind = enum { none, effort, normal };

/// contextLabel emits ?%, >100%, or canonical tenths in 0.0..100.0%.
/// The policy marker, when enabled, precedes the value (never its percent).
fn normalLabel(label_: []const u8, low_price: bool) bool {
    var label = label_;
    if (low_price) {
        if (!std.mem.startsWith(u8, label, "L")) return false;
        label = label[1..];
    }
    if (std.mem.eql(u8, label, "?%") or std.mem.eql(u8, label, ">100%")) return true;
    if (label.len < 4 or label.len > 6 or label[label.len - 3] != '.' or
        !std.ascii.isDigit(label[label.len - 2]) or label[label.len - 1] != '%') return false;
    const integer = label[0 .. label.len - 3];
    if (integer.len > 1 and integer[0] == '0') return false;
    var whole: u16 = 0;
    for (integer) |digit| {
        if (!std.ascii.isDigit(digit)) return false;
        whole = whole * 10 + @as(u16, digit - '0');
    }
    return whole < 100 or (whole == 100 and label[label.len - 2] == '0');
}

/// A prompt contributes exactly one separator space. Cursor position and all
/// cells after it matter: trimEnd would discard typed spaces or hide a draft.
fn composerKind(view: *const regular.Screen, model: []const u8, effort: []const u8, low_price: bool) ComposerKind {
    if (view.row >= view.rows or view.row >= view.grid.len or view.col >= view.columns or view.wrap) return .none;
    const line = &view.grid[view.row];
    const text = line[0..view.col];
    for (line[view.col..]) |byte| if (byte != ' ') return .none;
    if (text.len < model.len + 5 or text[0] != '(' or
        !std.mem.eql(u8, text[1..][0..model.len], model) or
        !std.mem.startsWith(u8, text[model.len + 1 ..], ") ") or
        !std.mem.endsWith(u8, text, "> ")) return .none;
    const slot = text[model.len + 3 .. text.len - 2];
    if (low_price) {
        if (std.mem.startsWith(u8, slot, "L") and std.mem.eql(u8, slot[1..], effort)) return .effort;
    } else if (std.mem.eql(u8, slot, effort)) return .effort;
    return if (normalLabel(slot, low_price)) .normal else .none;
}

/// Reconstruct ACK-prefix screens incrementally, only when a caller actually
/// needs historical evidence. Each captured byte is replayed at most once per
/// scan; sparse frames inherit the prior screen rather than inventing pixels.
const FrameScanner = struct {
    view: *regular.Screen,
    consumed: usize = 0,
    witness: ?Frame = null,

    fn init(columns: usize) !FrameScanner {
        const view = try std.heap.page_allocator.create(regular.Screen);
        view.* = .{ .columns = columns };
        return .{ .view = view };
    }

    fn deinit(self: *FrameScanner) void {
        std.heap.page_allocator.destroy(self.view);
    }

    fn next(self: *FrameScanner, bytes: []const u8) !?Frame {
        const ack = std.mem.indexOfPos(u8, bytes, self.consumed, frame_ack) orelse return null;
        const begin = std.mem.lastIndexOf(u8, bytes[self.consumed..ack], frame_begin);
        const end = ack + frame_ack.len;
        const complete = begin != null and ack >= frame_end.len and
            std.mem.eql(u8, bytes[ack - frame_end.len .. ack], frame_end);
        const frame: Frame = .{ .begin = self.consumed + (begin orelse 0), .end = end, .complete = complete };
        try self.view.replay(bytes[self.consumed..end]);
        self.consumed = end;
        return frame;
    }

    fn findEffort(self: *FrameScanner, bytes: []const u8, start: usize, model: []const u8, effort: []const u8) !?Frame {
        if (self.witness) |frame| return frame;
        while (true) {
            const previously_effort = composerKind(self.view, model, effort, false) == .effort;
            const frame = (try self.next(bytes)) orelse return null;
            // An unrelated ACK that merely retains an old effort is not proof
            // of this action. Require an actual transition to the exact slot.
            if (frame.complete and frame.begin >= start and !previously_effort and
                composerKind(self.view, model, effort, false) == .effort)
            {
                self.witness = frame;
                return frame;
            }
        }
    }
};

/// PTY 驱动器：持有 master/slave 与子进程 PID，负责读写终端、收集输出，并校验退出状态与终端恢复情况。
const Driver = struct {
    /// 主端 fd：驱动方通过它向应用发送按键、读取屏幕输出。
    master: c_int,
    /// 从端 fd：作为子进程的 stdin/stdout/stderr；用于结束时检查 termios 是否恢复。
    slave: c_int,
    /// 子进程 PID。
    pid: c_int,
    /// 子进程是否仍归本驱动器所有（未被回收）。回收后置为 false，之后不再发信号，避免 PID 被复用后误杀。
    owned: bool = true,
    /// waitpid 返回的原始状态字（正常退出时 exit code 位于高 8 位）。
    status: c_int = 0,
    /// 启动前 slave 的 termios，结束时用于比对是否完整恢复。
    original: abi.Termios,
    /// 启动前 slave 的 fcntl 标志，结束时用于比对。
    flags: c_int,
    /// 输出缓冲区，固定 2 MiB 上限；超出时返回 OutputLimit。
    output: [2 * 1024 * 1024]u8 = undefined,
    /// output 中已写入的字节数。
    used: usize = 0,
    settings_key_start: usize = 0,
    columns: usize = 80,
    /// Owns every explicit screen snapshot returned by `screen()`. One Screen
    /// is ~330 KiB (160x24 grid plus 2048 history rows), far beyond the
    /// acceptance stack, so snapshots live here until Driver.deinit.
    screens: std.heap.ArenaAllocator,
    /// Single heap scratch screen reused by `acknowledgedScreen()`, which is
    /// polled frequently. Owners must not retain the pointer across another
    /// call; use `screen()` for an independent snapshot.
    scratch: ?*regular.Screen = null,
    /// Evidence for the most recent changed-effort wait, including the actual
    /// acknowledged frame even when the current screen has already expired.
    effort_witness: ?Frame = null,
    effort_witness_start: usize = 0,

    /// 在最多 ms 毫秒内轮询 master 并读尽可读数据；若子进程仍归属本驱动器，则非阻塞检查它是否已退出。
    fn drain(self: *Driver, ms: c_int) !void {
        if (interrupted.load(.acquire)) return error.DriverInterrupted;
        var poll = [_]c.pollfd{.{ .fd = self.master, .events = 1, .revents = 0 }};
        _ = c.poll(&poll, 1, ms);
        while (true) {
            var buf: [8192]u8 = undefined;
            const n = c.read(self.master, &buf, buf.len);
            if (n <= 0) break;
            const count: usize = @intCast(n);
            if (self.used + count > self.output.len) return error.OutputLimit;
            @memcpy(self.output[self.used..][0..count], buf[0..count]);
            self.used += count;
        }

        if (self.owned) {
            // WNOHANG：非阻塞回收，避免 drain 被子进程挂住。
            const result = waitpid(self.pid, &self.status, c.W.NOHANG);
            if (result == self.pid) {
                self.owned = false;
            } else if (result < 0 and c._errno().* != @backingInt(c.E.INTR)) {
                // ECHILD: never signal a possibly reused PID.
                if (c._errno().* == @backingInt(c.E.CHILD)) self.owned = false;
                return error.WaitFailed;
            }
        }
    }

    /// 等待 output 中自 start 偏移之后出现 needle，最长 10 秒；期间子进程提前退出则失败。
    fn waitText(self: *Driver, start: usize, needle: []const u8) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            if (std.mem.indexOf(u8, self.output[start..self.used], needle) != null) return;
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// A visible menu fragment is not an acknowledged complete owned frame.
    fn waitFrame(self: *Driver, start: usize, needle: []const u8) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            const bytes = self.output[start..self.used];
            if (std.mem.indexOf(u8, bytes, needle)) |at| {
                if (std.mem.indexOf(u8, bytes[at + needle.len ..], "\x1b[?25h") != null) return;
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// A redraw may be an asynchronous pending frame. Inspect only a complete
    /// acknowledged screen, never historical text or an unfinished latest diff.
    /// Polling reuses one Driver-owned scratch Screen: the result is valid only
    /// until the next acknowledgedScreen() call.
    fn acknowledgedScreen(self: *Driver, start: usize) !?*regular.Screen {
        const bytes = self.output[0..self.used];
        const ack = std.mem.lastIndexOf(u8, bytes, "\x1b[?25h") orelse return null;
        if (ack < start) return null;
        const after = bytes[ack + frame_ack.len ..];
        if (std.mem.indexOf(u8, after, frame_begin) != null) return null;
        // read() can stop at *any* byte of the next sync-begin. Even a lone
        // ESC is an unfinished latest frame, not permission to reuse the ACK.
        for (1..frame_begin.len) |n| {
            if (std.mem.endsWith(u8, after, frame_begin[0..n])) return null;
        }
        if (self.scratch == null) self.scratch = try self.screens.allocator().create(regular.Screen);
        const view = self.scratch.?;
        view.* = .{ .columns = self.columns };
        try view.replay(bytes[0 .. ack + "\x1b[?25h".len]);
        return view;
    }

    fn waitVisibleFrame(self: *Driver, start: usize, text_: []const u8) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            if (try self.acknowledgedScreen(start)) |view| if (view.visible(text_)) return;
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// A generated/ready caption is visible before execution. Require both a
    /// current complete row and an execution-only warm icon after the gate.
    fn waitRunningFrame(self: *Driver, start: usize, command: []const u8) !void {
        const view = try std.heap.page_allocator.create(regular.Screen);
        defer std.heap.page_allocator.destroy(view);
        var buffer: [512]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buffer, "> {s}", .{command});
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            const raw = self.output[0..self.used];
            const ack = std.mem.lastIndexOf(u8, raw, "\x1b[?25h") orelse continue;
            if (ack < start) continue;
            view.* = .{ .columns = self.columns };
            try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
            if (view.visible(needle)) {
                for (spinner_theme.tool_icon_pulse) |tone| {
                    var expected: [512]u8 = undefined;
                    const running = try std.fmt.bufPrint(&expected, "{s}>{s} {s}", .{ tone, spinner_theme.muted, command });
                    if (std.mem.indexOf(u8, raw[start .. ack + 1], running) != null) return;
                }
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.RunningToolFrameTimeout;
    }

    /// Completion has no label. Match the idle prefix's percentage tail only
    /// in new output: the model's neutral closing parenthesis precedes the
    /// percentage, which resets before the marker. Keep the full-frame cursor ACK.
    fn waitIdle(self: *Driver, start: usize) !void {
        try self.waitIdleUntil(start, now() + 10000);
    }

    fn waitIdleUntil(self: *Driver, start: usize, until: i64) !void {
        while (now() < until) {
            try self.drain(20);
            // A pending-submit redraw can contain an idle prefix before the
            // busy/answer frames. Historical raw matches are not current idle.
            if (try self.acknowledgedScreen(start)) |view| {
                const composer = &view.grid[view.row];
                if (std.mem.indexOf(u8, composer, "%> ") != null or
                    std.mem.startsWith(u8, composer, "> ")) return;
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// Only post-reply callers may accept a normal percentage without a new
    /// effort witness. Changed-effort waits recover a delivered flash from the
    /// capture when a later expiry ACK arrived in the same drain.
    fn waitEffortIdle(self: *Driver, start: usize, model: []const u8, effort: []const u8, allow_normal: bool) !void {
        self.effort_witness = null;
        self.effort_witness_start = start;
        var scanner: ?FrameScanner = null;
        defer if (scanner) |*s| s.deinit();
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            if (try self.effortIdleReady(start, model, effort, allow_normal, &scanner)) return;
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    fn effortIdleReady(self: *Driver, start: usize, model: []const u8, effort: []const u8, allow_normal: bool, scanner: *?FrameScanner) !bool {
        const view = (try self.acknowledgedScreen(start)) orelse return false;
        const kind = composerKind(view, model, effort, false);
        if (kind == .none) return false;
        if (allow_normal) return true; // Only used after a completed reply.
        if (scanner.* == null) scanner.* = try FrameScanner.init(self.columns);
        const ack = std.mem.lastIndexOf(u8, self.output[0..self.used], frame_ack).?;
        if (scanner.*) |*s| {
            if (try s.findEffort(self.output[0 .. ack + frame_ack.len], start, model, effort)) |frame| {
                self.effort_witness = frame;
                self.effort_witness_start = start;
                return true;
            }
        }
        return false;
    }

    /// Login promises a settled model composer, not an effort confirmation.
    fn waitAuthSettlement(self: *Driver, start: usize, model: []const u8, effort: []const u8) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            if (try self.acknowledgedScreen(start)) |view| {
                if (composerKind(view, model, effort, false) != .none) return;
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// Busy evidence requires a percentage prefix, a renderer-owned braille
    /// marker and the subsequent completed-frame cursor acknowledgement.
    fn waitBusy(self: *Driver, start: usize) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            const bytes = self.output[start..self.used];
            var from: usize = 0;
            const busy_prefix = "%\x1b[0m"; // Static occupancy resets immediately before the busy marker.
            while (std.mem.indexOfPos(u8, bytes, from, busy_prefix)) |prefix| {
                from = prefix + busy_prefix.len;
                // Bold prefix rendering restores weight after the occupancy reset.
                if (std.mem.startsWith(u8, bytes[from..], "\x1b[1m")) from += "\x1b[1m".len;
                // Accept only the running-tool palette, with a reset before
                // the editor's space. Neither TPS nor effort colors qualify.
                for (spinner_theme.command_pulse) |tone| {
                    if (!std.mem.startsWith(u8, bytes[from..], tone)) continue;
                    const marker = from + tone.len;
                    for ([_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }) |icon| {
                        if (std.mem.startsWith(u8, bytes[marker..], icon) and
                            std.mem.startsWith(u8, bytes[marker + icon.len ..], spinner_theme.reset ++ " ") and
                            std.mem.indexOf(u8, bytes[marker + icon.len ..], "\x1b[?25h") != null) return;
                    }
                }
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// One actual blank retained row between the sent message and live content.
    fn checkGap(screen_value: *const regular.Screen, before: []const u8, after: []const u8) !void {
        var first: ?usize = null;
        var second: ?usize = null;
        for (0..screen_value.history_len + screen_value.grid.len) |i| {
            const line = if (i < screen_value.history_len) &screen_value.history[i] else &screen_value.grid[i - screen_value.history_len];
            if (first == null and std.mem.indexOf(u8, line, before) != null) first = i;
            if (second == null and std.mem.indexOf(u8, line, after) != null) second = i;
        }
        try check(first != null and second != null);
        try check(second.? == first.? + 2);
        const gap = first.? + 1;
        const line = if (gap < screen_value.history_len) &screen_value.history[gap] else &screen_value.grid[gap - screen_value.history_len];
        for (line) |byte| try check(byte == ' ');
    }

    /// The seeded prior line remains visible, followed by one blank row and
    /// the natural first frame: optionally one hint, then the composer.
    fn checkStartupFootprint(view: *const regular.Screen) !void {
        try check(view.rows > 3 and view.rows <= view.grid.len);
        try check(view.history_len == 0 and view.count(regular.prior) == 1);
        try check(std.mem.indexOf(u8, &view.grid[0], regular.prior) != null);
        for (view.grid[1]) |byte| try check(byte == ' ');
        try check((view.row == 2 or view.row == 3) and view.col < view.columns);
        var composers: usize = 0;
        for (view.grid, 0..) |line, row| {
            if (std.mem.indexOf(u8, &line, "%> ") != null or std.mem.startsWith(u8, &line, "> ")) {
                composers += 1;
                try check(row == view.row);
            }
        }
        try check(composers == 1);
        if (view.row == 3) try check(std.mem.trim(u8, &view.grid[2], " ").len != 0);
        try checkComposerTail(view);
    }

    /// Only the two capability-clamp starts own this one-shot notice body.
    fn checkStartupNoticeFootprint(view: *const regular.Screen, notice: []const u8) !void {
        try check(view.rows > 4 and view.rows <= view.grid.len);
        try check(view.history_len == 0 and view.count(regular.prior) == 1);
        try check(std.mem.indexOf(u8, &view.grid[0], regular.prior) != null);
        for (view.grid[1]) |byte| try check(byte == ' ');
        try check(view.count(notice) == 1);
        try check(std.mem.eql(u8, std.mem.trim(u8, &view.grid[2], " "), notice));
        for (view.grid[3]) |byte| try check(byte == ' ');
        try check(view.row == 4 and view.col < view.columns);
        var composers: usize = 0;
        for (view.grid, 0..) |line, row| {
            if (std.mem.indexOf(u8, &line, "%> ") != null or std.mem.startsWith(u8, &line, "> ")) {
                composers += 1;
                try check(row == view.row);
            }
        }
        try check(composers == 1);
        try checkComposerTail(view);
    }

    /// A fresh end-position snapshot ends at the composer, with no owned rows
    /// below it. Short frames do not imply the physical bottom was reached.
    fn checkComposerTail(view: *const regular.Screen) !void {
        try check(view.rows > 0 and view.rows <= view.grid.len);
        try check(view.row < view.rows and view.col < view.columns);
        for (view.grid[view.row + 1 ..]) |line| for (line) |byte| try check(byte == ' ');
    }

    fn checkStreamFooter(view: *const regular.Screen) !void {
        const warning = "Saved thinking level not applied: model capabilities unknown";
        const prefix = "Saved thinking level not applied";
        try check(view.columns >= 2 and view.row >= 2 and view.rows <= view.grid.len and view.row < view.rows);
        const clipped = warning[0..@min(warning.len, view.columns - 1)];
        try check(std.mem.eql(u8, std.mem.trimEnd(u8, &view.grid[view.row - 1], " "), clipped));
        var matches: usize = 0;
        for (view.grid[0..view.rows]) |line| {
            if (std.mem.indexOf(u8, &line, prefix) != null) matches += 1;
        }
        try check(matches == 1);
        for (view.grid[view.row - 2]) |byte| try check(byte == ' ');
    }

    /// Fixed-size replay only: resize cases check sequences, not terminal reflow.
    /// Each call returns an independent Driver-owned snapshot that stays valid
    /// until Driver.deinit, so before/after comparisons never alias.
    fn screen(self: *Driver) !*regular.Screen {
        const result = try self.screens.allocator().create(regular.Screen);
        result.* = .{ .columns = self.columns };
        try result.replay(self.output[0..self.used]);
        return result;
    }

    /// Candidate rows stay below prior output and directly above the composer.
    fn checkMenu(self: *Driver, candidate: []const u8, composer: []const u8) !void {
        const view = try self.screen();
        try check(view.count(regular.prior) == 1);
        try check(!view.visible("Commands") and !view.visible("Configure provider (API key)"));
        var prior_row: ?usize = null;
        var candidate_row: ?usize = null;
        var composer_row: ?usize = null;
        for (0..view.history_len + view.grid.len) |i| {
            const line = if (i < view.history_len) &view.history[i] else &view.grid[i - view.history_len];
            if (std.mem.indexOf(u8, line, regular.prior) != null) prior_row = i;
            if (std.mem.indexOf(u8, line, candidate) != null) candidate_row = i;
            if (std.mem.indexOf(u8, line, composer) != null) composer_row = i;
        }
        if (prior_row == null or candidate_row == null or composer_row == null) {
            std.debug.print("menu missing: prior={any} candidate={any} composer={any}\n", .{ prior_row, candidate_row, composer_row });
        }
        try check(prior_row != null and candidate_row != null and composer_row != null);
        try check(prior_row.? < candidate_row.? and candidate_row.? < composer_row.?);
        try check(composer_row.? - candidate_row.? <= 11); // Ten candidates plus the blank composer separator.
    }

    /// The selected provider (or local fixture endpoint) must be visible before
    /// Enter opens masked input. Mode changes intentionally drop batched bytes.
    fn openAuth(self: *Driver) !void {
        var start = self.used;
        try self.send("/login\r");
        try self.waitFrame(start, "Provider> ");
        start = self.used;
        try self.send("\r");
        try self.waitFrame(start, "API key>");
    }

    /// 向 master 写入 bytes，最长 2 秒；写缓冲满（写入返回 0）时先 drain，避免与应用互相阻塞。
    fn send(self: *Driver, bytes: []const u8) !void {
        var pos: usize = 0;
        const until = now() + 2000;
        while (pos < bytes.len and now() < until) {
            const n = c.write(self.master, bytes[pos..].ptr, bytes.len - pos);
            if (n > 0) pos += @intCast(n) else try self.drain(10);
        }
        try check(pos == bytes.len);
    }

    /// 持续 drain 指定毫秒，用于等待界面稳定（确保拿到完整帧，而不是只有帧头前缀）。
    fn quiet(self: *Driver, ms: i64) !void {
        const until = now() + ms;
        while (now() < until) try self.drain(10);
    }

    /// 等待子进程退出（最长 10 秒），并校验：退出码、终端 termios 与 fcntl 标志已恢复，输出中没有 OSC 52 剪贴板写入或测试密钥。
    fn finish(self: *Driver, expected: c_int) !void {
        const until = now() + 10000;
        while (self.owned and now() < until) try self.drain(20);
        try check(!self.owned);
        // waitpid 状态的退出码位于高 8 位，因此与 expected << 8 比较。
        try check(self.status == expected << 8);

        try self.drain(0);

        var restored: abi.Termios = undefined;
        try check(abi.tcgetattr(self.slave, &restored) == 0);
        // Only Darwin's verified kernel-owned PENDIN/FWASWRITTEN bits are
        // normalized. Every other termios field and file flag stays strict.
        var original = self.original;
        original.lflag = abi.configuredLocalFlags(original.lflag);
        restored.lflag = abi.configuredLocalFlags(restored.lflag);
        try check(std.meta.eql(original, restored));
        const restored_flags = c.fcntl(self.slave, c.F.GETFL);
        try check(restored_flags >= 0);
        try check(posix_terminal.configuredFileFlags(restored_flags) == posix_terminal.configuredFileFlags(self.flags));

        // Regular TUI must never switch buffers, address absolute cells,
        // erase the display, or install a scrolling region (including resize).
        try regular.rejectFullscreen(self.output[0..self.used]);

        // 安全检查：应用不得输出 OSC 52 剪贴板序列，也不得泄露测试注入的密钥。
        try check(std.mem.indexOf(u8, self.output[0..self.used], "\x1b]52;") == null);
        try check(std.mem.indexOf(u8, self.output[0..self.used], "fixture-secret-never-log") == null);
        const prefix = "thin --resume ";
        const bytes = self.output[0..self.used];
        try check(std.mem.indexOf(u8, bytes, "Session ID: ") == null);
        try check(std.mem.indexOf(u8, bytes, "Resume: ") == null);
        const at = std.mem.indexOf(u8, bytes, prefix);
        if (expected == 0 and at != null) {
            try check(at.? + prefix.len + 32 <= bytes.len);
            const id = bytes[at.? + prefix.len ..][0..32];
            for (id) |byte| try check((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
            try check(std.mem.indexOf(u8, bytes[at.? + prefix.len + 32 ..], prefix) == null);
            const leave = "\x18\x1b[0m\x1b[?2004l\x1b[?2026l\x1b[?25h\r\n";
            // Restored OPOST/ONLCR may add an extra CR before LF.
            const translated_leave = "\x18\x1b[0m\x1b[?2004l\x1b[?2026l\x1b[?25h\r\r\n";
            const exit_at = std.mem.lastIndexOf(u8, bytes[0..at.?], leave) orelse std.mem.lastIndexOf(u8, bytes[0..at.?], translated_leave);
            try check(exit_at != null);
            const after_leave = exit_at.? + (if (std.mem.startsWith(u8, bytes[exit_at.?..], leave)) leave.len else translated_leave.len);
            // Only the terminal leave, a blank separator, the green command and
            // its reset may follow; no other escape or stray byte.
            const theme = @import("../ui/theme.zig");
            var expected_buffer: [128]u8 = undefined;
            const expected_tail = std.fmt.bufPrint(&expected_buffer, "\n{s}thin --resume {s}{s}\n", .{ theme.success, id, theme.reset }) catch unreachable;
            var translated_buffer: [128]u8 = undefined;
            const translated_tail = std.fmt.bufPrint(&translated_buffer, "\r\n{s}thin --resume {s}{s}\r\n", .{ theme.success, id, theme.reset }) catch unreachable;
            try check(std.mem.eql(u8, bytes[after_leave..], expected_tail) or std.mem.eql(u8, bytes[after_leave..], translated_tail));
            // Only validated immutable metadata leaves this capture buffer.
            std.debug.print("PTY_SESSION_ID={s}\n", .{id});
        } else try check(at == null); // Signal/headless exits do not announce it.
    }

    /// 清理：若子进程仍归本驱动器所有，则 SIGKILL 进程组与进程本身，并在 2 秒内尝试回收；最后关闭两端 fd。
    fn deinit(self: *Driver) void {
        if (self.owned) {
            // The child remains unreaped, hence its PID/group cannot be reused.
            if (getpgid(self.pid) == self.pid) _ = kill(-self.pid, @backingInt(c.SIG.KILL));
            _ = kill(self.pid, @backingInt(c.SIG.KILL)); // Also covers failure before group setup.

            const until = now() + 2000;
            while (self.owned and now() < until) {
                const result = waitpid(self.pid, &self.status, c.W.NOHANG);
                if (result == self.pid or (result < 0 and c._errno().* == @backingInt(c.E.CHILD))) {
                    self.owned = false;
                    break;
                }
                if (result < 0 and c._errno().* != @backingInt(c.E.INTR)) break;
                // fd 为 -1 的 pollfd 会被 poll 忽略，因此这里充当 5 毫秒的休眠。
                var descriptors = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
                _ = c.poll(&descriptors, 1, 5);
            }

            // 超时仍未确认回收时只打印警告，不再无限阻塞。
            if (self.owned) std.debug.print("PTY_CHILD_CLEANUP_UNCONFIRMED pid={d}\n", .{self.pid});
        }

        // PTY 两端的关闭与子进程是否回收无关，始终执行。
        _ = c.close(self.master);
        _ = c.close(self.slave);

        // All explicit snapshots and the polling scratch share this arena.
        self.scratch = null;
        self.screens.deinit();
    }
};

/// 读取必需的环境变量；缺失时返回 FixtureEnvironmentRequired。
fn required(init: std.process.Init, key: []const u8) ![]const u8 {
    return init.environ_map.get(key) orelse error.FixtureEnvironmentRequired;
}

/// Exact configured-effort hues, not a visual guess from an animated request.
/// The caller supplies only one replay-validated, acknowledged frame.
fn settingsColorFrame(bytes: []const u8, level: []const u8) !bool {
    const color: []const u8 = if (std.mem.eql(u8, level, "off")) "\x1b[38;5;245m" else if (std.mem.eql(u8, level, "low")) "\x1b[38;5;114m" else if (std.mem.eql(u8, level, "high")) "\x1b[38;5;75m" else if (std.mem.eql(u8, level, "max")) "\x1b[38;5;177m" else return error.UnknownSettingsLevel;
    const model_end = "fixture-model\x1b[0m\x1b[1m) ";
    const at = std.mem.lastIndexOf(u8, bytes, model_end) orelse return false;
    if (at < color.len or !std.mem.eql(u8, bytes[at - color.len .. at], color)) return false;
    const slot = bytes[at + model_end.len ..];
    if (std.mem.startsWith(u8, slot, color) and std.mem.startsWith(u8, slot[color.len..], level) and std.mem.startsWith(u8, slot[color.len + level.len ..], "\x1b[0m\x1b[1m>\x1b[0m ")) return true;
    if (std.mem.startsWith(u8, slot, "\x1b[0m\x1b[1m?%\x1b[0m\x1b[1m>\x1b[0m ")) return true;
    const green = "\x1b[38;5;114m";
    if (!std.mem.startsWith(u8, slot, green)) return false;
    var end = green.len;
    while (end < slot.len and (std.ascii.isDigit(slot[end]) or slot[end] == '.')) : (end += 1) {}
    if (!std.mem.startsWith(u8, slot[end..], "%\x1b[0m\x1b[1m>\x1b[0m ")) return false;
    if (!normalLabel(slot[green.len .. end + 1], false)) return false;
    const percent = std.fmt.parseFloat(f64, slot[green.len..end]) catch return false;
    return percent < 25;
}

fn settingsColor(d: *Driver, start: usize, level: []const u8) !void {
    const view = (try d.acknowledgedScreen(start)) orelse return error.SettingsColorMismatch;
    if (composerKind(view, "fixture-model", level, false) == .none) return error.SettingsColorMismatch;
    if (d.effort_witness_start == start) if (d.effort_witness) |frame| {
        // In the expiry fallback this is the actual effort frame, not a later
        // percent frame or some unrelated earlier occurrence of the color.
        if (try settingsColorFrame(d.output[frame.begin..frame.end], level)) return;
        return error.SettingsColorMismatch;
    };

    const ack = std.mem.lastIndexOf(u8, d.output[0..d.used], frame_ack).?;
    const bytes = d.output[0 .. ack + frame_ack.len];
    var scanner = try FrameScanner.init(d.columns);
    defer scanner.deinit();
    var latest_color: ?bool = null;
    while (try scanner.next(bytes)) |frame| {
        if (!frame.complete or frame.begin < start or composerKind(scanner.view, "fixture-model", level, false) == .none) continue;
        const raw = bytes[frame.begin..frame.end];
        // A sparse frame may not repaint the footer at all. Preserve the last
        // validated footer repaint, but never an unacknowledged raw match.
        if (std.mem.indexOf(u8, raw, "fixture-model") != null) latest_color = try settingsColorFrame(raw, level);
    }
    if (latest_color orelse false) return;
    return error.SettingsColorMismatch;
}

/// Each input waits for a new completed frame; sparse diffs need not reprint
/// unchanged labels. Assertions below inspect the replayed owned screen.
fn settingsKey(d: *Driver, bytes: []const u8) !void {
    const start = d.used;
    d.settings_key_start = start;
    try d.send(bytes);
    try d.waitFrame(start, "\x1b[?25l");
}

fn settingsValues(d: *Driver, low: []const u8, decision: []const u8, selected: usize) !void {
    var low_buffer: [100]u8 = undefined;
    var decision_buffer: [100]u8 = undefined;
    const low_text = try std.fmt.bufPrint(&low_buffer, "Low-price input  {s}", .{low});
    const decision_text = try std.fmt.bufPrint(&decision_buffer, "Decision model   {s}", .{decision});
    const selected_text = if (selected == 0) "> Low-price input" else "> Decision model";
    const until = now() + 10000;
    while (now() < until) {
        try d.drain(20);
        if (try d.acknowledgedScreen(d.settings_key_start)) |view| {
            if (view.visible(low_text) and view.visible(decision_text) and view.visible(selected_text)) return;
        }
        if (!d.owned) return error.EarlyExit;
    }
    // Never print terminal captures, model labels or keys in diagnostics.
    return error.SettingsValueFrameTimeout;
}

fn settingsDecisionChoose(d: *Driver, name: []const u8, backwards: bool) !void {
    var buffer: [1200]u8 = undefined;
    const selected = try std.fmt.bufPrint(&buffer, "> {s}", .{name});
    for (0..64) |_| {
        const view = try d.screen();
        if (view.visible(selected)) return;
        try settingsKey(d, if (backwards) "\x1b[A" else "\x1b[B");
    }
    return error.DecisionChoiceUnavailable;
}

// The Node owner checks config.json CAS persistence and ignored legacy files;
// choices are exact model references, never a dedicated Jev preset.
// Omitted decision.enabled defaults on only when decision is configured.
fn globalSettings(d: *Driver, mode: []const u8) !void {
    const off = std.mem.eql(u8, mode, "settings-global-off");
    const on = std.mem.eql(u8, mode, "settings-global-on");
    const verify = std.mem.eql(u8, mode, "settings-global-verify");
    const absent = std.mem.eql(u8, mode, "settings-global-unconfigured");
    const native = std.mem.eql(u8, mode, "settings-global-native");
    try check(off or on or verify or absent or native);
    try d.waitIdle(0);
    try settingsKey(d, "/settings\r");
    const before = if (on) "off" else "on";
    const after = if (off) "off" else "on";
    const decision_before = if (absent or native or on) "Off" else "native/family/native-review";
    const decision_after = if (absent or off) "Off" else "native/family/native-review";
    try settingsValues(d, before, decision_before, 0);
    if (off or on) {
        try settingsKey(d, "\r");
        try settingsValues(d, after, decision_before, 0);
    }
    try settingsKey(d, "\x1b[B");
    try settingsValues(d, after, decision_before, 1);
    try settingsKey(d, "\r");
    try d.waitVisibleFrame(d.settings_key_start, "Search> ");
    const choice = try d.screen();
    try check(!choice.visible("OpenCode Jev Free") and !choice.visible("Logged-in model") and !choice.visible("Request timeout"));
    // The selected native row may be beyond the first bounded window. Verify
    // both exact choices are navigable, not that every candidate fits at once.
    try settingsDecisionChoose(d, "Off", false);
    try check((try d.screen()).visible("> Off"));
    try settingsDecisionChoose(d, "native/family/native-review", false);
    try check((try d.screen()).visible("> native/family/native-review"));
    try settingsKey(d, "\x1b[D");
    try settingsValues(d, after, decision_before, 1);
    try settingsKey(d, "\r");
    try d.waitVisibleFrame(d.settings_key_start, "Search> ");
    try settingsKey(d, "\x1b");
    try settingsValues(d, after, decision_before, 1);
    if (!verify) {
        try settingsKey(d, "\r");
        try d.waitVisibleFrame(d.settings_key_start, "Search> ");
        try settingsDecisionChoose(d, if (on or native) "native/family/native-review" else "Off", false);
        try settingsKey(d, "\r");
        try settingsValues(d, after, decision_after, 1);
    }
    try settingsKey(d, "\x1b[A");
    try settingsValues(d, after, decision_after, 0);
    // Left returns to the root command list with settings selected. Tab
    // completes it, and a separately acknowledged Enter opens it again.
    try settingsKey(d, "\x1b[D");
    const root = try d.screen();
    try check(root.visible("> /settings") and root.visible("/model") and !root.visible("Low-price input"));
    try settingsKey(d, "\t");
    const completed = try d.screen();
    try check(completed.visible("/settings"));
    try settingsKey(d, "\r");
    try settingsValues(d, after, decision_after, 0);
    const start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    const closed = try d.screen();
    try check(!closed.visible("Low-price input") and !closed.visible("Decision model"));
    // No fabricated L assertion: unknown pricing has no authoritative tier.
    // Reopening checks the owner's published values after Esc, not UI intent.
    try settingsKey(d, "/settings\r");
    try settingsValues(d, after, decision_after, 0);
    const close_start = d.used;
    try d.send("\x1b");
    try d.waitIdle(close_start);
}

// Node validates the saved whole JSON and request counts before releasing
// each owned gate. Marker emission follows a complete replayed UI frame.
fn decisionModelGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/decision-model-release-{s}", .{ project, name }), 0);
    try check(access(path, 0) == -1 and c._errno().* == @backingInt(c.E.NOENT));
    std.debug.print("DECISION_MODEL_GATE={s}\n", .{name});
    const until = now() + 10000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == @backingInt(c.E.NOENT));
        try d.drain(20);
        if (!d.owned) return error.EarlyExit;
    }
    return error.DecisionModelGateTimeout;
}

// Screens are large: keep these extra acceptance helpers off the main stack.
fn decisionModelScreen(d: *Driver, a: std.mem.Allocator, required_text: []const []const u8, hidden: []const []const u8) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    // A bare Escape has an ambiguity deadline. An animation/metadata frame
    // can ACK before that deadline without having processed the key. Require
    // the intended CURRENT complete screen, not just an arbitrary new ACK.
    const until = now() + 10000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        const ack = std.mem.lastIndexOf(u8, raw, "\x1b[?25h") orelse continue;
        view.* = .{ .columns = d.columns };
        try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
        var matches = true;
        for (required_text) |needle| matches = matches and view.visible(needle);
        for (hidden) |needle| matches = matches and !view.visible(needle);
        if (matches) return;
        if (!d.owned) return error.EarlyExit;
    }
    return error.DecisionModelScreenDeadline;
}

fn decisionModel(d: *Driver, init: std.process.Init, mode: []const u8, project: []const u8) !void {
    const a = init.arena.allocator();
    const backwards = std.mem.eql(u8, mode, "settings-decision-model-wrap");
    try check(backwards or std.mem.eql(u8, mode, "settings-decision-model-down") or std.mem.eql(u8, mode, "settings-decision-model-native"));
    try d.waitIdle(0);
    var start = d.used;
    try d.send("decision-warmup-history-private-marker\r");
    try d.waitText(start, "decision-warmup-answer");
    try d.waitIdle(start);
    try settingsKey(d, "/settings\r");
    try settingsKey(d, "\x1b[B");
    try decisionModelScreen(d, a, &.{"> Decision model"}, &.{});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Off", "aux/family/judge", "primary/fixture-main", "Search> " }, &.{ "locked/secret-model", "OpenCode Jev Free", "Logged-in model", "Request timeout" });
    try decisionModelGate(d, a, project, "opened");
    try settingsDecisionChoose(d, "aux/family/judge", backwards);
    // A pasted identity plus Enter cannot save or fabricate a candidate.
    try d.send("\x1b[200~locked/secret-model\x1b[201~\r");
    try d.quiet(150);
    try decisionModelScreen(d, a, &.{"aux/family/judge"}, &.{ "locked/secret-model", "Decision model selected" });
    try settingsKey(d, "\x1b");
    try decisionModelScreen(d, a, &.{"> Decision model"}, &.{"Search> "});
    try decisionModelGate(d, a, project, "canceled");

    try settingsKey(d, "\r");
    try settingsDecisionChoose(d, "aux/family/judge", backwards);
    try decisionModelScreen(d, a, &.{ "> aux/family/judge", "Search> " }, &.{"locked/secret-model"});
    // Search intersects provider and raw-ID tokens, case-insensitively. A query
    // with no candidates cannot invent a choice or save on Enter.
    try settingsKey(d, "missing-decision-query");
    try decisionModelScreen(d, a, &.{ "Search> missing-decision-query", "No matching models" }, &.{ "> Off", "aux/family/judge", "primary/fixture-main" });
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"No matching models"}, &.{"Decision model   aux/family/judge"});
    try settingsKey(d, "\x15AUX /JUDGE");
    try decisionModelScreen(d, a, &.{ "Search> AUX /JUDGE", "> aux/family/judge" }, &.{ "> Off", "primary/fixture-main", "locked/secret-model", "No matching models" });
    // Settings now returns a generic Ready notice. Authorize success from the
    // completed owner-published frame and the following whole-JSON gate, not a
    // removed selection-specific caption.
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Decision model", "Decision model   aux/family/judge" }, &.{ "Search> ", "Logged-in model", "AUX /JUDGE", "missing-decision-query" });
    try decisionModelGate(d, a, project, "selected");
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{ "family/judge", "AUX /JUDGE", "missing-decision-query" });
    start = d.used;
    try d.send("decision-normal-task-private-marker\r");
    // The server only emits this AFTER inspecting the canonical bash result,
    // not when a command preview or ready caption happens to become visible.
    try d.waitFrame(start, "decision-tool-result-verified");
    try d.waitIdle(start);
    try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{});
}

// Image selection owns separate ACKed gates; no timer stands in for a save.
fn imageModelGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/image-model-release-{s}", .{ project, name }), 0);
    try check(access(path, 0) == -1 and c._errno().* == @backingInt(c.E.NOENT));
    std.debug.print("IMAGE_MODEL_GATE={s}\n", .{name});
    const until = now() + 10000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == @backingInt(c.E.NOENT));
        try d.drain(20);
        if (!d.owned) return error.EarlyExit;
    }
    return error.ImageModelGateTimeout;
}

fn imageModel(d: *Driver, init: std.process.Init, project: []const u8) !void {
    const a = init.arena.allocator();
    try d.waitIdle(0);
    var start = d.used;
    try d.send("image-warmup-history-private-marker\r");
    try d.waitText(start, "image-warmup-answer");
    try d.waitIdle(start);
    try decisionModelScreen(d, a, &.{"3.1%"}, &.{"?%"});
    try settingsKey(d, "/settings\r");
    // Resolve the eight-row root by label and wait for every navigation ACK.
    try settingsValueSelect(d, a, "Image model");
    try decisionModelScreen(d, a, &.{ "> Image model", "Image model      Off" }, &.{});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Off", "aux/deepseek-flash", "Search> " }, &.{ "primary/fixture-main", "locked/deepseek-flash", "aux/not-image" });
    try imageModelGate(d, a, project, "opened");
    try settingsKey(d, "aux/deepseek-flash");
    try decisionModelScreen(d, a, &.{"> aux/deepseek-flash"}, &.{});
    try settingsKey(d, "\x1b");
    try decisionModelScreen(d, a, &.{"> Image model"}, &.{"Search> "});
    try imageModelGate(d, a, project, "canceled");
    try settingsKey(d, "\r");
    try settingsKey(d, "aux/deepseek-flash");
    try decisionModelScreen(d, a, &.{"> aux/deepseek-flash"}, &.{});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Image model", "aux/deepseek-flash" }, &.{"Search> "});
    try imageModelGate(d, a, project, "selected");
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    // Settings> replaces the decorated composer. Inspect actual context only
    // after its completed close frame, before another request can repair it.
    try decisionModelScreen(d, a, &.{"3.1%"}, &.{"?%"});
    start = d.used;
    try d.send("image-normal-task-private-marker\r");
    try d.waitFrame(start, "image-tool-result-verified");
    try d.waitIdle(start);
    try settingsKey(d, "/settings\r");
    try settingsValueSelect(d, a, "Image model");
    try decisionModelScreen(d, a, &.{"> Image model"}, &.{});
    try settingsKey(d, "\r");
    try settingsKey(d, "\x15Off");
    try decisionModelScreen(d, a, &.{"> Off"}, &.{"aux/deepseek-flash"});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Image model", "Image model      Off" }, &.{"Search> "});
    try imageModelGate(d, a, project, "off");
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    try decisionModelScreen(d, a, &.{"3.1%"}, &.{"?%"});
    // A subsequent explicit request proves Off actually removes the tool.
    start = d.used;
    try d.send("image-off-proof\r");
    try d.waitFrame(start, "image-off-verified");
    try d.waitIdle(start);
}

// Shared request-timeout and main-preference journey, with direct Decision choices.
fn settingsValueGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const raw = try std.fmt.allocPrint(a, "{s}/settings-values-release-{s}", .{ project, name });
    defer a.free(raw);
    const path = try a.dupeSentinel(u8, raw, 0);
    defer a.free(path);
    try check(access(path, 0) == -1 and c._errno().* == @backingInt(c.E.NOENT));
    std.debug.print("SETTINGS_VALUES_GATE={s}\n", .{name});
    const until = now() + 5000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == @backingInt(c.E.NOENT));
        try d.drain(5);
        if (!d.owned) return error.EarlyExit;
    }
    return error.SettingsValueGateTimeout;
}

// Bounded candidate navigation, not fixed preset indices: current custom values
// may insert another row. Heap screen avoids inflating the acceptance stack.
fn settingsValueSelect(d: *Driver, a: std.mem.Allocator, label: []const u8) !void {
    const needle = try std.fmt.allocPrint(a, "> {s}", .{label});
    defer a.free(needle);
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    for (0..12) |_| {
        view.* = .{ .columns = d.columns };
        try view.replay(d.output[0..d.used]);
        if (view.visible(needle)) return;
        try settingsKey(d, "\x1b[B");
    }
    return error.SettingsValueCandidateMissing;
}

fn settingsValueMenuOrder(d: *Driver, a: std.mem.Allocator, labels: []const []const u8) !void {
    for (labels) |label| {
        const selected = try std.fmt.allocPrint(a, "> {s}", .{label});
        defer a.free(selected);
        try decisionModelScreen(d, a, &.{selected}, &.{});
        try settingsKey(d, "\x1b[B");
    }
}

fn settingsValueOpen(d: *Driver, a: std.mem.Allocator, label: []const u8) !void {
    try settingsValueSelect(d, a, label);
    try settingsKey(d, "\r");
}

fn settingsValueChoose(d: *Driver, a: std.mem.Allocator, label: []const u8, parent: []const u8) !void {
    try settingsValueOpen(d, a, label);
    const selected = try std.fmt.allocPrint(a, "> {s}", .{parent});
    defer a.free(selected);
    try decisionModelScreen(d, a, &.{selected}, &.{"Custom ("});
}

// Node validates the saved whole JSON and request counts before releasing
// each owned gate. Marker emission follows a complete replayed UI frame.
fn settingsProxyGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/settings-proxy-release-{s}", .{ project, name }), 0);
    try check(access(path, 0) == -1 and c._errno().* == @backingInt(c.E.NOENT));
    std.debug.print("SETTINGS_PROXY_GATE={s}\n", .{name});
    const until = now() + 10000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == @backingInt(c.E.NOENT));
        try d.drain(20);
        if (!d.owned) return error.EarlyExit;
    }
    return error.SettingsProxyGateTimeout;
}

/// Exact row state from one complete acknowledged frame. The query composer
/// also echoes the model text, so only a row carrying its own inline checkbox
/// can prove the owner-published membership; an arbitrary new frame cannot.
fn settingsProxyState(d: *Driver, a: std.mem.Allocator, model: []const u8, checked: bool) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const box = if (checked) "[x]" else "[ ]";
    const opposite = if (checked) "[ ]" else "[x]";
    const until = now() + 10000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        if (std.mem.lastIndexOf(u8, raw, "\x1b[?25h")) |ack| {
            view.* = .{ .columns = d.columns };
            try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
            var found: ?usize = null;
            var total: usize = 0;
            for (0..view.history_len + view.grid.len) |i| {
                const line = if (i < view.history_len) &view.history[i] else &view.grid[i - view.history_len];
                if (std.mem.indexOf(u8, line, model) == null) continue;
                if (std.mem.indexOf(u8, line, "[ ]") == null and std.mem.indexOf(u8, line, "[x]") == null) continue;
                total += 1;
                found = i;
            }
            if (total == 1) {
                const line = if (found.? < view.history_len) &view.history[found.?] else &view.grid[found.? - view.history_len];
                if (std.mem.indexOf(u8, line, box) != null and std.mem.indexOf(u8, line, opposite) == null) return;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.SettingsProxyStateDeadline;
}

/// Replace the child search query instead of assuming an unfiltered window.
/// Clearing and typing share one input batch: an already empty query still
/// needs no separate frame of its own.
fn settingsProxySearch(d: *Driver, a: std.mem.Allocator, query: []const u8) !void {
    try settingsKey(d, try std.fmt.allocPrint(a, "\x15{s}", .{query}));
}

// Proxy allowlist: read-only without root.proxy, otherwise one acknowledged
// per-row save that keeps the submenu open. Every write needs its own fresh
// complete frame; the same input batch may not toggle twice.
fn settingsProxy(d: *Driver, init: std.process.Init, mode: []const u8, project: []const u8) !void {
    const a = init.arena.allocator();
    const configured = std.mem.eql(u8, mode, "settings-proxy-configured");
    try check(configured or std.mem.eql(u8, mode, "settings-proxy-unconfigured"));
    try d.waitIdle(0);
    // Unsubmitted management drafts stay ordinary editable text: the exact
    // draft is visible in the composer, no hidden-arguments placeholder is
    // substituted, and nothing runs because Enter is never sent.
    for ([_][]const u8{ "/attach ", "/cd /tmp/owned path" }) |draft| {
        const visible = std.mem.trimEnd(u8, draft, " \t\r\n");
        try settingsKey(d, draft);
        try decisionModelScreen(d, a, &.{visible}, &.{"command arguments hidden"});
        const view = try d.screen();
        const composer = &view.grid[view.row];
        try check(std.mem.indexOf(u8, composer, visible) != null);
        try check(std.mem.indexOf(u8, composer, "command arguments hidden") == null);
        try settingsKey(d, "\x15");
    }
    try settingsKey(d, "/settings\r");
    // A batched command plus Enter may be processed in one read; require the
    // replayed Settings root before sending navigation keys.
    try decisionModelScreen(d, a, &.{ "Low-price input", "Decision model" }, &.{});
    try settingsValueSelect(d, a, "Proxy");
    try decisionModelScreen(d, a, &.{ "> Proxy", "Low-price input" }, &.{});
    try settingsKey(d, "\r");
    if (configured) {
        // Root 8 opens the second level on Address. Its editor is prefilled
        // with the saved endpoint; an abandoned draft writes nothing.
        try decisionModelScreen(d, a, &.{ "> Address", "Models" }, &.{ "Search> ", "Address> " });
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "Address> ", "127.0.0.1:8888" }, &.{});
        try settingsKey(d, "\x1510.9.9.9:1");
        try decisionModelScreen(d, a, &.{ "Address> ", "10.9.9.9:1" }, &.{});
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{ "> Address", "127.0.0.1:8888" }, &.{ "Address> ", "10.9.9.9:1" });
        try settingsProxyGate(d, a, project, "address-canceled");
        // One complete frame for the edited endpoint authorizes exactly one
        // save; the preserved member list keeps its single entry.
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "Address> ", "127.0.0.1:8888" }, &.{});
        try settingsKey(d, "\x15127.0.0.2:9999");
        try decisionModelScreen(d, a, &.{ "Address> ", "127.0.0.2:9999" }, &.{});
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "> Address", "127.0.0.2:9999", "1 selected" }, &.{"Address> "});
        try settingsProxyGate(d, a, project, "address-changed");
        // Models opens the existing multi-select list from the second level.
        try settingsValueSelect(d, a, "Models");
        try decisionModelScreen(d, a, &.{"> Models"}, &.{"Address> "});
        try settingsKey(d, "\r");
        // The pre-existing allowlist entry stays checked on open.
        try settingsProxyState(d, a, "zen/fixture-zen/model-x", true);
        try settingsProxyGate(d, a, project, "opened");
        // A declared alias without a resolvable local credential is not a
        // candidate: filtering to it offers no saveable row and Enter is inert.
        try settingsProxySearch(d, a, "ghost/Case-Model");
        try decisionModelScreen(d, a, &.{"No matching models"}, &.{});
        try d.send("\r");
        try d.quiet(40);
        try decisionModelScreen(d, a, &.{"No matching models"}, &.{"[x]"});
        try settingsProxyGate(d, a, project, "unlogged");
        // One batch with two Enters toggles exactly once and stays in the menu.
        try settingsProxySearch(d, a, "native/family/native-review");
        try settingsProxyState(d, a, "native/family/native-review", false);
        try settingsKey(d, "\r\r");
        try settingsProxyState(d, a, "native/family/native-review", true);
        try settingsProxyGate(d, a, project, "native-added");
        // Second literal-key model: raw ID keeps its inner slash and upper case.
        try settingsProxySearch(d, a, "go/Repo/Model-X");
        try settingsProxyState(d, a, "go/Repo/Model-X", false);
        try settingsKey(d, "\r");
        try settingsProxyState(d, a, "go/Repo/Model-X", true);
        try settingsProxyGate(d, a, project, "added");
        // Left leaves the list for the second level, Esc leaves Models for the
        // root row that owns it; each step keeps its owning selection.
        try settingsKey(d, "\x1b[D");
        try decisionModelScreen(d, a, &.{"> Models"}, &.{"Search> "});
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{ "> Proxy", "Low-price input" }, &.{"Search> "});
        try settingsProxyGate(d, a, project, "root-return");
        // Reopen lands on Address; Models then opens the list again.
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{"> Address"}, &.{"Address> "});
        try settingsValueSelect(d, a, "Models");
        try settingsKey(d, "\r");
        // A full reopen does not keep all three targets inside the bounded
        // window, so each membership proof starts from its own search query.
        try settingsProxySearch(d, a, "zen/fixture-zen/model-x");
        try settingsProxyState(d, a, "zen/fixture-zen/model-x", true);
        try settingsProxySearch(d, a, "native/family/native-review");
        try settingsProxyState(d, a, "native/family/native-review", true);
        try settingsProxySearch(d, a, "go/Repo/Model-X");
        try settingsProxyState(d, a, "go/Repo/Model-X", true);
        try settingsProxyGate(d, a, project, "reopened");
        // Uncheck one row; the preserved entry and the other addition stay.
        try settingsProxySearch(d, a, "go/Repo/Model-X");
        try settingsProxyState(d, a, "go/Repo/Model-X", true);
        try settingsKey(d, "\r");
        try settingsProxyState(d, a, "go/Repo/Model-X", false);
        try settingsProxySearch(d, a, "native/family/native-review");
        try settingsProxyState(d, a, "native/family/native-review", true);
        try settingsProxySearch(d, a, "zen/fixture-zen/model-x");
        try settingsProxyState(d, a, "zen/fixture-zen/model-x", true);
        try settingsProxyGate(d, a, project, "removed");
        // Escape from the list lands on Models; Enter reopens the same list.
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{"> Models"}, &.{"Search> "});
        try settingsKey(d, "\r");
        // Same bounded window after reopen: search each target before proving
        // its checked state from a complete frame.
        try settingsProxySearch(d, a, "native/family/native-review");
        try settingsProxyState(d, a, "native/family/native-review", true);
        try settingsProxySearch(d, a, "go/Repo/Model-X");
        try settingsProxyState(d, a, "go/Repo/Model-X", false);
        try settingsProxySearch(d, a, "zen/fixture-zen/model-x");
        try settingsProxyState(d, a, "zen/fixture-zen/model-x", true);
        try settingsProxyGate(d, a, project, "persisted");
        // The list itself returns to Models before the shared root Escape.
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{"> Models"}, &.{"Search> "});
        // Models is a second level; one more Escape reaches the root row that
        // owns it, so both branches leave from the same screen.
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{ "> Proxy", "Low-price input" }, &.{"Search> "});
    } else {
        // Models is the blocked child: opening without root.proxy shows the
        // fixed notice and Enter reports the missing endpoint instead of
        // guessing or writing one.
        try settingsValueSelect(d, a, "Models");
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "Proxy host/port not configured", "[ ]" }, &.{"[x]"});
        try settingsProxyGate(d, a, project, "opened");
        try d.send("\r");
        try d.quiet(50);
        try decisionModelScreen(d, a, &.{"Configure a proxy"}, &.{"[x]"});
        try settingsProxyGate(d, a, project, "unconfigured");
        // An invalid port never lands: the editor keeps its draft and the
        // submenu keeps the unconfigured row underneath.
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{"> Models"}, &.{"Search> "});
        try settingsValueSelect(d, a, "Address");
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "Address> ", "Not configured" }, &.{});
        try settingsKey(d, "127.0.0.1:0");
        try decisionModelScreen(d, a, &.{ "Address> ", "127.0.0.1:0" }, &.{});
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "Invalid proxy address", "Address> " }, &.{});
        try settingsProxyGate(d, a, project, "invalid");
        // A visible, fully acknowledged address is the first savable state.
        try settingsKey(d, "\x15127.0.0.1:8888");
        try decisionModelScreen(d, a, &.{ "Address> ", "127.0.0.1:8888" }, &.{});
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "> Address", "127.0.0.1:8888" }, &.{"Address> "});
        try settingsProxyGate(d, a, project, "address-saved");
        // The saved endpoint makes the very first toggle savable.
        try settingsValueSelect(d, a, "Models");
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{"Search> "}, &.{"Proxy host/port not configured"});
        try settingsProxySearch(d, a, "zen/fixture-zen/model-x");
        try settingsProxyState(d, a, "zen/fixture-zen/model-x", false);
        try settingsKey(d, "\r");
        try settingsProxyState(d, a, "zen/fixture-zen/model-x", true);
        try settingsProxyGate(d, a, project, "member-added");
        // Empty input disables the proxy through the same acknowledged save.
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{"> Models"}, &.{"Search> "});
        try settingsValueSelect(d, a, "Address");
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "Address> ", "127.0.0.1:8888" }, &.{});
        // The submenu row behind still prints the saved endpoint, so only the
        // cleared composer's own completed frame may authorize the save. The
        // offset must predate the Ctrl-U send: settingsKey already pumps that
        // frame to completion, so a later offset can never see a frame start.
        const erased = d.used;
        try settingsKey(d, "\x15");
        try d.waitFrame(erased, "");
        const empty = try d.screen();
        try check(std.mem.startsWith(u8, &empty.grid[empty.row], "Address> "));
        try check(std.mem.indexOf(u8, &empty.grid[empty.row], "127.0.0.1:8888") == null);
        try settingsKey(d, "\r");
        try decisionModelScreen(d, a, &.{ "> Address", "Not configured" }, &.{"Address> "});
        try settingsProxyGate(d, a, project, "cleared");
        // Esc leaves the second level for the root row, which now reports the
        // removed endpoint instead of a stale host:port.
        try settingsKey(d, "\x1b");
        try decisionModelScreen(d, a, &.{ "> Proxy", "Not configured", "Low-price input" }, &.{"Address> "});
        try settingsProxyGate(d, a, project, "reopened");
    }
    // Both branches end on the Settings root with Proxy selected: one Escape
    // closes Settings and needs its own acknowledged screen.
    try decisionModelScreen(d, a, &.{ "> Proxy", "Low-price input" }, &.{"Search> "});
    const start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    const closed = try d.screen();
    try check(!closed.visible("Low-price input") and !closed.visible("Search> "));
}

fn settingsValuesJourney(d: *Driver, init: std.process.Init, project: []const u8) !void {
    const a = init.arena.allocator();
    try d.waitIdle(0);
    var start = d.used;
    try d.send("values-warmup-private-marker\r");
    try d.waitText(start, "values-warmup-answer");
    try d.waitIdle(start);
    try settingsKey(d, "/settings\r");
    try decisionModelScreen(d, a, &.{ "> Low-price input", "Decision model", "Auto compaction", "Command timeout", "Request timeout", "Image model" }, &.{ "Output limit", "Task timeout" });
    try settingsValueMenuOrder(d, a, &.{ "Low-price input", "Decision model", "Auto compaction", "Command timeout", "Request timeout", "Image model", "Auto memory", "Proxy" });
    try settingsValueGate(d, a, project, "opened");
    try settingsValueOpen(d, a, "Auto compaction"); // Boolean toggle, no numeric picker.
    try decisionModelScreen(d, a, &.{ "> Auto compaction", "Auto compaction  off" }, &.{});
    try settingsValueGate(d, a, project, "compaction");

    try settingsValueOpen(d, a, "Command timeout");
    try decisionModelScreen(d, a, &.{ "> 123.456 s (current)", "Custom (s)..." }, &.{});
    try settingsValueGate(d, a, project, "current");
    try settingsValueOpen(d, a, "Custom (s)...");
    try decisionModelScreen(d, a, &.{ "Custom: _ s", "up to 3 decimals", "Enter stages" }, &.{});
    // Invalid candidates may intentionally have no confirmable ACK and emit
    // no new frame on Enter. Observe the existing screen, not waitFrame.
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"Custom: _ s"}, &.{"(staged)"});
    try settingsValueGate(d, a, project, "invalid-empty");
    try settingsKey(d, "0");
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"Custom: 0_ s"}, &.{"(staged)"});
    try settingsValueGate(d, a, project, "invalid-zero");
    try settingsKey(d, "\x15"); // Ctrl-U must clear all digits, not edit the composer.
    try decisionModelScreen(d, a, &.{"Custom: _ s"}, &.{});
    try settingsKey(d, "4294967.296"); // Same u32-ms overflow, expressed in seconds.
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"Custom: 4294967.296_ s"}, &.{"(staged)"});
    try settingsValueGate(d, a, project, "invalid-overflow");
    try settingsKey(d, "\x1b[D"); // edit -> candidate list, not parent Settings.
    try decisionModelScreen(d, a, &.{"> Custom (s)..."}, &.{"Custom:"});
    try settingsValueGate(d, a, project, "edit-cancel");
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{"Custom: _ s"}, &.{});
    try settingsKey(d, "120.001");
    // Two Enters in ONE input batch must only stage. The owner drops remaining
    // batch input, publishes a fresh generation, and waits for its frame ACK.
    try settingsKey(d, "\r\r");
    try decisionModelScreen(d, a, &.{"> 120.001 s (staged)"}, &.{"Custom:"});
    try settingsValueGate(d, a, project, "staged-cancel");
    try settingsKey(d, "\x1b"); // staged candidate -> parent, no save.
    try decisionModelScreen(d, a, &.{"> Command timeout"}, &.{"Custom ("});
    try settingsValueGate(d, a, project, "canceled");

    try settingsValueOpen(d, a, "Command timeout");
    try decisionModelScreen(d, a, &.{"> 123.456 s (current)"}, &.{"120.001 s"});
    try settingsValueOpen(d, a, "Custom (s)...");
    try settingsKey(d, "120");
    try settingsKey(d, "\r\r");
    try decisionModelScreen(d, a, &.{"> 120 s (staged)"}, &.{"Custom:"});
    try settingsValueGate(d, a, project, "command-staged");
    try settingsKey(d, "\r"); // Separate Enter only after fresh ACK and disk gate.
    try decisionModelScreen(d, a, &.{ "> Command timeout", "120 s" }, &.{"Custom ("});
    try settingsValueGate(d, a, project, "command");

    try settingsValueOpen(d, a, "Request timeout");
    try decisionModelScreen(d, a, &.{"> 10 s (current)"}, &.{});
    try settingsValueChoose(d, a, "60 s", "Request timeout");
    try settingsValueGate(d, a, project, "request");
    // The retired task timeout is not a setting; no save occurs at this gate.
    try decisionModelScreen(d, a, &.{"> Request timeout"}, &.{"Task timeout"});
    try settingsValueGate(d, a, project, "task");

    try settingsValueOpen(d, a, "Decision model");
    try decisionModelScreen(d, a, &.{ "> aux/family/judge", "Off", "primary/fixture-main" }, &.{ "OpenCode Jev Free", "Logged-in model", "Request timeout" });
    try settingsValueGate(d, a, project, "decision-menu");
    try settingsKey(d, "\x1b[D"); // decision -> root Settings.
    try decisionModelScreen(d, a, &.{"> Decision model"}, &.{"Logged-in model"});
    try settingsKey(d, "\x1b[D"); // Settings -> root commands.
    try decisionModelScreen(d, a, &.{"> /settings"}, &.{"Low-price input"});
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{"family/judge"});
    // Back-to-commands deliberately restores "/". Esc dismisses that menu
    // without discarding the user's input; clear it before a normal prompt.
    try settingsKey(d, "\x15");
    try settingsValueGate(d, a, project, "closed");
    start = d.used;
    try d.send("values-task-private-marker\r");
    try d.waitFrame(start, "values-tool-result-verified");
    try d.waitIdle(start);
    try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{});
}

// Whole-capture replay through the last ACK, not a suffix that loses native
// scrollback or an in-flight frame. Keep this large fixture off the stack.
fn approvalCancelScreen(d: *Driver, view: *regular.Screen) !void {
    const raw = d.output[0..d.used];
    const ack = std.mem.lastIndexOf(u8, raw, "\x1b[?25h") orelse return error.MissingApprovalCancelAck;
    view.* = .{ .columns = d.columns };
    try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
}

// Confirmation controls are transient composer content, not transcript rows.
// These fixtures use a normal-width PTY, so both choices fit on the question row.
fn checkConfirmationRow(view: *const regular.Screen, question: []const u8, selected: []const u8, other: []const u8) !void {
    try Driver.checkComposerTail(view);
    const row = &view.grid[view.row];
    try check(std.mem.indexOf(u8, row, question) != null);
    try check(std.mem.indexOf(u8, row, selected) != null);
    try check(std.mem.indexOf(u8, row, other) != null);
    try check(view.count(question) == 1);
    for (view.history[0..view.history_len]) |line| {
        try check(std.mem.indexOf(u8, &line, question) == null);
    }
}

// Opening and every PageDown share the original one-shot 15s screen budget.
// Only a fresh, fully acknowledged frame may advance the three-line preview;
// PageDown moves its window by two rows without selecting or allowing a call.
fn approvalCancelPreview(d: *Driver, view: *regular.Screen, start: usize) !void {
    const until = now() + 15000;
    var since = start;
    var pages: usize = 0;
    var approval_id: ?u64 = null;
    std.debug.print("APPROVAL_CANCEL_CHECKPOINT=preview-await\n", .{});
    while (now() < until) {
        try d.drain(20);
        if (try d.acknowledgedScreen(since)) |current| {
            if (current.visible("Approval #")) {
                try checkConfirmationRow(current, "Approval #", "> Deny", "Allow once");
                const row = &current.grid[current.row];
                const id_start = std.mem.indexOf(u8, row, "Approval #").? + "Approval #".len;
                var id_end = id_start;
                while (id_end < row.len and std.ascii.isDigit(row[id_end])) : (id_end += 1) {}
                const id = try std.fmt.parseInt(u64, row[id_start..id_end], 10);
                if (approval_id) |expected| try check(id == expected) else approval_id = id;
                const ghost_visible = current.visible("GHOST-CANCEL-ONLY");
                std.debug.print("APPROVAL_CANCEL_PREVIEW page={d} ghost_visible={any}\n", .{ pages, ghost_visible });
                if (ghost_visible) {
                    view.* = current.*;
                    return;
                }
                if (pages == 8) return error.ApprovalCancelPreviewPageLimit;
                since = d.used;
                try d.send("\x1b[6~");
                pages += 1;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.ApprovalCancelPreviewDeadline;
}

fn checkApprovalCancelRestored(view: *const regular.Screen) !void {
    std.debug.print("APPROVAL_CANCEL_SCREEN last_visible={any} prior_total={d} history={d}\n", .{ view.visible("PRIOR-CANCEL-17"), view.count("PRIOR-CANCEL-"), view.history_len });
    try check(view.visible("PRIOR-CANCEL-17"));
    var marker: [32]u8 = undefined;
    var visible_prior: usize = 0;
    for (0..18) |i| {
        const text = try std.fmt.bufPrint(&marker, "PRIOR-CANCEL-{d:0>2}", .{i});
        // count includes history AND grid: restore must not reprint old rows.
        try check(view.count(text) == 1);
        if (view.visible(text)) visible_prior += 1;
    }
    try check(view.count("Approval #") == 0 and view.count("GHOST-CANCEL-ONLY") == 0);
    // The closed panel must not leave stale rows below the composer.
    try Driver.checkComposerTail(view);
    const composer = &view.grid[view.row];
    try check(std.mem.indexOf(u8, composer, "%> ") != null);
    const tail = std.mem.trimEnd(u8, composer, " ");
    try check(view.col == tail.len + @as(usize, if (std.mem.endsWith(u8, tail, "%>")) 1 else 0));
    // Catch the original screenful of erased body, not just a surviving tail
    // marker. This compact fixture leaves many prior lines in the viewport.
    try check(visible_prior >= 8);
    var occupied: usize = 0;
    var blanks: usize = 0;
    var longest_blank: usize = 0;
    // Only rows above the composer are checked for erased transcript content;
    // rows below it are already verified blank.
    for (view.grid[0..view.row]) |row| {
        if (std.mem.trim(u8, &row, " ").len == 0) {
            blanks += 1;
            longest_blank = @max(longest_blank, blanks);
        } else {
            occupied += 1;
            blanks = 0;
        }
    }
    try check(occupied >= 10 and longest_blank <= 5);
}

fn approvalCancel(d: *Driver) !void {
    const a = std.heap.page_allocator;
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    try d.waitIdle(0);
    var start = d.used;
    try d.send("approval-cancel-seed\r");
    try queuedScreen(d, a, start, &.{"PRIOR-CANCEL-17"});
    try queuedIdle(d, a, start);
    try approvalCancelScreen(d, view);
    try check(view.visible("PRIOR-CANCEL-17"));
    for (0..18) |i| {
        var marker: [32]u8 = undefined;
        try check(view.count(try std.fmt.bufPrint(&marker, "PRIOR-CANCEL-{d:0>2}", .{i})) == 1);
    }

    start = d.used;
    try d.send("approval-cancel-long\r");
    try approvalCancelPreview(d, view, start);
    const history_before = view.history_len;
    const waiting = d.used;
    try d.quiet(2400);
    try check(d.owned);
    const titles = std.mem.count(u8, d.output[waiting..d.used], "Approval #");
    try approvalCancelScreen(d, view);
    try check(titles == 0 and view.history_len == history_before);
    try check(view.count("Approval #") == 1 and view.visible("GHOST-CANCEL-ONLY"));
    try checkConfirmationRow(view, "Approval #", "> Deny", "Allow once");
    var visible_prior: usize = 0;
    for (0..18) |i| {
        var marker: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&marker, "PRIOR-CANCEL-{d:0>2}", .{i});
        try check(view.count(text) == 1);
        if (view.visible(text)) visible_prior += 1;
    }
    try check(visible_prior >= 8);
    // The long command's preview is confined to the three rows immediately
    // above the question, rather than becoming a scrollback record.
    for (view.grid[0..view.row], 0..) |row, i| {
        if (std.mem.indexOf(u8, &row, "GHOST-CANCEL-ONLY") != null or
            std.mem.indexOf(u8, &row, "synthetic-step") != null)
            try check(view.row - i <= 3);
    }
    std.debug.print("APPROVAL_CANCEL_WAIT repeated_titles={d}\n", .{titles});

    // Standalone ESC: no following byte may mask the parser's 150ms expiry.
    // Escape confirms the safe default Deny choice. The canonical denied tool
    // result is then returned to the model exactly once for its final response.
    start = d.used;
    try d.send("\x1b");
    try queuedScreen(d, a, start, &.{"Approval denied; continuing without execution."});
    try queuedIdle(d, a, start);
    try approvalCancelScreen(d, view);
    try checkApprovalCancelRestored(view);
    start = d.used;
    try d.send("cancel-live-draft");
    try queuedScreen(d, a, start, &.{"cancel-live-draft"});
    try approvalCancelScreen(d, view);
    try checkApprovalCancelRestored(view);
    try check(std.mem.endsWith(u8, std.mem.trimEnd(u8, &view.grid[view.row], " "), "cancel-live-draft"));
    start = d.used;
    try d.send("\x15");
    try queuedIdle(d, a, start);
    try approvalCancelScreen(d, view);
    try checkApprovalCancelRestored(view);
    try check(std.mem.endsWith(u8, std.mem.trimEnd(u8, &view.grid[view.row], " "), "%>"));
    std.debug.print("APPROVAL_CANCEL_GATE=verified\n", .{});
}

extern "c" fn mkdir([*:0]const u8, c.mode_t) c_int;
const approval_marker_content = "owned approval sentinel\n";

fn checkApprovalMarker(init: std.process.Init, project: []const u8) !void {
    const a = init.arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/.ssh/fixture-marker", .{project});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(approval_marker_content.len + 1));
    try check(std.mem.eql(u8, bytes, approval_marker_content));
}

fn localCommand(d: *Driver, mode: []const u8, init: std.process.Init, project: []const u8) !void {
    // Do not materialize another large Screen on this history driver's stack.
    errdefer std.debug.print("command PTY acceptance failed\n", .{});
    try d.waitIdle(0);
    const accept = std.mem.eql(u8, mode, "settings-command-accept");
    const deny = std.mem.eql(u8, mode, "settings-command-deny");
    const cancel = std.mem.eql(u8, mode, "settings-command-cancel");
    const timeout = std.mem.eql(u8, mode, "settings-command-timeout");
    const stable = std.mem.eql(u8, mode, "settings-command-stable");
    try check(accept or deny or cancel or timeout or stable);
    const a = init.arena.allocator();
    const dir = try std.fmt.allocPrintSentinel(a, "{s}/.ssh", .{project}, 0);
    if (mkdir(dir, 0o700) != 0) try check(c._errno().* == @backingInt(c.E.EXIST));
    const marker = try std.fmt.allocPrint(a, "{s}/fixture-marker", .{dir});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = marker, .data = approval_marker_content });
    try checkApprovalMarker(init, project);
    if (stable) {
        var source: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer source.deinit();
        try source.writer.writeAll("  !rm -f .ssh/fixture-marker; touch stable-executed; #");
        for (0..125) |i| try source.writer.print(" synthetic-step-{d}: 中文注释 abcdefghijklmnopqrstuvwxyz", .{i});
        try source.writer.writeByte('\r');
        const submitted = d.used;
        try d.send(source.written());
        try d.waitFrame(submitted, "Approval #");
        const view = try std.heap.page_allocator.create(regular.Screen);
        defer std.heap.page_allocator.destroy(view);
        const ack_before = std.mem.lastIndexOf(u8, d.output[0..d.used], "\x1b[?25h").? + "\x1b[?25h".len;
        view.* = .{ .columns = d.columns };
        try view.replay(d.output[0..ack_before]);
        const history_before = view.history_len;
        try check(view.visible("Approval #"));
        const waiting = d.used;
        try d.quiet(2400);
        try check(d.owned);
        const titles = std.mem.count(u8, d.output[waiting..d.used], "Approval #");
        const ack_after = std.mem.lastIndexOf(u8, d.output[0..d.used], "\x1b[?25h").? + "\x1b[?25h".len;
        view.* = .{ .columns = d.columns };
        try view.replay(d.output[0..ack_after]);
        std.debug.print("APPROVAL_WAIT repeated_titles={d} history_delta={d} visible_titles={d}\n", .{ titles, view.history_len -| history_before, view.count("Approval #") });
        try check(titles == 0 and view.history_len == history_before and view.count("Approval #") == 1);
        try checkConfirmationRow(view, "Approval #", "> Deny", "Allow once");
        // An actual scroll still redraws and needs a fresh completed frame;
        // freezing idle animation must not freeze input or approval controls.
        const scrolled = d.used;
        try d.send("\x1b[6~");
        try d.waitFrame(scrolled, "Approval #");
        const denied = d.used;
        try d.send("\r");
        try d.waitIdle(denied);
        try checkApprovalMarker(init, project);
        return;
    }
    // Empty command, bracketed paste and submit batch tail must not execute.
    if (deny) {
        var start = d.used;
        try d.send("!\r");
        try d.waitIdle(start);
        start = d.used;
        try d.send("\x1b[200~!touch pasted\n\x1b[201~");
        try d.quiet(150);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
        try d.send("\x15");
        try d.quiet(100);
    }
    // The rm operation targets the owned relative sentinel and deliberately
    // exercises mandatory approval.
    const command = if (accept) "printf 'OUT\\n'; printf 'ERR\\n' >&2; touch marker; rm -f .ssh/fixture-marker; exit 7" else if (deny) "rm -f .ssh/fixture-marker; touch denied" else "rm -f .ssh/fixture-marker; sleep 30 & echo $! > child; touch started; wait";
    var line: [256]u8 = undefined;
    const start = d.used;
    // Prefix whitespace follows the same dispatch semantics as the composer.
    try d.send(try std.fmt.bufPrint(&line, "  !{s}\r", .{command}));
    // Both command preview and approval must belong to a completed new frame.
    try d.waitFrame(start, command);
    try d.waitFrame(start, "Approval #");
    // Approval is a modal selector. Deny is the safe default; allowing once
    // requires a visible arrow-selected frame before Enter can authorize it.
    if (!deny) {
        const selected = d.used;
        try d.send("\x1b[D");
        try d.waitFrame(selected, "> Allow once");
    }
    const answered = d.used;
    try d.send("\r");
    if (cancel) {
        try d.quiet(200);
        try d.send("\x1b");
        try d.waitText(answered, "Canceled");
    }
    try d.waitIdle(answered);
    if (accept) {
        // These labels do not occur in the command preview. They prove that
        // actual local output is visible before any subsequent inference.
        try d.waitFrame(answered, "Command exited with status 7");
        // Do not confuse OUT/ERR in the quoted command preview with actual
        // decoded stream lines. Keep the large screen off the driver's stack.
        const view = try std.heap.page_allocator.create(regular.Screen);
        defer std.heap.page_allocator.destroy(view);
        view.* = .{ .columns = d.columns };
        try view.replay(d.output[0..d.used]);
        var stdout_line = false;
        var stderr_line = false;
        for (0..view.history_len + view.grid.len) |i| {
            const row = if (i < view.history_len) &view.history[i] else &view.grid[i - view.history_len];
            const value = std.mem.trim(u8, row, " \t");
            stdout_line = stdout_line or std.mem.eql(u8, value, "OUT");
            stderr_line = stderr_line or std.mem.eql(u8, value, "ERR");
        }
        try check(stdout_line and stderr_line);
        try check(view.count("stdout:") == 0 and view.count("stderr:") == 0 and view.count("output encoding:") == 0 and view.count("exit: 0") == 0);
        // Exactly one explicit subsequent inference; the mock validates the
        // preceding canonical bash call/result, including streams and exit 7.
        const normal = d.used;
        try d.send("command-normal-proof\r");
        try d.waitText(normal, "command-pair-verified");
        try d.waitIdle(normal);
    }
    if (deny) {
        try checkApprovalMarker(init, project);
        const batch = d.used;
        try d.send("!rm -f .ssh/fixture-marker; touch batch-first\r!touch batch-tail\r");
        try d.waitFrame(batch, "Approval #");
        const title = "Approval #";
        const number_start = batch + (std.mem.lastIndexOf(u8, d.output[batch..d.used], title) orelse return error.AcceptanceFailed) + title.len;
        var number_end = number_start;
        while (number_end < d.used and std.ascii.isDigit(d.output[number_end])) : (number_end += 1) {}
        const denied_id = try std.fmt.parseInt(u64, d.output[number_start..number_end], 10);
        const rejected = d.used;
        try d.send("\r");
        try d.waitIdle(rejected);
        try d.quiet(150);
        // The asynchronous denial may redraw the SAME permission while its
        // receipt is pending. It must never create another permission or run
        // the second command in the read batch (also checked by the Node owner).
        var from = rejected;
        while (std.mem.indexOfPos(u8, d.output[0..d.used], from, title)) |at| {
            const begin = at + title.len;
            var end = begin;
            while (end < d.used and std.ascii.isDigit(d.output[end])) : (end += 1) {}
            try check(try std.fmt.parseInt(u64, d.output[begin..end], 10) == denied_id);
            from = end;
        }
        const settled = (try d.acknowledgedScreen(rejected)) orelse return error.AcceptanceFailed;
        if (settled.visible(title)) std.debug.print("denial title still visible\n", .{});
        try check(!settled.visible(title));
        try checkApprovalMarker(init, project);
    }
}

/// 验收入口：从环境变量读取二进制、项目目录、HOME 与测试 URL，创建 PTY 并 fork 启动应用，再按 THIN_APP_TEST_MODE 驱动对应的交互场景。
// Tool-preview fixture handshakes are emitted only after replaying a complete
// cursor-ACK frame. Node keeps the SSE response open until each owned gate.
extern "c" fn access([*:0]const u8, c_int) c_int;

fn previewAbsent(path: [*:0]const u8) !void {
    try check(access(path, 0) == -1 and c._errno().* == @backingInt(c.E.NOENT));
}

fn previewFrame(d: *Driver, a: std.mem.Allocator, start: usize, needle: []const u8, pending: bool, summary: ?[]const u8) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 10000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        const ack = std.mem.lastIndexOf(u8, raw, "\x1b[?25h") orelse continue;
        if (ack < start) continue;
        const complete = raw[0 .. ack + "\x1b[?25h".len];
        view.* = .{ .columns = d.columns };
        try view.replay(complete);
        if (!view.visible(needle)) continue;
        try check(view.count(needle) == 1);
        var matched = false;
        for (0..view.history_len + view.grid.len) |i| {
            const row = if (i < view.history_len) &view.history[i] else &view.grid[i - view.history_len];
            if (std.mem.indexOf(u8, row, needle) == null) continue;
            const line = std.mem.trim(u8, row, " ");
            // Normal tool rows occupy at most floor(80 * .8) cells.
            try check(std.mem.trimEnd(u8, row, " ").len <= 64);
            if (pending and summary == null) try check(std.mem.startsWith(u8, line, "w "));
            matched = true;
        }
        try check(matched);
        if (pending) {
            if (summary) |value| {
                // The remote emitter may reveal the path one tick before the summary
                // lands, so a legal intermediate frame is not a failure.
                if (!view.visible(value)) continue;
                try check(view.visible(value));
                // The first complete generated row owns the full muted SGR;
                // later sparse frames may update only its numeric suffix.
                if (std.mem.eql(u8, needle, "write_file")) {
                    try check(std.mem.indexOf(u8, complete[start..], spinner_theme.muted ++ "w" ++ spinner_theme.muted) != null);
                }
            }
        }
        for ([_][]const u8{ "receiving arguments", "Preparing write", "PREVIEW_RAW_CONTENT_SECRET" }) |hidden|
            try check(std.mem.indexOf(u8, complete, hidden) == null);
        return;
    }
    return error.ToolPreviewFrameTimeout;
}

fn toolPreview(d: *Driver, init: std.process.Init, mode: []const u8, project: []const u8) !void {
    const a = init.arena.allocator();
    const target = try a.dupeSentinel(u8, try std.fs.path.join(a, &.{ project, "preview-owned.txt" }), 0);
    const canceled = std.mem.eql(u8, mode, "tool-preview-cancel");
    try d.waitIdle(0);
    const start = d.used;
    try d.send("preview-task\r");
    try previewFrame(d, a, start, "write_file", true, "+? -? preview");
    try previewAbsent(target);
    std.debug.print("PREVIEW_GATE=header\n", .{});
    // The server now sends an unclosed path. A bounded observation window
    // proves it cannot leak the unreliable partial field into a normal row.
    try d.quiet(200);
    try previewFrame(d, a, start, "write_file", true, "+? -? preview");
    try check(std.mem.indexOf(u8, d.output[start..d.used], "preview-owned") == null);
    try previewAbsent(target);
    std.debug.print("PREVIEW_GATE=partial\n", .{});
    const path_start = d.used;
    try previewFrame(d, a, path_start, "preview-owned.txt", true, "+1 -0 preview");
    try previewAbsent(target);
    std.debug.print("PREVIEW_GATE=path-absent\n", .{});
    // Content is already arriving but the call remains unfinished at this gate.
    try d.quiet(250);
    try previewFrame(d, a, path_start, "preview-owned.txt", true, "+1 -0 preview");
    try previewAbsent(target);
    if (canceled) {
        const cancel_start = d.used;
        try d.send("\x1b");
        try d.waitIdle(cancel_start);
        try previewAbsent(target);
        std.debug.print("PREVIEW_GATE=canceled\n", .{});
    } else {
        std.debug.print("PREVIEW_GATE=finish\n", .{});
        const running = d.used;
        try d.waitFrame(running, "sleep 0.7");
        // A running *tool row*, not the busy composer, must have its warm
        // original bash icon and elapsed time before the owned sleep completes.
        const until = now() + 1500;
        var witnessed = false;
        while (now() < until and !witnessed) {
            try d.drain(10);
            const bytes = d.output[running..d.used];
            for (spinner_theme.tool_icon_pulse) |tone| {
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, bytes, from, tone)) |at| {
                    from = at + tone.len;
                    const end = std.mem.indexOfPos(u8, bytes, from, "\x1b[K") orelse continue;
                    const line = bytes[from..end];
                    if (std.mem.startsWith(u8, line, ">" ++ spinner_theme.muted) and
                        std.mem.indexOf(u8, line, "sleep 0.7") != null and
                        std.mem.indexOf(u8, line, "s\x1b[0m") != null and
                        std.mem.indexOf(u8, bytes[end..], "\x1b[?25h") != null) witnessed = true;
                }
            }
        }
        try check(witnessed);
        try d.waitFrame(start, "preview-final-answer");
        try d.waitIdle(start);
        try check(access(target, 0) == 0);
        try previewFrame(d, a, start, "preview-owned.txt", false, null);
        try previewFrame(d, a, start, "sleep 0.7", false, null);
    }
    for ([_][]const u8{ "receiving arguments", "Preparing write", "PREVIEW_RAW_CONTENT_SECRET", "preview-bash-proof" }) |hidden|
        try check(std.mem.indexOf(u8, d.output[start..d.used], hidden) == null);
    std.debug.print("PREVIEW_GATE=verified\n", .{});
}

// Queued product scenarios deliberately reuse the real fork/PTY/ACK helpers.
// Stage markers contain only fixed fixture names; captured terminal bytes stay
// in the owned project on failure, never in the parent console.
fn queuedFile(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/{s}", .{ project, name }), 0);
    const until = now() + 15000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == @backingInt(c.E.NOENT));
        try d.drain(20);
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedFileDeadline;
}

fn queuedGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    std.debug.print("QUEUED_GATE={s}\n", .{name});
    try queuedFile(d, a, project, try std.fmt.allocPrint(a, "release-{s}", .{name}));
}

// Replay only through the LAST complete cursor ACK, never an in-flight diff.
fn queuedScreen(d: *Driver, a: std.mem.Allocator, since: usize, needles: []const []const u8) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 15000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        if (std.mem.lastIndexOf(u8, raw, "\x1b[?25h")) |ack| {
            if (ack >= since) {
                view.* = .{ .columns = d.columns };
                try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
                var found = true;
                for (needles) |needle| found = found and view.visible(needle);
                if (found) return;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedScreenDeadline;
}

fn queuedKey(d: *Driver, a: std.mem.Allocator, bytes: []const u8, needles: []const []const u8) !void {
    const start = d.used;
    try d.send(bytes);
    try queuedScreen(d, a, start, needles);
}

fn queuedIdle(d: *Driver, a: std.mem.Allocator, since: usize) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 15000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        if (std.mem.lastIndexOf(u8, raw, "\x1b[?25h")) |ack| {
            if (ack >= since) {
                view.* = .{ .columns = d.columns };
                try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
                const row = &view.grid[view.row];
                if (std.mem.indexOf(u8, row, "%> ") != null or std.mem.startsWith(u8, row, "> ")) return;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedIdleDeadline;
}

fn queuedDraft(d: *Driver, a: std.mem.Allocator, text: []const u8) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 15000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        if (std.mem.lastIndexOf(u8, raw, "\x1b[?25h")) |ack| {
            view.* = .{ .columns = d.columns };
            try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
            const row = &view.grid[view.row];
            // Require the ENTIRE acknowledged editor tail, not recalled text
            // still visible in a pending row or an unrelated animation ACK.
            if (std.mem.indexOf(u8, row, ") ")) |prefix| {
                // The context/effort slot now follows the model parentheses.
                // Its final marker is one logical cell (braille replays as ~),
                // then one space; never assume a fixed percentage width.
                const slot_start = prefix + 2;
                if (std.mem.findScalar(u8, row[slot_start..], ' ')) |space| {
                    const slot_end = slot_start + space;
                    if (slot_end > slot_start and (row[slot_end - 1] == '>' or row[slot_end - 1] == '~') and
                        std.mem.eql(u8, std.mem.trimEnd(u8, row[slot_end + 1 ..], " "), text)) return;
                }
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedComposerDeadline;
}

/// Receipt, not activity: `waitBusy` below matches only the renderer's spinner,
/// which is also drawn while an async submit is still pending (draw's `working`
/// includes presentationWaiting) and before acceptance clears the submitted
/// text. This waits instead for a FRESH complete acknowledged frame (cursor
/// ACK, no later partial frame) whose composer row is the actual cursor row and
/// shows the configured model prefix, the busy braille marker and an exactly
/// EMPTY editor tail: the task is accepted and the submitted draft is gone.
fn waitAcceptedBusy(d: *Driver, start: usize) !void {
    const until = now() + 10000;
    while (now() < until) {
        try d.drain(20);
        if (try d.acknowledgedScreen(start)) |view| {
            const row = &view.grid[view.row];
            if (std.mem.indexOf(u8, row, ") ")) |prefix| {
                const slot_start = prefix + 2;
                if (std.mem.findScalar(u8, row[slot_start..], ' ')) |space| {
                    const slot_end = slot_start + space;
                    // The busy braille marker is one cell and replays as '~'.
                    if (slot_end > slot_start and row[slot_end - 1] == '~' and
                        std.mem.trimEnd(u8, row[slot_end + 1 ..], " ").len == 0) return;
                }
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.AcceptedBusyDeadline;
}

// The cursor row is the current editor, not a historical echo. Require a
// complete fresh ACK and the running marker alongside the exact fixture text.
fn selectionBusyFrame(d: *Driver, start: usize, slot: []const u8, draft: []const u8, rejected: bool) !void {
    const until = now() + 10000;
    var seen_fresh_ack = false;
    var last_cursor_row: usize = 0;
    var exact_composer_match = false;
    var has_exact_draft = false;
    var has_expected_rejection_notice = false;
    var has_model_selection_idle_notice = false;
    var has_steering = false;
    var observed_effort_minimal = false;
    var busy_marker_present = false;
    errdefer std.debug.print("SELECTION_FRAME_DIAG seenFreshAck={} lastCursorRow={d} exactComposerMatch={} hasExactDraft={} hasExpectedRejectionNotice={} hasModelSelectionIdleNotice={} hasSteering={} observedEffortMinimal={} busyMarkerPresent={} expectedRejected={}\n", .{ seen_fresh_ack, last_cursor_row, exact_composer_match, has_exact_draft, has_expected_rejection_notice, has_model_selection_idle_notice, has_steering, observed_effort_minimal, busy_marker_present, rejected });
    while (now() < until) {
        try d.drain(20);
        if (try d.acknowledgedScreen(start)) |view| {
            const row = &view.grid[view.row];
            var expected: [128]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&expected, "(fixture-model) {s}~ {s}", .{ slot, draft });
            const trimmed = std.mem.trimEnd(u8, row, " ");
            seen_fresh_ack = true;
            last_cursor_row = view.row;
            exact_composer_match = std.mem.eql(u8, trimmed, std.mem.trimEnd(u8, prefix, " "));
            has_exact_draft = if (std.mem.indexOf(u8, row, ") ")) |at| blk: {
                const remainder = row[at + 2 ..];
                const space = std.mem.indexOfScalar(u8, remainder, ' ') orelse break :blk false;
                break :blk std.mem.eql(u8, std.mem.trimEnd(u8, remainder[space + 1 ..], " "), draft);
            } else false;
            has_expected_rejection_notice = view.visible("Only ordinary conversation text can be queued");
            has_model_selection_idle_notice = view.visible("Model selection requires an idle, non-pasted session");
            has_steering = view.visible("Steering pending");
            observed_effort_minimal = std.mem.indexOf(u8, row, "(fixture-model) minimal") != null;
            busy_marker_present = std.mem.indexOf(u8, row, "~ ") != null;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, row, " "), std.mem.trimEnd(u8, prefix, " ")) and
                (!rejected or view.visible("Only ordinary conversation text can be queued")))
            {
                try check(!view.visible("Steering pending"));
                return;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.SelectionBusyFrameDeadline;
}

fn queuedScenario(d: *Driver, init: std.process.Init, mode: []const u8, project: []const u8) !void {
    const a = init.arena.allocator();
    errdefer {
        const path = std.fmt.allocPrint(a, "{s}/queued-pty.log", .{project}) catch unreachable;
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = d.output[0..d.used] }) catch {};
    }
    const steer = std.mem.eql(u8, mode, "test-queued-steer");
    const withdraw = std.mem.eql(u8, mode, "test-queued-withdraw");
    const cancel = std.mem.eql(u8, mode, "test-queued-cancel");
    const natural = std.mem.eql(u8, mode, "test-queued-natural");
    try check(steer or withdraw or cancel or natural);
    try d.waitIdle(0);
    const start = d.used;
    try d.send("queued-start\r");
    if (withdraw) {
        try queuedScreen(d, a, start, &.{"queued-held"});
    } else {
        // A tool caption/argument preview is NOT execution evidence.
        try queuedFile(d, a, project, "started");
        if (natural) try queuedFile(d, a, project, "natural-awaiting");
        try d.waitBusy(start);
    }
    try queuedKey(d, a, "keep-steer\r", &.{"Steering pending #1: keep-steer"});
    try queuedDraft(d, a, "");
    try queuedKey(d, a, if (withdraw) "old-follow\x1b\r" else "keep-follow\x1b\r", &.{if (withdraw) "FollowUp pending #2: old-follow" else "FollowUp pending #2: keep-follow"});
    try queuedDraft(d, a, "");
    if (withdraw) {
        try queuedKey(d, a, "\x1b", &.{"old-follow"});
        try queuedDraft(d, a, "old-follow");
        try queuedGate(d, a, project, "withdrawn-follow");
        // Retyping after Ctrl-U and Enter creates a NEW Steering message.
        try queuedKey(d, a, "\x15new-steer\r", &.{"Steering pending #3: new-steer"});
        try queuedDraft(d, a, "");
        try queuedKey(d, a, "\x1b", &.{"new-steer"});
        try queuedDraft(d, a, "new-steer");
        // And a second recall can freely switch back to FollowUp.
        try queuedKey(d, a, "\x15new-follow\x1b\r", &.{"FollowUp pending #4: new-follow"});
        try queuedDraft(d, a, "");
    }
    if (steer or withdraw) {
        try queuedGate(d, a, project, "queued");
        try queuedScreen(d, a, start, &.{"queued-follow-answer"});
        try queuedIdle(d, a, start);
        try queuedGate(d, a, project, "done");
    } else {
        try queuedKey(d, a, "preserved-draft", &.{"preserved-draft"});
        // Opening drops the whole read tail: neither repetition nor Enter can
        // approve. The fresh replay must still show the safe default.
        try queuedKey(d, a, "\x03\x03\r", &.{"> Continue"});
        const confirmation = try a.create(regular.Screen);
        defer a.destroy(confirmation);
        try approvalCancelScreen(d, confirmation);
        try checkConfirmationRow(confirmation, "Task running", "> Continue", "Stop and clear");
        try check(confirmation.visible("Steering pending #1: keep-steer"));
        try check(confirmation.visible("FollowUp pending #2: keep-follow"));
        try queuedGate(d, a, project, "modal-default");
        // Each probe must cause an observable safe-selection transition.
        // Consecutive writes are NOT application read boundaries: without
        // these semantic ACKs a stop_feed tail could discard the later Esc.
        try queuedKey(d, a, "\x1b[B", &.{"> Stop and clear"});
        try queuedKey(d, a, "\x03\x03\r", &.{"> Continue"});
        try queuedKey(d, a, "\x1b[B", &.{"> Stop and clear"});
        try queuedKey(d, a, "\x1b[200~\r\x03\x1b[201~", &.{"> Continue"});
        try queuedKey(d, a, "\x1b", &.{ "Steering pending #1: keep-steer", "FollowUp pending #2: keep-follow", "preserved-draft" });
        try queuedDraft(d, a, "preserved-draft");
        try queuedGate(d, a, project, "modal-dismissed");
        try queuedKey(d, a, "\x03", &.{"> Continue"});
        if (natural) {
            const natural_start = d.used;
            // Node releases the already-in-flight final response after this ACK.
            try queuedGate(d, a, project, "natural-release");
            try queuedScreen(d, a, natural_start, &.{ "queued-natural-answer", "Task ended", "> Continue" });
            try approvalCancelScreen(d, confirmation);
            try checkConfirmationRow(confirmation, "Task ended", "> Continue", "Stop and clear");
            try queuedGate(d, a, project, "natural-finished");
        }
        // Selection and Enter in one read must NOT approve. One write is not
        // one read: the leading Up/Down may be ACKed alone while the trailing
        // Enter stays queued, so an intermediate dangerous ACK can precede that
        // tail Enter's safe reset. Therefore explicitly reselect safe and then
        // danger as separate semantic ACKs, and only trust the independent
        // Enter after the latest complete dangerous-option ACK.
        try queuedKey(d, a, "\x1b[B\r", &.{"> Stop and clear"});
        try queuedGate(d, a, project, "selected-not-approved");
        try queuedKey(d, a, "\x1b[A", &.{"> Continue"});
        try queuedKey(d, a, "\x1b[B", &.{"> Stop and clear"});
        const stop_start = d.used;
        try d.send("\r");
        try queuedIdle(d, a, stop_start);
        try queuedDraft(d, a, "preserved-draft");
        const cleared_view = try a.create(regular.Screen);
        defer a.destroy(cleared_view);
        cleared_view.* = .{ .columns = d.columns };
        const cleared_raw = d.output[0..d.used];
        const cleared_ack = std.mem.lastIndexOf(u8, cleared_raw, "\x1b[?25h").?;
        try cleared_view.replay(cleared_raw[0 .. cleared_ack + "\x1b[?25h".len]);
        for ([_][]const u8{ "keep-steer", "keep-follow", "> Continue", "> Stop and clear" }) |text| try check(!cleared_view.visible(text));
        try queuedGate(d, a, project, "cleared");
        // A fresh explicit task proves stale confirmation cannot cancel a new
        // epoch. No queued message is allowed to sneak ahead of this probe.
        const probe_start = d.used;
        try d.send("\x15after-clear\r");
        try queuedScreen(d, a, probe_start, &.{"queued-probe-answer"});
        try queuedIdle(d, a, probe_start);
        try queuedGate(d, a, project, "done");
    }
    try d.send("\x04");
    try d.finish(0);
}

// Concrete entrypoints exported to the standalone dispatcher/build root.
pub fn testQueuedSteer(init: std.process.Init) !void {
    try main(init);
}
pub fn testQueuedWithdraw(init: std.process.Init) !void {
    try main(init);
}
pub fn testQueuedCancel(init: std.process.Init) !void {
    try main(init);
}
pub fn testQueuedNatural(init: std.process.Init) !void {
    try main(init);
}

/// Deterministic test-only capture fixtures; no PTY, child or product clock.
fn selfAppend(d: *Driver, bytes: []const u8) !void {
    try check(d.used + bytes.len <= d.output.len);
    @memcpy(d.output[d.used..][0..bytes.len], bytes);
    d.used += bytes.len;
}

fn selfCapture(d: *Driver, parts: []const []const u8) !void {
    d.used = 0;
    d.effort_witness = null;
    for (parts) |part| try selfAppend(d, part);
}

fn selfEffortReady(d: *Driver, start: usize, allow_normal: bool) !bool {
    var scanner: ?FrameScanner = null;
    defer if (scanner) |*s| s.deinit();
    return try d.effortIdleReady(start, "fixture-model", "low", allow_normal, &scanner);
}

fn frameSelfCheck() !void {
    const d = try std.heap.page_allocator.create(Driver);
    defer std.heap.page_allocator.destroy(d);
    d.* = .{ .master = -1, .slave = -1, .pid = -1, .owned = false, .original = undefined, .flags = 0, .screens = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer d.screens.deinit();
    const prefix = frame_begin ++ "\r\x1b[2K";
    const suffix = frame_end ++ frame_ack;
    const normal = prefix ++ "(\x1b[38;5;114mfixture-model\x1b[0m\x1b[1m) \x1b[0m\x1b[1m?%\x1b[0m\x1b[1m>\x1b[0m " ++ suffix;
    const low = prefix ++ "(\x1b[38;5;114mfixture-model\x1b[0m\x1b[1m) \x1b[38;5;114mlow\x1b[0m\x1b[1m>\x1b[0m " ++ suffix;
    const wrong_color = prefix ++ "(\x1b[38;5;75mfixture-model\x1b[0m\x1b[1m) \x1b[38;5;75mlow\x1b[0m\x1b[1m>\x1b[0m " ++ suffix;
    const high = prefix ++ "(fixture-model) high> " ++ suffix;

    // Every nonempty split of sync-begin invalidates the old ACK; only the
    // next complete fresh frame may restore it.
    for (1..frame_begin.len + 1) |n| {
        try selfCapture(d, &.{ normal, low[0..n] });
        try check((try d.acknowledgedScreen(0)) == null);
        try selfAppend(d, low[n..]);
        const view = (try d.acknowledgedScreen(normal.len)) orelse return error.SelfCheckMissingAck;
        try check(composerKind(view, "fixture-model", "low", false) == .effort);
    }

    // Exact prompt suffix + cursor, not trimEnd: typed spaces, a multi-character
    // draft and a cursor moved before the draft must never count as empty.
    for ([_][]const u8{
        prefix ++ "(fixture-model) low>  " ++ suffix,
        prefix ++ "(fixture-model) low>   " ++ suffix,
        prefix ++ "(fixture-model) low> draft" ++ suffix,
        prefix ++ "(fixture-model) low> draft\r\x1b[21C" ++ suffix,
        prefix ++ "(fixture-model) low> \r\x1b[20C" ++ suffix,
    }) |bad| {
        try selfCapture(d, &.{bad});
        const view = (try d.acknowledgedScreen(0)) orelse return error.SelfCheckMissingAck;
        try check(composerKind(view, "fixture-model", "low", false) == .none);
    }
    try selfCapture(d, &.{low});
    const view = (try d.acknowledgedScreen(0)) orelse return error.SelfCheckMissingAck;
    view.wrap = true;
    try check(composerKind(view, "fixture-model", "low", false) == .none);

    const valid = [_][]const u8{ "?%", "0.0%", "9.0%", "99.9%", "100.0%", ">100%" };
    const invalid = [_][]const u8{ "9%", "999.999%", "100.1%", "101.0%", "00.0%", "-1.0%", "+1.0%", "1e1%", "NaN%", "1.2.3%", "x9.0%", "9.0%x", "9.0L%", "L9.0%" };
    var buffer: [256]u8 = undefined;
    for (valid ++ invalid, 0..) |label, i| {
        const bytes = try std.fmt.bufPrint(&buffer, "{s}(fixture-model) {s}> {s}", .{ prefix, label, suffix });
        try selfCapture(d, &.{bytes});
        const current = (try d.acknowledgedScreen(0)) orelse return error.SelfCheckMissingAck;
        try check((composerKind(current, "fixture-model", "low", false) == .normal) == (i < valid.len));
    }
    try check(normalLabel("L9.0%", true) and normalLabel("L?%", true) and normalLabel("L>100%", true));
    try check(!normalLabel("9.0L%", true) and !normalLabel("9.0%", true) and !normalLabel("LL9.0%", true));
    try selfCapture(d, &.{prefix ++ "(fixture-model) L9.0%> " ++ suffix});
    const marked = (try d.acknowledgedScreen(0)) orelse return error.SelfCheckMissingAck;
    try check(composerKind(marked, "fixture-model", "low", true) == .normal);
    try check(composerKind(marked, "fixture-model", "low", false) == .none);
    try selfCapture(d, &.{prefix ++ "(fixture-model) Llow> " ++ suffix});
    const marked_effort = (try d.acknowledgedScreen(0)) orelse return error.SelfCheckMissingAck;
    try check(composerKind(marked_effort, "fixture-model", "low", true) == .effort);
    try check(composerKind(marked_effort, "fixture-model", "low", false) == .none);

    // One drain can deliver both the actual flash and its expiry. Historical
    // ACKs, a wrong effort, and a partial frame cannot stand in for the flash.
    try selfCapture(d, &.{ normal, low, normal });
    try check(try selfEffortReady(d, normal.len, false));
    try settingsColor(d, normal.len, "low");
    try selfCapture(d, &.{ normal, normal });
    try check(!(try selfEffortReady(d, normal.len, false)));
    try check(try selfEffortReady(d, normal.len, true)); // post-reply only
    try selfCapture(d, &.{ low, normal });
    try check(!(try selfEffortReady(d, low.len, false)));
    try selfCapture(d, &.{ low, frame_begin ++ suffix }); // Fresh ACK, unchanged old effort.
    try check(!(try selfEffortReady(d, low.len, false)));
    try selfCapture(d, &.{ normal, high, normal });
    try check(!(try selfEffortReady(d, normal.len, false)));
    try selfCapture(d, &.{ normal, low[0 .. low.len - suffix.len] });
    try check(!(try selfEffortReady(d, normal.len, false)));
    try selfCapture(d, &.{ normal, prefix ++ "(other-model) low> " ++ suffix, normal });
    try check(!(try selfEffortReady(d, normal.len, false)));
    // A scanner reused across drains advances rather than replaying prefixes.
    try selfCapture(d, &.{ normal, normal });
    var incremental: ?FrameScanner = null;
    defer if (incremental) |*s| s.deinit();
    try check(!(try d.effortIdleReady(normal.len, "fixture-model", "low", false, &incremental)));
    try selfAppend(d, low ++ normal);
    try check(try d.effortIdleReady(normal.len, "fixture-model", "low", false, &incremental));
    try selfCapture(d, &.{ normal, wrong_color, normal });
    try check(try selfEffortReady(d, normal.len, false));
    var color_failed = false;
    settingsColor(d, normal.len, "low") catch |err| {
        if (err != error.SettingsColorMismatch) return err;
        color_failed = true;
    };
    try check(color_failed);
}

/// 入口：先创建本驱动独占的短运行时目录，再运行验收主体。主体返回后，只有在
/// 该目录下的 worker 端点都不再接受连接时才删除目录。
pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("THIN_PTY_SELF_CHECK")) |value| {
        try check(std.mem.eql(u8, value, "1"));
        try frameSelfCheck();
        std.debug.print("PTY_FRAME_SELF_CHECK=ok\n", .{});
        return;
    }
    // 前台实例会为自己启动 AF_UNIX worker，其 socket 位于
    // `$XDG_RUNTIME_DIR/thin/workers/<instance>.sock`。未设置时产品会回落到共享的
    // `/tmp/thin-<uid>`；因此这里在 fork 之前创建本驱动独占的短绝对运行时目录。
    // mkdtemp 已给出 0700 且属于本 UID 的真实目录，正是产品要求的形态。
    var runtime_buf: [32]u8 = undefined;
    const runtime_template = "/tmp/tn-XXXXXX";
    @memcpy(runtime_buf[0..runtime_template.len], runtime_template);
    runtime_buf[runtime_template.len] = 0;
    const runtime_z = mkdtemp(runtime_buf[0..runtime_template.len :0].ptr) orelse return error.RuntimeDirectoryNotCreated;
    const runtime_path = std.mem.span(runtime_z);
    // 最长实际路径为 <base>/thin/workers/<32 hex>.sock；保守按 14+32+5 预留 AF_UNIX 上限。
    try check(std.fs.path.isAbsolute(runtime_path));
    try check(runtime_path.len + 14 + 32 + 5 <= 107);
    const runtime_stat = try std.Io.Dir.cwd().statFile(init.io, runtime_path, .{});
    try check(@backingInt(runtime_stat.permissions) & 0o777 == 0o700);

    const body_result: anyerror!void = runBody(init, runtime_path);
    // worker 由 process.run 放入独立 process group：直属子进程被 kill/reap、
    // PDEATHSIG 的 TERM 都是异步清理，因此不能靠 defer 顺序断言 worker 已退出。
    // 删除目录前必须观察到这些 socket 不再接受连接。Thin 正常结束会自己 join
    // 全部 worker，所以快路径立即完成；超时则显式失败并保留目录用于取证。
    waitWorkersGone(init, runtime_path) catch |err| {
        std.debug.print("PTY_RUNTIME_KEPT {s}\n", .{runtime_path});
        return err;
    };
    try std.Io.Dir.cwd().deleteTreeMinStackSize(init.io, runtime_path);
    return body_result;
}

/// 有界等待本驱动 runtime 下的 worker 端点全部消失。只读自己的目录、只做连接
/// 探测：不扫描系统、不发任何 PID 信号，也不把超时当成功。
fn waitWorkersGone(init: std.process.Init, runtime: []const u8) !void {
    const a = init.arena.allocator();
    const workers = try std.fmt.allocPrint(a, "{s}/thin/workers", .{runtime});
    const until = now() + 10_000;
    while (true) {
        var live: usize = 0;
        scan: {
            var dir = std.Io.Dir.cwd().openDir(init.io, workers, .{ .iterate = true }) catch |err| switch (err) {
                // 没有 worker 目录即代表本次运行从未启动 worker。
                error.FileNotFound, error.NotDir => break :scan,
                else => return err,
            };
            defer dir.close(init.io);
            var it = dir.iterateAssumeFirstIteration();
            while (try it.next(init.io)) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
                const endpoint = try std.fmt.allocPrint(a, "{s}/{s}", .{ workers, entry.name });
                if (try endpointAccepts(init, endpoint)) live += 1;
            }
        }
        if (live == 0) return;
        if (now() >= until) return error.WorkerEndpointsStillLive;
        // fd 为 -1 的 pollfd 会被忽略，这里充当 5 毫秒有界让步。
        var idle = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = c.poll(&idle, 1, 5);
    }
}

/// 单个端点是否仍接受连接；拒绝或已消失即视为该 worker 已退出。
fn endpointAccepts(init: std.process.Init, path: []const u8) !bool {
    const address = try std.Io.net.UnixAddress.init(path);
    const stream = std.Io.net.UnixAddress.connect(&address, init.io) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => return false,
        else => return err,
    };
    stream.close(init.io);
    return true;
}

fn runBody(init: std.process.Init, runtime_path: []const u8) !void {
    const a = init.arena.allocator();
    const bin = try a.dupeSentinel(u8, try required(init, "THIN_APP_BIN"), 0);
    const project = try a.dupeSentinel(u8, try required(init, "THIN_APP_TEST_PROJECT"), 0);
    const home = try required(init, "THIN_APP_TEST_HOME");
    const url = try required(init, "THIN_APP_TEST_URL");

    // 测试 URL 必须指向本机 127.0.0.1 的 http 地址，且不能带 userinfo/query/fragment，防止测试误连外部服务。
    const uri = try std.Uri.parse(url);
    const host = uri.host orelse return error.UnsafeFixtureUrl;
    const host_text = switch (host) {
        .raw, .percent_encoded => |value| value,
    };
    try check(std.mem.eql(u8, uri.scheme, "http") and std.mem.eql(u8, host_text, "127.0.0.1") and uri.port != null and uri.port != 0 and uri.user == null and uri.password == null and uri.query == null and uri.fragment == null);
    try check(std.fs.path.isAbsolute(bin) and std.fs.path.isAbsolute(project) and std.fs.path.isAbsolute(home));

    // HOME 必须与进程环境中的 HOME 一致，保证应用读取的是测试目录。
    try check(std.mem.eql(u8, home, try required(init, "HOME")));

    const mode = try required(init, "THIN_APP_TEST_MODE");
    const home_env = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "HOME={s}", .{home}), 0);

    const full_resume = std.mem.startsWith(u8, mode, "resume-") and !std.mem.eql(u8, mode, "resume-create");
    const restore_error: ?[]const u8 = if (std.mem.eql(u8, mode, "restore-failure") or std.mem.eql(u8, mode, "resume-failure")) try required(init, "THIN_APP_TEST_RESTORE_ERROR") else null;
    if (restore_error) |expected| {
        try check(std.mem.eql(u8, expected, "SelectionNotFound") or std.mem.eql(u8, expected, "ApiKeyNotFound") or std.mem.eql(u8, expected, "SelectionEndpointUnavailable") or std.mem.eql(u8, expected, "ResumeNotFound") or std.mem.eql(u8, expected, "ResumeAuthenticationFailed") or std.mem.eql(u8, expected, "ResumeConflict") or std.mem.eql(u8, expected, "ResumeNotClosed") or std.mem.eql(u8, expected, "UnsupportedVersion") or std.mem.eql(u8, expected, "SessionInUse") or std.mem.eql(u8, expected, "InvalidResumeLength") or std.mem.eql(u8, expected, "InvalidJson"));
    }
    const restore_mode = std.mem.eql(u8, mode, "restore-selection") or std.mem.eql(u8, mode, "restore-idle") or std.mem.eql(u8, mode, "restore-no-key") or std.mem.eql(u8, mode, "restore-failure");
    // All child environment bytes are prepared before fork; missing-key case
    // terminates the env array before the fixture key, never inheriting HOME.
    const timezone = init.environ_map.get("THIN_APP_TEST_TZ") orelse "UTC0";
    try check(std.mem.eql(u8, timezone, "UTC0") or std.mem.eql(u8, timezone, "UTC-8"));
    const timezone_env = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "TZ={s}", .{timezone}), 0);

    const runtime_env = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "XDG_RUNTIME_DIR={s}", .{runtime_path}), 0);

    const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", home_env, "LANG=C.UTF-8", "TERM=xterm-256color", timezone_env, runtime_env, if (std.mem.eql(u8, mode, "resume-login") or std.mem.eql(u8, mode, "restore-no-key") or (restore_error != null and std.mem.eql(u8, restore_error.?, "ApiKeyNotFound"))) null else "THIN_FIXTURE_KEY=fixture-secret-never-log" };

    const interactive_argv = [_:null]?[*:0]const u8{ bin, "--no-model-auto-refresh" };
    const print_argv = [_:null]?[*:0]const u8{ bin, "--print", "large-output" };
    const restore_id = try a.dupeSentinel(u8, if (restore_mode or full_resume) try required(init, "THIN_APP_TEST_RESTORE_ID") else "", 0);
    const restore_argv = [_:null]?[*:0]const u8{ bin, "--restore-selection", restore_id };
    const resume_argv = [_:null]?[*:0]const u8{ bin, "--resume", restore_id };
    // output 模式直接执行 --print 大输出；其余模式启动交互式界面。
    const argv: [*:null]const ?[*:0]const u8 = if (full_resume) &resume_argv else if (restore_mode) &restore_argv else if (std.mem.eql(u8, mode, "output")) &print_argv else &interactive_argv;

    var master: c_int = undefined;
    var slave: c_int = undefined;

    var size = std.mem.zeroes(c.winsize);
    size.col = if (std.mem.startsWith(u8, mode, "settings-command-") and !std.mem.eql(u8, mode, "settings-command-stable")) 160 else 80;
    size.row = 24;

    // Darwin revokes a controlling PTY when its session leader exits. The
    // disposable DRIVER, not Thin, must own this session through finish().
    // Node must launch it detached:true with piped/non-TTY stdin and stdout.
    // Refuse an attached invocation BEFORE acquiring any controlling terminal.
    var ignore_action = std.mem.zeroes(c.Sigaction);
    var default_action = std.mem.zeroes(c.Sigaction);
    if (darwin) {
        if (builtin.cpu.arch != .x86_64) return error.IntelDarwinFixtureRequired;
        if (getsid(0) != c.getpid() or c.isatty(0) == 1 or c.isatty(1) == 1)
            return error.DetachedNonTtyDriverRequired;
        ignore_action.handler = .{ .handler = c.SIG.IGN };
        default_action.handler = .{ .handler = c.SIG.DFL };
        try check(c.sigemptyset(&ignore_action.mask) == 0);
        try check(c.sigemptyset(&default_action.mask) == 0);
        // Keep HUP ignored until process exit, including all PTY close/error
        // paths. Thin resets it below, so product signal behavior is unchanged.
        try check(c.sigaction(.HUP, &ignore_action, null) == 0);
        try check(c.sigaction(.TTOU, &ignore_action, null) == 0);
    }

    // 创建 PTY 对，初始窗口尺寸为 80x24。
    try check(openpty(&master, &slave, null, null, &size) == 0);

    // handed_off 为 false 时由 errdefer 关闭 fd；一旦交给 Driver，所有权转移，由 Driver.deinit 负责。
    var handed_off = false;
    errdefer if (!handed_off) {
        _ = c.close(master);
        _ = c.close(slave);
    };

    // Only this just-created slave may become the driver's controlling TTY.
    // Retain both original descriptors until Thin exits and finish verifies
    // restoration; reopening a revoked slave would produce false evidence.
    if (darwin) try check(c.ioctl(slave, @as(c_int, 0x20007461), @as(c_int, 0)) == 0);

    var original: abi.Termios = undefined;
    try check(abi.tcgetattr(slave, &original) == 0);
    const flags = c.fcntl(slave, c.F.GETFL);
    try check(flags >= 0);

    // Target O_NONBLOCK, preserving all other master file status flags.
    const master_flags = c.fcntl(master, c.F.GETFL);
    try check(master_flags >= 0);
    const nonblock: c_int = @intCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    try check(c.fcntl(master, c.F.SETFL, master_flags | nonblock) == 0);

    // Seed pre-existing terminal OUTPUT through the owned slave, never master
    // input. --print backpressure must wait for genuine application stdout.
    if (!std.mem.eql(u8, mode, "output")) {
        const seed = regular.prior ++ "\r\n";
        try check(c.write(slave, seed.ptr, seed.len) == seed.len);
    }

    // fork 之后子进程只能调用 async-signal-safe 的 libc 函数。
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Async-signal-safe libc ONLY; all strings/argv/env prepared before fork.
        _ = c.close(master);
        if (darwin) {
            // Do not setsid: the driver must outlive Thin's controlling session.
            // A background group's tcsetpgrp would stop on SIGTTOU unless ignored.
            if (c.sigaction(.TTOU, &ignore_action, null) != 0) _exit(120);
            if (c.setpgid(0, 0) != 0) _exit(120);
            if (tcsetpgrp(slave, c.getpid()) != 0) _exit(121);
            if (c.sigaction(.TTOU, &default_action, null) != 0) _exit(120);
            if (c.sigaction(.HUP, &default_action, null) != 0) _exit(120);
        } else {
            // Linux keeps its original child-owned session/TIOCSCTTY path.
            if (setsid() < 0) _exit(120);
            if (c.ioctl(slave, @as(c_int, 0x540e), @as(c_int, 0)) < 0) _exit(121);
        }
        // 将 slave 复制到 stdin/stdout/stderr。
        if (dup2(slave, 0) < 0 or dup2(slave, 1) < 0 or dup2(slave, 2) < 0) _exit(122);
        if (slave > 2) _ = c.close(slave);
        if (chdir(project) != 0) _exit(123);
        // execve 成功不会返回；返回则说明失败，以 124 退出，由父进程的 waitText/finish 发现。
        _ = execve(bin, argv, &env);
        _exit(124);
    }

    // Transfer PID AND fds before any fallible parent group/foreground setup:
    // even a setup failure must kill/reap this exact child within two seconds.
    var d = Driver{ .master = master, .slave = slave, .pid = pid, .original = original, .flags = flags, .columns = size.col, .screens = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    handed_off = true;
    defer d.deinit();

    // 父进程安装 SIGTERM 与 SIGINT 处理器，使驱动在收到外部中断时能中止等待并清理子进程。
    _ = signal(@backingInt(c.SIG.TERM), onSignal);
    _ = signal(@backingInt(c.SIG.INT), onSignal);

    if (darwin) {
        // Both sides establish the same group/foreground to close scheduling
        // races. An already-exec'd child may reject setpgid (EACCES), but its
        // exact owned group must still be verified before proceeding.
        if (c.setpgid(pid, pid) != 0) try check(getpgid(pid) == pid);
        try check(tcsetpgrp(slave, pid) == 0);
    }

    if (std.mem.eql(u8, mode, "output")) {
        // A slow output consumer must not trap the installed signal handler.
        // Wait for first output without reading, then leave this owned PTY full.
        var readable = [_]c.pollfd{.{ .fd = master, .events = 1, .revents = 0 }};
        try check(c.poll(&readable, 1, 10000) > 0);

        // 短暂停顿，确保子进程已因 PTY 缓冲区写满而阻塞在 write 上。
        var pause = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = c.poll(&pause, 1, 150);

        // 在子进程阻塞写入时发送 SIGINT，验证取消路径不会被未读取的输出卡住。
        try check(d.owned and kill(d.pid, @backingInt(c.SIG.INT)) == 0);
        const until = now() + 2000;
        // 循环非阻塞回收，最长等待 2 秒；超时则报告取消超时。
        while (d.owned and now() < until) {
            const result = waitpid(pid, &d.status, c.W.NOHANG);
            if (result == pid) d.owned = false;
            if (result < 0 and c._errno().* != @backingInt(c.E.INTR)) {
                if (c._errno().* == @backingInt(c.E.CHILD)) d.owned = false;
                return error.WaitFailed;
            }
            if (d.owned) _ = c.poll(&pause, 1, 5);
        }
        if (d.owned) return error.OutputCancellationTimeout;

        // 期望退出码 130（128 + SIGINT）。
        try d.finish(130);
        return;
    }

    // A startup refusal before task admission must fail closed: the owned
    // child never reaches a composer, so finish on the real child and check its
    // exit/termios cleanup rather than waiting for banner or idle.
    if (std.mem.eql(u8, mode, "log-owner-refused")) {
        try d.finish(1);
        const output = d.output[0..d.used];
        // Client.run 的固定前缀：拿不到执行锁时拒绝启动前台会话。
        try check(std.mem.indexOf(u8, output, "thin: could not start the session worker") != null);
        try check(std.mem.indexOf(u8, output, "thin --resume ") == null);
        // Same early-shaped refusal as restore-error: no raw mode, no frame.
        try check(std.mem.indexOfScalar(u8, output, 0x1b) == null);
        return;
    }

    // Startup refusals precede raw mode and the first frame. Check their exit
    // directly; waiting for a composer would mistake correct refusal for EOF.
    if (restore_error) |expected| {
        try d.finish(1);
        const message = try std.fmt.allocPrint(a, "thin: {s}", .{expected});
        try check(std.mem.indexOf(u8, d.output[0..d.used], message) != null);
        try check(std.mem.indexOfScalar(u8, d.output[0..d.used], 0x1b) == null);
        return;
    }
    // The first owned frame establishes a blank viewport with the composer at
    // the bottom, without an automatic banner. Readiness is a fresh acknowledged
    // idle composer, not version text. Keep the original 10s startup budget and
    // report only fixed refusal identifiers.
    const startup_until = now() + 10000;
    d.waitIdleUntil(0, startup_until) catch |err| {
        if (!d.owned) std.debug.print("error: ChildStatus{d}\n", .{d.status});
        // Only fixed identifiers from our owned child, never captured content.
        for ([_][]const u8{ "InvalidConfig", "UnknownField", "DefaultModelUnavailable", "UnknownInputPriceThreshold", "InvalidProvider", "InvalidModel", "NotDir", "SymlinkNotAllowed", "SpawnFailed", "CleanupFailed", "ParentGone", "MissingOwnerFd", "InvalidOwnerFd", "MissingOwnerPid", "PeerPidMismatch", "PeerUidMismatch", "PeerCredentialsUnavailable", "TtyRequired", "ForegroundRequired", "AccessDenied", "FileNotFound", "NameTooLong", "InvalidPath", "DirectoryMoved", "InsecureRuntimeBase", "IdentityChanged", "SocketPathTooLong", "Timeout" }) |code| {
            if (std.mem.indexOf(u8, d.output[0..d.used], code) != null) std.debug.print("error: {s}\n", .{code});
        }
        return err;
    };
    // A resumed conversation may raise an owned notice row above the composer;
    // other starts have only the composer and an optional single hint row.
    if (!full_resume) {
        const clamp = std.mem.eql(u8, mode, "settings-clamp-high") or std.mem.eql(u8, mode, "settings-clamp-low");
        const expected_notice: ?[]const u8 = if (clamp)
            "Saved thinking level adjusted for this model; preference unchanged"
        else if (std.mem.eql(u8, mode, "restore-selection") or std.mem.eql(u8, mode, "restore-idle"))
            "Selection restored; NEW EMPTY CHAT (history not restored)"
        else
            null;
        if (expected_notice) |notice| {
            var ready = false;
            while (now() < startup_until) {
                try d.drain(20);
                const at = std.mem.indexOf(u8, d.output[0..d.used], notice);
                if (at) |notice_at| {
                    if (try d.acknowledgedScreen(notice_at + notice.len)) |startup| {
                        if (startup.visible(notice)) {
                            try Driver.checkStartupNoticeFootprint(startup, notice);
                            ready = true;
                            break;
                        }
                    }
                }
                if (!d.owned) return error.EarlyExit;
            }
            if (!ready) return error.VisibleTextTimeout;
        } else {
            const startup = (try d.acknowledgedScreen(0)) orelse return error.MissingStartupFrame;
            try Driver.checkStartupFootprint(startup);
        }
    }
    // The removed banner was the only startup version/directory text. Its
    // absence is part of the first-screen contract, not a frozen caption.
    try check(std.mem.indexOf(u8, d.output[0..d.used], @import("../app/version.zig").text) == null);
    if (std.mem.startsWith(u8, mode, "test-queued-")) {
        try queuedScenario(&d, init, mode, project);
        return;
    }
    if (std.mem.eql(u8, mode, "auth-missing") or std.mem.eql(u8, mode, "auth-empty")) {
        // A generated disk default is not an activated selection. Do not enter
        // a key or submit a prompt: no public endpoint may be contacted.
        try d.waitText(0, "/login");
        // The warning owns exactly one row immediately before the first input
        // row, both at startup and after an acknowledged menu close.
        const initial = (try d.acknowledgedScreen(0)) orelse return error.MissingStartupFrame;
        const history_before = initial.history_len;
        try Driver.checkComposerTail(initial);
        try check(initial.row >= 1 and std.mem.indexOf(u8, &initial.grid[initial.row - 1], "Not configured:") != null);
        try check(initial.count("Not configured:") == 1);
        for (0..2) |_| {
            const opened = d.used;
            try d.send("/");
            try d.waitVisibleFrame(opened, "/model");
            const closed = d.used;
            try d.send("\x7f");
            try d.waitVisibleFrame(closed, "Not configured:");
            const view = (try d.acknowledgedScreen(closed)) orelse return error.MissingStartupFrame;
            try Driver.checkComposerTail(view);
            try check(view.row >= 1 and std.mem.indexOf(u8, &view.grid[view.row - 1], "Not configured:") != null);
            try check(view.count("Not configured:") == 1);
            try check(view.history_len == history_before and view.count(regular.prior) == 1);
        }
        const pending = try d.screen();
        try check(pending.visible("/model"));
        try check(!pending.visible("deepseek-flash") and !pending.visible("?%"));
        try check(std.mem.startsWith(u8, &pending.grid[pending.row], "> "));
        var start = d.used;
        try d.send("/model\r");
        try d.waitFrame(start, "No logged-in providers");
        const no_providers = try d.screen();
        try check(no_providers.visible("Search> ") and !no_providers.visible("Provider> ") and !no_providers.visible("deepseek-flash"));
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/login\r");
        try d.waitFrame(start, "Provider> ");
        const login = try d.screen();
        try check(login.visible("DeepSeek") and login.visible("OpenCode Zen") and login.visible("OpenCode Go"));
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "manual-compact")) {
        var start = d.used;
        try d.send("manual-first\r");
        try d.waitText(start, "manual-first-answer");
        try d.waitIdle(start);
        start = d.used;
        try d.send("manual-second\r");
        try d.waitText(start, "manual-second-answer");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/comp");
        try d.waitFrame(start, "/compact  Compact conversation");
        start = d.used;
        try d.send("\r");
        try d.waitText(start, "Context compacted:");
        try d.waitIdle(start);
        const compacted = try d.screen();
        try check(compacted.visible("Context compacted:"));
        try check(!compacted.visible("Unknown command"));
    } else if (std.mem.eql(u8, mode, "read-error")) {
        const start = d.used;
        try d.send("read-missing\r");
        try d.waitFrame(start, "[error] FileNotFound: file not found");
        try d.waitText(start, "read-error-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "menu-navigation")) {
        // Offline only: no message or credential is submitted. Every navigation
        // waits for a complete owned frame before a subsequent confirmation.
        var start = d.used;
        try d.send("/");
        try d.waitFrame(start, "/login");
        try d.checkMenu("/model", "%> /");
        start = d.used;
        const commands = try d.screen();
        // The loopback fixture explicitly opts out; the default-on marker must
        // not be inferred merely from the presence of a context percentage.
        try check(std.mem.indexOf(u8, &commands.grid[commands.row], " L ") == null);
        try check(commands.visible("/model [exact-id|--refresh]  Select model"));
        // Inspect logical terminal cells, not raw SGR/padding substrings.
        var description_column: ?usize = null;
        var descriptions: usize = 0;
        for ([_][]const u8{ "Select model", "Configure provider", "Compact conversation", "Global settings" }) |description| {
            var found = false;
            for (commands.grid) |line| {
                if (std.mem.indexOf(u8, &line, description)) |column| {
                    if (description_column) |expected| try check(column == expected) else description_column = column;
                    try check(!found);
                    found = true;
                }
            }
            try check(found);
            descriptions += 1;
        }
        try check(descriptions == 4);
        try d.send("\x1b[B"); // /model -> /login; /compact is the third root row.
        try d.waitFrame(start, "");
        start = d.used;
        try d.send("\t");
        try d.waitFrame(start, "");
        const login_completed = try d.screen();
        try check(std.mem.indexOf(u8, &login_completed.grid[login_completed.row], "%> /login") != null);
        try check(!login_completed.visible("Provider> ") and !login_completed.visible("API key> "));
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Provider> ");
        try d.checkMenu("DeepSeek", "Provider> ");
        const providers = try d.screen();
        try check(providers.row > 0);
        try check(!providers.visible("Configure provider"));
        start = d.used;
        try d.send("\x1b[D"); // Provider -> root, not a cursor movement.
        try d.waitFrame(start, "");
        const root = try d.screen();
        try check(root.visible("/model") and root.visible("/login") and !root.visible("Provider> "));
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/");
        try d.waitFrame(start, "/login");
        start = d.used;
        try d.send("\x1b[B");
        try d.waitFrame(start, "");
        start = d.used;
        try d.send("\x1b[A"); // Up from /login returns to /model.
        try d.waitFrame(start, "");
        start = d.used;
        try d.send("\t");
        try d.waitFrame(start, "");
        const model_completed = try d.screen();
        try check(std.mem.indexOf(u8, &model_completed.grid[model_completed.row], "%> /model") != null);
        try check(!model_completed.visible("Search> "));
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Search> ");
        const model_list = try d.screen();
        try check(!model_list.visible("Provider> ") and !model_list.visible("deepseek-flash") and !model_list.visible("claude-haiku"));
        try d.checkMenu("fixture-model  (", "Search> ");
        const models = try d.screen();
        try check(!models.visible("Commands") and !models.visible("Configure provider"));
        start = d.used;
        try d.send("\x1b[D"); // Model -> root (no provider stage).
        try d.waitFrame(start, "");
        const model_parent = try d.screen();
        try check(model_parent.visible("/model") and model_parent.visible("/login") and !model_parent.visible("Search> "));
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/co");
        try d.waitFrame(start, "Compact conversation");
        start = d.used;
        try d.send("\t");
        try d.waitFrame(start, "");
        const compact_completed = try d.screen();
        try check(std.mem.indexOf(u8, &compact_completed.grid[compact_completed.row], "%> /compact") != null);
        try check(!compact_completed.visible("Context compacted:"));
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        try d.openAuth();
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.waitFrame(start, "*");
        start = d.used;
        try d.send("\x1b"); // Wipe the secret AND release paste quarantine.
        try d.waitIdle(start);
        try d.openAuth(); // Would fail if quarantine still swallowed /login.
        const empty_secret = try d.screen();
        try check(empty_secret.visible("API key> ") and !empty_secret.visible("***"));
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
        start = d.used;
        try d.send("ordinary-edit");
        try d.waitFrame(start, "ordinary-edit");
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        const cleared = try d.screen();
        try check(!cleared.visible("ordinary-edit"));
        start = d.used;
        try d.send("/model --refresh\r");
        try d.waitFrame(start, "No official provider configured");
        // This fixture uses a custom loopback endpoint: refresh must not send
        // its credential to any official service or submit a model request.
        try check(std.mem.indexOf(u8, d.output[0..d.used], "Saved locally; send a message to connect") == null);
    } else if (std.mem.eql(u8, mode, "auth-go")) {
        var login_stage: usize = 1;
        errdefer std.debug.print("error: GoLoginStage{d}\n", .{login_stage});
        var start = d.used;
        try d.send("/model ");
        try d.waitFrame(start, "/model ");
        const command = try d.screen();
        try check(command.visible("/model ") and !command.visible("arguments hidden"));
        login_stage = 2;
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/login\r");
        try d.waitFrame(start, "Provider> ");
        start = d.used;
        try d.send("\x1b[A"); // Wrap first row to Codex; never select its OAuth route.
        try d.waitFrame(start, ">   OpenAI Codex/ChatGPT");
        start = d.used;
        try d.send("\x1b[A");
        try d.waitFrame(start, ">   OpenCode Go");
        login_stage = 3;
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "API key> ");
        login_stage = 4;
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.waitFrame(start, "***");
        login_stage = 5;
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Key saved locally");
        const saved = try d.screen();
        try check(!saved.visible("API key>") and !saved.visible("***") and !saved.visible("Provider> "));
        // No Escape/Ctrl+U unlock step: fresh text must immediately be editable.
        login_stage = 6;
        start = d.used;
        try d.send("ordinary-after-login");
        try d.waitFrame(start, "ordinary-after-login");
        login_stage = 7;
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/model\r");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("opencode-go/claude-haiku");
        try d.waitFrame(start, "opencode-go/claude-haiku-5-5");
        login_stage = 8;
        start = d.used;
        try d.send("\x15");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("opencode-go/kimi-k3");
        try d.waitFrame(start, "opencode-go/kimi-k3  (");
        login_stage = 9;
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "resume-create")) {
        const start = d.used;
        try d.send("resume-first-turn remember-resume-marker\r");
        try d.waitText(start, "resume-first-answer");
        try d.waitIdle(start);
    } else if (full_resume) {
        try d.waitFrame(0, if (std.mem.eql(u8, mode, "resume-login")) "Not configured: /login, then /model" else "prior tools are NOT rerun");
        // Actual history is delivered asynchronously after the restore notice.
        try d.waitText(0, "resume-first-answer");
        try check(std.mem.indexOf(u8, d.output[0..d.used], "PRIVATE-RESUME-REASONING") == null);
        try d.quiet(150); // No startup model request or historical execution.
        if (std.mem.eql(u8, mode, "resume-login")) {
            try d.waitFrame(0, "Not configured: /login, then /model");
            try d.openAuth();
            const login_start = d.used;
            try d.send("fixture-secret-never-log\r");
            // The restored-owner notice may follow this in the bounded hint
            // row; check its visible save prefix, then exact continuation below.
            try d.waitFrame(login_start, "Saved locally");
            try check(std.mem.indexOf(u8, d.output[0..d.used], "resume-first-answer") != null);
        }
        if (!std.mem.eql(u8, mode, "resume-idle")) {
            const start = d.used;
            try d.send("resume-next-turn\r");
            try d.waitText(start, "resume-next-answer");
            try d.waitIdle(start);
        }
    } else if (std.mem.eql(u8, mode, "restore-idle") or std.mem.eql(u8, mode, "restore-no-key")) {
        const needle = if (std.mem.eql(u8, mode, "restore-no-key")) "Not configured: /login, then /model" else "history not restored";
        d.waitFrame(0, needle) catch |err| {
            if (std.mem.eql(u8, mode, "restore-idle")) {
                const bytes = d.output[0..d.used];
                const at = std.mem.indexOf(u8, bytes, needle);
                const ack = if (at) |pos| std.mem.indexOf(u8, bytes[pos + needle.len ..], "\x1b[?25h") != null else false;
                std.debug.print("RESTORE_IDLE_WAIT text={any} ack={any}\n", .{ at != null, ack });
            }
            return err;
        };
        try check(std.mem.indexOf(u8, d.output[0..d.used], "OLD-HISTORY-MUST-NOT-APPEAR") == null);
        try d.quiet(150);
    } else if (std.mem.eql(u8, mode, "restore-selection")) {
        try d.waitFrame(0, "history not restored");
        try check(std.mem.indexOf(u8, d.output[0..d.used], "fixture-restored") != null);
        try check(std.mem.indexOf(u8, d.output[0..d.used], "OLD-HISTORY-MUST-NOT-APPEAR") == null);
        const start = d.used;
        try d.send("restore-new-turn\r");
        try d.waitText(start, "restore-fresh-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "exit-no-submit") or std.mem.eql(u8, mode, "exit-unconfigured") or std.mem.eql(u8, mode, "exit-batched")) {
        try d.quiet(100);
    } else if (std.mem.eql(u8, mode, "exit-secret")) {
        try d.openAuth();
        try d.send("fixture-secret-never-log");
        try d.quiet(100);
    } else if (std.mem.eql(u8, mode, "exit-recorded")) {
        const start = d.used;
        try d.send("fixture-task\r");
        try d.waitText(start, "fixture-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "exit-busy") or std.mem.eql(u8, mode, "exit-busy-tool")) {
        const start = d.used;
        try d.send("exit-busy-task\r");
        if (std.mem.eql(u8, mode, "exit-busy-tool")) {
            try d.waitRunningFrame(start, "sleep 30");
        } else {
            // A busy composer alone is not evidence that Runtime accepted its
            // user or sent HTTP. Test an IN-FLIGHT request, not pre-start cancel.
            try queuedFile(&d, a, project, "exit-busy-arrived");
            try d.waitBusy(start);
        }
        // Ctrl+D at the shared tail below cancels and joins before restoration.
    } else if (std.mem.eql(u8, mode, "auth-activate")) {
        // 待激活配置指向本地 fixture。/login 使用独立的掩码输入，取消不能保存或污染聊天输入。
        try d.waitText(0, "/login");
        var start = d.used;
        try d.openAuth();
        try d.quiet(150);
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.quiet(150);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Saved locally; send a message to connect") == null);
        try d.send("\x03");
        try d.quiet(150);
        try check(d.owned);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Saved locally; send a message to connect") == null);

        // 粘贴退出后保持保护，按屏幕提示显式 Ctrl+U，避免剩余密钥字节进入普通输入。
        try d.send("\x15");
        try d.quiet(150);

        // 再次打开，粘贴本身不能保存；只有显式 Enter 才能提交，并在同一进程激活配置。
        start = d.used;
        try d.openAuth();
        try d.quiet(150);
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.quiet(150);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Saved locally; send a message to connect") == null);
        try d.send("\r");
        try d.waitText(start, "Saved locally; send a message to connect");
        try d.quiet(150);
        try d.send("\x15");
        try d.quiet(150);

        start = d.used;
        try d.send("fixture-task\r");
        try d.waitText(start, "fixture-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "log-idle")) {
        // 已配置但尚未提交：Node 检查退出后仍没有日志目录。
        try d.quiet(150);
    } else if (std.mem.eql(u8, mode, "date")) {
        const start = d.used;
        try d.send("获取时间\r");
        // 默认直接运行真实 date，不发送 y/n/t；无响应会由驱动截止时间判失败。
        try d.waitText(start, "date-completed");
        try d.waitIdle(start);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
    } else if (std.mem.eql(u8, mode, "regular-two")) {
        // Same owned PTY, two loopback-only turns. Force the first reply into
        // scrollback; repeated input-tail redraws must not append it again.
        for ([_][]const u8{ "regular-first", "regular-second" }, 0..) |prompt, turn| {
            const start = d.used;
            try d.send(prompt);
            try d.send("\r");
            try d.waitText(start, if (turn == 0) "regular-answer-one" else "regular-answer-two");
            try d.waitIdle(start);
            try d.quiet(150);
            try d.send("tail-refresh");
            try d.quiet(150);
            try d.send("\x15");
            try d.quiet(150);
            const current = try d.screen();
            try check(current.count("regular-answer-one") == 1);
            if (turn == 1) try check(current.count("regular-answer-two") == 1);
        }
    } else if (std.mem.eql(u8, mode, "stream-native-history")) {
        try d.waitIdle(0);
        const start = d.used;
        try d.send("native-scroll-task\r");
        try d.waitFrame(start, "native-row-039");
        var stage = try d.screen();
        if (stage.history_len < 8) return error.NativeHistoryMissing;
        try check(stage.row == stage.rows - 1);
        const top = stage.history_len - 8;
        const old_history = stage.history_len;
        var pinned: [24]@TypeOf(stage.grid[0]) = undefined;
        for (&pinned, 0..) |*line, index| {
            const position = top + index;
            @memcpy(line, if (position < stage.history_len) &stage.history[position] else &stage.grid[position - stage.history_len]);
        }
        // No mouse events are sent. Observe the same absolute native viewport
        // while streaming continues beneath it, as a scrolled terminal would.
        try d.waitFrame(start, "native-row-069");
        stage = try d.screen();
        if (stage.history_len <= old_history) return error.NativeHistoryDidNotGrow;
        for (&pinned, 0..) |*line, index| {
            const position = top + index;
            const actual = if (position < stage.history_len) &stage.history[position] else &stage.grid[position - stage.history_len];
            if (!std.mem.eql(u8, line, actual)) return error.NativeHistoryChanged;
        }
        try d.waitIdle(start);
        stage = try d.screen();
        try check(stage.count("native-row-") == 70);
        try check(stage.count("native-row-000") == 1 and stage.count("native-row-069") == 1);
        try check(stage.count("Response revised") == 0);
        try check(stage.count("native-scroll-task") == 1);
    } else if (std.mem.eql(u8, mode, "stream-markdown")) {
        try d.waitIdle(0);
        const initial = try d.screen();
        try check(std.mem.indexOf(u8, &initial.grid[initial.row], "(fixture-model) 0.0%>") != null);
        const start = d.used;
        try d.send("stream-task\r");
        try d.waitText(start, "reasoning-stage-one");
        try d.quiet(100);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
        var stage = try d.screen();
        // Check the actual streamed reasoning on the logical terminal, not
        // only Record.layout: Markdown punctuation must remain literal.
        if (!stage.visible("# **reasoning-stage-one** with `literal`")) return error.ThinkingMarkupNotLiteral;
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;103m# **reasoning-stage-one** with `literal`") != null);
        var reasoning_rows: usize = 0;
        for (stage.grid[0..stage.rows]) |line| if (std.mem.indexOf(u8, &line, "reasoning-stage-") != null or std.mem.indexOf(u8, &line, "thinking-") != null) {
            reasoning_rows += 1;
        };
        try check(reasoning_rows == 1 and stage.count("reasoning-stage-one") == 1);
        for (stage.history[0..stage.history_len]) |line| try check(std.mem.indexOf(u8, &line, "reasoning-stage-") == null and std.mem.indexOf(u8, &line, "thinking-") == null);
        try Driver.checkComposerTail(stage);
        try Driver.checkGap(stage, "stream-task", "reasoning-stage-one");
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Thinking") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "thin |") == null);
        for ([_][]const u8{ "thinking-old-one", "thinking-old-two", "thinking-old-three", "thinking-new-five", "thinking-new-six" }) |marker| try check(!stage.visible(marker));
        try d.waitText(start, "reasoning-stage-two");
        try d.quiet(100);
        stage = try d.screen();
        try check(stage.visible("# **reasoning-stage-two** with `literal`") and stage.count("reasoning-stage-two") == 1);
        reasoning_rows = 0;
        for (stage.grid[0..stage.rows]) |line| if (std.mem.indexOf(u8, &line, "reasoning-stage-") != null or std.mem.indexOf(u8, &line, "thinking-") != null) {
            reasoning_rows += 1;
        };
        try check(reasoning_rows == 1);
        for ([_][]const u8{ "reasoning-stage-one", "thinking-old-one", "thinking-old-two", "thinking-old-three", "thinking-new-five", "thinking-new-six" }) |marker| try check(!stage.visible(marker));
        for (stage.history[0..stage.history_len]) |line| try check(std.mem.indexOf(u8, &line, "reasoning-stage-") == null and std.mem.indexOf(u8, &line, "thinking-") == null);
        try Driver.checkGap(stage, "stream-task", "reasoning-stage-two");
        try check(std.mem.indexOf(u8, &stage.grid[stage.row], "(fixture-model) ") != null and std.mem.indexOf(u8, &stage.grid[stage.row], "%~") != null);
        try Driver.checkStreamFooter(stage);
        try check(!stage.visible("TPS:") and !stage.visible("tokens in:"));
        try check(std.mem.indexOf(u8, &stage.grid[stage.row], "(fixture-model) 0.0%~") != null);
        try Driver.checkComposerTail(stage);
        try d.waitText(start, "stream-stage-one");
        try d.quiet(100);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
        stage = try d.screen();
        try check(stage.visible("Orange heading") and stage.visible("stream-stage-one"));
        try Driver.checkComposerTail(stage);
        try Driver.checkGap(stage, "stream-task", "Orange heading");
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Streaming") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "History preview") == null);
        try check(!stage.visible("reasoning-stage-two") and !stage.visible("Thinking"));
        try check(!stage.visible("Enter send") and !stage.visible("Ctrl+J newline"));
        try check(std.mem.indexOf(u8, d.output[start..d.used], "[user]") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "[assistant") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;208m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[48;2;52;36;24m") != null);
        // Do not satisfy completion with the old idle composer emitted before
        // this request. Wait for an acknowledged frame after the final delta.
        const final_start = d.used;
        try d.waitText(final_start, "stream-final-answer");
        try d.waitIdle(final_start);
        try d.quiet(100);
        stage = try d.screen();
        try check(stage.count("reasoning-stage-one") == 0 and stage.count("reasoning-stage-two") == 0);
        try check(stage.count("thinking-new-five") == 0 and stage.count("stream-final-answer") == 1);
        try Driver.checkGap(stage, "stream-task", "Orange heading");
        try check(!stage.visible("TPS:") and !stage.visible("tokens in:") and !stage.visible("Completed"));
        try check(std.mem.indexOf(u8, &stage.grid[stage.row], "(fixture-model) ") != null and std.mem.indexOf(u8, &stage.grid[stage.row], "%>") != null);
        try check(stage.count("Final answer") == 0 and !stage.visible("ctx ~"));
        // Loopback provider reported 12 input + 90 output = 102 total: 0.3%.
        // Cached9/reasoning30 already belong to those counts, not extra context.
        try check(std.mem.indexOf(u8, &stage.grid[stage.row], "(fixture-model) 0.3%>") != null);
        // Supported inline semantics retain their styles; table pipes remain literal.
        // Confirmed inline code hides its delimiters and uses purple foreground.
        const markdown_output = d.output[start..d.used];
        for ([_][]const u8{ "\x1b[1m\x1b[38;5;220m", "\x1b[4m\x1b[38;5;12m", "\x1b[39m\x1b[2m", "\x1b[1m", "\x1b[38;5;77m", "| Item | State |", "| --- | --- |", "| second-row | verified |", "exit_code=124", "exit_code=0" }, 0..) |part, part_index| {
            const found = std.mem.indexOf(u8, markdown_output, part) != null;
            if (!found) std.debug.print("Markdown assertion index: {d}\n", .{part_index}); // Safe index, never captured bytes.
            try check(found);
        }
        // The independent model-name flow may legitimately contain orange.
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;5;215m\x1b[1mstream-stage-one") == null);
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;5;141minline-marker\x1b[0m") != null);
        try check(std.mem.indexOf(u8, markdown_output, "`inline-marker`") == null);
        for ([_][]const u8{ "┌", "├", "┼", "└" }) |border| try check(std.mem.indexOf(u8, markdown_output, border) == null);
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;2;") == null);
        // Code remains foreground-only and unpadded; user background is separate.
        for ([_][]const u8{ "exit_code=124", "exit_code=0" }) |code| {
            const expected = try std.fmt.allocPrint(a, "\x1b[38;5;77m{s}\x1b[0m", .{code});
            defer a.free(expected);
            try check(std.mem.indexOf(u8, markdown_output, expected) != null);
        }
        try check(std.mem.indexOf(u8, markdown_output, "(\x1b[38;5;75mfixture-model\x1b[0m\x1b[1m) \x1b[38;5;114m0.3%\x1b[0m\x1b[1m>\x1b[0m ") != null); // High model, static green occupancy.
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;5;75m>\x1b[0m") == null);
        try Driver.checkStreamFooter(stage);
        try Driver.checkComposerTail(stage);
    } else if (std.mem.eql(u8, mode, "architecture-table")) {
        const start = d.used;
        try d.send("architecture-table-task\r");
        try d.waitText(start, "architecture-table-final-answer");
        try d.waitIdle(start);
        const final = try d.screen();
        try check(final.count("architecture-table-final-answer") == 1);
        try Driver.checkComposerTail(final);
        const raw = d.output[start..d.used];
        for ([_][]const u8{ "| 目录 | 职责 |", "|---|---|", "app/", "core/", "llm/", "platform/", "util/" }) |marker| try check(std.mem.indexOf(u8, raw, marker) != null);
        for ([_][]const u8{ "┌", "┬", "┼", "└", "┴" }) |border| try check(std.mem.indexOf(u8, raw, border) == null);
        try check(std.mem.indexOf(u8, raw, "Markdown complexity limit") == null);
        try check(std.mem.indexOf(u8, raw, "Streaming") == null);
    } else if (std.mem.eql(u8, mode, "tool-icons")) {
        const start = d.used;
        // Startup already shows configured high on idle text, not the marker.
        try check(std.mem.indexOf(u8, d.output[0..start], "(\x1b[38;5;75mfixture-model\x1b[0m\x1b[1m) \x1b[38;5;114m0.0%\x1b[0m\x1b[1m>\x1b[0m ") != null);
        try check(std.mem.indexOf(u8, d.output[0..start], "%\x1b[0m\x1b[1m>\x1b[0m ") != null);
        try check(std.mem.indexOf(u8, d.output[0..start], "\x1b[38;5;75m>\x1b[0m") == null);
        try d.send("tool-icon-task\r");
        try d.waitRunningFrame(start, "sleep 1; cat r.json");
        const animation_start = d.used;
        try d.quiet(120);
        const first = try d.screen();
        try d.quiet(240);
        const second = try d.screen();
        try check(first.visible("> sleep 1; cat r.json") and second.visible("> sleep 1; cat r.json"));
        try Driver.checkGap(first, "tool-icon-task", "> sleep 1; cat r.json");
        try Driver.checkGap(second, "tool-icon-task", "> sleep 1; cat r.json");
        // The bash glyph stays fixed; only its warm foreground changes.
        var pulses: usize = 0;
        for ([_][]const u8{ "\x1b[38;5;137m", "\x1b[38;5;173m", "\x1b[38;5;208m", "\x1b[38;5;214m" }) |color| {
            var pattern: [96]u8 = undefined;
            const effect = try std.fmt.bufPrint(&pattern, "{s}>\x1b[38;5;245m sleep 1; cat r.json", .{color});
            if (std.mem.indexOf(u8, d.output[animation_start..d.used], effect) != null) pulses += 1;
        }
        try check(pulses >= 2); // Distinct prefix shades, not repeated glyph/text.
        try check(std.mem.indexOf(u8, d.output[start..d.used], ">_") == null);
        try Driver.checkComposerTail(first);
        try Driver.checkComposerTail(second);
        try check(std.mem.indexOf(u8, &first.grid[first.row], "(fixture-model) ") != null and std.mem.indexOf(u8, &first.grid[first.row], "%~") != null);
        try Driver.checkStreamFooter(first);
        try d.waitRunningFrame(start, "sleep 0.6; printf ok");
        const next_pending = try d.screen();
        var completed_row: ?usize = null;
        var next_row: ?usize = null;
        for (next_pending.grid, 0..) |line, row| {
            if (std.mem.indexOf(u8, &line, "> sleep 1; cat r.json") != null) completed_row = row;
            if (std.mem.indexOf(u8, &line, "> sleep 0.6; printf ok") != null) next_row = row;
        }
        try check(completed_row != null and next_row != null);
        try check(next_row.? == completed_row.? + 1);
        try Driver.checkComposerTail(next_pending);
        try d.waitText(start, "tool-icon-final-answer");
        try d.waitIdle(start);
        try d.quiet(100);
        const final = try d.screen();
        try check(final.count("tool-icon-final-answer") == 1);
        var command_rows: [3]?usize = @splat(null);
        const markers = [_][]const u8{ "> sleep 1; cat r.json", "> sleep 0.6; printf ok", "> false; #" };
        for (final.grid, 0..) |line, row| {
            var calls_on_row: usize = 0;
            for (markers, 0..) |marker, index| if (std.mem.indexOf(u8, &line, marker) != null) {
                command_rows[index] = row;
                calls_on_row += 1;
            };
            try check(calls_on_row <= 1);
        }
        try check(command_rows[0] != null and command_rows[1] != null and command_rows[2] != null);
        try check(command_rows[1].? == command_rows[0].? + 1 and command_rows[2].? == command_rows[1].? + 1);
        try check(final.count(markers[0]) == 1 and final.count(markers[1]) == 1 and final.count(markers[2]) == 1);
        try Driver.checkComposerTail(final);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114m>\x1b[38;5;245m sleep 0.6; printf ok") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;203m>\x1b[38;5;203m false; #") != null); // Failure prefix; the summary clips at the full row width in its failure color.
        // The clipped target ends in dots, then the reserved outcome marker.
        try check(std.mem.indexOf(u8, d.output[start..d.used], "... [error]\x1b[0m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "·") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "bash #") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "tool-json-hidden-marker") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Running bash") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Enter send") == null);
    } else if (std.mem.eql(u8, mode, "memory-summary")) {
        const start = d.used;
        try d.send("memory-summary-task\r");
        try d.waitText(start, "memory-summary-final-answer");
        try d.waitIdle(start);
        const final = try d.screen();
        for ([_][]const u8{ "m write caption-note", "m read caption-note", "m list core/index", "m delete caption-note" }) |caption| {
            try check(final.count(caption) == 1);
        }
        try check(std.mem.indexOf(u8, d.output[start..d.used], "memory-summary-hidden-body") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "expected_version") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114mm\x1b[38;5;245m read caption-note") != null);
        try check(final.count("memory-summary-final-answer") == 1);
        try Driver.checkComposerTail(final);
    } else if (std.mem.eql(u8, mode, "file-stats")) {
        const start = d.used;
        try d.send("file-stats-task\r");
        try d.waitText(start, "file-stats-final-answer");
        try d.waitIdle(start);
        const final = try d.screen();
        var previous: ?usize = null;
        for ([_][]const u8{ "w stats.txt  ~0 +5 -0 lines", "w stats.txt  ~1 +1 -1 lines", "r stats.txt  5 lines", "r stats.txt  2 lines [partial]", "w stats.txt  ~0 +0 -5 lines", "w stats.txt [error]" }) |caption| {
            try check(final.count(caption) == 1);
            var found: ?usize = null;
            for (final.grid, 0..) |line, row| if (std.mem.indexOf(u8, &line, caption) != null) {
                found = row;
            };
            try check(found != null);
            if (previous) |row| try check(found.? == row + 1);
            previous = found;
        }
        try check(final.count("Final answer") == 0 and final.count("file-stats-final-answer") == 1);
        try Driver.checkGap(final, "file-stats-task", "w stats.txt");
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114mw\x1b[38;5;245m stats.txt") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114mr\x1b[38;5;245m stats.txt") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;203mw\x1b[38;5;203m stats.txt [error]") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;2m+1\x1b[38;5;245m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;1m-1\x1b[38;5;245m") != null);
        for ([_][]const u8{ "read_file ", "write_file ", "memory read " }) |old_label| try check(std.mem.indexOf(u8, d.output[start..d.used], old_label) == null);
        var answer: ?usize = null;
        for (final.grid, 0..) |line, row| if (std.mem.indexOf(u8, &line, "file-stats-final-answer") != null) {
            answer = row;
        };
        try check(answer != null and answer.? == previous.? + 2);
        for (final.grid[answer.? - 1]) |byte| try check(byte == ' ');
        try check(std.mem.indexOf(u8, &final.grid[final.row], "(fixture-model) ") != null and std.mem.indexOf(u8, &final.grid[final.row], "%>") != null);
        try Driver.checkComposerTail(final);
        try check(!final.visible("ctx ~"));
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\"written_bytes\"") == null);
    } else if (std.mem.startsWith(u8, mode, "tool-preview-")) {
        try toolPreview(&d, init, mode, project);
    } else if (std.mem.startsWith(u8, mode, "settings-proxy-")) {
        try settingsProxy(&d, init, mode, project);
    } else if (std.mem.eql(u8, mode, "settings-values")) {
        try settingsValuesJourney(&d, init, project);
    } else if (std.mem.eql(u8, mode, "settings-image-model")) {
        try imageModel(&d, init, project);
    } else if (std.mem.startsWith(u8, mode, "settings-decision-model-")) {
        try decisionModel(&d, init, mode, project);
    } else if (std.mem.eql(u8, mode, "settings-approval-cancel")) {
        try approvalCancel(&d);
    } else if (std.mem.startsWith(u8, mode, "settings-command-")) {
        try localCommand(&d, mode, init, project);
    } else if (std.mem.startsWith(u8, mode, "settings-global")) {
        // Handle before the historical thinking-level settings-* dispatcher.
        // No prompt, model selection, refresh or inference is submitted here.
        try globalSettings(&d, mode);
    } else if (std.mem.startsWith(u8, mode, "settings-")) {
        // All settings processes are real owned PTYs. Check an
        // acknowledged initial frame before typing; a missing preference is initialized.
        try d.waitIdle(0);
        if (std.mem.eql(u8, mode, "settings-initial")) try settingsColor(&d, 0, "off");
        if (std.mem.eql(u8, mode, "settings-cycle") or std.mem.eql(u8, mode, "settings-map")) {
            try settingsColor(&d, 0, "off");
            const levels: []const []const u8 = if (std.mem.eql(u8, mode, "settings-cycle")) &.{ "low", "high", "max", "off" } else &.{ "low", "high", "off" };
            for (levels) |level| {
                var start = d.used;
                try d.send("\x1b[Z");
                try d.waitEffortIdle(start, "fixture-model", level, false);
                try settingsColor(&d, start, level);
                start = d.used;
                try d.send("settings-task\r");
                try d.waitText(start, "settings-answer");
                try d.waitEffortIdle(start, "fixture-model", level, true);
            }
            if (std.mem.eql(u8, mode, "settings-cycle")) {
                // Leave max saved without another HTTP call.
                for ([_][]const u8{ "low", "high", "max" }) |level| {
                    const start = d.used;
                    try d.send("\x1b[Z");
                    try d.waitEffortIdle(start, "fixture-model", level, false);
                    try settingsColor(&d, start, level);
                }
            }
        } else if (std.mem.eql(u8, mode, "settings-pending-auth")) {
            try d.waitText(0, "/login");
            // A visible not-configured prompt precedes its settled idle frame:
            // settle it before capturing the offset this shortcut must follow.
            try d.waitIdle(0);
            var start = d.used;
            try d.send("\x1b[Z");
            // Cycling a pending preference may leave the bare prompt pixels
            // unchanged, and its async busy frame is not the result. Require a
            // settled idle operation, not an unchanged footer.
            try d.waitIdle(start);
            const pending = try d.screen();
            try check(std.mem.startsWith(u8, &pending.grid[pending.row], "> ") and !pending.visible("fixture-model"));
            start = d.used;
            try d.openAuth();
            start = d.used;
            try d.send("fixture-secret-never-log\r");
            try d.waitText(start, "Saved locally; send a message to connect");
            try d.waitAuthSettlement(start, "fixture-model", "low");
            try settingsColor(&d, start, "low");
            start = d.used;
            try d.send("settings-task\r");
            try d.waitText(start, "settings-answer");
            try d.waitEffortIdle(start, "fixture-model", "low", true);
        } else if (!std.mem.eql(u8, mode, "settings-initial")) {
            const blocked = std.mem.eql(u8, mode, "settings-blocked-low") or std.mem.eql(u8, mode, "settings-unknown-low");
            const clamped = std.mem.startsWith(u8, mode, "settings-clamp-");
            const level = if (blocked) "low" else if (clamped or std.mem.startsWith(u8, mode, "settings-probe-")) mode[15..] else return error.UnknownSettingsMode;
            try settingsColor(&d, 0, level);
            if (clamped) try d.waitText(0, "Saved thinking level adjusted");
            if (std.mem.eql(u8, mode, "settings-unknown-low")) try d.waitText(0, "Saved thinking level not applied");
            if (blocked) {
                // A complete pending frame is not a settled operation: the
                // optional saved-level notice may still be rendered, so settle
                // the previous shortcut's operation before capturing "before".
                try d.waitIdle(0);
                const before = try d.screen();
                const start = d.used;
                try d.send("\x1b[Z");
                // The rejected shortcut adds a conversation warning, which may
                // move the composer. Require its fresh text and a complete idle
                // frame under the same interaction deadline.
                const warning = "Thinking capabilities unknown";
                const until = now() + 10000;
                var settled = false;
                while (now() < until) {
                    try d.drain(20);
                    if (std.mem.indexOf(u8, d.output[start..d.used], warning)) |at| {
                        if (try d.acknowledgedScreen(start + at + warning.len)) |view| {
                            const composer = &view.grid[view.row];
                            if (std.mem.indexOf(u8, composer, "%> ") != null or std.mem.startsWith(u8, composer, "> ")) {
                                settled = true;
                                break;
                            }
                        }
                    }
                    if (!d.owned) return error.EarlyExit;
                }
                if (!settled) return error.VisibleTextTimeout;
                const after = try d.screen();
                try check(std.mem.endsWith(u8, std.mem.trimEnd(u8, &before.grid[before.row], " "), ">"));
                try check(std.mem.eql(u8, &before.grid[before.row], &after.grid[after.row]));
                try Driver.checkComposerTail(after);
                try check(after.row > 0);
                var warnings: usize = 0;
                for (after.grid[0 .. after.row - 1]) |line| {
                    if (std.mem.indexOf(u8, &line, warning) != null) warnings += 1;
                }
                try check(warnings == 1 and std.mem.indexOf(u8, &after.grid[after.row - 1], warning) == null);
                if (std.mem.indexOf(u8, d.output[start..d.used], "fixture-model") != null) {
                    try settingsColor(&d, start, level);
                } else {
                    // No new styled footer payload: the previously verified
                    // low color is retained, not silently replaced by another.
                    try settingsColor(&d, 0, level);
                }
            }
            const start = d.used;
            try d.send("settings-task\r");
            try d.waitText(start, "settings-answer");
            try d.waitIdle(start);
        }
        const final = try d.screen();
        try check(final.count(regular.prior) == 1);
        try Driver.checkComposerTail(final);
    } else if (std.mem.eql(u8, mode, "model-select-empty")) {
        const start = d.used;
        try d.send("/model fixture-next\r");
        try d.waitEffortIdle(start, "fixture-next", "low", false);
        const selected = try d.screen();
        try check(selected.visible("fixture-next") and !selected.visible("Model selection failed"));
    } else if (std.mem.eql(u8, mode, "model-select")) {
        var start = d.used;
        try d.send("selection-first\r");
        // Wait for the accepted receipt's cleared composer, not the pending
        // submit spinner: only after acceptance is the busy composer empty, so
        // the injected draft below cannot be appended to the submitted text.
        try waitAcceptedBusy(&d, start);
        // Acceptance alone does not prove the first HTTP body has been sent.
        try queuedFile(&d, a, project, "selection-request-started");
        // The first wire request is held by the fixture. A fresh complete
        // composer ACK proves the new level was applied while still running.
        start = d.used;
        try d.send("\x1b[Z");
        try selectionBusyFrame(&d, start, "minimal", "", false);
        start = d.used;
        try d.send("/model rejected-busy\r");
        try selectionBusyFrame(&d, start, "minimal", "/model rejected-busy", true);
        // Existing driver-to-server gate: never use an observation timer as
        // evidence of a UI action. The request remains held until this point.
        std.debug.print("SELECTION_GATE=release\n", .{});
        try d.waitText(start, "selection-answer-one");
        try d.waitIdle(start);
        // Busy special commands are rejected without destroying their draft.
        // The user explicitly clears it before opening a new local menu; it
        // must not silently become Steering or a second inference request.
        try queuedDraft(&d, a, "/model rejected-busy");
        start = d.used;
        try d.send("\x15/");
        try d.waitFrame(start, "/login");
        const commands = try d.screen();
        try check(commands.visible("/model") and commands.visible("/login"));
        try check(!commands.visible("Commands") and !commands.visible("Search> "));
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("\x1b[B");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("\r");
        try d.waitEffortIdle(start, "fixture-next", "low", false);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "fixture-next") != null);
        // No global override exists: the selected profile's configured low is
        // now the default, not an obsolete project preference. ACK-safe redraws
        // may emit changed cells only; inspect the resulting idle screen. The
        // exact medium wire after ONE shortcut below proves low was applied.
        const selected_next = try d.screen();
        try check(selected_next.visible("fixture-next"));
        try check(!selected_next.visible("Search> "));
        try Driver.checkComposerTail(selected_next);
        start = d.used;
        try d.send("\x1b[Z"); // Selected profile low -> medium.
        // Require the acknowledged confirmation, then its automatic expiry.
        // Sparse redraws may leave the model prefix unchanged; inspect the
        // reconstructed fresh frame even if both ACKs arrive in one read.
        try d.waitEffortIdle(start, "fixture-next", "medium", false);
        // The flash may already have expired by the time the driver is
        // scheduled; inspect the exact fresh ACK that proved it was delivered.
        const medium_frame = d.effort_witness orelse return error.MissingEffortFrame;
        const medium_screen = try d.screens.allocator().create(regular.Screen);
        medium_screen.* = .{ .columns = d.columns };
        try medium_screen.replay(d.output[0..medium_frame.end]);
        try check(composerKind(medium_screen, "fixture-next", "medium", false) == .effort);
        // The transient effort confirmation then expires back to the ordinary
        // percentage prompt; only after observing it should this wait for idle.
        try d.waitIdle(start);
        const expired_next = try d.screen();
        try check(expired_next.visible("?%"));
        try check(std.mem.eql(u8, std.mem.trimEnd(u8, &expired_next.grid[expired_next.row], " "), "(fixture-next) ?%>"));
        start = d.used;
        try d.send("selection-second\r");
        try d.waitText(start, "selection-answer-two");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/model\r");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("\x1b"); // Owned ambiguity timeout for standalone Escape.
        try d.waitIdle(start);
        start = d.used;
        try d.send("/model fixture-custom\r");
        try d.waitEffortIdle(start, "fixture-custom", "off", false);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "fixture-custom") != null);
        start = d.used;
        try d.send("\x1b[Z"); // Selected profile off -> minimal.
        try d.waitFrame(start, "(\x1b[38;5;117mfixture-custom\x1b[0m\x1b[1m) \x1b[38;5;117m");
        try d.waitEffortIdle(start, "fixture-custom", "minimal", false);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "(\x1b[38;5;117mfixture-custom\x1b[0m\x1b[1m) \x1b[38;5;117m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;117m>\x1b[0m") == null);
        start = d.used;
        try d.send("selection-third\r");
        try d.waitText(start, "selection-answer-three");
        try d.waitEffortIdle(start, "fixture-custom", "minimal", true);
        const final = try d.screen();
        try check(final.count("selection-answer-one") == 1 and final.count("selection-answer-two") == 1 and final.count("selection-answer-three") == 1);
        try check(final.count("selection-first") == 1 and final.count("selection-second") == 1 and final.count("selection-third") == 1);
        try check(final.count("/model") == 0);
        try Driver.checkComposerTail(final);
    } else if (std.mem.eql(u8, mode, "log-failure")) {
        const start = d.used;
        try d.send("log-fixture-task\r");
        try d.waitText(start, "REC FAILED");
        try d.waitText(start, "log-fixture-answer");
        try d.waitIdle(start);
        try d.send("\x04");
        try d.finish(0);
        const final = try d.screen();
        try check(final.count(regular.prior) == 1 and final.count("log-fixture-answer") == 1);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "session recording disabled") != null);
        return;
    } else if (std.mem.eql(u8, mode, "auto-tools")) {
        // 同一终端两轮写入均无需审批；只提交任务并等待执行结果。
        for ([_][]const u8{ "auto-one", "auto-two" }) |prompt| {
            const start = d.used;
            try d.send(prompt);
            try d.send("\r");
            try d.waitText(start, "fixture-answer");
            try d.waitIdle(start);
            try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
        }
    } else if (std.mem.eql(u8, mode, "keyboard-history")) {
        for ([_][]const u8{ "history-one", "history-two" }, 1..) |message, number| {
            const start = d.used;
            try d.send(message);
            try d.send("\r");
            const answer = try std.fmt.allocPrint(a, "history-answer-{d}", .{number});
            try d.waitText(start, answer);
            try d.waitIdle(start);
        }
        const EditorCheck = struct {
            fn expect(driver: *Driver, keys: []const u8, expected: []const u8) !void {
                try driver.send(keys);
                try driver.quiet(120);
                const state = try driver.screen();
                const row = &state.grid[state.row];
                const at = std.mem.indexOf(u8, row, "> ") orelse return error.EditorNotIdle;
                try check(std.mem.eql(u8, std.mem.trim(u8, row[at + 2 ..], " "), expected));
            }
        };
        try EditorCheck.expect(&d, "\x1b[A", "history-two");
        try EditorCheck.expect(&d, "\x1b[A", "history-one");
        try EditorCheck.expect(&d, "\x1b[B", "history-two");
        try EditorCheck.expect(&d, "\x1b[B", "");
        // Keep each navigation/edit transaction separately observable. The
        // input loop may stop consuming the current read after an ACK-owning
        // history transition, so batching unrelated actions would make the
        // fixture depend on kernel PTY read boundaries.
        try EditorCheck.expect(&d, "manual-draft", "manual-draft");
        try EditorCheck.expect(&d, "\x1b[A", "manual-draft");
        try EditorCheck.expect(&d, "\x1b[B", "manual-draft");
        try EditorCheck.expect(&d, "\x15", "");
        try EditorCheck.expect(&d, "\x1b[A", "history-two");
        // Recall preserves the preferred display column (zero here), so move
        // explicitly to the end before testing a manual edit of the entry.
        try EditorCheck.expect(&d, "\x1b[F", "history-two");
        try EditorCheck.expect(&d, "-edited", "history-two-edited");
        try EditorCheck.expect(&d, "\x1b[A", "history-two-edited");
        try EditorCheck.expect(&d, "\x1b[B", "history-two-edited");
        const start = d.used;
        try d.send("\x15esc-task\r");
        try queuedFile(&d, a, project, "keyboard-history-arrived");
        try d.waitBusy(start);
        try d.send("\x1b");
        try d.waitText(start, "Canceled; prior side effects remain");
        try d.waitIdle(start);
        try EditorCheck.expect(&d, "\x1b[A\x1b[A\x1b[A", "history-one");
        const again = d.used;
        try d.send("\r");
        try d.waitText(again, "after-esc-answer");
        try d.waitIdle(again);
    } else if (std.mem.eql(u8, mode, "esc-cancel-tool")) {
        const start = d.used;
        try d.send("esc-tool-task\r");
        try d.waitRunningFrame(start, "sleep 30");
        try d.send("\x1b");
        try d.waitText(start, "Canceled; prior side effects remain");
        try d.waitIdle(start);
        const again = d.used;
        try d.send("after-esc\r");
        try d.waitText(again, "after-esc-answer");
        try d.waitIdle(again);
    } else if (std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "term")) {
        // cancel / term：等待输入行模型流动色后的reset，证明任务已经启动。
        const start = d.used;
        try d.send("stall\r");
        try d.waitBusy(start);
        try d.quiet(250);

        if (std.mem.eql(u8, mode, "term")) {
            // term 模式：直接发送 SIGTERM，期望退出码 143（128 + 15）。
            try check(d.owned and kill(d.pid, @backingInt(c.SIG.TERM)) == 0);
            try d.finish(143);
            return;
        }

        // Ctrl-C only opens the safe-default confirmation. Selection must
        // receive a complete owned frame before an independent Enter acts.
        try queuedKey(&d, a, "\x03", &.{"> Continue"});
        try queuedKey(&d, a, "\x1b[C", &.{"> Stop and clear"});
        try d.send("\r");
        try d.waitText(start, "Canceled");
        try d.waitIdle(start);

        // 取消后应能继续使用：再次提交 resume 并等待完成。
        const next = d.used;
        try d.send("resume\r");
        try d.waitIdle(next);
    } else {
        // 默认（交互）模式：验证 Unicode 输出；缩放只更新尺寸并作废旧帧权限，
        // 新尺寸下的完整帧由一次真实编辑触发，不再有自动重绘。
        const start = d.used;
        try d.send("unicode\r");
        const reply_until = now() + 10000;
        try d.waitText(start, "世界");
        try d.waitIdleUntil(start, reply_until);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "世界") != null);

        // 依次把列宽改为40/80/120。缩放本身不重绘、不强制移位到屏底、不回放旧画面：
        // 应用只接收新尺寸并作废旧帧权限；每次用一次真实编辑触发新尺寸下的完整帧，
        // 再用 Ctrl-U 清空并等待空输入行。字节级的无重绘/无回放与空闲静默由专用
        // resize 夹具核对，这里只验证应用仍能在新尺寸下完成帧。
        for ([_]u16{ 40, 80, 120 }) |width| {
            size.col = width;
            // IOCSWINSZ 设置窗口尺寸，内核会向前台进程组发送 SIGWINCH；此处只登记新尺寸。
            try check(posix_terminal.setSize(slave, &size) == 0);
            const edited = d.used;
            try d.send("x");
            try d.waitFrame(edited, "x");
            const cleared = d.used;
            try d.send("\x15");
            try d.waitIdle(cleared);
        }
    }

    const no_submit_exit = std.mem.eql(u8, mode, "exit-no-submit") or std.mem.eql(u8, mode, "exit-unconfigured") or std.mem.eql(u8, mode, "exit-batched");
    const before_exit = if (no_submit_exit) try d.screen() else null;
    if (before_exit) |before| {
        try Driver.checkStartupFootprint(before);
        try check(before.count(regular.prior) == 1);
    }
    // Remainder of the SAME read after Ctrl+D must not submit anything.
    const exit_start = d.used;
    try d.send(if (std.mem.eql(u8, mode, "exit-batched")) "\x04post-quit-must-not-submit\r" else "\x04");
    try d.finish(0);
    if (full_resume or std.mem.eql(u8, mode, "resume-create")) {
        const prefix = "thin --resume ";
        const at = (std.mem.indexOf(u8, d.output[0..d.used], prefix) orelse return error.MissingResumeCommand) + prefix.len;
        const id = d.output[at..][0..32].*;
        if (full_resume) try check(std.mem.eql(u8, &id, restore_id));
    }
    if (before_exit) |before| {
        const final = try d.screen();
        try check(final.col == 0);
        const after = d.output[exit_start..d.used];
        const leave = "\x18\x1b[0m\x1b[?2004l\x1b[?2026l\x1b[?25h";
        const leave_at = std.mem.lastIndexOf(u8, after, leave) orelse return error.MissingTerminalLeave;
        const cleanup = try d.screens.allocator().create(regular.Screen);
        cleanup.* = before.*;
        try cleanup.replay(after[0..leave_at]);
        try check(cleanup.history_len == before.history_len and final.history_len == before.history_len);
        for (0..before.history_len) |i| {
            try check(std.mem.eql(u8, &before.history[i], &cleanup.history[i]));
            try check(std.mem.eql(u8, &before.history[i], &final.history[i]));
        }
        try check(cleanup.col == 0);
        try check(cleanup.row < cleanup.rows / 2 or final.row < 8);
        try check(final.row == cleanup.row + 1);
        try check(std.mem.trim(u8, &cleanup.grid[cleanup.row], " ").len != 0);
        for (final.grid[final.row + 1 .. final.rows]) |line| {
            try check(std.mem.trim(u8, &line, " ").len == 0);
        }
        try check(final.count(regular.prior) == 1);
        try check(final.count("Directory:") == 0 and final.count("Time:") == 0 and final.count("Session ID:") == 0);
        try check(final.count("thin --resume") == 0);
        const tail = std.mem.lastIndexOf(u8, d.output[0..d.used], "\x1b[?25h").? + "\x1b[?25h".len;
        try check(std.mem.trim(u8, d.output[tail..d.used], "\r\n").len == 0);
        try check(std.mem.count(u8, d.output[tail..d.used], "\n") == 1);
    }
    if (std.mem.eql(u8, mode, "date") or std.mem.eql(u8, mode, "log-idle") or std.mem.eql(u8, mode, "regular-two")) {
        const final = try d.screen();
        try check(final.count(regular.prior) == 1);
        if (std.mem.eql(u8, mode, "date")) try check(final.count("date-completed") == 1);
        if (std.mem.eql(u8, mode, "regular-two")) {
            try check(final.count("regular-answer-one") == 1 and final.count("regular-answer-two") == 1);
            try check(!final.visible("regular-answer-one")); // Actually reached scrollback.
        }
    }
}
