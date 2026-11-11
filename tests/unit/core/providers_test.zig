test "SystemOne route rewriting is exact and limited to official Zen" {
    const t = std.testing;
    for ([_][]const u8{ "https://opencode.ai/zen/v1", "https://opencode.ai/zen/v1/", "https://opencode.ai/inference/v1" }) |url| {
        try t.expectEqualStrings(systemone_base_url, systemOneRoute(url));
    }
    for ([_][]const u8{ systemone_base_url, systemone_base_url ++ "/", "http://127.0.0.1:1/v1", "https://opencode.ai.example/zen/v1", "https://opencode.ai/zen/go/v1", "https://opencode.ai/inference/go/v1", "https://opencode.ai/zen/v10", "https://opencode.ai/zen/v1?key=x" }) |url| {
        try t.expectEqualStrings(url, systemOneRoute(url));
    }
}
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
    try t.expectEqual(Id.opencode_zen, Id.fromSystemOneUrl("https://opencode.ai/inference/systemone/v1/").?);
    try t.expect(Id.fromUrl("https://opencode.ai/inference/systemone/v1") == null);
    try t.expect(Id.fromUrl("https://opencode.ai/inference/systemone/v10") == null);
    try t.expect(Id.fromUrl("https://opencode.ai.example/inference/systemone/v1") == null);
}
