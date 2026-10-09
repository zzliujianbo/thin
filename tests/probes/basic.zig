//! 基础探针：验证 Io.Threaded 的并发任务取消是否及时响应、JSON 对 Unicode 和可选字段的往返处理，以及临时文件替换的原子性语义。

const std = @import("std");
// 测试断言工具别名。
const t = std.testing;
const h = @import("common.zig");
const Io = h.Io;

/// 并发任务：先置位 ready 通知已启动，然后睡眠 60 秒，用于测试取消。
fn sleeper(io: Io, ready: *h.Flag) !void {
    ready.store(true, .release);
    try Io.sleep(io, .fromSeconds(60), .awake);
}

// 验证并发任务在运行中被取消时，cancel 会在 2 秒内返回并报告 error.Canceled。
test "probe: Threaded concurrent task and cancellation stay responsive" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    var ready = h.Flag.init(false);
    var future = try Io.concurrent(io, sleeper, .{ io, &ready });
    defer future.cancel(io) catch {};

    // 等待任务真正开始运行后再记录起始时间并取消。
    try h.waitFlag(io, &ready, 2000);
    const started = Io.Clock.awake.now(io);
    try t.expectError(error.Canceled, future.cancel(io));
    try t.expect(started.untilNow(io, .awake).toMilliseconds() < 2000);
}

// 验证 JSON 序列化再解析后，中文/emoji 文本保持不变，且 null 的可选字段仍然为 null。
test "probe: JSON survives Unicode and explicit optional usage fields" {
    const Value = struct { text: []const u8, input_tokens: ?u64, cached_tokens: ?u64 };
    const original = Value{ .text = "中文🙂\ncode", .input_tokens = 100, .cached_tokens = null };

    const encoded = try std.json.Stringify.valueAlloc(h.alloc, original, .{});
    defer h.alloc.free(encoded);
    const parsed = try std.json.parseFromSlice(Value, h.alloc, encoded, .{});
    defer parsed.deinit();

    try t.expectEqualStrings(original.text, parsed.value.text);
    try t.expectEqual(@as(?u64, 100), parsed.value.input_tokens);
    try t.expectEqual(@as(?u64, null), parsed.value.cached_tokens);
}

// 验证先写临时文件再 rename 替换时：rename 之前旧内容保持不变，rename 之后临时文件消失。
test "probe: temporary file replacement preserves old contents until rename" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "state", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state.tmp", .data = "new" });
    const before = try tmp.dir.readFileAlloc(io, "state", h.alloc, .limited(128));
    defer h.alloc.free(before);
    try t.expectEqualStrings("old", before);

    try tmp.dir.rename("state.tmp", tmp.dir, "state", io);

    const after = try tmp.dir.readFileAlloc(io, "state", h.alloc, .limited(128));
    defer h.alloc.free(after);
    try t.expectEqualStrings("new", after);
    try t.expectError(error.FileNotFound, tmp.dir.openFile(io, "state.tmp", .{}));
}
