//! SSE（Server-Sent Events）增量解码器：把任意切分的网络字节流还原为完整事件，
//! 并交给 Sink 分发。协议解析（JSON）由上层适配器负责。

const std = @import("std");

/// 事件分发接口：通过函数指针把 (事件名, 数据) 交给调用方。
pub const Sink = struct {
    /// 调用方自定义的上下文指针，作为 emit_fn 的第一个参数。
    context: *anyopaque,
    /// 分发回调。参数为事件名与数据；数据不含末尾 LF，且尚未做 UTF-8 解码。
    emit_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
};

/// Incremental byte framing. UTF-8 is decoded only by the JSON adapter after a
/// complete event; network reads may split any codepoint or CRLF pair.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    /// 单个事件允许的最大字节数（data 与 event 字段合计），超出即报 EventTooLarge。
    max_event_bytes: usize,
    /// 当前未结束的行缓冲，遇到 CR 或 LF 时交给 endLine 处理。
    line: std.ArrayList(u8) = .empty,
    /// 当前事件累计的 data 内容，每行以 LF 结尾。
    data: std.ArrayList(u8) = .empty,
    /// 当前事件的 event 字段；为空时分发名为 message。
    event: std.ArrayList(u8) = .empty,
    /// 上一个字节是 CR 时为真，用来跳过紧随其后的 LF（CRLF 只算一个行结束）。
    skip_lf: bool = false,
    /// 是否仍处于流的第一行，只有第一行需要检查并剥离 UTF-8 BOM。
    first_line: bool = true,
    /// 当前事件是否出现过 data 字段；没有 data 的空事件不会分发。
    has_data: bool = false,
    /// 当前事件已消耗的字节数，分发后归零。
    event_bytes: usize = 0,

    /// 创建解码器。allocator 用于行与数据缓冲，调用方需保证 sink 在解码期间有效。
    pub fn init(allocator: std.mem.Allocator, max_event_bytes: usize, sink: Sink) Decoder {
        return .{ .allocator = allocator, .max_event_bytes = max_event_bytes, .sink = sink };
    }

    /// 释放内部缓冲。
    pub fn deinit(self: *Decoder) void {
        self.line.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.event.deinit(self.allocator);
    }

    /// 喂入一段任意切分的字节。可能分发零个或多个完整事件。
    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        // 逐字节处理，因此网络读取可以在任意位置切开（包括 UTF-8 多字节字符与 CRLF 中间）。
        for (bytes) |byte| {
            // 上一个字节是 CR 时，跳过紧随其后的 LF，避免 CRLF 被当成两个行结束。
            if (self.skip_lf) {
                self.skip_lf = false;
                if (byte == '\n') continue;
            }

            if (byte == '\r' or byte == '\n') {
                try self.endLine();
                self.skip_lf = byte == '\r';
            } else {
                // 限制单个事件的总字节数，防止恶意服务器无限增长内存。
                if (self.event_bytes >= self.max_event_bytes) return error.EventTooLarge;
                self.event_bytes += 1;
                try self.line.append(self.allocator, byte);
            }
        }
    }

    /// 处理一整行：空行表示事件结束并尝试分发；以冒号开头的行是注释；其余行按 SSE 字段解析。
    fn endLine(self: *Decoder) !void {
        var line = self.line.items;
        // 只有流的第一行可能带 UTF-8 BOM（EF BB BF），需要剥离。
        if (self.first_line) {
            self.first_line = false;
            if (std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
        }
        // 无论本行走哪个分支，行缓冲都在返回前清空，保留容量以便复用。
        defer self.line.clearRetainingCapacity();

        // 空行是事件边界：只有收到过 data 字段时才分发；随后重置事件级状态。
        if (line.len == 0) {
            if (self.has_data) {
                // 没有 event 字段时，事件名按 SSE 规范默认为 message。
                const name = if (self.event.items.len == 0) "message" else self.event.items;
                // Every data field contributes one LF; the final LF is omitted.
                try self.sink.emit_fn(self.sink.context, name, self.data.items[0 .. self.data.items.len - 1]);
            }

            // 分发后重置事件级状态，为下一个事件做准备。
            self.event_bytes = 0;
            self.has_data = false;
            self.data.clearRetainingCapacity();
            self.event.clearRetainingCapacity();
            return;
        }

        if (line[0] == ':') return; // Heartbeat/comment, not model content.

        // 按第一个冒号拆分字段名与值；没有冒号时整行是字段名，值为空。
        const colon = std.mem.findScalar(u8, line, ':');
        const field = if (colon) |i| line[0..i] else line;
        var value = if (colon) |i| line[i + 1 ..] else "";

        // 规范只去掉冒号后的一个空格，其余空白保留。
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        // data 字段按行追加，每行以 LF 结尾；event 字段记录下一次分发使用的事件名。
        if (std.mem.eql(u8, field, "data")) {
            if (self.event_bytes >= self.max_event_bytes) return error.EventTooLarge;
            self.event_bytes += 1;
            try self.data.appendSlice(self.allocator, value);
            try self.data.append(self.allocator, '\n');
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "event")) {
            self.event.clearRetainingCapacity();
            try self.event.appendSlice(self.allocator, value);
        }

        // id/retry/unknown fields do not introduce server-side session state.
    }
    /// 流结束时调用：若仍有未分发的事件则返回 IncompleteSseEvent，不会补发。
    pub fn finish(self: *const Decoder) !void {
        // EOF does not dispatch an unfinished SSE event.
        if (self.line.items.len != 0 or self.has_data or self.event.items.len != 0)
            return error.IncompleteSseEvent;
    }
};

