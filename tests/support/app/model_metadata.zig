fn serveMetadata(io: std.Io, server: *std.Io.net.Server, response: []const u8, cleaned: *std.atomic.Value(bool)) !void {
    return serveMetadataChecked(io, server, response, cleaned, false);
}

fn servePublicMetadata(io: std.Io, server: *std.Io.net.Server, response: []const u8, cleaned: *std.atomic.Value(bool)) !void {
    return serveMetadataChecked(io, server, response, cleaned, true);
}

fn serveMetadataChecked(io: std.Io, server: *std.Io.net.Server, response: []const u8, cleaned: *std.atomic.Value(bool), check_public: bool) !void {
    defer cleaned.store(true, .release);
    var stream = try server.accept(io);
    defer stream.close(io);
    var buffer: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = stream.reader(io, &buffer);
    var suffix: u32 = 0;
    var count: usize = 0;
    var headers: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &headers);
    while (suffix != 0x0d0a0d0a) {
        if (count == buffer.len) return error.TestHeadersTooLarge;
        const byte = try reader.interface.takeByte();
        headers[count] = std.ascii.toLower(byte);
        suffix = (suffix << 8) | byte;
        count += 1;
    }
    if (check_public) {
        try std.testing.expect(std.mem.startsWith(u8, headers[0..count], "get /api.json http/1.1\r\n"));
        try std.testing.expect(std.mem.find(u8, headers[0..count], "authorization:") == null);
        try std.testing.expect(std.mem.find(u8, headers[0..count], "user-agent: thinagent-metadata-check/1.0") != null);
        try std.testing.expect(std.mem.find(u8, headers[0..count], "accept: application/json") != null);
    }
    var output: [1024]u8 = undefined;
    var writer = stream.writer(io, &output);
    try writer.interface.writeAll(response);
    try writer.interface.flush();
}

fn serveCodexFixture(io: std.Io, server: *std.Io.net.Server) !void {
    var stream = try server.accept(io);
    defer stream.close(io);
    var buffer: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var reader = stream.reader(io, &buffer);
    var headers: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &headers);
    var count: usize = 0;
    var suffix: u32 = 0;
    while (suffix != 0x0d0a0d0a) {
        if (count == headers.len) return error.TestHeadersTooLarge;
        const byte = try reader.interface.takeByte();
        headers[count] = std.ascii.toLower(byte);
        count += 1;
        suffix = (suffix << 8) | byte;
    }
    try std.testing.expect(std.mem.startsWith(u8, headers[0..count], "get /models?client_version=" ++ @import("version.zig").number ++ " http/1.1\r\n"));
    try std.testing.expect(std.mem.find(u8, headers[0..count], "authorization: bearer fake-token\r\n") != null);
    try std.testing.expect(std.mem.find(u8, headers[0..count], "chatgpt-account-id: fake-account\r\n") != null);
    try std.testing.expect(std.mem.find(u8, headers[0..count], "originator: thin\r\n") != null);
    var out: [1024]u8 = undefined;
    var writer = stream.writer(io, &out);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"models\":[]}");
    try writer.interface.flush();
}

fn testRow(listing: *const Listing, id: providers.Id, name: []const u8) directory.Record {
    return listing.directory.rows[listing.directory.find(id, name).?];
}

fn testRoot(dir: std.Io.Dir) !fs.Root {
    var buffer: [4096]u8 = undefined;
    const len = try dir.realPath(std.testing.io, &buffer);
    return fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..len]);
}

fn cacheAllocationCheck(a: std.mem.Allocator) !void {
    var cache = try parseCache(a,
        \\{"version":16,"directory_mask":1,"models":[{"provider":"deepseek","id":"deepseek/raw/id","context_window":131072,"available":true,"protocol":"chat","reasoning":{"format":"deepseek","map":{"off":"off","high":"high"}},"dev_protocol":"chat","dev_present":true,"dev_output_tokens":8192,"dev_context_tokens":262144,"dev_input_price_flat_limit":262144}],"refresh":[{"generation":7,"last_attempt_ms":10,"last_success_ms":11,"successful":true},{},{},{},{}]}
    );
    defer cache.deinit(a);
    try std.testing.expectEqualStrings("deepseek/raw/id", cache.directory.name(0));
    try std.testing.expectEqual(@as(u64, 7), cache.refresh[0].generation);
}
