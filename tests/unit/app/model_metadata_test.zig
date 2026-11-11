test "explicit SystemOne directory identity survives cache without generative capabilities" {
    const a = std.testing.allocator;
    const listing = try parseListing(a,
        \\{"data":[{"id":"reviewer/not-jev","protocol":"systemone"}]}
    , .opencode_zen);
    const cache: Cache = .{ .directory = listing.directory, .directory_mask = listing.directory_mask };
    const entry = dynamicEntry(&cache, .opencode_zen, "reviewer/not-jev").?;
    try std.testing.expectEqual(Protocol.systemone, entry.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), entry.model.context_tokens);
    try std.testing.expect(capacityFor(&cache, entry) == null);
    try std.testing.expect(contextFor(&cache, entry) == null);
    try std.testing.expect(outputFor(&cache, entry) == null);
    try std.testing.expect(entryDeclaration(&cache, entry) == null);
    try std.testing.expect(inputPriceThresholdFor(&cache, entry) == null);
    try std.testing.expect(inputPriceFlatLimitFor(&cache, entry) == null);
    var bytes: std.Io.Writer.Allocating = .init(a);
    defer bytes.deinit();
    try std.json.Stringify.value(Document{ .directory_mask = listing.directory_mask, .models = &.{.{ .provider = .opencode_zen, .id = "reviewer/not-jev", .protocol = entry.model.protocol, .available = true }} }, .{}, &bytes.writer);
    const restored = try parseCache(a, bytes.written());
    const again = dynamicEntry(&restored, .opencode_zen, "reviewer/not-jev").?;
    try std.testing.expectEqual(Protocol.systemone, again.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), again.model.context_tokens);
}
test "models.dev native API identity survives cache roundtrip without generative metadata" {
    const a = std.testing.allocator;
    const source = try parseDev(a,
        \\{"opencode":{"npm":"@ai-sdk/openai-compatible","models":{"reviewer":{"api":{"url":"https://opencode.ai/inference/systemone/v1"},"limit":{"context":100000,"output":32000},"cost":{"input":1,"output":2}}}}}
    );
    var merged: Listing = .{};
    try mergeDev(&merged, &source);
    const row = merged.directory.rows[merged.directory.find(.opencode_zen, "reviewer").?];
    try std.testing.expectEqual(Protocol.systemone, row.dev_protocol);
    var bytes: std.Io.Writer.Allocating = .init(a);
    defer bytes.deinit();
    try std.json.Stringify.value(Document{ .models = &.{.{
        .provider = .opencode_zen,
        .id = "reviewer",
        .dev_protocol = row.dev_protocol,
        .dev_present = row.dev_present,
        .dev_context_tokens = row.dev_context_tokens,
        .dev_output_tokens = row.dev_output_tokens,
        .dev_input_price_threshold = row.dev_input_price_threshold,
        .dev_input_price_flat_limit = row.dev_input_price_flat_limit,
    }} }, .{}, &bytes.writer);
    const cache = try parseCache(a, bytes.written());
    const entry = restoreEntry(&cache, .opencode_zen, "reviewer").?;
    try std.testing.expectEqual(Protocol.systemone, entry.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), entry.model.context_tokens);
    try std.testing.expect(entry.model.output_tokens == null);
    try std.testing.expect(capacityFor(&cache, entry) == null);
    try std.testing.expect(contextFor(&cache, entry) == null);
    try std.testing.expect(outputFor(&cache, entry) == null);
    try std.testing.expect(entryDeclaration(&cache, entry) == null);
    try std.testing.expect(inputPriceThresholdFor(&cache, entry) == null);
    try std.testing.expect(inputPriceFlatLimitFor(&cache, entry) == null);
}
test "documented SystemOne fallback resolves listed Jev without inventing availability or capabilities" {
    var cache: Cache = .{};
    cache.directory_mask = bit(.opencode_zen);
    const name = "jev-1.13-free";
    try std.testing.expect(dynamicEntry(&cache, .opencode_zen, name) == null);
    const row = try cache.directory.upsert(.opencode_zen, name);
    row.available = true;
    row.tokens = 65536;
    row.dev_context_tokens = 65536;
    row.dev_output_tokens = 4096;
    var entry = dynamicEntry(&cache, .opencode_zen, name).?;
    try std.testing.expectEqual(Protocol.systemone, entry.model.protocol);
    try std.testing.expectEqual(@as(u32, 0), entry.model.context_tokens);
    try std.testing.expect(entry.model.output_tokens == null);
    try std.testing.expect(capacityFor(&cache, entry) == null);
    try std.testing.expect(outputFor(&cache, entry) == null);
    try std.testing.expect(entryDeclaration(&cache, entry) == null);
    try std.testing.expect(inputPriceThresholdFor(&cache, entry) == null);
    row.protocol = .responses;
    try std.testing.expectEqual(Protocol.responses, dynamicEntry(&cache, .opencode_zen, name).?.model.protocol);
    row.protocol = .auto;
    row.dev_protocol = .chat;
    entry = dynamicEntry(&cache, .opencode_zen, name).?;
    try std.testing.expectEqual(Protocol.chat, entry.model.protocol);
    row.dev_protocol = .auto;
    row.available = false;
    try std.testing.expect(dynamicEntry(&cache, .opencode_zen, name) == null);
    try std.testing.expect(dynamicEntry(&cache, .opencode_go, name) == null);
}
test "Codex listing uses explicit route, visibility and advertised efforts" {
    const listing = try parseListing(std.testing.allocator,
        \\{"models":[{"slug":"sample/raw","visibility":"list","supported_in_api":false,"context_window":12345,"max_context_window":99999,"supported_reasoning_levels":[{"effort":"high","description":""},{"effort":"ultra","description":""}]},{"slug":"hidden","visibility":"hide"}]}
    , .openai_codex);
    const row = listing.directory.rows[listing.directory.find(.openai_codex, "sample/raw").?];
    try std.testing.expectEqual(Protocol.responses, row.protocol);
    try std.testing.expectEqual(@as(?u32, 12345), row.tokens);
    try std.testing.expect(row.available == true);
    try std.testing.expectEqualStrings("high", row.reasoning.?.declaration().map.high.?);
    try std.testing.expect(row.reasoning.?.declaration().map.off == null);
    try std.testing.expect(listing.directory.rows[listing.directory.find(.openai_codex, "hidden").?].available == false);
    const empty = try parseListing(std.testing.allocator, "{\"models\":[]}", .openai_codex);
    try std.testing.expectEqual(bit(.openai_codex), empty.directory_mask);
}
test "metadata lexical limits precede allocation and respect quoted escapes" {
    const a = std.testing.allocator;
    var buffer: [2048]u8 = undefined;
    for ([_]usize{ 31, 32 }) |levels| {
        var w = std.Io.Writer.fixed(&buffer);
        try w.writeAll("{\"data\":[],\"unknown\":");
        for (0..levels) |_| try w.writeByte('[');
        try w.writeAll("null");
        for (0..levels) |_| try w.writeByte(']');
        try w.writeByte('}');
        if (levels == 31) {
            _ = try parseListing(a, buffer[0..w.end], .deepseek);
        } else {
            // A zero-capacity allocator proves this rejects before JSON allocation.
            var fixed = std.heap.FixedBufferAllocator.init(&.{});
            try std.testing.expectError(error.MetadataTooDeep, parseListing(fixed.allocator(), buffer[0..w.end], .deepseek));
            try std.testing.expectError(error.MetadataTooDeep, parseCache(fixed.allocator(), buffer[0..w.end]));
        }
    }
    const quoted =
        \\{"data":[],"extra":{"text":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\\\"{}","next":true}}
    ;
    _ = try parseListing(a, quoted, .deepseek);
    try std.testing.expectError(error.DuplicateField, parseListing(a, "{\"data\":[],\"extra\":{\"x\":1,\"x\":2}}", .deepseek));
    try std.testing.expectError(error.DuplicateField, parseCache(a, "{\"version\":1,\"version\":1,\"attempted\":0,\"records\":[]}"));
    try std.testing.expectError(error.InvalidMetadata, boundJson("{\"x\":\"unterminated", max_body_bytes));
    try std.testing.expectError(error.InvalidMetadata, boundJson("{]", max_body_bytes));
    const many = try a.alloc(u8, 2 * 32768 + 1);
    defer a.free(many);
    many[0] = '[';
    for (0..32768) |i| {
        many[1 + 2 * i] = '0';
        many[2 + 2 * i] = if (i == 32767) ']' else ',';
    }
    many[many.len - 3] = ']';
    try boundJson(many[0 .. many.len - 2], max_body_bytes);
    many[many.len - 3] = ',';
    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    try std.testing.expectError(error.MetadataTooComplex, parseListing(fixed.allocator(), many, .deepseek));
}
test "metadata deep oversized and duplicate caches remain untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const oversized = try std.testing.allocator.alloc(u8, max_cache_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    var deep: [66]u8 = undefined;
    @memset(deep[0..33], '[');
    @memset(deep[33..], ']');
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = &deep, .err = error.MetadataTooDeep },
        .{ .body = oversized, .err = error.MetadataTooLarge },
        .{ .body = "{\"version\":1,\"version\":1,\"attempted\":0,\"records\":[]}", .err = error.DuplicateField },
        .{ .body = "{\"version\":", .err = error.InvalidMetadata },
    };
    for (cases) |case| {
        try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = case.body });
        const before = try root.dir.statFile(root.io, file_name, .{});
        try std.testing.expectError(case.err, claim(&root, all_mask, true));
        try std.testing.expectError(case.err, commit(&root, all_mask, .{}));
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
        const result = try root.read(std.testing.allocator, file_name, 0, max_cache_bytes + 1);
        defer std.testing.allocator.free(result.data);
        try std.testing.expectEqualStrings(case.body, result.data);
    }
}
test "Codex private fetch seam uses exact headers and fixed production scope" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/models?client_version=" ++ @import("version.zig").number, codex_listing_url);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/models?client_version={s}", .{ server.socket.address.getPort(), @import("version.zig").number });
    defer a.free(url);
    var token = [_]u8{ 'f', 'a', 'k', 'e', '-', 't', 'o', 'k', 'e', 'n' };
    var account = [_]u8{ 'f', 'a', 'k', 'e', '-', 'a', 'c', 'c', 'o', 'u', 'n', 't' };
    const credential: codex_auth.RequestCredential = .{ .access_token = &token, .account_id = &account };
    var server_job = try std.Io.concurrent(io, serveCodexFixture, .{ io, &server });
    defer server_job.cancel(io) catch {};
    const listing = try fetchCodexAt(a, io, &credential, null, 5000, url);
    try server_job.await(io);
    try std.testing.expectEqual(bit(.openai_codex), listing.directory_mask);
    try std.testing.expectEqualStrings("fake-token", &token);
    var canceled: p.Cancellation = .{};
    canceled.cancel();
    try std.testing.expectError(error.Canceled, fetchCodexAt(a, io, &credential, &canceled, 5000, url));
    try std.testing.expectError(error.RequestTimeout, fetchCodexAt(a, io, &credential, null, 0, url));
}
test "metadata loopback transport success redirects size short body and cleanup" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const close_head = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";
    const streamed_oversized = try a.alloc(u8, close_head.len + max_body_bytes + 1);
    defer a.free(streamed_oversized);
    @memcpy(streamed_oversized[0..close_head.len], close_head);
    @memset(streamed_oversized[close_head.len..], ' ');
    const cases = [_]struct { response: []const u8, err: ?anyerror }{
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"data\":[]}", .err = null },
        .{ .response = "HTTP/1.1 302 Found\r\nLocation: /not-followed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .err = error.MetadataHttpStatus },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 524289\r\nConnection: close\r\n\r\n", .err = error.MetadataTooLarge },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n{}", .err = error.IncompleteMetadata },
        .{ .response = streamed_oversized, .err = error.StreamTooLong },
    };
    for (cases) |case| {
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/models", .{server.socket.address.getPort()});
        defer a.free(url);
        var cleaned = std.atomic.Value(bool).init(false);
        var worker = try std.Io.concurrent(io, serveMetadata, .{ io, &server, case.response, &cleaned });
        defer worker.cancel(io) catch {};
        if (case.err) |err| {
            try std.testing.expectError(err, fetchUrl(a, io, url, "synthetic-test-key", max_body_bytes));
        } else {
            const body = try fetchUrl(a, io, url, null, max_body_bytes);
            defer a.free(body);
            _ = try parseListing(a, body, .deepseek);
        }
        try worker.await(io);
        try std.testing.expect(cleaned.load(.acquire));
    }
}
test "metadata uses only context_window and exact provider raw names" {
    const a = std.testing.allocator;
    const body =
        \\{"object":"list","data":[{"id":"deepseek-flash","context_window":12345,"max_tokens":2},{"id":"deepseek-v4-pro","max_tokens":8192,"input_tokens":100000,"output_tokens":3}]}
    ;
    const values = try parseListing(a, body, .deepseek);
    try std.testing.expectEqual(@as(?u32, 12345), testRow(&values, .deepseek, "deepseek-flash").tokens);
    try std.testing.expect(testRow(&values, .deepseek, "deepseek-v4-pro").tokens == null);
    const other = try parseListing(a, body, .opencode_go);
    try std.testing.expect(other.directory.find(.deepseek, "deepseek-flash") == null);
    const absent = try parseListing(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":null}]}", .deepseek);
    try std.testing.expect(testRow(&absent, .deepseek, "deepseek-flash").tokens == null);
    const shared = "{\"data\":[{\"id\":\"minimax-m2.7\",\"context_window\":204800}]}";
    const zen = try parseListing(a, shared, .opencode_zen);
    try std.testing.expectEqual(@as(?u32, 204800), testRow(&zen, .opencode_zen, "minimax-m2.7").tokens);
    try std.testing.expect(zen.directory.find(.opencode_go, "minimax-m2.7") == null);
}
test "metadata rejects invalid IDs capacities duplicate IDs and shapes" {
    const bad = [_][]const u8{
        "[]",                                                      "{}",                                                 "{\"data\":{}}",                                          "{\"data\":[{}]}",
        "{\"data\":[{\"id\":\"\"}]}",                              "{\"data\":[{\"id\":\"x\"},{\"id\":\"x\"}]}",         "{\"data\":[{\"id\":\"x\",\"context_window\":0}]}",       "{\"data\":[{\"id\":\"x\",\"context_window\":-1}]}",
        "{\"data\":[{\"id\":\"x\",\"context_window\":16777217}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":1.5}]}", "{\"data\":[{\"id\":\"x\",\"context_window\":\"100\"}]}",
    };
    for (bad) |body| try std.testing.expectError(error.InvalidMetadata, parseListing(std.testing.allocator, body, .deepseek));
    try std.testing.expectError(error.DuplicateField, parseListing(std.testing.allocator, "{\"data\":[],\"data\":[]}", .deepseek));
}
test "metadata body list and ID bounds are enforced" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, max_body_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.MetadataTooLarge, parseListing(a, oversized, .deepseek));
    var buffer: [32768]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[");
    for (0..513) |i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"id\":\"model-{d}\"}}", .{i});
    }
    try writer.writeAll("]}");
    try std.testing.expectError(error.InvalidMetadata, parseListing(a, buffer[0..writer.end], .deepseek));
    writer = std.Io.Writer.fixed(&buffer);
    try writer.writeAll("{\"data\":[{\"id\":\"");
    for (0..257) |_| try writer.writeByte('a');
    try writer.writeAll("\"}]}");
    try std.testing.expectError(error.InvalidMetadata, parseListing(a, buffer[0..writer.end], .deepseek));
}
test "metadata private roundtrip claims once and merges only successful providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try testRoot(tmp.dir);
    defer first.deinit();
    var second = try testRoot(tmp.dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try load(&first)).directory.count);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&first, 0, false)).mask);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, file_name, .{}));
    try std.testing.expectEqual(all_mask, (try claim(&first, all_mask, false)).mask);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&second, all_mask, false)).mask);
    try std.testing.expectEqual(bit(.deepseek), (try claim(&second, bit(.deepseek), true)).mask);
    var original: Listing = .{};
    for (providers.Id.all) |id| {
        const source = try parseListing(std.testing.allocator, if (id == .openai_codex) "{\"models\":[{\"slug\":\"raw/id\",\"visibility\":\"list\",\"context_window\":1000}]}" else "{\"data\":[{\"id\":\"raw/id\",\"context_window\":1000}]}", id);
        try mergeOfficial(&original, &source, id);
    }
    _ = try commit(&first, all_mask, original);
    const refreshed = try parseListing(std.testing.allocator, "{\"data\":[{\"id\":\"deepseek-flash\",\"context_window\":2000,\"effort\":{\"supported_levels\":[\"low\",\"high\",\"max\"]}}]}", .deepseek);
    const cache = try commit(&second, bit(.deepseek), refreshed);
    const row = cache.directory.rows[cache.directory.find(.deepseek, "deepseek-flash").?];
    try std.testing.expectEqual(@as(?u32, 2000), row.tokens);
    try std.testing.expectEqualStrings("max", row.reasoning.?.declaration().map.max.?);
    try std.testing.expectEqual(@as(?u32, 1000), cache.directory.rows[cache.directory.find(.opencode_zen, "raw/id").?].tokens);
    try std.testing.expectEqualDeep(cache, try load(&first));
    const stat = try tmp.dir.statFile(std.testing.io, file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    _ = try commit(&first, 0, .{});
    try std.testing.expectEqual(stat.inode, (try tmp.dir.statFile(std.testing.io, file_name, .{})).inode);
}
test "metadata rejects old future unknown and malformed cache without writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const a = std.testing.allocator;
    for (0..18) |version| {
        if (version == cache_version) continue;
        const body = try std.fmt.allocPrint(a, "{{\"version\":{d},\"models\":[]}}", .{version});
        defer a.free(body);
        try root.writeMode(file_name, body, true, 0o600);
        const before = try root.dir.statFile(root.io, file_name, .{});
        if (version < @as(usize, cache_version)) {
            // Older schemas are classified for claims, never migrated here.
            try std.testing.expectError(error.OutdatedMetadataCache, load(&root));
            try std.testing.expectError(error.OutdatedMetadataCache, commitAt(&root, all_mask, .{}, 1000));
        } else {
            try std.testing.expectError(error.InvalidMetadata, load(&root));
            try std.testing.expectError(error.InvalidMetadata, claimAt(&root, all_mask | dev_bit, true, 1000, .{}));
            try std.testing.expectError(error.InvalidMetadata, commitAt(&root, all_mask, .{}, 1000));
        }
        const bytes = try root.read(a, file_name, 0, max_cache_bytes);
        defer a.free(bytes.data);
        try std.testing.expectEqualStrings(body, bytes.data);
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
    }
    for ([_][]const u8{
        "{\"version\":16,\"attempted\":0}",
        "{\"version\":16,\"records\":[]}",
        "{\"version\":16,\"unknown\":false}",
        "{\"version\":16,\"models\":[{\"provider\":\"deepseek\",\"id\":\"raw/id\",\"unknown\":1}]}",
        "{\"version\":16,\"refresh\":[{\"unknown\":0},{},{},{},{}]}",
    }) |body| {
        try root.writeMode(file_name, body, true, 0o600);
        const before = try root.dir.statFile(root.io, file_name, .{});
        try std.testing.expectError(error.UnknownField, claimAt(&root, all_mask, true, 1000, .{}));
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
        const bytes = try root.read(a, file_name, 0, max_cache_bytes);
        defer a.free(bytes.data);
        try std.testing.expectEqualStrings(body, bytes.data);
    }
}
test "version 15 ambiguous public profiles are outdated rather than migrated" {
    try std.testing.expectError(error.OutdatedMetadataCache, parseCache(std.testing.allocator,
        \\{"version":15,"models":[{"provider":"opencode_go","id":"raw/id","dev_protocol":"anthropic","dev_present":true,"dev_reasoning":{"format":"anthropic","map":{"high":"high"}}}]}
    ));
}
test "metadata stale document is rebuilt by manual and automatic claims only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const a = std.testing.allocator;
    // A claim against a missing cache still starts at generation 1.
    const first = try claimAt(&root, all_mask, true, 900, .{});
    try std.testing.expectEqual(@as(u64, 1), first.generations[0]);
    const stale = "{\"version\":12,\"attempted\":1750000000000,\"records\":[{\"id\":\"legacy\",\"context_window\":4096}],\"models\":[{\"provider\":\"deepseek\",\"id\":\"legacy\",\"context_window\":4096}]}";
    var listing: Listing = .{};
    for (providers.Id.all) |id| {
        const source = try parseListing(a, if (id == .openai_codex) "{\"models\":[{\"slug\":\"fresh\",\"visibility\":\"list\",\"context_window\":8192}]}" else "{\"data\":[{\"id\":\"fresh\",\"context_window\":8192}]}", id);
        try mergeOfficial(&listing, &source, id);
    }
    for ([_]bool{ true, false }) |manual| {
        try root.writeMode(file_name, stale, true, 0o600);
        try std.testing.expectError(error.OutdatedMetadataCache, load(&root));
        const bytes = try root.read(a, file_name, 0, max_cache_bytes);
        defer a.free(bytes.data);
        try std.testing.expectEqualStrings(stale, bytes.data);
        const rebuilt = try claimAt(&root, all_mask, manual, 1000, .{});
        try std.testing.expectEqual(all_mask, rebuilt.mask);
        try std.testing.expectEqual(@as(usize, 0), rebuilt.cache.directory.count);
        for (rebuilt.generations) |generation| try std.testing.expect(generation >= (@as(u64, 1) << 61));
        const published = try commitClaimedAt(&root, all_mask, listing, rebuilt.generations, 1010);
        try std.testing.expectEqual(all_mask, published.accepted);
        const reloaded = try load(&root);
        try std.testing.expectEqual(providers.Id.all.len, reloaded.directory.count);
        try std.testing.expectEqual(@as(?u32, 8192), reloaded.directory.rows[reloaded.directory.find(.deepseek, "fresh").?].tokens);
        // A claim taken before the rebuild can no longer publish.
        const delayed = try commitClaimedAt(&root, all_mask, listing, first.generations, 1020);
        try std.testing.expectEqual(@as(u8, 0), delayed.accepted);
        const after = try load(&root);
        try std.testing.expectEqual(providers.Id.all.len, after.directory.count);
        try std.testing.expectEqual(@as(?u32, 8192), after.directory.rows[after.directory.find(.deepseek, "fresh").?].tokens);
    }
}
test "official effort metadata maps exact model IDs and protocol formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deepseek = try parseListing(
        a,
        "{\"data\":[{\"id\":\"deepseek-flash\",\"effort\":{\"supported_levels\":[\"low\",\"high\",\"max\"],\"default_level\":\"high\"}}]}",
        .deepseek,
    );
    const flash = testRow(&deepseek, .deepseek, "deepseek-flash").reasoning.?.declaration();
    try std.testing.expectEqual(thinking.Format.deepseek, flash.format);
    try std.testing.expectEqual(@as(usize, 4), flash.map.levels().count()); // includes protocol off toggle
    try std.testing.expectEqualStrings("max", flash.map.max.?);
    const anthropic = try parseListing(
        a,
        "{\"data\":[{\"id\":\"claude-haiku-5-5\",\"effort\":{\"supported_levels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]}}]}",
        .opencode_go,
    );
    const haiku = testRow(&anthropic, .opencode_go, "claude-haiku-5-5").reasoning.?.declaration();
    try std.testing.expectEqual(thinking.Format.anthropic, haiku.format);
    try std.testing.expectEqualStrings("xhigh", haiku.map.xhigh.?);
    var unknown = try std.json.parseFromSlice(std.json.Value, a, "{\"supported_levels\":[\"ultra\"]}", .{});
    defer unknown.deinit();
    try std.testing.expectEqual(@as(?thinking.Declaration, null), try parseEffort(unknown.value, .deepseek, .chat));
    try std.testing.expectError(error.InvalidMetadata, parseEffort(.{ .string = "bad" }, .deepseek, .chat));
}
test "metadata listing tracks exact membership independently of capacity and provider" {
    const a = std.testing.allocator;
    const listing = try parseListing(a, "{\"data\":[{\"id\":\"minimax-m2.7\"},{\"id\":\"deepseek-flash\",\"context_window\":42},{\"id\":\"unknown\",\"context_window\":100}]}", .opencode_go);
    try std.testing.expectEqual(@as(usize, 3), listing.directory.count);
    try std.testing.expectEqual(@as(?bool, true), testRow(&listing, .opencode_go, "minimax-m2.7").available);
    try std.testing.expect(testRow(&listing, .opencode_go, "minimax-m2.7").tokens == null);
    try std.testing.expect(listing.directory.find(.deepseek, "deepseek-flash") == null);
    const absent = try parseListing(a, "{\"data\":[{\"id\":\"opencode-go/minimax-m2.7\"},{\"id\":\"MINIMAX-M2.7\"}]}", .opencode_go);
    try std.testing.expect(absent.directory.find(.opencode_go, "minimax-m2.7") == null);
    const explicit_null = try parseListing(a, "{\"data\":[{\"id\":\"minimax-m2.7\",\"context_window\":null}]}", .opencode_go);
    try std.testing.expectEqual(@as(?bool, true), testRow(&explicit_null, .opencode_go, "minimax-m2.7").available);
    try std.testing.expect(testRow(&explicit_null, .opencode_go, "minimax-m2.7").tokens == null);
}
test "metadata empty official listing is authoritative and failed refresh preserves other providers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var listing: Listing = .{};
    for (providers.Id.all) |id| {
        const source = try parseListing(std.testing.allocator, if (id == .openai_codex) "{\"models\":[{\"slug\":\"raw/id\",\"visibility\":\"list\",\"context_window\":4096}]}" else "{\"data\":[{\"id\":\"raw/id\",\"context_window\":4096}]}", id);
        try mergeOfficial(&listing, &source, id);
    }
    const original = try commit(&root, all_mask, listing);
    try std.testing.expectEqualDeep(original, try commit(&root, 0, .{}));
    const empty = try parseListing(std.testing.allocator, "{\"data\":[]}", .deepseek);
    const removed = try commit(&root, bit(.deepseek), empty);
    for (providers.Id.all) |id| {
        const row = removed.directory.rows[removed.directory.find(id, "raw/id").?];
        try std.testing.expectEqual(@as(?bool, id != .deepseek), row.available);
        try std.testing.expectEqual(if (id == .deepseek) @as(?u32, null) else @as(?u32, 4096), row.tokens);
    }
    try std.testing.expect(hasDirectory(&removed, .deepseek));
    try std.testing.expect(findEntry(&removed, "deepseek/deepseek-flash") == null);
    try std.testing.expectEqualDeep(removed, try load(&root));
    const claimed = try claim(&root, all_mask, true);
    try std.testing.expectEqualDeep(removed.directory, claimed.cache.directory);
    const before = try load(&root);
    var invalid = listing;
    invalid.directory.rows[invalid.directory.find(.deepseek, "raw/id").?].tokens = 0;
    try std.testing.expectError(error.InvalidMetadata, commit(&root, bit(.deepseek), invalid));
    try std.testing.expectEqualDeep(before, try load(&root));
}
test "metadata rejects malformed availability and duplicate cache records without overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = "{\"version\":16,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":1}]}", .err = error.UnexpectedToken },
        .{ .body = "{\"version\":16,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":\"true\"}]}", .err = error.UnexpectedToken },
        .{ .body = "{\"version\":16,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":true,\"available\":false}]}", .err = error.DuplicateField },
        .{ .body = "{\"version\":16,\"models\":[{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":true},{\"provider\":\"deepseek\",\"id\":\"deepseek-flash\",\"context_window\":null,\"available\":false}]}", .err = error.InvalidMetadata },
    };
    for (cases) |case| {
        try root.dir.writeFile(root.io, .{ .sub_path = file_name, .data = case.body });
        const before = try root.dir.statFile(root.io, file_name, .{});
        try std.testing.expectError(case.err, claim(&root, all_mask, true));
        try std.testing.expectError(case.err, commit(&root, all_mask, .{}));
        try std.testing.expectEqual(before.inode, (try root.dir.statFile(root.io, file_name, .{})).inode);
        const bytes = try root.read(std.testing.allocator, file_name, 0, max_cache_bytes);
        defer std.testing.allocator.free(bytes.data);
        try std.testing.expectEqualStrings(case.body, bytes.data);
    }
}
test "metadata official listing routes only DeepSeek credentials" {
    try std.testing.expectEqualStrings("https://api.deepseek.com/models", listingUrl(.deepseek));
    try std.testing.expectEqualStrings("https://opencode.ai/inference/go/v1/models", listingUrl(.opencode_go));
    try std.testing.expectEqualStrings("https://opencode.ai/inference/v1/models", listingUrl(.opencode_zen));
    try std.testing.expectEqualStrings("synthetic-test-key", listingKey(.deepseek, "synthetic-test-key").?);
    try std.testing.expect(listingKey(.deepseek, null) == null);
    for ([_]providers.Id{ .opencode_go, .opencode_zen }) |id| {
        try std.testing.expect(listingKey(id, "synthetic-test-key") == null);
        try std.testing.expect(listingKey(id, "invalid\r\nkey") == null);
    }
}
test "models.dev profiles persist in current cache and automatic claims observe cooldown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const body =
        \\{"deepseek":{"id":"deepseek","models":{"deepseek-flash":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high","max"]}],"provider":{"npm":"@ai-sdk/openai-compatible"}}}}}
    ;
    const listing = try parseDev(std.testing.allocator, body);
    try std.testing.expect(listing.dev_done);
    try std.testing.expectEqualStrings("off", testRow(&listing, .deepseek, "deepseek-flash").dev_reasoning.?.declaration().map.off.?);
    try std.testing.expectEqual(dev_bit, (try claim(&root, dev_bit, false)).mask);
    _ = try commit(&root, 0, listing);
    const reloaded = try load(&root);
    try std.testing.expectEqualStrings("off", reloaded.directory.rows[reloaded.directory.find(.deepseek, "deepseek-flash").?].dev_reasoning.?.declaration().map.off.?);
    try std.testing.expect(reloaded.directory.rows[reloaded.directory.find(.deepseek, "deepseek-flash").?].reasoning == null);
    try std.testing.expect(reloaded.refresh[providers.Id.all.len].last_attempt_ms != null);
    try std.testing.expectEqual(@as(u8, 0), (try claim(&root, dev_bit, false)).mask);
    // A failed later models.dev fetch does not erase the last successful profile.
    _ = try commit(&root, 0, .{});
    try std.testing.expect((try load(&root)).directory.rows[reloaded.directory.find(.deepseek, "deepseek-flash").?].dev_reasoning != null);
}
test "models.dev loopback transport parses public catalog and enforces its own size limit" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const document =
        \\{"deepseek":{"id":"deepseek","models":{"deepseek-flash":{"reasoning_options":[{"type":"toggle"},{"type":"effort","values":["high","max"]}],"provider":{"npm":"@ai-sdk/openai-compatible"}}}}}
    ;
    // A valid catalog body larger than the official provider's 512 KiB limit.
    const body = try a.alloc(u8, max_body_bytes + document.len + 1);
    defer a.free(body);
    @memset(body, ' ');
    @memcpy(body[body.len - document.len ..], document);
    const response = try std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    defer a.free(response);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api.json", .{server.socket.address.getPort()});
    defer a.free(url);
    var cleaned = std.atomic.Value(bool).init(false);
    var worker = try std.Io.concurrent(io, servePublicMetadata, .{ io, &server, response, &cleaned });
    defer worker.cancel(io) catch {};
    const fetched = try fetchUrl(a, io, url, null, models_dev.max_body_bytes);
    defer a.free(fetched);
    const listing = try parseDev(a, fetched);
    try worker.await(io);
    try std.testing.expect(cleaned.load(.acquire));
    try std.testing.expect(listing.dev_done);
    try std.testing.expectEqualStrings("off", testRow(&listing, .deepseek, "deepseek-flash").dev_reasoning.?.declaration().map.off.?);
    // The provider limit (512 KiB) is not used for the public catalog, and a
    // smaller explicit limit fails before any parser sees a partial document.
    var tiny = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var second = try tiny.listen(io, .{});
    defer second.deinit(io);
    const second_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api.json", .{second.socket.address.getPort()});
    defer a.free(second_url);
    var second_cleaned = std.atomic.Value(bool).init(false);
    const oversized_head = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n";
    var second_worker = try std.Io.concurrent(io, servePublicMetadata, .{ io, &second, oversized_head, &second_cleaned });
    defer second_worker.cancel(io) catch {};
    try std.testing.expectError(error.MetadataTooLarge, fetchUrl(a, io, second_url, null, 8));
    try second_worker.await(io);
    try std.testing.expect(second_cleaned.load(.acquire));
}
test "metadata current cache allocation failures release all parser scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cacheAllocationCheck, .{});
}
test "metadata declaration identity never strips a provider prefix inside raw IDs" {
    var listing = try parseDev(std.testing.allocator,
        \\{"opencode-go":{"npm":"@ai-sdk/openai-compatible","models":{"raw/id":{"reasoning_options":[{"type":"effort","values":["low"]}]},"opencode-go/raw/id":{"reasoning_options":[{"type":"effort","values":["high"]}]}}}}
    );
    const official = try parseListing(std.testing.allocator, "{\"data\":[{\"id\":\"raw/id\"},{\"id\":\"opencode-go/raw/id\"}]}", .opencode_go);
    try mergeOfficial(&listing, &official, .opencode_go);
    const cache: Cache = .{ .directory = listing.directory, .directory_mask = bit(.opencode_go) };
    var config: cfg.Config = .{ .provider = catalog.connection(.opencode_go), .model = .{ .name = "opencode-go/raw/id", .protocol = .chat, .context_tokens = 32768 } };
    try std.testing.expectEqualStrings("high", declarationForConfig(&cache, config).?.map.high.?);
    config.model.name = "raw/id";
    try std.testing.expectEqualStrings("low", declarationForConfig(&cache, config).?.map.low.?);
    config.model.name = "opencode-go/opencode-go/raw/id";
    try std.testing.expect(declarationForConfig(&cache, config) == null);
    config.provider.kind = .deepseek;
    config.model.name = "raw/id";
    try std.testing.expect(declarationForConfig(&cache, config) == null);
    const exact = restoreEntry(&cache, .opencode_go, "opencode-go/raw/id").?;
    try std.testing.expectEqualStrings("opencode-go/raw/id", exact.model.name);
    try std.testing.expectEqualStrings("opencode-go/raw/id", findEntry(&cache, "opencode-go/opencode-go/raw/id").?.model.name);
}
test "provider reasoning source is fixed by verified provider" {
    const t = std.testing;
    for (providers.Id.all) |id| {
        var cache: Cache = .{};
        const row = try cache.directory.upsert(id, "source-test");
        row.available = true;
        const protocol: Protocol = if (id == .deepseek) .chat else .responses;
        const format: thinking.Format = if (id == .deepseek) .deepseek else .standard;
        row.protocol = protocol;
        row.dev_protocol = protocol;
        row.dev_present = true;
        row.reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "high" } });
        row.dev_reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
        row.dev_context_tokens = 123456;
        row.dev_output_tokens = 8192;
        row.dev_input_price_flat_limit = 123456;
        const entry = restoreEntry(&cache, id, "source-test").?;
        var config: cfg.Config = .{ .provider = catalog.connection(id), .model = entry.model };
        const official = id == .deepseek or id == .openai_codex;
        const selected = declarationForConfig(&cache, config).?;
        const selected_entry = entryDeclaration(&cache, entry).?;
        if (official) {
            try t.expectEqualStrings("high", selected.map.high.?);
            try t.expectEqualStrings("high", selected_entry.map.high.?);
            try t.expect(selected.map.low == null);
            row.dev_reasoning = null;
            try t.expectEqualStrings("high", declarationForConfig(&cache, config).?.map.high.?);
            row.dev_reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
            row.reasoning = null;
        } else {
            try t.expectEqualStrings("low", selected.map.low.?);
            try t.expectEqualStrings("low", selected_entry.map.low.?);
            try t.expect(selected.map.high == null);
            row.dev_reasoning = null;
        }
        try t.expect(declarationForConfig(&cache, config) == null);
        try t.expect(entryDeclaration(&cache, entry) == null);
        config.model.reasoning = .{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "user-high" } };
        config.model.reasoning_source = .explicit;
        applyReasoning(&cache, &config);
        try t.expectEqualStrings("user-high", config.model.reasoning.?.map.high.?);
        row.reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "high" } });
        row.dev_reasoning = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
        try t.expect(declarationForConfig(&cache, config) != null);
        config.model.name = "wrong-id";
        try t.expect(declarationForConfig(&cache, config) == null);
        config.model.name = "source-test";
        config.provider.base_url = "https://invalid.example/v1";
        try t.expect(declarationForConfig(&cache, config) == null);
        config.provider = catalog.connection(id);
        config.provider.kind = if (id == .deepseek) .opencode_go else .deepseek;
        try t.expect(declarationForConfig(&cache, config) == null);
        config.provider = catalog.connection(id);
        config.model.protocol = if (protocol == .chat) .responses else .chat;
        try t.expect(declarationForConfig(&cache, config) == null);
        if (id == .deepseek) {
            try t.expectEqual(@as(?u32, 123456), contextFor(&cache, entry));
            try t.expectEqual(@as(?u32, 8192), outputFor(&cache, entry));
            try t.expectEqual(@as(?u32, 123456), inputPriceFlatLimitFor(&cache, entry));
        }
    }
}
test "provider reasoning source official route ignores public protocol" {
    const t = std.testing;
    for ([_]providers.Id{ .deepseek, .openai_codex }) |id| {
        var cache: Cache = .{};
        const row = try cache.directory.upsert(id, "route-test");
        const protocol: Protocol = if (id == .deepseek) .chat else .responses;
        const format: thinking.Format = if (id == .deepseek) .deepseek else .standard;
        const official = try directory.Profile.from(.{ .format = format, .map = .{ .off = if (id == .deepseek) "off" else "none", .high = "high" } });
        row.reasoning = official;
        row.dev_protocol = .anthropic;
        row.dev_reasoning = try directory.Profile.from(.{ .format = .anthropic, .map = .{ .off = "disabled", .low = "low" } });
        var config: cfg.Config = .{ .provider = catalog.connection(id), .model = .{ .name = "route-test", .protocol = protocol, .context_tokens = 65536 } };
        var selected = declarationForConfig(&cache, config).?;
        try t.expectEqual(format, selected.format);
        try t.expectEqualStrings("high", selected.map.high.?);
        try t.expect(selected.map.low == null);
        row.dev_protocol = .auto;
        row.dev_reasoning = null;
        selected = declarationForConfig(&cache, config).?;
        try t.expectEqual(format, selected.format);
        try t.expectEqualStrings("high", selected.map.high.?);
        row.dev_protocol = .chat;
        row.dev_reasoning = try directory.Profile.from(.{ .format = if (id == .deepseek) .deepseek else .standard, .map = .{ .off = if (id == .deepseek) "off" else "none", .low = "low" } });
        row.reasoning = null;
        try t.expect(declarationForConfig(&cache, config) == null);
        row.reasoning = official;
        selected = declarationForConfig(&cache, config).?;
        try t.expectEqual(format, selected.format);
        try t.expectEqualStrings("high", selected.map.high.?);
        config.model.protocol = if (id == .deepseek) .responses else .chat;
        try t.expect(declarationForConfig(&cache, config) == null);
    }
}
test "provider reasoning source ignores stale public cache and public refresh for DeepSeek" {
    const t = std.testing;
    const cache = try parseCache(t.allocator,
        \\{"version":16,"models":[{"provider":"deepseek","id":"refresh-test","protocol":"chat","dev_protocol":"chat","dev_present":true,"dev_reasoning":{"format":"deepseek","map":{"off":"off","low":"low"}}}]}
    );
    var listing: Listing = .{ .directory = cache.directory };
    const entry = restoreEntry(&cache, .deepseek, "refresh-test").?;
    try t.expect(entryDeclaration(&cache, entry) == null);
    const row = &listing.directory.rows[listing.directory.find(.deepseek, "refresh-test").?];
    row.reasoning = try directory.Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .high = "high" } });
    var public: Listing = .{ .dev_done = true };
    const fresh = try public.directory.upsert(.deepseek, "refresh-test");
    fresh.dev_present = true;
    fresh.dev_protocol = .chat;
    fresh.dev_reasoning = try directory.Profile.from(.{ .format = .deepseek, .map = .{ .off = "off", .max = "max" } });
    try mergeDev(&listing, &public);
    const refreshed: Cache = .{ .directory = listing.directory };
    const declaration = entryDeclaration(&refreshed, entry).?;
    try t.expectEqualStrings("high", declaration.map.high.?);
    try t.expect(declaration.map.low == null and declaration.map.max == null);
}