/// 测试用：收集所有被分发的事件名与数据副本。
const Capture = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    /// 把事件名与数据复制到 arena 中保存，因为 Sink 传入的切片只在回调期间有效。
    fn emit(context: *anyopaque, event: []const u8, data: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.names.append(self.allocator, try self.allocator.dupe(u8, event));
        try self.values.append(self.allocator, try self.allocator.dupe(u8, data));
    }

    /// 生成供 Decoder 使用的 Sink。
    fn sink(self: *Capture) Sink {
        return .{ .context = self, .emit_fn = emit };
    }
};

// 验证：逐字节输入、UTF-8、CRLF、BOM、注释行与多行 data 都能正确处理。
test "SSE accepts byte-by-byte UTF8 CRLF BOM comments and multiline data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .allocator = arena.allocator() };
    var decoder = Decoder.init(std.testing.allocator, 1024, capture.sink());
    defer decoder.deinit();

    const bytes = "\xef\xbb\xbf: hello\r\nevent: delta\r\ndata: 中文\r\ndata: two\r\n\r\ndata: [DONE]\n\n";
    for (bytes) |byte| try decoder.feed(&.{byte});
    try decoder.finish();

    try std.testing.expectEqual(@as(usize, 2), capture.values.items.len);
    try std.testing.expectEqualStrings("delta", capture.names.items[0]);
    try std.testing.expectEqualStrings("中文\ntwo", capture.values.items[0]);
    try std.testing.expectEqualStrings("message", capture.names.items[1]);
    try std.testing.expectEqualStrings("[DONE]", capture.values.items[1]);
}

// 验证：未结束的事件在 finish 时报错且不分发；超出上限时报 EventTooLarge。
test "SSE rejects oversized and truncated events without dispatching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .allocator = arena.allocator() };
    var decoder = Decoder.init(std.testing.allocator, 20, capture.sink());
    defer decoder.deinit();

    try decoder.feed("data: unfinished");
    try std.testing.expectError(error.IncompleteSseEvent, decoder.finish());
    try std.testing.expectEqual(@as(usize, 0), capture.values.items.len);
    try std.testing.expectError(error.EventTooLarge, decoder.feed(" more and more"));
}

// 验证：空 data 与单独 CR 作为行结束符都是合法的。
test "SSE empty data and lone CR delimiters are valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .allocator = arena.allocator() };
    var decoder = Decoder.init(std.testing.allocator, 20, capture.sink());
    defer decoder.deinit();

    try decoder.feed("data\r\r");
    try decoder.finish();
    try std.testing.expectEqual(@as(usize, 1), capture.values.items.len);
    try std.testing.expectEqualStrings("", capture.values.items[0]);
}
