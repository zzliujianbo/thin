fn expectKind(command: []const u8, kind: Kind) !void {
    const found = classify(command) orelse {
        std.debug.print("expected {s}: {s}\n", .{ @tagName(kind), command });
        return error.ExpectedDangerous;
    };
    if (found.kind != kind) {
        std.debug.print("kind {s} ({s}) wanted {s}: {s}\n", .{ @tagName(found.kind), found.label, @tagName(kind), command });
        return error.UnexpectedKind;
    }
}

fn expectSafe(command: []const u8) !void {
    if (classify(command)) |found| {
        std.debug.print("false positive {s} ({s}): {s}\n", .{ found.label, @tagName(found.kind), command });
        return error.FalsePositive;
    }
}
