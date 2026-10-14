//! Explicit built-in services. Zen and Go have independent credential slots;
//! no hostname substring matching, discovery or OAuth is performed here.
const std = @import("std");

pub const Id = enum {
    deepseek,
    opencode_zen,
    opencode_go,

    pub const all = [_]Id{ .deepseek, .opencode_zen, .opencode_go };

    pub fn label(self: Id) []const u8 {
        return switch (self) {
            .deepseek => "DeepSeek",
            .opencode_zen => "OpenCode Zen",
            .opencode_go => "OpenCode Go",
        };
    }
    pub fn slug(self: Id) []const u8 {
        return switch (self) {
            .deepseek => "deepseek",
            .opencode_zen => "opencode-zen",
            .opencode_go => "opencode-go",
        };
    }
    pub fn baseUrl(self: Id) []const u8 {
        return switch (self) {
            .deepseek => "https://api.deepseek.com",
            .opencode_zen => "https://opencode.ai/zen/v1",
            .opencode_go => "https://opencode.ai/zen/go/v1",
        };
    }
    pub fn fromUrl(url: []const u8) ?Id {
        const normalized = std.mem.trimEnd(u8, url, "/");
        for (all) |id| if (std.mem.eql(u8, normalized, id.baseUrl())) return id;
        if (std.mem.eql(u8, normalized, "https://api.deepseek.com/v1")) return .deepseek;
        if (std.mem.eql(u8, normalized, "https://opencode.ai/inference/go/v1")) return .opencode_go;
        if (std.mem.eql(u8, normalized, "https://opencode.ai/inference/v1")) return .opencode_zen;
        return null;
    }
    pub fn fromSlug(value: []const u8) ?Id {
        for (all) |id| if (std.mem.eql(u8, value, id.slug())) return id;
        return null;
    }
    pub fn usesSessionHeader(self: Id) bool {
        return self != .deepseek;
    }
};

/// Values are borrowed until included in an owned Config parse arena. Never
/// copy this structure into session metadata or a UI connection snapshot.
pub const Credentials = struct {
    deepseek: ?[]const u8 = null,
    opencode_zen: ?[]const u8 = null,
    opencode_go: ?[]const u8 = null,

    pub fn get(self: Credentials, id: Id) ?[]const u8 {
        return switch (id) {
            .deepseek => self.deepseek,
            .opencode_zen => self.opencode_zen,
            .opencode_go => self.opencode_go,
        };
    }
    pub fn set(self: *Credentials, id: Id, key: []const u8) void {
        switch (id) {
            .deepseek => self.deepseek = key,
            .opencode_zen => self.opencode_zen = key,
            .opencode_go => self.opencode_go = key,
        }
    }
    pub fn validate(self: Credentials) !void {
        for (Id.all) |id| if (self.get(id)) |key| {
            if (key.len == 0 or key.len > 16384 or std.mem.trim(u8, key, " ").len == 0) return error.InvalidApiKey;
            for (key) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidApiKey;
        };
    }
};

test "provider services have distinct exact endpoints and credential slots" {
    const t = std.testing;
    var keys: Credentials = .{};
    for (Id.all) |id| {
        try t.expectEqual(id, Id.fromUrl(id.baseUrl()).?);
        try t.expectEqual(id, Id.fromSlug(id.slug()).?);
        keys.set(id, id.slug());
    }
    for (Id.all) |id| try t.expectEqualStrings(id.slug(), keys.get(id).?);
    try keys.validate();
    try t.expect(Id.fromUrl("https://opencode.ai.example/zen/v1") == null);
    try t.expect(Id.fromUrl("https://opencode.ai/zen/go/v1?key=foo") == null);
    try t.expect(Id.fromUrl("https://opencode.ai/zen/go/v10") == null);
    try t.expectEqual(Id.deepseek, Id.fromUrl("https://api.deepseek.com/v1/").?);
    try t.expectEqual(Id.opencode_go, Id.fromUrl("https://opencode.ai/inference/go/v1/").?);
    try t.expectEqual(Id.opencode_zen, Id.fromUrl("https://opencode.ai/inference/v1").?);
    try t.expect(Id.fromUrl("https://opencode.ai/inference/go/v10") == null);
    keys.set(.opencode_go, "bad\nheader");
    try t.expectError(error.InvalidApiKey, keys.validate());
}
