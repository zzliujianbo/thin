//! Bounded VT subset (up to 160x24, default 80x24) for offline acceptance.
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
                if (code.final == 'h' and (mode == 1000 or mode == 1002 or mode == 1003 or mode == 1006)) return error.MouseCaptureSequence;
            }
        }
    }
}

pub const Screen = struct {
    const width = 160;
    const height = 24;
    const Line = [width]u8;
    grid: [height]Line = @splat(@splat(' ')),
    history: [2048]Line = undefined,
    history_len: usize = 0,
    row: usize = 0,
    col: usize = 0,
    wrap: bool = false,
    /// Bounded logical dimensions. Changing these directly is only valid before
    /// output; this fixture deliberately does not emulate terminal text reflow.
    columns: usize = 80,
    rows: usize = height,

    fn down(self: *Screen) !void {
        if (self.row < self.rows - 1) {
            self.row += 1;
        } else {
            if (self.history_len == self.history.len) return error.ScrollbackLimit;
            self.history[self.history_len] = self.grid[0];
            self.history_len += 1;
            for (0..self.rows - 1) |r| self.grid[r] = self.grid[r + 1];
            self.grid[self.rows - 1] = @splat(' ');
        }
    }

    fn cell(self: *Screen, value: u8) !void {
        if (self.wrap) {
            self.col = 0;
            try self.down();
            self.wrap = false;
        }
        self.grid[self.row][self.col] = value;
        if (self.col == self.columns - 1) self.wrap = true else self.col += 1;
    }

    /// Replay a complete bounded capture. Split/incomplete frames are rejected.
    pub fn replay(self: *Screen, bytes: []const u8) !void {
        if (self.columns == 0 or self.columns > width or self.rows == 0 or self.rows > height)
            return error.InvalidScreenSize;
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
                    self.col = @min(self.columns - 1, (self.col / 8 + 1) * 8);
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
                    if (final == 'n' and std.mem.eql(u8, args, "6")) continue; // Cursor position query is observational.
                    if (final == 'h' or final == 'l') {
                        if (!std.mem.eql(u8, args, "?25") and !std.mem.eql(u8, args, "?2004") and !std.mem.eql(u8, args, "?2026")) return error.UnsupportedMode;
                        // Logical screen only: accept sync mode without claiming
                        // physical presentation timing or terminal support.
                        continue;
                    }
                    const n = if (args.len == 0) 0 else try std.fmt.parseInt(usize, args, 10);
                    const step = @max(1, n);
                    switch (final) {
                        'A' => self.row -|= step,
                        'B' => self.row = @min(self.rows - 1, self.row +| step),
                        'C' => self.col = @min(self.columns - 1, self.col +| step),
                        'D' => self.col -|= step,
                        'M' => {
                            // DL shifts only cursor..bottom, adds no scrollback,
                            // and does not move the cursor. No scroll region exists.
                            const count_ = @min(step, self.rows - self.row);
                            for (self.row..self.rows - count_) |row_index|
                                self.grid[row_index] = self.grid[row_index + count_];
                            for (self.rows - count_..self.rows) |row_index|
                                self.grid[row_index] = @splat(' ');
                        },
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
