//! 中文说明：终端输入解析。把原始字节流（UTF-8、控制字符、ESC 序列、bracketed paste）
//! 转换为 Event，并提供带 UTF-8 字形簇边界的单行编辑器 Editor。

const std = @import("std");
const text = @import("text.zig");

/// 解析器输出的键盘 / 控制事件。粘贴文本的 enter、cancel 等不会被当作按键处理。
pub const Event = union(enum) {
    /// 文本内容（合法 UTF-8）；pasted 表示来自 bracketed paste。
    text: struct { value: []const u8, pasted: bool },
    enter,
    paste_start,
    backspace,
    delete,
    left,
    right,
    home,
    end,
    clear,
    kill_end,
    cancel,
    quit,
    up,
    down,
    page_up,
    page_down,
    /// Kept separate from text so completion cannot mistake a paste for Tab.
    tab,
    toggle_reasoning,
    cycle_effort,
    escape,
};

/// 事件接收端。用函数指针回调代替泛型，便于在测试中替换。
pub const Sink = struct {
    /// 回调的上下文指针。
    context: *anyopaque,
    /// 实际处理事件的函数。
    emit_fn: *const fn (*anyopaque, Event) anyerror!void,

    fn emit(self: Sink, event: Event) !void {
        try self.emit_fn(self.context, event);
    }
};

