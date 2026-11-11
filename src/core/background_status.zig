//! Bounded, UI-only background command metadata.
const std = @import("std");

pub const Id = struct {
    bytes: [64]u8 = @splat(0),
    len: usize = 0,

    pub fn from(raw: []const u8) Id {
        var result: Id = .{};
        for (raw) |ch| {
            if (result.len == result.bytes.len) break;
            result.bytes[result.len] = if (ch >= 0x21 and ch <= 0x7e) ch else '_';
            result.len += 1;
        }
        return result;
    }
    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Command = struct {
    bytes: [512]u8 = @splat(0),
    len: usize = 0,

    pub fn from(raw: []const u8) Command {
        var result: Command = .{};
        var i: usize = 0;
        while (i < raw.len and result.len < result.bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
                result.bytes[result.len] = ' ';
                result.len += 1;
                i += 1;
                continue;
            };
            if (i + n > raw.len or !std.unicode.utf8ValidateSlice(raw[i..][0..n])) {
                result.bytes[result.len] = ' ';
                result.len += 1;
                i += 1;
                continue;
            }
            const code = std.unicode.utf8Decode(raw[i..][0..n]) catch unreachable;
            if (code < 0x20 or (code >= 0x7f and code <= 0x9f) or code == 0x2028 or code == 0x2029) {
                result.bytes[result.len] = ' ';
                result.len += 1;
            } else {
                if (result.len + n > result.bytes.len) break;
                @memcpy(result.bytes[result.len..][0..n], raw[i..][0..n]);
                result.len += n;
            }
            i += n;
        }
        return result;
    }
    pub fn slice(self: *const Command) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Result = enum { success, failed, canceled };
pub const Failure = enum { exit, signal, spawn, timeout, cleanup, io };
pub const Terminal = struct {
    id: Id,
    command: Command,
    result: Result,
    duration_ms: u64,
    exit_code: ?u8 = null,
    signal: ?u32 = null,
    failure: ?Failure = null,
};
pub const View = struct { active_count: usize = 0 };
pub const Action = enum { start, list, status, logs, stop };
pub const Caption = struct { action: Action, id: ?Id = null, command: ?Command = null };
