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
