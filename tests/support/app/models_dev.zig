fn directoryAllocationCheck(a: std.mem.Allocator) !void {
    var result = try parseDirectory(a,
        \\{"opencode-go":{"npm":"@ai-sdk/anthropic","models":{"fresh":{}}},"other":{"npm":"@ai-sdk/anthropic","models":{"fresh":{"reasoning_options":[{"type":"effort","values":["low"]}]}}}}
    );
    defer result.deinit(a);
    try std.testing.expect(result.rows[0].dev_reasoning == null);
}
