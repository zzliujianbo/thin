test "image PNG JPEG WebP bounded container headers and malformed lengths" {
    const a = std.testing.allocator;
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1sAAAAASUVORK5CYII=";
    const decoder = std.base64.standard.Decoder;
    const png_data = try a.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer a.free(png_data);
    try decoder.decode(png_data, encoded);
    // Construct checksum-verified chunks rather than trusting fixture transport.
    var pos: usize = 8;
    while (pos < png_data.len) {
        const n: usize = uint(png_data[pos..][0..4], .big);
        std.mem.writeInt(u32, png_data[pos + 8 + n ..][0..4], std.hash.crc.@"CRC-32/ISO-HDLC".hash(png_data[pos + 4 ..][0 .. n + 4]), .big);
        pos += n + 12;
    }
    const jpg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x00\xff\xd9";
    const lossless = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\x00\x00\x00\x00\x00";
    const lossy = "RIFF\x16\x00\x00\x00WEBPVP8 \x0a\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\x01\x00\x01\x00";
    for ([_][]const u8{ png_data, jpg, lossless, lossy }, [_]image.Format{ .png, .jpeg, .webp, .webp }) |bytes, format| {
        const parsed = try identify(bytes);
        try std.testing.expectEqual(format, parsed.format);
        try std.testing.expectEqual(@as(u32, 1), parsed.width);
        try std.testing.expectEqual(@as(u32, 1), parsed.height);
        for (0..bytes.len) |n| {
            if (identify(bytes[0..n])) |_| return error.TruncatedImageAccepted else |_| {}
        }
    }
    png_data[16] ^= 1;
    try std.testing.expectError(error.InvalidImage, identify(png_data));
    var bad_webp = lossless.*;
    bad_webp[16] = 0xff;
    try std.testing.expectError(error.InvalidImage, identify(&bad_webp));
    // Unknown/random bounded bytes never cause unchecked slicing.
    var random: [64]u8 = @splat(0xff);
    for (0..random.len) |n| {
        random[n] = @intCast(n);
        if (identify(random[0 .. n + 1])) |_| return error.RandomImageAccepted else |_| {}
    }
}
test "image containers validate byte signatures dimensions and truncation" {
    const parsed = try identify(test_gif);
    try std.testing.expectEqual(image.Format.gif, parsed.format);
    try std.testing.expectEqual(@as(u32, 1), parsed.width);
    for (0..test_gif.len) |n| try std.testing.expectError(if (n == 0) error.ImageTooLarge else if (n < 6) error.UnsupportedImageFormat else error.InvalidImage, identify(test_gif[0..n]));
    try std.testing.expectError(error.UnsupportedImageFormat, identify("not an image.png"));
    var bad = test_gif.*;
    bad[6] = 0;
    try std.testing.expectError(error.InvalidImageDimensions, identify(&bad));
    bad[7] = 0x21;
    try std.testing.expectError(error.InvalidImageDimensions, identify(&bad));
}
