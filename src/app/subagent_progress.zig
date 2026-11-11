//! Bounded, display-only projection of ordinary child text.
const std = @import("std");
const r = @import("../core/runtime.zig");

pub const Projection = struct {
    latest: [2048]u8 = undefined,
    latest_len: usize = 0,
    draft: [2048]u8 = undefined,
    draft_len: usize = 0,
    pending: [4]u8 = undefined,
    pending_len: usize = 0,
    pending_need: usize = 0,
    escape: enum { none, esc, csi, osc, osc_esc } = .none,
    phase: [128]u8 = undefined,
    phase_len: usize = 0,

    fn setPhase(self: *Projection, text: []const u8) void {
        const n = @min(text.len, self.phase.len);
        @memcpy(self.phase[0..n], text[0..n]);
        self.phase_len = n;
    }
    pub fn begin(self: *Projection) void {
        self.draft_len = 0;
        self.pending_len = 0;
        self.pending_need = 0;
        self.escape = .none;
    }
    fn scalar(self: *Projection, bytes: []const u8) void {
        if (bytes.len == 1 and (bytes[0] == '\n' or bytes[0] == '\r')) {
            self.draft_len = 0;
            return;
        }
        if (bytes.len == 1 and bytes[0] == '\t') return self.scalar(" ");
        if (bytes.len == 1 and (bytes[0] < 32 or bytes[0] == 127)) return;
        if (bytes.len == 2 and bytes[0] == 0xc2 and bytes[1] >= 0x80 and bytes[1] <= 0x9f) return;
        if (self.draft_len + bytes.len > self.draft.len) return;
        @memcpy(self.draft[self.draft_len..][0..bytes.len], bytes);
        self.draft_len += bytes.len;
        if (std.mem.trim(u8, self.draft[0..self.draft_len], " \t").len != 0) {
            @memcpy(self.latest[0..self.draft_len], self.draft[0..self.draft_len]);
            self.latest_len = self.draft_len;
        }
    }
    pub fn feed(self: *Projection, text: []const u8) void {
        for (text) |b| {
            switch (self.escape) {
                .esc => {
                    self.escape = switch (b) {
                        '[' => .csi,
                        ']' => .osc,
                        else => .none,
                    };
                    continue;
                },
                .csi => {
                    if (b == 0x1b) {
                        self.escape = .esc;
                    } else if (b >= 0x40 and b <= 0x7e) {
                        self.escape = .none;
                    }
                    continue;
                },
                .osc => {
                    if (b == 0x07) {
                        self.escape = .none;
                    } else if (b == 0x1b) {
                        self.escape = .osc_esc;
                    }
                    continue;
                },
                .osc_esc => {
                    self.escape = if (b == '\\' or b == 0x07) .none else if (b == 0x1b) .osc_esc else .osc;
                    continue;
                },
                .none => {},
            }
            if (b == 0x1b) {
                self.pending_len = 0;
                self.escape = .esc;
                continue;
            }
            if (self.pending_len == 0) {
                if (b < 128) {
                    self.scalar(&.{b});
                    continue;
                }
                self.pending_need = std.unicode.utf8ByteSequenceLength(b) catch continue;
                self.pending[0] = b;
                self.pending_len = 1;
            } else if (b & 0xc0 == 0x80) {
                self.pending[self.pending_len] = b;
                self.pending_len += 1;
                if (self.pending_len == self.pending_need) {
                    if (std.unicode.utf8ValidateSlice(self.pending[0..self.pending_len])) self.scalar(self.pending[0..self.pending_len]);
                    self.pending_len = 0;
                }
            } else {
                self.pending_len = 0;
                if (b < 128) self.scalar(&.{b});
            }
        }
    }
    pub fn observe(self: *Projection, event: r.Event) void {
        switch (event) {
            .state => |state| {
                if (state == .calling_model) self.begin();
                self.setPhase(switch (state) {
                    .calling_model => "Calling model",
                    .awaiting_permission => "Awaiting permission",
                    .executing_tool => "Executing tool",
                    .compacting => "Compacting",
                });
            },
            .tool_started => |tool| {
                self.setPhase("Executing tool");
                var name: Projection = .{};
                name.feed(tool.name);
                const clean = name.current();
                const n = @min(clean.len, self.phase.len - self.phase_len - 2);
                var end = n;
                while (end > 0 and !std.unicode.utf8ValidateSlice(clean[0..end])) end -= 1;
                if (end != 0) {
                    self.phase[self.phase_len] = ':';
                    self.phase[self.phase_len + 1] = ' ';
                    @memcpy(self.phase[self.phase_len + 2 ..][0..end], clean[0..end]);
                    self.phase_len += end + 2;
                }
            },
            .text => |text| self.feed(text),
            .assistant_committed => |blocks| {
                self.begin();
                for (blocks) |block| if (block == .text) {
                    self.feed(block.text);
                };
            },
            else => {},
        }
    }
    pub fn current(self: *const Projection) []const u8 {
        return if (self.latest_len != 0) self.latest[0..self.latest_len] else self.phase[0..self.phase_len];
    }
};
