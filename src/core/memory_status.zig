const std = @import("std");
const display_text = @import("../util/display_text.zig");

pub const Phase = enum { extracting, saving };
pub const Result = enum { saved, skipped, failed, uncertain, canceled };
pub const Failure = enum { canceled, unavailable, invalid_output, busy, storage, cleanup, other };
pub const Active = struct { id: u64, phase: Phase };

/// Fixed owned, single-line terminal-safe text. Appends separate saved entries.
pub const Summary = struct {
    len: u16 = 0,
    buf: [256]u8 = @splat(0),

    pub fn text(self: *const Summary) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn append(self: *Summary, input: []const u8) void {
        const original = self.len;
        var i: usize = 0;
        var pending_space = false;
        while (i < input.len) {
            const rune = display_text.decode(input, i);
            i = rune.end;
            const cp = rune.cp;
            if (cp == ' ' or cp == '\n' or cp == '\r' or cp == '\t') {
                pending_space = self.len > original;
                continue;
            }
            const safe = display_text.displayCodepoint(cp);
            var encoded: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(safe, &encoded) catch unreachable;
            const separator: usize = if (self.len == original and original != 0) 4 else if (pending_space) 1 else 0;
            if (@as(usize, self.len) + separator + n > self.buf.len) break;
            if (separator == 4) {
                @memcpy(self.buf[self.len..][0..4], " · ");
                self.len += 4;
            } else if (separator == 1) {
                self.buf[self.len] = ' ';
                self.len += 1;
            }
            @memcpy(self.buf[self.len..][0..n], encoded[0..n]);
            self.len += @intCast(n);
            pending_space = false;
        }
    }
};
pub const Terminal = struct { id: u64, result: Result, failure: ?Failure = null, saved_count: u32 = 0, summary: Summary = .{} };
pub const View = struct {
    enabled: bool = false,
    revision: u64 = 0,
    active: ?Active = null,
    queued_count: u64 = 0,
    last_terminal: ?Terminal = null,
};
