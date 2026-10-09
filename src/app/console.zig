//! Non-interactive host: no implicit approval; final committed visible answer
//! only. Drafts/opaque replay never reach stdout, and callbacks do not block on it.

const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");

/// --print 模式的无交互客户端：收集最终已提交的可见回答，并拒绝所有特权工具调用。
/// 回调在 Runtime 的线程中执行，必须快速返回，不得阻塞。
pub const Console = struct {
    allocator: std.mem.Allocator,

    /// 最终回答文本，上限 256 KiB。每次 assistant_committed 会覆盖旧内容。
    answer: std.ArrayList(u8) = .empty,
    /// 回答因超出上限而被截断时为 true（只影响显示，不影响模型历史）。
    clipped: bool = false,
    /// 被拒绝的特权工具调用次数，用于 main 提示用户。
    denied: usize = 0,
    /// Responses 协议不被支持而已降级为 Chat 时为 true。
    fallback: bool = false,

    /// 释放累积的回答缓冲区。
    pub fn deinit(self: *Console) void {
        self.answer.deinit(self.allocator);
    }

    /// 生成 Runtime 需要的 Host 接口，使用本对象作为上下文指针。
    pub fn host(self: *Console) r.Host {
        return .{ .context = self, .emit_fn = emit, .authorize_fn = authorize };
    }

    /// 处理 Runtime 事件。只有 assistant_committed 会写入回答；草稿、不透明的回放内容都被忽略。
    fn emit(ctx: ?*anyopaque, event: r.Event, _: *const p.Cancellation) !void {
        const self: *Console = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .assistant_committed => |blocks| {
                self.answer.clearRetainingCapacity();
                self.clipped = false;
                for (blocks) |block| if (block == .text) {
                    // 剩余可用空间。上限与 main.zig 中的 sanitize 保持一致。
                    const room = 256 * 1024 - self.answer.items.len;
                    var end = @min(room, block.text.len);

                    // 截断点不能落在 UTF-8 多字节字符中间（0x80..0xBF 为续编码字节），
                    // 因此向前回退到字符边界，防止输出乱码。
                    while (end > 0 and end < block.text.len and block.text[end] & 0xc0 == 0x80) end -= 1;

                    try self.answer.appendSlice(self.allocator, block.text[0..end]);
                    if (end != block.text.len) {
                        self.clipped = true;
                        break;
                    }
                };
            },
            .fallback => self.fallback = true,
            else => {},
        }
    }

    /// --print 模式不自动批准任何特权操作；计数并无条件拒绝。
    fn authorize(ctx: ?*anyopaque, _: r.Permission, _: *const p.Cancellation) !r.Decision {
        const self: *Console = @ptrCast(@alignCast(ctx.?));
        self.denied += 1;
        return .deny;
    }
};
