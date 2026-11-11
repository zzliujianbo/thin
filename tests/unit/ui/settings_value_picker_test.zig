test "boolean preferences never offer confirmable numeric values" {
    const a = std.testing.allocator;
    for ([_]Key{ .compaction_enabled, .memory_auto }) |key| {
        var picker = Picker.init(key, 1, .{});
        try std.testing.expectEqual(@as(usize, 0), picker.values_len);
        const rendered = try rows(a, .{}, picker, 80, 3);
        defer {
            for (rendered.lines) |line| a.free(line);
            a.free(rendered.lines);
        }
        try std.testing.expect(!rendered.can_confirm);
        picker.beginCustom();
        try std.testing.expect(picker.append("1"));
        try std.testing.expectError(error.InvalidKey, picker.submitCustom());
    }
}
test "value picker preserves exact current custom values and stable stages" {
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    const current_index = picker.currentIndex();
    try std.testing.expectEqual(picker.find(123456).?, current_index);
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    const count_before = picker.count();
    try std.testing.expect(!picker.append("12"));
    picker.beginCustom();
    try std.testing.expectError(error.InvalidValue, picker.submitCustom());
    try std.testing.expect(picker.append("234.567"));
    try std.testing.expectError(error.Editing, picker.chosen(current_index));
    const staged_index = try picker.submitCustom();
    try std.testing.expect(!picker.editing);
    try std.testing.expectEqual(@as(?u32, 123456), picker.current);
    try std.testing.expectEqual(@as(?u32, 234567), try picker.chosen(staged_index));
    try std.testing.expectError(error.NotEditing, picker.submitCustom());
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    try std.testing.expectEqual(count_before + 1, picker.count());
    picker.beginCustom();
    try std.testing.expect(picker.append("345.678"));
    try std.testing.expectEqual(staged_index, try picker.submitCustom());
    try std.testing.expectEqual(@as(?u32, 345678), try picker.chosen(staged_index));
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(current_index));
    try std.testing.expectError(error.CustomChoice, picker.chosen(picker.count() - 1));
    try std.testing.expectError(error.InvalidIndex, picker.chosen(picker.count()));
}
test "value constraints include command maximum and timeout bounds" {
    const legacy = Picker.init(.request_timeout_ms, 86400001, .{});
    try std.testing.expectEqual(@as(?u32, 86400001), legacy.values[legacy.currentIndex()]);
    try std.testing.expectError(error.InvalidValue, legacy.chosen(legacy.currentIndex()));
    const command = Picker.init(.command_timeout_ms, 123, .{ .command_max_timeout_ms = 1000 });
    try std.testing.expectError(error.InvalidValue, command.validate(1001));
    try command.validate(1000);
    try std.testing.expectEqual(@as(?u32, 123), try command.chosen(command.find(123).?));
    for ([_]Key{ .request_timeout_ms, .task_timeout_ms }) |key| {
        const picker = Picker.init(key, 300000, .{});
        const maximum: u32 = 86400000;
        try picker.validate(maximum);
        try std.testing.expectError(error.InvalidValue, picker.validate(maximum + 1));
        try std.testing.expectError(error.InvalidValue, picker.validate(null));
        try std.testing.expectError(error.InvalidValue, picker.validate(0));
    }
}
test "value windows keep selected visible and reject clipped identities and paste" {
    const a = std.testing.allocator;
    const picker = Picker.init(.request_timeout_ms, 123456, .{});
    for (0..picker.count()) |selected| for (0..12) |height| for (0..45) |columns| {
        const rendered = try rows(a, .{ .selected = selected }, picker, columns, height);
        defer freeRows(a, rendered);
        try std.testing.expect(rendered.lines.len <= height);
        var buffer: [96]u8 = undefined;
        const expected = try candidate(&buffer, picker, selected);
        try std.testing.expectEqual(height > 0 and columns >= 2 + text.width(expected), rendered.can_confirm);
        if (rendered.selected_line) |index| {
            try std.testing.expect(index < rendered.lines.len);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[index], expected) != null);
        } else try std.testing.expect(height == 0);
        for (rendered.lines) |line| try std.testing.expect(text.width(line) <= columns);
    };
    const pasted = try rows(a, .{ .pasted = true }, picker, 80, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
}
test "editing custom can only stage valid complete input then confirm staged row" {
    const a = std.testing.allocator;
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    picker.beginCustom();
    const invalid = try rows(a, .{ .selected = picker.count() - 1 }, picker, 80, 1);
    defer freeRows(a, invalid);
    try std.testing.expect(!invalid.can_confirm);
    try std.testing.expect(picker.append("234.567"));
    const valid = try rows(a, .{ .selected = picker.count() - 1 }, picker, 80, 1);
    defer freeRows(a, valid);
    try std.testing.expect(valid.can_confirm);
    const clipped = try rows(a, .{ .selected = picker.count() - 1 }, picker, 10, 1);
    defer freeRows(a, clipped);
    try std.testing.expect(!clipped.can_confirm);
    const index = try picker.submitCustom();
    const staged = try rows(a, .{ .selected = index }, picker, 80, 1);
    defer freeRows(a, staged);
    try std.testing.expect(staged.can_confirm);
    try std.testing.expect(std.mem.find(u8, staged.lines[0], "234.567 s (staged)") != null);
}
test "seconds custom input is exact atomic and strictly bounded" {
    for ([_]Key{ .command_timeout_ms, .request_timeout_ms, .task_timeout_ms }) |key| {
        var picker = Picker.init(key, 123456, .{ .command_max_timeout_ms = 86400000 });
        picker.beginCustom();
        for ([_][]const u8{ ".", ".1", "-1", "1..2", "1.0001", "1e3", "1\n", "auto", "12x", "\x1b[200~12", "１２" }) |bad| {
            try std.testing.expect(!picker.append(bad));
            try std.testing.expectEqual(@as(usize, 0), picker.input_len);
        }
        try std.testing.expect(picker.append("1."));
        try std.testing.expectError(error.InvalidValue, picker.submitCustom());
        try std.testing.expect(!picker.append(".2"));
        try std.testing.expectEqualStrings("1.", picker.input[0..picker.input_len]);
        try std.testing.expect(picker.append("001"));
        try std.testing.expect(!picker.append("0"));
        try std.testing.expectEqualStrings("1.001", picker.input[0..picker.input_len]);
        picker.backspace();
        try std.testing.expectEqualStrings("1.00", picker.input[0..picker.input_len]);
        for ([_][]const u8{ "0", "0.000", "86400.001", "4294967.296", "99999999999999" }) |bad| {
            picker.clear();
            try std.testing.expect(picker.append(bad));
            try std.testing.expectError(error.InvalidValue, picker.submitCustom());
            try std.testing.expect(picker.editing);
        }
        picker.clear();
        try std.testing.expect(!picker.append("123456789012345"));
        try std.testing.expect(picker.append("0.001"));
        const index = try picker.submitCustom();
        try std.testing.expectEqual(@as(?u32, 1), try picker.chosen(index));
        try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(picker.currentIndex()));
        picker.beginCustom();
        try std.testing.expect(picker.append("86400"));
        const maximum = try picker.submitCustom();
        try std.testing.expectEqual(@as(?u32, 86400000), try picker.chosen(maximum));
    }
    var command = Picker.init(.command_timeout_ms, 1, .{ .command_max_timeout_ms = 1500 });
    command.beginCustom();
    try std.testing.expect(command.append("1.501"));
    try std.testing.expectError(error.InvalidValue, command.submitCustom());
    command.clear();
    try std.testing.expect(command.append("1.5"));
    const index = try command.submitCustom();
    try std.testing.expectEqual(@as(?u32, 1500), try command.chosen(index));
}
test "seconds append rejection preserves all bytes and preset staging stays exact" {
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    picker.beginCustom();
    try std.testing.expect(picker.append("0000000000.001"));
    const before = picker.input;
    const length = picker.input_len;
    for ([_][]const u8{ "0", ".", "x", "\n", "12.3", "123456789012345" }) |bad| {
        try std.testing.expect(!picker.append(bad));
        try std.testing.expectEqual(length, picker.input_len);
        try std.testing.expectEqualSlices(u8, &before, &picker.input);
    }
    const staged = try picker.submitCustom();
    try std.testing.expectEqual(@as(?u32, 1), try picker.chosen(staged));
    const count_before = picker.count();
    picker.beginCustom();
    try std.testing.expect(picker.append("30.000"));
    const preset = try picker.submitCustom();
    try std.testing.expectEqual(@as(?u32, 30000), try picker.chosen(preset));
    try std.testing.expectEqual(count_before, picker.count());
    try std.testing.expectEqual(@as(?u32, 1), try picker.chosen(staged));
    try std.testing.expectEqual(@as(?u32, 123456), try picker.chosen(picker.currentIndex()));
}
test "seconds current and staged identities require complete rows and reject paste" {
    const a = std.testing.allocator;
    var picker = Picker.init(.request_timeout_ms, 123456, .{});
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("123.456 s (current)", try candidate(&buffer, picker, picker.currentIndex()));
    picker.beginCustom();
    try std.testing.expect(picker.append("0.001"));
    const editing = try rows(a, .{ .selected = picker.count() - 1 }, picker, 100, 12);
    defer freeRows(a, editing);
    try std.testing.expect(editing.can_confirm);
    try std.testing.expect(std.mem.find(u8, editing.lines[editing.lines.len - 1], "up to 3 decimals") != null);
    const index = try picker.submitCustom();
    try std.testing.expectEqualStrings("0.001 s (staged)", try candidate(&buffer, picker, index));
    const clipped = try rows(a, .{ .selected = index }, picker, 16, 1);
    defer freeRows(a, clipped);
    try std.testing.expect(!clipped.can_confirm);
    const pasted = try rows(a, .{ .selected = index, .pasted = true }, picker, 100, 1);
    defer freeRows(a, pasted);
    try std.testing.expect(!pasted.can_confirm);
    const short = try rows(a, .{ .selected = index }, picker, 100, 0);
    defer freeRows(a, short);
    try std.testing.expect(!short.can_confirm);
}
test "value rows release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
