//! Generic Decision selection: owned local fixtures, no inference or metadata fetch.
const std = @import("std");
const cfg = @import("../core/config.zig");
const Session = @import("session.zig").Session;
const Store = @import("auth_store.zig").Store;
const profiles = @import("decision_selection.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const fixture =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main-only","models":{"first":{"protocol":"chat","context_tokens":65536},"second":{"protocol":"chat","context_tokens":131072},"tiny":{"protocol":"chat","context_tokens":2048},"judge/raw":{"protocol":"chat","context_tokens":32768},"auto":{"protocol":"auto","context_tokens":32768}}},"other":{"base_url":"https://other.invalid/v1","api_key_env":"OWN_REVIEW_KEY","models":{"family/judge":{"protocol":"chat","context_tokens":16384}}},"native":{"base_url":"https://native-fixture.invalid/v1","api_key":"fake-native-only","models":{"judge/raw":{"protocol":"systemone"},"jev-1.13-free":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"safety_tokens":100}}
;
fn seed(home: []const u8, bytes: []const u8) !void {
    var store = try Store.open(a, io, home);
    defer store.deinit();
    try store.root.writeMode(cfg.file_name, bytes, false, 0o600);
}
fn disk(home: []const u8) ![]const u8 {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    return (try store.root.read(a, cfg.file_name, 0, cfg.max_config_bytes)).data;
}
fn choose(session: *Session, name: []const u8) !void {
    const connection = session.connection();
    try connection.decision_fn.?(connection.context, .{ .model = name });
}
fn prepareNativeForTest(client: *@import("decision_client.zig").Client) !void {
    var cancel: @import("../core/protocol.zig").Cancellation = .{};
    const output = try client.service().decide(a, .{ .refine_outputs = &.{} }, &cancel);
    defer @import("../core/decision.zig").freeOutput(a, output);
    try std.testing.expect(output == .refine_outputs and output.refine_outputs.len == 0);
    try std.testing.expect(client.native != null and client.resolved != null and client.calls == 0);
}
fn declarationsWithoutDecision(config: cfg.Config) ![]u8 {
    var value = config;
    value.decision = null;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try cfg.writeDisk(value, &out.writer);
    return a.dupe(u8, out.written());
}
fn contains(models: []const cfg.Model, name: []const u8) bool {
    for (models) |model| if (std.mem.eql(u8, model.name, name)) return true;
    return false;
}

const metadata = @import("model_metadata.zig");
const resolver = @import("model_resolver.zig");
const zen_fixture =
    \\{"llm":{"default":"route/first","providers":{"route":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main-only","models":{"first":{"protocol":"chat","context_tokens":65536}}},"zen":{"base_url":"https://opencode.ai/zen/v1","api_key_env":"ZEN_OWN_KEY","models":{}},"zen-unlogged":{"base_url":"https://opencode.ai/zen/v1","api_key_env":"ZEN_MISSING_KEY","models":{}},"go":{"base_url":"https://opencode.ai/zen/go/v1","api_key":"fake-go-only","models":{}},"lookalike":{"base_url":"https://opencode.ai.example/zen/v1","api_key":"fake-lookalike-only","models":{"jev-1.13-free":{"protocol":"chat","context_tokens":65536}}}}},"limits":{"safety_tokens":100}}
;
const zen_listing =
    \\{"object":"list","data":[{"id":"jev-1.13","object":"model","created":1,"owned_by":"opencode"},{"id":"jev-1.13-free","object":"model","created":1,"owned_by":"opencode"},{"id":"jev-1.13-free-lookalike"},{"id":"JEV-1.13"}]}
;

/// Exercise the actual bounded parser, generation claim and persisted cache,
/// not a guessed disk DTO or an in-memory candidate injected after startup.
fn publishListing(home: []const u8, provider: cfg.providers.Id, body: []const u8, now: u64) !void {
    var store = try Store.openExisting(a, io, home);
    defer store.deinit();
    const mask = metadata.bit(provider);
    const claim = try metadata.claimAt(&store.root, mask, true, now, .{});
    const listing = try metadata.parseListing(a, body, provider);
    const result = try metadata.commitClaimedAt(&store.root, mask, listing, claim.generations, now + 1);
    try std.testing.expectEqual(mask, result.accepted);
}

fn expectNativeCandidate(session: *Session, name: []const u8) !void {
    for (session.connection().current().decision_models) |model| {
        if (!std.mem.eql(u8, model.name, name)) continue;
        try std.testing.expectEqual(@import("../core/protocol.zig").Protocol.systemone, model.protocol);
        try std.testing.expectEqual(@as(u32, 0), model.context_tokens);
        try std.testing.expect(model.output_tokens == null and model.reasoning == null);
        try std.testing.expect(model.input_price_threshold == null and model.input_price_flat_limit == null);
        return;
    }
    return error.ExpectedNativeCandidate;
}