/// 增量式输入解析器。每次 feed 可以只给一个字节，状态跨调用保留，因此能正确处理被拆分的 UTF-8 与 ESC 序列。
pub const Parser = struct {
    /// ESC 序列缓冲区（包含 ESC 本身），最长 32 字节。
    escape: [32]u8 = undefined,
    /// 0 表示不在 ESC 序列中；非 0 表示已收集的字节数。
    escape_len: usize = 0,
    /// 多字节 UTF-8 字符的临时缓冲。
    utf8: [4]u8 = undefined,
    /// 已收集的字节数；0 表示没有未完成的字符。
    utf8_len: usize = 0,
    /// 当前字符所需的总字节数。
    utf8_need: usize = 0,
    /// 是否处于 bracketed paste（ESC[200~ 与 ESC[201~ 之间）。
    pasted: bool = false,
    /// 上一个字节是否为 CR，用于把 CRLF 折叠为一次换行。
    pasted_cr: bool = false,

    /// Secret parsing rejects bytes that the normal editor would silently discard.
    secret: bool = false,
    stop_feed: bool = false,
    secret_paste: bool = false,
    secret_batch_paste: bool = false,

    /// Wipe scratch and discard the remainder of the current read on a mode change.
    pub fn secretMode(self: *Parser, enabled: bool) void {
        std.crypto.secureZero(u8, &self.escape);
        std.crypto.secureZero(u8, &self.utf8);
        self.escape_len = 0;
        self.utf8_len = 0;
        self.utf8_need = 0;
        self.pasted = false;
        self.pasted_cr = false;
        self.secret_paste = false;
        self.secret_batch_paste = false;
        self.secret = enabled;
        self.stop_feed = true;
    }

    fn invalid(self: *Parser, sink: Sink) !void {
        if (self.secret) try sink.emit(.{ .text = .{ .value = "\x00", .pasted = self.pasted } });
    }

    /// UI-owned ambiguity timeout for a standalone Escape, including canceling
    /// secret entry. Partial CSI and pasted/batch-tail escapes never navigate.
    pub fn expireEscape(self: *Parser, sink: Sink) !void {
        if (self.escape_len != 1 or self.pasted or (self.secret and self.secret_batch_paste)) return;
        self.escape_len = 0;
        std.crypto.secureZero(u8, &self.escape);
        try sink.emit(.escape);
    }

    /// 逐字节解析输入。
    pub fn feed(self: *Parser, bytes: []const u8, sink: Sink) !void {
        self.stop_feed = false;
        self.secret_batch_paste = self.secret and self.pasted;
        for (bytes) |value| {
            try self.byte(value, sink);
            if (self.stop_feed) break;
        }
    }

    /// 状态机核心，按顺序处理：ESC 序列 -> UTF-8 续字节 -> 粘贴模式 -> 普通按键。
    fn byte(self: *Parser, b: u8, sink: Sink) !void {
        // CRLF folding requires adjacent bytes, including across feed calls.
        // ESC/UTF-8 early returns must also break adjacency; a CR below sets it again.
        if (b != '\n') self.pasted_cr = false;
        // 中文：状态一，正在收集 ESC 序列。
        if (self.escape_len != 0) {
            // 中文：序列中途的 Ctrl-C / Ctrl-D 仍视为取消 / 退出；粘贴中则忽略。
            if (!self.pasted and (b == 3 or b == 4)) {
                self.escape_len = 0;
                return sink.emit(if (b == 3) .cancel else .quit);
            }

            // 中文：序列超长则丢弃，防止缓冲区溢出。
            if (self.escape_len == self.escape.len) {
                self.escape_len = 0;
                return self.invalid(sink);
            }
            self.escape[self.escape_len] = b;
            self.escape_len += 1;

            const seq = self.escape[0..self.escape_len];

            // 中文：ESC[（CSI）或 ESC O（SS3）之后继续收集，等待终结字节。
            if (self.escape_len == 2 and (b == '[' or b == 'O')) return;
            // 中文：参数字节（0x30-0x3f）之后仍未结束，继续收集。
            if (self.escape_len > 2 and b >= 0x30 and b <= 0x3f) return;

            // 中文：遇到终结字节后，无论是否匹配，返回前都重置为非序列状态。
            defer self.escape_len = 0;

            // 中文：bracketed paste 的开始 / 结束标记。
            // 中文：粘贴结束时同时清除 pasted_cr，避免跨粘贴影响 CRLF 判断。
            if (std.mem.eql(u8, seq, "\x1b[200~")) {
                if (self.secret and self.pasted) try self.invalid(sink);
                self.pasted = true;
                if (self.secret) {
                    self.secret_paste = true;
                    self.secret_batch_paste = true;
                }
                return sink.emit(.paste_start);
            }
            if (std.mem.eql(u8, seq, "\x1b[201~")) {
                if (self.secret and !self.pasted) try self.invalid(sink);
                self.pasted = false;
                self.pasted_cr = false;
                return;
            }

            if (self.pasted) return self.invalid(sink); // Pasted escape sequences never become keys/approvals.

            // 中文：常见光标与编辑键映射，同时兼容 SS3 与 CSI 两种编码。
            const keys = .{
                .{ "\x1bOH", Event.home },            .{ "\x1bOF", Event.end },
                .{ "\x1bOA", Event.up },              .{ "\x1bOB", Event.down },
                .{ "\x1bOC", Event.right },           .{ "\x1bOD", Event.left },
                .{ "\x1b[D", Event.left },            .{ "\x1b[C", Event.right },
                .{ "\x1b[A", Event.up },              .{ "\x1b[B", Event.down },
                .{ "\x1b[H", Event.home },            .{ "\x1b[F", Event.end },
                .{ "\x1b[1~", Event.home },           .{ "\x1b[4~", Event.end },
                .{ "\x1b[3~", Event.delete },         .{ "\x1b[5~", Event.page_up },
                .{ "\x1b[6~", Event.page_down },      .{ "\x1b[Z", Event.cycle_effort },
                .{ "\x1b[1;2Z", Event.cycle_effort }, .{ "\x1b[9;2u", Event.cycle_effort },
            };
            inline for (keys) |key| if (std.mem.eql(u8, seq, key[0])) {
                if (self.secret and key[1] == .cycle_effort) return;
                try sink.emit(key[1]);
                return;
            };

            // 中文：Alt+Enter（ESC CR）视为插入换行。
            if (std.mem.eql(u8, seq, "\x1b\r")) {
                try sink.emit(.{ .text = .{ .value = "\n", .pasted = false } });
            } else try self.invalid(sink);
            return;
        }

        // 中文：ESC 开始一个新序列，并丢弃尚未完成的 UTF-8 字符。
        if (b == 0x1b) {
            if (self.utf8_len != 0) try self.invalid(sink);
            self.escape[0] = b;
            self.escape_len = 1;
            self.utf8_len = 0;
            return;
        }

        // 中文：状态二，正在收集多字节 UTF-8 字符。
        if (self.utf8_len > 0) {
            // 中文：不是续字节说明前一字符被截断，丢弃残缺部分，并把当前字节作为新输入重新处理。
            if (b & 0xc0 != 0x80) {
                self.utf8_len = 0;
                try self.invalid(sink);
                return self.byte(b, sink);
            }

            self.utf8[self.utf8_len] = b;
            self.utf8_len += 1;

            // 中文：收齐后整体校验 UTF-8，非法序列被静默丢弃。
            if (self.utf8_len == self.utf8_need) {
                const s = self.utf8[0..self.utf8_len];
                if (std.unicode.utf8ValidateSlice(s)) try sink.emit(.{ .text = .{ .value = s, .pasted = self.pasted } }) else try self.invalid(sink);
                self.utf8_len = 0;
            }
            return;
        }

        // 中文：多字节字符的首字节，记录所需长度；非法首字节直接忽略。
        if (b >= 0x80) {
            self.utf8_need = std.unicode.utf8ByteSequenceLength(b) catch return self.invalid(sink);
            self.utf8[0] = b;
            self.utf8_len = 1;
            return;
        }

        // 中文：状态三，粘贴模式。CR、LF、CRLF 都转为换行，其他控制字符丢弃，仅保留 Tab。
        if (self.pasted) {
            // 中文：CRLF 中的 LF 在 CR 时已输出过换行，这里跳过。
            if (b == '\n' and self.pasted_cr) {
                self.pasted_cr = false;
                return;
            }

            self.pasted_cr = b == '\r';
            if (b == '\r' or b == '\n') return sink.emit(.{ .text = .{ .value = "\n", .pasted = true } });
            if (b < 0x20 and b != '\t' or b == 0x7f) return self.invalid(sink);
        } else switch (b) {
            3 => return sink.emit(.cancel),
            4 => return sink.emit(.quit),
            13 => return sink.emit(if (self.secret and self.secret_batch_paste) .{ .text = .{ .value = "\n", .pasted = true } } else .enter),
            10 => return sink.emit(.{ .text = .{ .value = "\n", .pasted = false } }),
            8, 127 => return sink.emit(.backspace),
            1 => return sink.emit(.home),
            5 => return sink.emit(.end),
            21 => return sink.emit(.clear),
            11 => return sink.emit(.kill_end),
            18 => return sink.emit(.toggle_reasoning),
            9 => return sink.emit(if (self.secret) .{ .text = .{ .value = "\t", .pasted = false } } else .tab),
            // 中文：未映射的其他控制字符直接忽略。
            else => if (b < 0x20) return self.invalid(sink),
        }

        // 中文：状态四的普通字符输出（可打印字符，或粘贴中允许的字符）。
        const one = [_]u8{b};
        try sink.emit(.{ .text = .{ .value = &one, .pasted = self.pasted } });
    }
};
/// Dedicated fixed-capacity secret storage. Never allocate or copy into the editor.
/// Invalid input is latched until explicit clear/cancel; a truncated key cannot save.
pub const SecretInput = struct {
    bytes: [16384]u8 = @splat(0),
    len: usize = 0,
    failed: bool = false,

    pub fn wipe(self: *SecretInput) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
        self.failed = false;
    }

    pub fn deinit(self: *SecretInput) void {
        self.wipe();
    }

    pub fn reject(self: *SecretInput) void {
        self.wipe();
        self.failed = true;
    }

    pub fn insert(self: *SecretInput, data: []const u8) void {
        if (self.failed) return;
        if (data.len > self.bytes.len - self.len) return self.reject();
        // API keys are printable ASCII without whitespace or control characters.
        for (data) |b| if (b < 0x21 or b > 0x7e) return self.reject();
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn erase(self: *SecretInput) void {
        if (self.len == 0) return;
        self.len -= 1;
        std.crypto.secureZero(u8, self.bytes[self.len..][0..1]);
    }

    pub fn value(self: *const SecretInput) ?[]const u8 {
        return if (self.failed or self.len == 0) null else self.bytes[0..self.len];
    }
};

