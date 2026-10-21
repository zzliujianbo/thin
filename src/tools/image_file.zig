//! Bounded container inspection only: no decompression, extension trust or commands.
const std = @import("std");
const image = @import("../core/image.zig");
const fs = @import("../platform/filesystem.zig");

/// Caller owns Image.data. The same anchored fd supplies every captured byte.
pub fn load(a: std.mem.Allocator, root: *fs.Root, path: []const u8) !image.Image {
    const data = try root.readBinary(a, path, image.max_image_bytes);
    errdefer a.free(data);
    return identify(data);
}

fn uint(bytes: []const u8, endian: std.builtin.Endian) u32 {
    var result: u32 = 0;
    if (endian == .big) {
        for (bytes) |b| result = (result << 8) | b;
    } else {
        var i = bytes.len;
        while (i > 0) {
            i -= 1;
            result = (result << 8) | bytes[i];
        }
    }
    return result;
}
fn dimensions(data: []const u8, format: image.Format, w: u32, h: u32) !image.Image {
    if (w == 0 or h == 0 or w > image.max_dimension or h > image.max_dimension) return error.InvalidImageDimensions;
    return .{ .data = data, .format = format, .width = w, .height = h };
}
fn skipBlocks(data: []const u8, offset: *usize) !void {
    while (true) {
        if (offset.* >= data.len) return error.InvalidImage;
        const n = data[offset.*];
        offset.* += 1;
        if (n > data.len - offset.*) return error.InvalidImage;
        offset.* += n;
        if (n == 0) return;
    }
}

