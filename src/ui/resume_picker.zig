//! Candidate-only saved-session picker. All data is owned by the caller.
const std = @import("std");
const session = @import("session_client.zig");
const text = @import("text.zig");

pub const Picker = struct {
    sessions: []session.SavedSession,
    selected: usize = 0,
    generation: u64 = 1,
    epoch: u64,
    session_id: ?[32]u8,
    launcher: ?[]u8,

    pub fn deinit(self: *Picker, a: std.mem.Allocator) void {
        a.free(self.sessions);
        if (self.launcher) |value| a.free(value);
    }
    pub fn move(self: *Picker, down: bool) void {
        if (self.sessions.len == 0) return;
        self.selected = if (down) (self.selected + 1) % self.sessions.len else if (self.selected == 0) self.sessions.len - 1 else self.selected - 1;
    }
};

// UTC conversion is independent of the host timezone and of libc's shared tm.
fn savedTime(a: std.mem.Allocator, milliseconds: i64) ![]const u8 {
    if (milliseconds < -62135596800000 or milliseconds > 253402300799999) return a.dupe(u8, "time unavailable");
    const seconds = @divFloor(milliseconds, 1000);
    var days = @divFloor(seconds, 86400);
    const minute = @divFloor(@mod(seconds, 3600), 60);
    const hour = @divFloor(@mod(seconds, 86400), 3600);
    var year: u32 = 1970;
    while (days < 0) {
        year -= 1;
        days += if (leap(year)) 366 else 365;
    }
    while (true) : (year += 1) {
        const year_days: i64 = if (leap(year)) 366 else 365;
        if (days < year_days) break;
        days -= year_days;
    }
    const months = [_]u8{ 31, if (leap(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: usize = 0;
    while (days >= months[month]) : (month += 1) days -= months[month];
    const day: u8 = @intCast(days + 1);
    const unsigned_hour: u8 = @intCast(hour);
    const unsigned_minute: u8 = @intCast(minute);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ year, month + 1, day, unsigned_hour, unsigned_minute });
}
fn leap(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

pub const Rows = struct { lines: []const []const u8 = &.{}, selected_line: ?usize = null, can_confirm: bool = false };
pub fn rows(a: std.mem.Allocator, picker: *const Picker, columns: usize, max_rows: usize) !Rows {
    const count = @min(picker.sessions.len, @min(max_rows, 10));
    if (count == 0) return .{};
    const selected = @min(picker.selected, picker.sessions.len - 1);
    const start = @min(selected -| (count / 2), picker.sessions.len - count);
    const lines = try a.alloc([]const u8, count);
    var can_confirm = false;
    for (picker.sessions[start..][0..count], 0..) |item, index| {
        const title = item.title.text();
        const label = if (title.len != 0) title else item.id[0..8];
        const stamp = try savedTime(a, item.modified_ms);
        const raw = try std.fmt.allocPrint(a, "{s}{s}  {s}", .{ if (start + index == selected) "> " else "  ", label, stamp });
        const fitted = text.fitBytes(raw, columns);
        lines[index] = raw[0..fitted];
        if (start + index == selected and columns >= 2) {
            const label_end = text.fitBytes(label, columns - 2);
            can_confirm = text.width(label[0..label_end]) != 0;
        }
    }
    return .{ .lines = lines, .selected_line = selected - start, .can_confirm = can_confirm };
}
