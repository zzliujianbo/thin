fn verticalAllocationScenario(a: std.mem.Allocator) !void {
    _ = try moveVertical(a, "abc\t界\n🙂xyz", "abc\t界\n🙂xyz".len, 4, false, null);
}

fn allocationCase(a: std.mem.Allocator) !void {
    const value = try layout(a, "abcdefghijklmno", 7, 3, 4);
    defer value.deinit(a);
}
