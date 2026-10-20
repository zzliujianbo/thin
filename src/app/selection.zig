//! Bounded nonsecret selection metadata embedded in the `.session` checkpoint.
//! Diagnostic JSONL may record the same view; there is no `.selection.json` sidecar.
const std = @import("std");
const cfg = @import("../core/config.zig");
const p = @import("../core/protocol.zig");
const fs = @import("../platform/filesystem.zig");
const activity = @import("../presentation/activity.zig");

pub const max_bytes = 4096;
const model_limit = 512;
const Hash = std.crypto.hash.sha2.Sha256;

/// Fixed-size owned data: safe to publish/enqueue with no allocation or borrows.
pub const Snapshot = struct {
    model_buffer: [model_limit]u8 = @splat(0),
    model_len: u16 = 0,
    provider_name_buffer: [model_limit]u8 = @splat(0),
    provider_name_len: u16 = 0,

    endpoint: [64]u8,
    provider: ?cfg.providers.Id,
    protocol: p.Protocol,
    effort: ?activity.ReasoningEffort,
    /// Unknown fixed wire options can be restored only from identical current
    /// local options; their raw strings are never stored here.
    effort_hash: ?[64]u8 = null,

    pub fn providerName(self: *const Snapshot) ?[]const u8 {
        return if (self.provider_name_len == 0) null else self.provider_name_buffer[0..self.provider_name_len];
    }

    pub fn model(self: *const Snapshot) []const u8 {
        return self.model_buffer[0..self.model_len];
    }

    pub const View = struct {
        model: []const u8,
        provider_name: ?[]const u8,
        endpoint: []const u8,
        provider: ?cfg.providers.Id,
        protocol: p.Protocol,
        effort: ?activity.ReasoningEffort,
        effort_hash: ?[]const u8,
    };

    pub fn view(self: *const Snapshot) View {
        return .{ .model = self.model(), .provider_name = self.providerName(), .endpoint = &self.endpoint, .provider = self.provider, .protocol = self.protocol, .effort = self.effort, .effort_hash = if (self.effort_hash) |*hash| hash else null };
    }
};