/// 单行编辑器。保存 UTF-8 字节，光标以字节偏移表示，并保证光标始终落在字形簇边界上。
pub const Editor = struct {
    /// 用于 bytes 增长的分配器。
    allocator: std.mem.Allocator,
    /// 编辑缓冲区（UTF-8）。
    bytes: std.ArrayList(u8) = .empty,
    /// 光标的字节偏移，始终位于字形簇边界。
    cursor: usize = 0,

    /// 释放缓冲区。
    pub fn deinit(self: *Editor) void {
        self.bytes.deinit(self.allocator);
    }

    /// 在光标处插入 value。超过 65536 字节上限时返回 false 且不修改内容。
    pub fn insert(self: *Editor, value: []const u8) !bool {
        if (value.len > 65536 - self.bytes.items.len) return false;

        const old = self.bytes.items.len;
        try self.bytes.resize(self.allocator, old + value.len);

        // 中文：先把光标后的尾部整体后移，腾出空间再拷贝新内容。
        std.mem.copyBackwards(u8, self.bytes.items[self.cursor + value.len ..], self.bytes.items[self.cursor..old]);
        @memcpy(self.bytes.items[self.cursor..][0..value.len], value);
        self.cursor += value.len;
        return true;
    }

    /// 清空内容并把光标归零；保留已分配的容量以便复用。
    pub fn clear(self: *Editor) void {
        self.bytes.clearRetainingCapacity();
        self.cursor = 0;
    }

    /// 返回光标前一个字形簇的起始偏移：从头逐簇前进，直到下一簇会到达或越过光标。
    fn previous(self: *Editor) usize {
        var pos: usize = 0;
        while (pos < self.cursor) {
            const next = text.nextCluster(self.bytes.items, pos, 0).end;
            if (next >= self.cursor) return pos;
            pos = next;
        }
        return 0;
    }

    /// 光标左移一个字形簇。
    pub fn left(self: *Editor) void {
        self.cursor = self.previous();
    }

    /// 光标右移一个字形簇；已在末尾时不动。
    pub fn right(self: *Editor) void {
        if (self.cursor < self.bytes.items.len) self.cursor = text.nextCluster(self.bytes.items, self.cursor, 0).end;
    }

    /// 删除光标处的一个字形簇；光标在末尾时不动。
    pub fn delete(self: *Editor) void {
        if (self.cursor == self.bytes.items.len) return;
        const end = text.nextCluster(self.bytes.items, self.cursor, 0).end;
        std.mem.copyForwards(u8, self.bytes.items[self.cursor..], self.bytes.items[end..]);
        self.bytes.items.len -= end - self.cursor;
    }

    /// 删除光标前的一个字形簇（先左移再删除）。
    pub fn backspace(self: *Editor) void {
        if (self.cursor > 0) {
            self.left();
            self.delete();
        }
    }
};