pub fn identify(data: []const u8) !image.Image {
    if (data.len == 0 or data.len > image.max_image_bytes) return error.ImageTooLarge;
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return png(data);
    if (std.mem.startsWith(u8, data, "\xff\xd8")) return jpeg(data);
    if (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a")) return gif(data);
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return webp(data);
    return error.UnsupportedImageFormat;
}
fn png(data: []const u8) !image.Image {
    var pos: usize = 8;
    var result: ?image.Image = null;
    var pixels = false;
    while (pos < data.len) {
        if (data.len - pos < 12) return error.InvalidImage;
        const n: usize = uint(data[pos..][0..4], .big);
        if (n > data.len - pos - 12) return error.InvalidImage;
        const tag = data[pos + 4 ..][0..4];
        const body = data[pos + 8 ..][0..n];
        if (std.hash.crc.@"CRC-32/ISO-HDLC".hash(data[pos + 4 ..][0 .. n + 4]) != uint(data[pos + 8 + n ..][0..4], .big)) return error.InvalidImage;
        if (result == null) {
            if (!std.mem.eql(u8, tag, "IHDR") or n != 13) return error.InvalidImage;
            const depth = body[8];
            const valid_depth = switch (body[9]) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                2, 4, 6 => depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                else => false,
            };
            if (!valid_depth or body[10] != 0 or body[11] != 0 or body[12] > 1) return error.InvalidImage;
            result = try dimensions(data, .png, uint(body[0..4], .big), uint(body[4..8], .big));
        } else if (std.mem.eql(u8, tag, "IHDR")) return error.InvalidImage;
        pos += n + 12;
        if (std.mem.eql(u8, tag, "IDAT")) pixels = pixels or n > 0;
        if (std.mem.eql(u8, tag, "IEND")) {
            if (n != 0 or !pixels or pos != data.len) return error.InvalidImage;
            return result.?;
        }
    }
    return error.InvalidImage;
}
fn jpeg(data: []const u8) !image.Image {
    var pos: usize = 2;
    var result: ?image.Image = null;
    var scan = false;
    while (pos < data.len) {
        if (data[pos] != 0xff) return error.InvalidImage;
        while (pos < data.len and data[pos] == 0xff) pos += 1;
        if (pos == data.len) return error.InvalidImage;
        const marker = data[pos];
        pos += 1;
        if (marker == 0xd9) {
            if (!scan or pos != data.len) return error.InvalidImage;
            return result orelse error.InvalidImage;
        }
        if (marker == 0 or marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd7)) return error.InvalidImage;
        if (data.len - pos < 2) return error.InvalidImage;
        const n: usize = uint(data[pos..][0..2], .big);
        if (n < 2 or n > data.len - pos) return error.InvalidImage;
        const body = data[pos + 2 .. pos + n];
        const sof = marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (sof) {
            if (body.len < 6 or body[5] == 0 or body.len != 6 + @as(usize, body[5]) * 3 or result != null) return error.InvalidImage;
            result = try dimensions(data, .jpeg, uint(body[3..5], .big), uint(body[1..3], .big));
        }
        pos += n;
        if (marker == 0xda) {
            if (result == null or body.len < 4 or body[0] == 0 or body.len != 4 + @as(usize, body[0]) * 2) return error.InvalidImage;
            scan = true;
            // Entropy bytes: FF00 is escaped data; restart markers have no length.
            while (pos < data.len) {
                if (data[pos] != 0xff) {
                    pos += 1;
                    continue;
                }
                const start = pos;
                while (pos < data.len and data[pos] == 0xff) pos += 1;
                if (pos == data.len) return error.InvalidImage;
                if (data[pos] == 0 or (data[pos] >= 0xd0 and data[pos] <= 0xd7)) {
                    pos += 1;
                    continue;
                }
                pos = start;
                break;
            }
        }
    }
    return error.InvalidImage;
}
fn gif(data: []const u8) !image.Image {
    if (data.len < 13) return error.InvalidImage;
    const result = try dimensions(data, .gif, uint(data[6..8], .little), uint(data[8..10], .little));
    var pos: usize = 13;
    if (data[10] & 0x80 != 0) pos += @as(usize, 3) << @intCast((data[10] & 7) + 1);
    var pixels = false;
    while (pos < data.len) {
        const tag = data[pos];
        pos += 1;
        switch (tag) {
            0x3b => {
                if (!pixels or pos != data.len) return error.InvalidImage;
                return result;
            },
            0x21 => {
                if (pos >= data.len) return error.InvalidImage;
                pos += 1;
                try skipBlocks(data, &pos);
            },
            0x2c => {
                if (data.len - pos < 9) return error.InvalidImage;
                const w = uint(data[pos + 4 ..][0..2], .little);
                const h = uint(data[pos + 6 ..][0..2], .little);
                _ = try dimensions(data, .gif, w, h);
                if (uint(data[pos..][0..2], .little) + w > result.width or uint(data[pos + 2 ..][0..2], .little) + h > result.height) return error.InvalidImage;
                const flags = data[pos + 8];
                pos += 9;
                if (flags & 0x80 != 0) pos += @as(usize, 3) << @intCast((flags & 7) + 1);
                if (pos >= data.len or data[pos] < 2 or data[pos] > 8) return error.InvalidImage;
                pos += 1;
                if (pos >= data.len or data[pos] == 0) return error.InvalidImage;
                try skipBlocks(data, &pos);
                pixels = true;
            },
            else => return error.InvalidImage,
        }
    }
    return error.InvalidImage;
}
fn webp(data: []const u8) !image.Image {
    if (uint(data[4..8], .little) != data.len - 8) return error.InvalidImage;
    var pos: usize = 12;
    var result: ?image.Image = null;
    var pixels = false;
    while (pos < data.len) {
        if (data.len - pos < 8) return error.InvalidImage;
        const tag = data[pos..][0..4];
        const n: usize = uint(data[pos + 4 ..][0..4], .little);
        if (n > data.len - pos - 8) return error.InvalidImage;
        const body = data[pos + 8 ..][0..n];
        var frame: ?image.Image = null;
        if (std.mem.eql(u8, tag, "VP8X")) {
            if (pos != 12 or n != 10 or body[0] & 0xc1 != 0 or body[1] != 0 or body[2] != 0 or body[3] != 0) return error.InvalidImage;
            // Animated WebP needs nested ANMF parsing; reject instead of guessing.
            if (body[0] & 2 != 0) return error.UnsupportedImageFormat;
            result = try dimensions(data, .webp, uint(body[4..7], .little) + 1, uint(body[7..10], .little) + 1);
        } else if (std.mem.eql(u8, tag, "VP8 ")) {
            if (n < 10 or body[0] & 1 != 0 or !std.mem.eql(u8, body[3..6], "\x9d\x01\x2a")) return error.InvalidImage;
            frame = try dimensions(data, .webp, uint(body[6..8], .little) & 0x3fff, uint(body[8..10], .little) & 0x3fff);
        } else if (std.mem.eql(u8, tag, "VP8L")) {
            if (n < 5 or body[0] != 0x2f or body[4] & 0xe0 != 0) return error.InvalidImage;
            const bits = uint(body[1..5], .little);
            frame = try dimensions(data, .webp, (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
        }
        if (frame) |f| {
            if (pixels) return error.InvalidImage;
            if (result) |r| {
                if (r.width != f.width or r.height != f.height) return error.InvalidImage;
            }
            result = f;
            pixels = true;
        }
        pos += n + 8;
        if (n & 1 != 0) {
            if (pos >= data.len or data[pos] != 0) return error.InvalidImage;
            pos += 1;
        }
    }
    if (!pixels) return error.InvalidImage;
    return result orelse error.InvalidImage;
}

pub const test_gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
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
