test "idle login view has no authorization URL or private callback" {
    const view: View = .{};
    try std.testing.expectEqual(Status.idle, view.status);
    try std.testing.expectEqualStrings("", view.authorizationUrl());
    try std.testing.expect(!validAuthorizationUrl("http://localhost:1455/auth/callback?code=synthetic"));
    try std.testing.expect(!validAuthorizationUrl("https://auth.openai.com/oauth/authorize?code=synthetic"));
}