pub fn endpoint(url: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    Hash.hash(url, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

fn setModel(snapshot: *Snapshot, name: []const u8) !void {
    if (name.len == 0 or name.len > model_limit) return error.InvalidSelectionModel;
    try fs.validateText(name);
    for (name) |byte| if (byte < 32 or byte == 127) return error.InvalidSelectionModel;
    @memcpy(snapshot.model_buffer[0..name.len], name);
    snapshot.model_len = @intCast(name.len);
}

fn setProviderName(snapshot: *Snapshot, name: []const u8) !void {
    if (name.len == 0 or name.len > 64) return error.InvalidSelection;
    for (name) |byte| if (byte <= 0x20 or byte >= 0x7f or byte == '/' or byte == '\\') return error.InvalidSelection;
    @memcpy(snapshot.provider_name_buffer[0..name.len], name);
    snapshot.provider_name_len = @intCast(name.len);
}

fn knownEffort(effort: activity.ReasoningEffort) bool {
    return switch (effort) {
        .off, .minimal, .low, .medium, .high, .xhigh, .max => true,
        else => false,
    };
}

pub fn capture(config: cfg.Config) !Snapshot {
    const effort = activity.ReasoningEffort.fromName(config.model.reasoning_effort);
    var snapshot: Snapshot = .{
        .endpoint = endpoint(config.provider.base_url),
        .provider = config.provider.kind orelse cfg.providers.Id.fromUrl(config.provider.base_url),
        .protocol = config.model.protocol,
        .effort = if (knownEffort(effort)) effort else null,
        .effort_hash = if (!knownEffort(effort) and config.model.reasoning_effort != null) endpoint(config.model.reasoning_effort.?) else null,
    };
    try setModel(&snapshot, config.model.name);
    if (config.registry != null) if (config.selected_provider) |name| try setProviderName(&snapshot, name);
    return snapshot;
}

pub fn encode(writer: *std.Io.Writer, snapshot: *const Snapshot) !void {
    try std.json.Stringify.value(.{
        .version = 2,
        .provider = snapshot.provider,
        .provider_name = snapshot.providerName(),
        .endpoint = @as([]const u8, &snapshot.endpoint),
        .model = snapshot.model(),
        .protocol = snapshot.protocol,
        .effort = snapshot.effort,
        .effort_hash = snapshot.view().effort_hash,
    }, .{}, writer);
}

fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidSelection;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Snapshot {
    if (bytes.len > max_bytes) return error.SelectionTooLarge;
    try fs.validateText(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSelection;
    const object = parsed.value.object;
    if (object.count() != 8) return error.InvalidSelection;
    const version = object.get("version") orelse return error.InvalidSelection;
    if (version != .integer or version.integer != 2) return error.InvalidSelectionVersion;
    const fingerprint = try string(object.get("endpoint") orelse return error.InvalidSelection);
    if (fingerprint.len != 64) return error.InvalidSelection;
    for (fingerprint) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidSelection;
    const service = object.get("provider") orelse return error.InvalidSelection;
    const effort = object.get("effort") orelse return error.InvalidSelection;
    const effort_hash = object.get("effort_hash") orelse return error.InvalidSelection;
    const protocol = try string(object.get("protocol") orelse return error.InvalidSelection);
    var snapshot: Snapshot = .{
        .endpoint = undefined,
        .provider = if (service == .null) null else std.meta.stringToEnum(cfg.providers.Id, try string(service)) orelse return error.InvalidSelection,
        .protocol = std.meta.stringToEnum(p.Protocol, protocol) orelse return error.InvalidSelection,
        .effort = if (effort == .null) null else std.meta.stringToEnum(activity.ReasoningEffort, try string(effort)) orelse return error.InvalidSelection,
    };
    if (snapshot.effort) |level| if (!knownEffort(level)) return error.InvalidSelection;
    if (effort_hash != .null) {
        if (snapshot.effort != null) return error.InvalidSelection;
        const hash = try string(effort_hash);
        if (hash.len != 64) return error.InvalidSelection;
        for (hash) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return error.InvalidSelection;
        snapshot.effort_hash = hash[0..64].*;
    }
    const name = object.get("provider_name") orelse return error.InvalidSelection;
    if (name != .null) try setProviderName(&snapshot, try string(name));
    @memcpy(&snapshot.endpoint, fingerprint);
    try setModel(&snapshot, try string(object.get("model") orelse return error.InvalidSelection));
    return snapshot;
}

fn fixtureSnapshot() !Snapshot {
    return capture(.{ .provider = .{ .base_url = "https://opencode.ai/zen/go/v1" }, .model = .{ .name = "gpt-5.6-luna", .protocol = .responses, .context_tokens = 1050000, .reasoning_effort = "high" } });
}

test "selection v2 strict schema owns metadata and requires all eight fields" {
    const a = std.testing.allocator;
    var snapshot = try fixtureSnapshot();
    var buffer: [max_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encode(&writer, &snapshot);
    const restored = try parse(a, writer.buffered());
    try std.testing.expectEqualStrings(snapshot.model(), restored.model());
    try std.testing.expectEqual(cfg.providers.Id.opencode_go, restored.provider.?);
    try std.testing.expectEqual(activity.ReasoningEffort.high, restored.effort.?);
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "https://") == null);
    const missing = try std.mem.replaceOwned(u8, a, writer.buffered(), "\"provider_name\":null,", "");
    defer a.free(missing);
    try std.testing.expectError(error.InvalidSelection, parse(a, missing));
    for ([_][]const u8{ "{}", "[]", "{\"version\":2,\"version\":2}", "\xff" }) |invalid| {
        if (parse(a, invalid)) |_| return error.AcceptedInvalidSelection else |_| {}
    }
    const tail = writer.buffered()["{\"version\":2".len..];
    for ([_][]const u8{ "{\"version\":1", "{\"version\":\"2\"", "{\"version\":2.0", "{\"extra\":0,\"version\":2" }) |prefix| {
        const invalid = try std.mem.concat(a, u8, &.{ prefix, tail });
        defer a.free(invalid);
        if (parse(a, invalid)) |_| return error.AcceptedInvalidSelection else |_| {}
    }
    @memset(&buffer, 'x');
    try std.testing.expectEqualStrings("gpt-5.6-luna", restored.model());
}
