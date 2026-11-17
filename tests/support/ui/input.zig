const Record = struct {
    /// 收集到的文本缓冲区。
    data: [256]u8 = undefined,
    len: usize = 0,
    enters: usize = 0,
    follow_ups: usize = 0,
    cancels: usize = 0,
    pasted: usize = 0,
    cycles: usize = 0,
    escapes: usize = 0,
    cursor_lefts: usize = 0,
    cursor_rights: usize = 0,
    word_lefts: usize = 0,
    word_rights: usize = 0,
    kill_starts: usize = 0,
    kill_words: usize = 0,

    fn event(ctx: *anyopaque, ev: Event) !void {
        const self: *Record = @ptrCast(@alignCast(ctx));

        switch (ev) {
            .text => |v| {
                @memcpy(self.data[self.len..][0..v.value.len], v.value);
                self.len += v.value.len;
                if (v.pasted) self.pasted += 1;
            },
            .enter => self.enters += 1,
            .follow_up => self.follow_ups += 1,
            .cancel => self.cancels += 1,
            .cycle_effort => self.cycles += 1,
            .escape => self.escapes += 1,
            .cursor_left => self.cursor_lefts += 1,
            .cursor_right => self.cursor_rights += 1,
            .word_left => self.word_lefts += 1,
            .word_right => self.word_rights += 1,
            .kill_start => self.kill_starts += 1,
            .kill_word => self.kill_words += 1,
            else => {},
        }
    }
};
