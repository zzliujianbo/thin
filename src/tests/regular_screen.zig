//! Bounded, fixed 80x24 VT subset for offline regular-terminal acceptance.
//! Not a terminal emulator: no resize/reflow claim. Non-ASCII glyphs occupy
//! cells but assertions deliberately use ASCII markers only.
const std = @import("std");
pub const prior = "THIN-PTY-PRIOR-OUTPUT-SENTINEL";

const Csi = struct { args: []const u8, final: u8 };

/// CAN/SUB cancel a partial CSI; a fresh ESC starts a new sequence instead.
fn csi(bytes: []const u8, position: *usize) !?Csi {
    const start = position.*;
    while (position.* < bytes.len) {
        const b = bytes[position.*];
        if (b == 0x18 or b == 0x1a) {
            position.* += 1;
            return null;
        }
        if (b == 0x1b) return null;
        position.* += 1;
        if (b >= 0x40 and b <= 0x7e) return .{ .args = bytes[start .. position.* - 1], .final = b };
        if (b < 0x20) return error.UnsupportedControl;
    }
    return error.IncompleteCsi;
}

/// Scan every CSI (including compound private modes), not just known literals.
pub fn rejectFullscreen(bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] != 0x1b) {
            i += 1;
            continue;
        }
        i += 1;
        if (i == bytes.len or bytes[i] != '[') continue;
        i += 1;
        const code = try csi(bytes, &i) orelse continue;
        if (code.final == 'H' or code.final == 'f' or code.final == 'J' or code.final == 'r') return error.FullscreenSequence;
        if ((code.final == 'h' or code.final == 'l') and std.mem.startsWith(u8, code.args, "?")) {
            var parts = std.mem.splitScalar(u8, code.args[1..], ';');
            while (parts.next()) |part| {
                const mode = std.fmt.parseInt(u16, part, 10) catch continue;
                if (mode == 47 or mode == 1047 or mode == 1049) return error.FullscreenSequence;
            }
        }
    }
}

pub const Screen = struct {
    const width = 80;
    const height = 24;
    const Line = [width]u8;
    grid: [height]Line = @splat(@splat(' ')),
    history: [2048]Line = undefined,
    history_len: usize = 0,
    row: usize = 0,
    col: usize = 0,
    wrap: bool = false,

    fn down(self: *Screen) !void {
        if (self.row < height - 1) {
            self.row += 1;
        } else {
            if (self.history_len == self.history.len) return error.ScrollbackLimit;
            self.history[self.history_len] = self.grid[0];
            self.history_len += 1;
            for (0..height - 1) |r| self.grid[r] = self.grid[r + 1];
            self.grid[height - 1] = @splat(' ');
        }
    }

    fn cell(self: *Screen, value: u8) !void {
        if (self.wrap) {
            self.col = 0;
            try self.down();
            self.wrap = false;
        }
        self.grid[self.row][self.col] = value;
        if (self.col == width - 1) self.wrap = true else self.col += 1;
    }

    /// Replay a complete bounded capture. Split/incomplete frames are rejected.
    pub fn replay(self: *Screen, bytes: []const u8) !void {
        try rejectFullscreen(bytes);
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            i += 1;
            switch (b) {
                '\r' => {
                    self.col = 0;
                    self.wrap = false;
                },
                '\n' => {
                    self.wrap = false;
                    try self.down();
                },
                0x08 => {
                    self.col -|= 1;
                    self.wrap = false;
                },
                '\t' => {
                    self.col = @min(width - 1, (self.col / 8 + 1) * 8);
                    self.wrap = false;
                },
                0x07, 0x18, 0x1a => {},
                0x1b => {
                    if (i >= bytes.len) return error.UnsupportedEscape;
                    if (bytes[i] == 0x18 or bytes[i] == 0x1a or bytes[i] == 0x1b) continue;
                    if (bytes[i] != '[') return error.UnsupportedEscape;
                    i += 1;
                    const code = try csi(bytes, &i) orelse continue;
                    const args = code.args;
                    const final = code.final;
                    if (final == 'm') continue; // SGR does not change cells/cursor.
                    if (final == 'h' or final == 'l') {
                        if (!std.mem.eql(u8, args, "?25") and !std.mem.eql(u8, args, "?2004")) return error.UnsupportedMode;
                        continue; // Cursor visibility and bracketed paste.
                    }
                    const n = if (args.len == 0) 0 else try std.fmt.parseInt(usize, args, 10);
                    const step = @max(1, n);
                    switch (final) {
                        'A' => self.row -|= step,
                        'B' => self.row = @min(height - 1, self.row +| step),
                        'C' => self.col = @min(width - 1, self.col +| step),
                        'D' => self.col -|= step,
                        'K' => switch (n) {
                            0 => @memset(self.grid[self.row][self.col..], ' '),
                            1 => @memset(self.grid[self.row][0 .. self.col + 1], ' '),
                            2 => @memset(&self.grid[self.row], ' '),
                            else => return error.UnsupportedErase,
                        },
                        else => return error.UnsupportedCsi,
                    }
                    self.wrap = false;
                },
                0x20...0x7e => try self.cell(b),
                0x80...0xff => {
                    const len = try std.unicode.utf8ByteSequenceLength(b);
                    if (i - 1 + len > bytes.len) return error.IncompleteUtf8;
                    const cp = try std.unicode.utf8Decode(bytes[i - 1 ..][0..len]);
                    i += len - 1;
                    // Fixture CJK is wide; accents are single-cell. This is not
                    // a general grapheme/emoji width implementation.
                    try self.cell('~');
                    if (cp >= 0x2e80 and cp <= 0x9fff) try self.cell('~');
                },
                else => return error.UnsupportedControl,
            }
        }
    }

    pub fn visible(self: *const Screen, needle: []const u8) bool {
        for (&self.grid) |line| if (std.mem.indexOf(u8, &line, needle) != null) return true;
        return false;
    }

    pub fn count(self: *const Screen, needle: []const u8) usize {
        var total: usize = 0;
        for (self.history[0..self.history_len]) |line| total += std.mem.count(u8, &line, needle);
        for (&self.grid) |line| total += std.mem.count(u8, &line, needle);
        return total;
    }
};

