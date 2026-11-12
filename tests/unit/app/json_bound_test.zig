test "JSON preflight accepts deep and large valid documents and rejects malformed input" {
    const a = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendNTimes(a, '[', 256);
    try bytes.appendSlice(a, "0");
    try bytes.appendNTimes(a, ']', 256);
    try validate(a, bytes.items);
    bytes.clearRetainingCapacity();
    try bytes.appendSlice(a, "[");
    for (0..70000) |i| {
        if (i != 0) try bytes.appendSlice(a, ",");
        try bytes.appendSlice(a, "0");
    }
    try bytes.appendSlice(a, "]");
    try validate(a, bytes.items);
    try std.testing.expectError(error.SyntaxError, validate(a, "{]"));
    try std.testing.expectError(error.SyntaxError, validate(a, "{} []"));
    try std.testing.expectError(error.SyntaxError, validate(a, "true false"));
    try std.testing.expectError(error.SyntaxError, validate(a, "{} garbage"));
    try std.testing.expectError(error.SyntaxError, validate(a, "[1,}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, validate(a, "{\"x\":\"open"));
    try std.testing.expectError(error.SyntaxError, validate(a, "\"\xff\""));
}
