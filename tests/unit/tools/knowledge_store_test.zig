test "lexical references are relevant and UTF8 aligned" {
    try std.testing.expect(score("rust", "project-rust", "rust compiler") > 0);
    try std.testing.expectEqual(@as(usize, 0), score("rust", "trust", "unrelated"));
    try std.testing.expect(contains("中文项目", "中文"));
    try std.testing.expect(!contains("中文", "\xb8\xad"));
}