test "regular grid retains prior output and committed answers through tail redraw" {
    var s: Screen = .{};
    try s.replay(prior ++ "\r\nfirst-answer\r\nold tail\r\ninput\r\x1b[1A\x1b[2K\rsecond-answer\r\n\x1b[2K\r> \x1b[2C\x1b[1D\x1b[0m\x1b[?25h\x1b[?2004l");
    try std.testing.expect(s.visible("second-answer"));
    try std.testing.expectEqual(@as(usize, 1), s.count("first-answer"));
    for (0..30) |_| try s.replay("\r\n");
    try std.testing.expect(!s.visible(prior));
    try std.testing.expectEqual(@as(usize, 1), s.count(prior));
    try std.testing.expectEqual(@as(usize, 1), s.count("second-answer"));
}

test "reject fullscreen variants and erased historical-only approval" {
    for ([_][]const u8{ "\x1b[?1049h", "\x1b[?25;47l", "\x1b[?1047h", "\x1b[H", "\x1b[2;3f", "\x1b[0J", "\x1b[1;24r" }) |bad|
        try std.testing.expectError(error.FullscreenSequence, rejectFullscreen(bad));
    var s: Screen = .{};
    try s.replay("Approval #1 date -Ins\r\x1b[2K");
    try std.testing.expect(!s.visible("Approval #"));
    try std.testing.expectError(error.IncompleteCsi, s.replay("\x1b["));
}

test "CAN cancels partial reclaim without hiding later forbidden sequences" {
    var s: Screen = .{};
    try s.replay(prior ++ "\r\x1b[2\x18\x1b[0m\r\nanswer\x1b\x18\r\n");
    try std.testing.expectEqual(@as(usize, 1), s.count(prior));
    try std.testing.expect(s.visible("answer"));
    try std.testing.expectError(error.FullscreenSequence, rejectFullscreen("\x1b[2\x18\x1b[?1049h"));
    try std.testing.expectError(error.FullscreenSequence, rejectFullscreen("\x1b[2\x1b[2J"));
}

test "cursor movement erase and delayed wrapping" {
    var s: Screen = .{};
    try s.replay("abc\r\x1b[2C\x1b[1KX\x1b[1B\rbelow\x1b[1A\r");
    try std.testing.expect(s.visible("  X"));
    try std.testing.expect(s.visible("below"));
    var wrap: Screen = .{};
    try wrap.replay(&(@as([80]u8, @splat('x'))));
    try std.testing.expectEqual(@as(usize, 0), wrap.row);
    try wrap.replay("y");
    try std.testing.expectEqual(@as(usize, 1), wrap.row);
}
