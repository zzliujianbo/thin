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