/// 测试用的事件记录器，累计文本内容以及 enter、cancel、粘贴文本的次数。
const Record = struct {
    /// 收集到的文本缓冲区。
    data: [256]u8 = undefined,
    len: usize = 0,
    enters: usize = 0,
    cancels: usize = 0,
    pasted: usize = 0,
    cycles: usize = 0,
    escapes: usize = 0,

    fn event(ctx: *anyopaque, ev: Event) !void {
        const self: *Record = @ptrCast(@alignCast(ctx));

        switch (ev) {
            .text => |v| {
                @memcpy(self.data[self.len..][0..v.value.len], v.value);
                self.len += v.value.len;
                if (v.pasted) self.pasted += 1;
            },
            .enter => self.enters += 1,
            .cancel => self.cancels += 1,
            .cycle_effort => self.cycles += 1,
            .escape => self.escapes += 1,
            else => {},
        }
    }
};

// 验证被拆分的 UTF-8、粘贴中的 CR / Ctrl-C / 方向键都不会触发提交、取消或授权。
test "split UTF8 and bracketed paste cannot submit, cancel or authorize" {
    var record = Record{};
    var parser = Parser{};
    const sink = Sink{ .context = &record, .emit_fn = Record.event };

    const sequence = "你好\x1b[200~y\r\ny\x03\x1b[A\x1b[201~\r\x03";
    for (sequence) |b| try parser.feed(&.{b}, sink);

    try std.testing.expectEqualStrings("你好y\ny", record.data[0..record.len]);
    try std.testing.expectEqual(@as(usize, 1), record.enters);
    try std.testing.expectEqual(@as(usize, 1), record.cancels);
    try std.testing.expect(record.pasted > 0);
}

test "pasted CRLF requires immediate byte adjacency across feeds" {
    const cases = .{
        .{ "A\r你\nB", "A\n你\nB" },
        .{ "A\r\nB", "A\nB" },
        .{ "A\r\r\nB", "A\n\nB" },
        .{ "A\r\x1b[A\nB", "A\n\nB" },
        .{ "A\r\xe4\nB", "A\n\nB" },
    };
    inline for (cases) |case| {
        for ([_]bool{ false, true }) |split| {
            var record = Record{};
            var parser = Parser{};
            const sink = Sink{ .context = &record, .emit_fn = Record.event };
            const sequence = "\x1b[200~" ++ case[0] ++ "\x1b[201~";
            if (split) {
                for (sequence) |b| try parser.feed(&.{b}, sink);
            } else try parser.feed(sequence, sink);
            try std.testing.expectEqualStrings(case[1], record.data[0..record.len]);
            try std.testing.expectEqual(@as(usize, 0), record.enters);
            try std.testing.expectEqual(@as(usize, 0), record.cancels);
        }
    }
}

