//! Explicit built-in service identities and exact endpoints.
//! Credentials belong to declared registry connections, never service slots.
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

test "provider services have distinct exact endpoints" {
    const t = std.testing;
    for (Id.all) |id| {
        try t.expectEqual(id, Id.fromUrl(id.baseUrl()).?);
        try t.expectEqual(id, Id.fromSlug(id.slug()).?);
    }
    try t.expect(Id.fromUrl("https://opencode.ai.example/zen/v1") == null);
    try t.expect(Id.fromUrl("https://opencode.ai/zen/go/v1?key=foo") == null);
    try t.expect(Id.fromUrl("https://opencode.ai/zen/go/v10") == null);
    try t.expectEqual(Id.deepseek, Id.fromUrl("https://api.deepseek.com/v1/").?);
    try t.expectEqual(Id.opencode_go, Id.fromUrl("https://opencode.ai/inference/go/v1/").?);
    try t.expectEqual(Id.opencode_zen, Id.fromUrl("https://opencode.ai/inference/v1").?);
    try t.expect(Id.fromUrl("https://opencode.ai/inference/go/v10") == null);
}