test "split ShiftTab cannot change secret settings and only fresh Escape cancels" {
    var record = Record{};
    var parser = Parser{};
    const sink = Sink{ .context = &record, .emit_fn = Record.event };
    for ("\x1b[Z\x1b[1;2Z\x1b[9;2u") |byte| try parser.feed(&.{byte}, sink);
    try std.testing.expectEqual(@as(usize, 3), record.cycles);
    try parser.feed("\x1b[200~\x1b[Z\x1b[201~", sink);
    try std.testing.expectEqual(@as(usize, 3), record.cycles);
    try parser.feed("\x1b[", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 0), record.escapes);
    try parser.feed("Z", sink);
    try std.testing.expectEqual(@as(usize, 4), record.cycles);
    try parser.feed("\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 1), record.escapes);
    parser.secretMode(true);
    try parser.feed("\x1b[Z", sink);
    try parser.feed("\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 4), record.cycles);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
    try parser.feed("\x1b[200~key\x1b[201~\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
    parser.secretMode(true);
    try parser.feed("\x1b[200~\x1b", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
    parser.secretMode(true);
    try parser.feed("\x1b[", sink);
    try parser.expireEscape(sink);
    try std.testing.expectEqual(@as(usize, 2), record.escapes);
}

// 验证 Editor 的字形簇边界与输入长度上限。
test "editor preserves UTF8 cluster boundaries and bounded input" {
    try text.initLocale();

    var editor = Editor{ .allocator = std.testing.allocator };
    defer editor.deinit();

    try std.testing.expect(try editor.insert("a你e\u{301}"));
    editor.backspace();
    try std.testing.expectEqualStrings("a你", editor.bytes.items);

    editor.left();
    editor.delete();
    try std.testing.expectEqualStrings("a", editor.bytes.items);

    const huge: [65536]u8 = @splat('x');
    try std.testing.expect(!try editor.insert(&huge));
}

test "secret storage erases removed bytes and fails closed on invalid input and overflow" {
    var secret = SecretInput{};
    defer secret.deinit();
    secret.insert("abc");
    secret.erase();
    try std.testing.expectEqualStrings("ab", secret.value().?);
    try std.testing.expectEqual(@as(u8, 0), secret.bytes[2]);
    secret.wipe();
    const full: [16384]u8 = @splat('x');
    secret.insert(&full);
    try std.testing.expectEqual(@as(usize, 16384), secret.len);
    secret.insert("x");
    try std.testing.expect(secret.failed and secret.value() == null);
    for (secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    secret.insert("not-a-recovery");
    try std.testing.expect(secret.value() == null);
    secret.wipe();
    secret.insert("abc\n");
    try std.testing.expect(secret.failed and secret.len == 0);
    secret.wipe();
    secret.insert("abc");
    secret.deinit();
    for (secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "secret parser transitions erase scratch and discard the rest of the feed" {
    const State = struct {
        parser: *Parser,
        events: usize = 0,
        fn emit(ctx: *anyopaque, _: Event) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.events += 1;
            self.parser.secretMode(false);
        }
    };
    var parser = Parser{};
    parser.secretMode(true);
    var state = State{ .parser = &parser };
    try parser.feed("\xc3\xa9trailing-secret", .{ .context = &state, .emit_fn = State.emit });
    try std.testing.expectEqual(@as(usize, 1), state.events);
    for (parser.utf8) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (parser.escape) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "secret paste control bytes and embedded terminator enter never become save" {
    var record = Record{};
    var parser = Parser{};
    parser.secretMode(true);
    const sink = Sink{ .context = &record, .emit_fn = Record.event };
    try parser.feed("\x1b[200~key\x00\r\n\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(usize, 0), record.enters);
    try std.testing.expect(std.mem.findScalar(u8, record.data[0..record.len], 0) != null);
    try parser.feed("\xff", sink);
    try std.testing.expectEqual(@as(u8, 0), record.data[record.len - 1]);
}
