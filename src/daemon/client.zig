//! Remote session client: the only implementation of `ui/session_client.zig`
//! `VTable`, connected to a real per-user Unix RPC worker (see `protocol.zig`).
//!
//! Ownership rules enforced here:
//! - The UI never dereferences a Runtime. `tui.Connection.State.runtime` stays
//!   null; `available` says whether a worker session is attached and usable.
//! - The worker owns tasks, the queue, approvals and checkpoints. This client
//!   only submits, acknowledges, renders and manages views.
//! - Every borrowed wire string is copied into a client-owned arena (snapshot /
//!   settings projection) or into an owned `session_client.Item` before the
//!   frame buffer is freed. No pointer, `rawcfg`, key or native replay crosses
//!   into the UI.
//! - A lost socket means "the view is gone", never "the task was canceled".
//!   Nothing here re-sends a billable submission on its own.
const std = @import("std");
const cli = @import("../app/cli.zig");
const core_config = @import("../core/config.zig");
const ids = @import("../app/session_id.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const preferences = @import("../core/settings.zig");
const shared = @import("../presentation.zig");
const bridge_module = @import("../ui/bridge.zig");
const decision_picker = @import("../ui/decision_picker.zig");
const picker_module = @import("../ui/model_picker.zig");
const session_client = @import("../ui/session_client.zig");
const tui = @import("../ui/tui.zig");
const resume_store = @import("../app/resume_store.zig");
const fs = @import("../platform/filesystem.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const spawn = @import("spawn.zig");
const unix = @import("unix.zig");
const StreamReceiver = @import("stream_receiver.zig").Receiver;
const remote_action = @import("../ui/remote_action.zig");
const codex_login = @import("../core/codex_login.zig");
const memory_status = @import("../core/memory_status.zig");

const Io = std.Io;
const Registry = registry.Registry;
const Workers = spawn.Workers;
/// Wire protocol id type used by `core/config.Model.protocol`.
const ProtocolKind = @TypeOf(@as(core_config.Model, undefined).protocol);

/// Compare owned public settings, excluding only the envelope id and the
/// independently published runtime observation. Depth exhaustion is changed.
fn publicSettingsEqual(left: std.json.Value, right: std.json.Value, depth: usize) bool {
    if (depth > 64 or std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |v| v == right.bool,
        .integer => |v| v == right.integer,
        .float => |v| v == right.float,
        .number_string => |v| std.mem.eql(u8, v, right.number_string),
        .string => |v| std.mem.eql(u8, v, right.string),
        .array => |v| blk: {
            const other = right.array.items;
            if (v.items.len != other.len) break :blk false;
            for (v.items, other) |item, matching| {
                if (!publicSettingsEqual(item, matching, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        .object => |v| blk: {
            const other = right.object;
            var count: usize = 0;
            var it = v.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (depth == 0 and (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "context"))) continue;
                count += 1;
                const matching = other.get(key) orelse break :blk false;
                if (!publicSettingsEqual(entry.value_ptr.*, matching, depth + 1)) break :blk false;
            }
            var other_count: usize = 0;
            var other_it = other.iterator();
            while (other_it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (depth == 0 and (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "context"))) continue;
                other_count += 1;
            }
            break :blk count == other_count;
        },
    };
}

/// Bounded wait budgets. All of them are finite: there is no infinite wait.
const join_timeout_ms: u32 = 5_000;
const quick_timeout_ms: u32 = 4_000;
const poll_timeout_ms: u32 = 250;
const finish_timeout_ms: u32 = 60_000;
/// One page of display events per fetch; the UI drains one item per tick.
const max_events: u16 = protocol.max_events;
const max_history: u16 = protocol.max_history;
/// Bounded local item queue: never buffer more than this between UI ticks.
const max_pending: usize = 96;
const max_listing_bytes: usize = 8 * 1024;
const control_socket = "daemon.sock";
/// A pending receipt whose owner state cannot be queried is never blindly
/// resubmitted; the user must attach the original session first.
const receipt_unknown_notice = "Receipt state unknown; not resubmitted. Attach the original session to verify it.";

/// Canonical digest of one logical submission (kind + exact text).
fn submissionDigest(kind: session_client.TaskKind, text: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&[_]u8{@backingInt(kind)});
    hasher.update(text);
    hasher.final(&digest);
    return digest;
}

/// Owner answer for one unconfirmed receipt (side-effect free).
const ReceiptQuery = union(enum) { accepted: u64, rejected, unknown };

/// Outcome of one candidate attach. Only `gone` proves there is no owner left;
/// `unknown` (timeout, permission, identity, protocol) must never authorize a
/// second writer for the same history.
const AttachStage = enum { attached, busy, unknown, gone, outdated };

/// Which stage a failed dial reached. Only a provably absent listener may
/// authorize a resume.
fn dialStage(err: anyerror) AttachStage {
    return switch (err) {
        error.FileNotFound, error.ConnectionRefused, error.NotDir => .gone,
        else => .unknown,
    };
}

// ---------------------------------------------------------------------------
// Wire errors -> the exact `anyerror` values `session_client.describe` knows.
// ---------------------------------------------------------------------------

fn wireError(code: protocol.ErrorCode) anyerror {
    return switch (code) {
        .bad_request, .protocol => error.ProtocolError,
        .stale_control => error.StaleControl,
        .busy => error.Busy,
        .unavailable => error.Unavailable,
        .not_found => error.SessionNotFound,
        .invalid_input => error.InvalidInput,
        .input_too_large => error.InputTooLarge,
        .queue_full => error.QueueFull,
        .queue_empty => error.QueueEmpty,
        .input_budget => error.InputBudgetExceeded,
        .unsupported => error.Unsupported,
        .canceled => error.Canceled,
        .permission_expired => error.PermissionExpired,
        .no_official_provider => error.NoOfficialProvider,
        .metadata_refresh_busy => error.MetadataRefreshBusy,
        .thinking_capabilities_loading => error.ThinkingCapabilitiesLoading,
        .thinking_capabilities_unknown => error.ThinkingCapabilitiesUnknown,
        .transport => error.Transport,
        .internal => error.RemoteFailure,
    };
}

/// Socket-level failures collapse into one transport class: the caller must
/// not distinguish them, and no local error value crosses the wire.
fn transport(_: anyerror) anyerror {
    return error.Transport;
}

// ---------------------------------------------------------------------------
// Bounded JSON
// ---------------------------------------------------------------------------

/// Reject over-deep frames before allocating a parse tree. String- and
/// escape-aware so braces inside text never count as nesting.
fn boundedDepth(bytes: []const u8) bool {
    const limit = protocol.max_json_depth + 8;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > limit) return false;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return depth == 0 and !in_string;
}

const Response = struct {
    doc: std.json.Parsed(std.json.Value),
    object: std.json.ObjectMap,
    a: std.mem.Allocator,

    fn deinit(self: *Response) void {
        self.doc.deinit();
        self.* = undefined;
    }

    fn field(self: *const Response, name: []const u8) ?std.json.Value {
        return self.object.get(name);
    }

    fn text(self: *const Response, name: []const u8) ?[]const u8 {
        return switch (self.field(name) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    fn uint(self: *const Response, name: []const u8) ?u64 {
        return valueU64(self.field(name) orelse return null);
    }

    fn flag(self: *const Response, name: []const u8, default: bool) bool {
        return switch (self.field(name) orelse return default) {
            .bool => |b| b,
            else => default,
        };
    }
};

fn valueU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .number_string => |s| blk: {
            // Preserve full-width integer tokens without float rounding or a
            // trapping 2^64 conversion. Strings/fractions are not wire integers.
            if (s.len == 0 or s.len > 20) break :blk null;
            for (s) |byte| if (byte < '0' or byte > '9') break :blk null;
            break :blk std.fmt.parseInt(u64, s, 10) catch null;
        },
        else => null,
    };
}

fn decodeSubagentView(a: std.mem.Allocator, value: std.json.Value) !@import("../core/subagent_status.zig").View {
    const obj = switch (value) {
        .object => |v| v,
        else => return error.ProtocolError,
    };
    if (obj.count() != 13 and obj.count() != 15) return error.ProtocolError;
    const read = struct {
        fn uint(map: std.json.ObjectMap, key: []const u8) !u64 {
            return valueU64(map.get(key) orelse return error.ProtocolError) orelse error.ProtocolError;
        }
    };
    var view: @import("../core/subagent_status.zig").View = .{
        .group_id = try read.uint(obj, "group_id"),
        .revision = try read.uint(obj, "revision"),
        .total = try read.uint(obj, "total"),
        .running = try read.uint(obj, "running"),
        .waiting = try read.uint(obj, "waiting"),
        .completed = try read.uint(obj, "completed"),
        .failed = try read.uint(obj, "failed"),
        .canceled = try read.uint(obj, "canceled"),
        .paused = try read.uint(obj, "paused"),
        .elapsed_ms = try read.uint(obj, "elapsed_ms"),
        .latest_id = try read.uint(obj, "latest_id"),
    };
    const text = switch (obj.get("text") orelse return error.ProtocolError) {
        .string => |s| s,
        else => return error.ProtocolError,
    };
    if (text.len > view.text_buf.len or !std.unicode.utf8ValidateSlice(text)) return error.ProtocolError;
    for (text, 0..) |b, i| {
        if (b < 0x20 or b == 0x7f or (b == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f)) return error.ProtocolError;
    }
    var total: u64 = 0;
    for ([_]u64{ view.running, view.waiting, view.completed, view.failed, view.canceled, view.paused }) |n| {
        total = std.math.add(u64, total, n) catch return error.ProtocolError;
    }
    if (total != view.total or (view.group_id == 0 and (total != 0 or view.revision != 0 or view.latest_id != 0 or view.elapsed_ms != 0 or text.len != 0)) or (view.group_id != 0 and (total == 0 or view.latest_id == 0))) return error.ProtocolError;
    view.text_len = @intCast(text.len);
    @memcpy(view.text_buf[0..text.len], text);
    {
        const value_agents = obj.get("agents") orelse return error.ProtocolError;
        const items = switch (value_agents) {
            .array => |array| array.items,
            else => return error.ProtocolError,
        };
        const Agent = @import("../core/subagent_status.zig").AgentView;
        if (obj.count() == 15) {
            const offset = try read.uint(obj, "page_offset");
            const page_total = try read.uint(obj, "page_total");
            const end = std.math.add(u64, offset, items.len) catch return error.ProtocolError;
            if (items.len > 64 or page_total != view.total or offset > page_total or end > page_total or (end < page_total and items.len != 64) or (offset % 64 != 0)) return error.ProtocolError;
            view.page_offset = offset;
            view.page_total = page_total;
        } else if (obj.count() != 13 or items.len != view.total) return error.ProtocolError;
        const rows: []Agent = if (items.len == 0) &.{} else try a.alloc(Agent, items.len);
        errdefer if (rows.len != 0) a.free(rows);
        var counts: [6]u64 = @splat(0);
        for (items, 0..) |item, i| {
            const row = switch (item) {
                .object => |map| map,
                else => return error.ProtocolError,
            };
            if (row.count() != 5) return error.ProtocolError;
            const id = try read.uint(row, "id");
            if (id == 0) return error.ProtocolError;
            for (rows[0..i]) |previous| if (previous.id == id) return error.ProtocolError;
            const phase = switch (row.get("phase") orelse return error.ProtocolError) {
                .string => |s| std.meta.stringToEnum(@import("../core/subagent_status.zig").Phase, s) orelse return error.ProtocolError,
                else => return error.ProtocolError,
            };
            const row_text = switch (row.get("text") orelse return error.ProtocolError) {
                .string => |s| s,
                else => return error.ProtocolError,
            };
            if (row_text.len > 2048 or !std.unicode.utf8ValidateSlice(row_text)) return error.ProtocolError;
            for (row_text, 0..) |b, j| if (b < 0x20 or b == 0x7f or (b == 0xc2 and j + 1 < row_text.len and row_text[j + 1] >= 0x80 and row_text[j + 1] <= 0x9f)) return error.ProtocolError;
            const category: usize = switch (phase) {
                .starting, .running => 0,
                .waiting => 1,
                .completed => 2,
                .failed => 3,
                .canceled => 4,
                .paused => 5,
            };
            counts[category] += 1;
            rows[i] = .{ .id = id, .revision = try read.uint(row, "revision"), .phase = phase, .elapsed_ms = try read.uint(row, "elapsed_ms"), .text_len = @intCast(row_text.len) };
            @memcpy(rows[i].text_buf[0..row_text.len], row_text);
        }
        const expected = [_]u64{ view.running, view.waiting, view.completed, view.failed, view.canceled, view.paused };
        if (view.page_offset == null) {
            if (!std.mem.eql(u64, &counts, &expected)) return error.ProtocolError;
        } else {
            for (counts, expected) |count, max| if (count > max) return error.ProtocolError;
        }
        view.agents = rows;
    }
    return view;
}

fn decodeBackgroundView(value: std.json.Value) !@import("../core/background_status.zig").View {
    const obj = switch (value) {
        .object => |v| v,
        else => return error.ProtocolError,
    };
    if (obj.count() != 1) return error.ProtocolError;
    const count = valueU64(obj.get("active_count") orelse return error.ProtocolError) orelse return error.ProtocolError;
    return .{ .active_count = std.math.cast(usize, count) orelse return error.ProtocolError };
}

fn decodeMemoryView(value: std.json.Value) !memory_status.View {
    const obj = switch (value) {
        .object => |v| v,
        else => return error.ProtocolError,
    };
    if (obj.count() != 5) return error.ProtocolError;
    var result: memory_status.View = .{
        .enabled = valueBool(obj.get("enabled") orelse return error.ProtocolError) orelse return error.ProtocolError,
        .revision = valueU64(obj.get("revision") orelse return error.ProtocolError) orelse return error.ProtocolError,
        .queued_count = valueU64(obj.get("queued_count") orelse return error.ProtocolError) orelse return error.ProtocolError,
    };
    result.active = switch (obj.get("active") orelse return error.ProtocolError) {
        .null => null,
        .object => |active| blk: {
            if (active.count() != 2) return error.ProtocolError;
            const phase = switch (active.get("phase") orelse return error.ProtocolError) {
                .string => |s| std.meta.stringToEnum(memory_status.Phase, s) orelse return error.ProtocolError,
                else => return error.ProtocolError,
            };
            break :blk .{ .id = valueU64(active.get("id") orelse return error.ProtocolError) orelse return error.ProtocolError, .phase = phase };
        },
        else => return error.ProtocolError,
    };
    result.last_terminal = switch (obj.get("last_terminal") orelse return error.ProtocolError) {
        .null => null,
        .object => |terminal| blk: {
            if (terminal.count() != 5) return error.ProtocolError;
            const outcome = switch (terminal.get("result") orelse return error.ProtocolError) {
                .string => |s| std.meta.stringToEnum(memory_status.Result, s) orelse return error.ProtocolError,
                else => return error.ProtocolError,
            };
            const failure: ?memory_status.Failure = switch (terminal.get("failure") orelse return error.ProtocolError) {
                .null => null,
                .string => |s| std.meta.stringToEnum(memory_status.Failure, s) orelse return error.ProtocolError,
                else => return error.ProtocolError,
            };
            const saved_count = std.math.cast(u32, valueU64(terminal.get("saved_count") orelse return error.ProtocolError) orelse return error.ProtocolError) orelse return error.ProtocolError;
            var summary: memory_status.Summary = .{};
            const text = switch (terminal.get("summary") orelse return error.ProtocolError) {
                .string => |s| s,
                else => return error.ProtocolError,
            };
            if (text.len > summary.buf.len or !std.unicode.utf8ValidateSlice(text)) return error.ProtocolError;
            summary.append(text);
            if (!std.mem.eql(u8, summary.text(), text)) return error.ProtocolError;
            break :blk .{ .id = valueU64(terminal.get("id") orelse return error.ProtocolError) orelse return error.ProtocolError, .result = outcome, .failure = failure, .saved_count = saved_count, .summary = summary };
        },
        else => return error.ProtocolError,
    };
    return result;
}

fn valueBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn parseObject(a: std.mem.Allocator, bytes: []const u8) !Response {
    if (bytes.len == 0 or bytes.len > protocol.max_response) return error.ProtocolError;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.ProtocolError;
    if (!boundedDepth(bytes)) return error.ProtocolError;
    const doc = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProtocolError,
    };
    errdefer doc.deinit();
    const object = switch (doc.value) {
        .object => |value| value,
        else => return error.ProtocolError,
    };
    if (object.count() > 64) return error.ProtocolError;
    return .{ .doc = doc, .object = object, .a = a };
}

/// One request being built. `finish` on error keeps the builder consistent.
const Request = struct {
    owner: *Client,
    out: protocol.Out,
    id: u64,
    /// Which socket `exchange` must use. Built by `request` (worker) or
    /// `controlRequest` (daemon control); never inferred from the payload.
    target: Target = .worker,

    const Target = enum { worker, control };

    fn put(self: *Request, name: []const u8, value: anytype) !void {
        try self.out.field(name, value);
    }

    fn deinit(self: *Request) void {
        // Includes partial login encoding when building or sending fails.
        std.crypto.secureZero(u8, self.out.buf.items);
        self.out.deinit();
    }

    fn exchange(self: *Request, timeout_ms: u32) !Response {
        const client = self.owner;
        // Control frames are finished by `controlExchange` exactly once; the
        // worker path finishes here. Never call `finish` twice on one request.
        if (self.target == .control) return client.controlExchange(self, timeout_ms);
        const bytes = try self.out.finish();
        defer {
            std.crypto.secureZero(u8, bytes);
            client.a.free(bytes);
        }
        const conn = if (client.conn) |*value| value else return error.Unavailable;
        conn.writeFrame(bytes, client.waitFor(timeout_ms)) catch |err| {
            client.loseView();
            return transport(err);
        };
        return client.readResponse(self.id, timeout_ms);
    }
};

// ---------------------------------------------------------------------------
// Cached owner projections (no allocations except the settings document)
// ---------------------------------------------------------------------------

const max_preview_bytes = 96;
const max_label_bytes = 64;

const SnapshotCache = struct {
    background: @import("../core/background_status.zig").View = .{},
    memory: memory_status.View = .{},
    subagents: @import("../core/subagent_status.zig").View = .{},
    subagents_supported: bool = false,
    valid: bool = false,
    codex_login: codex_login.View = .{},
    busy: bool = false,
    phase: ?r.State = null,
    task: u64 = 0,
    kind: session_client.TaskKind = .prompt,
    epoch: u64 = 0,
    /// The owner published an `epoch` field. Only an explicit value may revoke
    /// control; an absent field is "unknown", not "no controller".
    epoch_known: bool = false,
    revision: u64 = 0,
    paused: bool = false,
    steering: u32 = 0,
    follow_up: u32 = 0,
    newest_id: ?u64 = null,
    newest_bytes: u64 = 0,
    context: ?r.ContextSnapshot = null,
    label_len: u8 = 0,
    label: [max_label_bytes]u8 = undefined,
    preview_count: u8 = 0,
    previews: [session_client.max_previews]Preview = @splat(.{}),

    const Preview = struct {
        id: u64 = 0,
        kind: session_client.QueueKind = .steering,
        len: u8 = 0,
        text: [max_preview_bytes]u8 = undefined,
    };
};

/// Public, nonsecret settings projection. Scalars are copied; string and model
/// slices point into `doc`, which stays alive until the next settings reply.
const Pub = struct {
    doc: ?std.json.Parsed(std.json.Value) = null,
    /// Owner-declared readiness: a local Runtime exists or a remote setup/session
    /// is usable. Only an explicit `true` from the owner sets this; missing or
    /// malformed fields stay false (never inferred from a model string).
    available: bool = false,
    model: []const u8 = "",
    selection: []const u8 = "",
    base_url: []const u8 = "",
    provider: ?core_config.providers.Id = null,
    effort: shared.ReasoningEffort = .unspecified,
    effort_levels: shared.activity.EffortSet = .{},
    configured: u8 = 0,
    read_only: bool = false,
    low_price_enabled: bool = true,
    low_price_active: bool = false,
    memory_auto: bool = true,
    decision_enabled: bool = false,
    image_enabled: bool = false,
    decision_model: ?[]const u8 = null,
    image_model: ?[]const u8 = null,
    /// Public proxy state: whether the owner has a proxy allowlist, the exact
    /// bounded model ids on it, and the one non-secret host/port pair. Never a
    /// scheme, credential, header or path. The address borrows `doc`.
    proxy_configured: bool = false,
    proxy_address: ?[]const u8 = null,
    proxy_port: u16 = 0,
    proxy_models: []const []const u8 = &.{},
    context_limit: u32 = 0,
    allow_custom: bool = true,
    pending_effort: ?shared.ReasoningEffort = null,
    notice: ?[]const u8 = null,
    metadata_notice: ?[]const u8 = null,
    limits: core_config.Limits = .{},
    models: []core_config.Model = &.{},
    providers: []picker_module.Provider = &.{},
    context_official: []bool = &.{},
    disabled: []bool = &.{},
    decision_models: []core_config.Model = &.{},
    image_models: []core_config.Model = &.{},
};

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

pub const Client = struct {
    a: std.mem.Allocator,
    io: std.Io,
    uid: u32,
    environ: ?*const std.process.Environ.Map,
    mode: cli.Mode,

    /// Launcher root (HOME) and the current launcher directory. `/cd` changes
    /// only the latter; the next explicit submission creates a session there.
    root: []u8,
    launcher: []u8,

    /// Worker session connection, or null while launcher-only/detached.
    conn: ?unix.Connection = null,
    /// The receive task owns a distinct read-only subscription fd. UI-side
    /// projection only consumes complete locally queued frames.
    stream: ?*StreamReceiver = null,
    stream_snapshot: ?[]u8 = null,
    resume_snapshot_pending: bool = false,
    stream_retry_after: i64 = 0,
    stream_expected: bool = false,
    cache_floor: u64 = 0,
    control: ?unix.Connection = null,
    session: ?ids.Id = null,
    /// Canonical project reported by the verified owner of the current view.
    view_project: ?[]u8 = null,
    epoch: u64 = 0,
    next_req: u64 = 0,
    /// Set only while a communication owner task has exclusive access.
    wait_cancel: ?*const p.Cancellation = null,
    wait_progress_context: ?*anyopaque = null,
    wait_progress_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    in_wait_progress: bool = false,
    stream_recovery_pending: bool = false,
    publication_revision: u64 = 0,
    configuration_revision: u64 = 0,
    stream_publication_revision: u64 = 0,

    /// One submission that may or may not have been accepted. Kept across a
    /// transport failure so an explicit re-submit reuses the same receipt.
    receipt: ?Receipt = null,
    /// Suppress the owner echo of the prompt this UI already rendered.
    suppress: ?struct { digest: [32]u8, armed: bool } = null,

    reg: ?Registry = null,
    workers: ?Workers = null,
    dir: ?unix.Directory = null,
    auto_refresh: bool = true,
    /// Candidate admission waits for the initial snapshot/baseline pages.
    /// Focused tests shorten this to prove timeout handling without 5s waits.
    candidate_timeout_ms: u32 = join_timeout_ms,

    /// Display cursors for the ordered snapshot+delta stream.
    cursor: u64 = 0,
    need_history: bool = false,
    dirty: bool = true,
    initial_settings_loading: bool = false,
    poll_error: ?anyerror = null,

    /// Published projections with a stable address for the VTable.
    snap: session_client.Snapshot = .{},
    state: tui.Connection.State = baseState(),
    /// Ping-pong arenas: the published projection stays valid until the next
    /// rebuild, so the UI never reads freed wire memory.
    arenas: [2]std.heap.ArenaAllocator = undefined,
    arena_index: u1 = 0,

    cache: SnapshotCache = .{},
    row_cursor: u64 = 0,
    row_group: u64 = 0,
    pubcfg: Pub = .{},
    pending: std.ArrayList(session_client.Item) = .empty,
    /// Locators this launcher really published for workers it owns. Kept so a
    /// later owner_instance/generation for the same id is never overwritten.
    published: std.ArrayList(Published) = .empty,

    const Published = struct { id: ids.Id, project: []u8, endpoint: []u8 };

    const Receipt = struct {
        /// Cryptographically random, non-zero. The owner dedups submissions by
        /// this value alone, so it must never be derived from a per-frontend
        /// counter: two fresh frontends would otherwise mint the same receipt.
        req: u64,
        kind: session_client.TaskKind,
        digest: [32]u8,
        /// Session identity this receipt belongs to. A retry may only reuse the
        /// nonce inside the same session; a different session mints a new one.
        session: ?ids.Id,
    };

    fn baseState() tui.Connection.State {
        return .{ .runtime = null, .model = "", .base_url = "" };
    }

    pub fn init(
        a: std.mem.Allocator,
        io: std.Io,
        environ: ?*const std.process.Environ.Map,
        mode: cli.Mode,
        launcher: []const u8,
        root: []const u8,
    ) !*Client {
        const self = try a.create(Client);
        errdefer a.destroy(self);
        const owned_root = try a.dupe(u8, root);
        errdefer a.free(owned_root);
        const owned_launcher = try a.dupe(u8, launcher);
        self.* = .{
            .a = a,
            .io = io,
            .uid = @intCast(std.c.getuid()),
            .environ = environ,
            .mode = mode,
            .root = owned_root,
            .launcher = owned_launcher,
        };
        self.arenas[0] = std.heap.ArenaAllocator.init(a);
        self.arenas[1] = std.heap.ArenaAllocator.init(a);
        self.rebuild();
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.closeStream();
        self.closeControl();
        self.clearPending();
        if (self.conn) |*conn| conn.close();
        self.conn = null;
        self.epoch = 0;
        if (self.reg) |*reg| reg.deinit();
        self.reg = null;
        if (self.workers) |*workers| {
            workers.deinit();
            self.workers = null;
        }
        if (self.dir) |*dir| dir.deinit();
        self.dir = null;
        self.freePub();
        self.cache.subagents.deinitOwned(self.a);
        self.arenas[0].deinit();
        self.arenas[1].deinit();
        self.pending.deinit(self.a);
        for (self.published.items) |entry| {
            self.a.free(entry.project);
            self.a.free(entry.endpoint);
        }
        self.published.deinit(self.a);
        self.a.free(self.root);
        self.a.free(self.launcher);
        if (self.view_project) |project| self.a.free(project);
        const a = self.a;
        a.destroy(self);
    }

    /// VTable handle for `tui.Connection.session_client`.
    pub fn vtable(self: *Client) session_client.Client {
        return .{ .context = self, .vtable = &table };
    }

    pub fn connection(self: *Client) tui.Connection {
        return .{
            .context = self,
            .current_fn = currentFn,
            .configure_fn = configureFn,
            .configure_provider_fn = configureProviderFn,
            .codex_login_fn = codexLoginFn,
            .select_model_fn = selectModelFn,
            .set_effort_fn = setEffortFn,
            .cycle_effort_fn = cycleEffortFn,
            .preference_fn = preferenceFn,
            .setting_fn = settingFn,
            .decision_fn = decisionFn,
            .image_fn = imageFn,
            .proxy_fn = proxyFn,
            .proxy_address_fn = proxyAddressFn,
            .refresh_models_fn = refreshModelsFn,
            .poll_models_fn = pollModelsFn,
            .session_client = self.vtable(),
        };
    }

    // -- transport ---------------------------------------------------------

    fn waitFor(self: *Client, timeout_ms: u32) unix.Wait {
        return .{ .io = self.io, .timeout_ms = timeout_ms, .cancel = self.wait_cancel, .progress_context = self, .progress_fn = progressWait };
    }

    fn progressWait(raw: ?*anyopaque) !void {
        const self: *Client = @ptrCast(@alignCast(raw orelse return));
        if (self.in_wait_progress) return;
        const progress = self.wait_progress_fn orelse return;
        self.in_wait_progress = true;
        defer self.in_wait_progress = false;
        try progress(self.wait_progress_context);
    }

    fn allocRequestId(self: *Client) u64 {
        self.next_req +%= 1;
        if (self.next_req == 0) self.next_req = 1;
        return self.next_req;
    }

    /// A fresh logical submission gets an unpredictable receipt nonce. The RPC
    /// envelope id stays sequential; only this dedup token is random. Kernel
    /// randomness, never wall-clock or pid, so two frontends cannot collide.
    fn allocReceiptId(self: *Client) !u64 {
        while (true) {
            var bytes: [8]u8 = undefined;
            try self.io.randomSecure(&bytes);
            const value = std.mem.readInt(u64, &bytes, .little);
            // The owner reserves 0 as "no receipt".
            if (value != 0) return value;
        }
    }

    /// Only an unconfirmed receipt from the same session with the same kind and
    /// digest may supply the nonce for an explicit retry.
    fn reusableReceipt(receipt: ?Receipt, session: ?ids.Id, kind: session_client.TaskKind, digest: *const [32]u8) ?Receipt {
        const known = receipt orelse return null;
        const bound = known.session orelse return null;
        const current = session orelse return null;
        if (known.kind != kind) return null;
        if (!std.mem.eql(u8, &known.digest, digest)) return null;
        if (!std.mem.eql(u8, &bound, &current)) return null;
        return known;
    }

    /// Build one request in `Out`'s implicit root layout: the authority opens the
    /// object and `finish()` closes it, so `beginObjectRaw` must not be used here
    /// (it would leave the builder one level deep and `finish` rejects it).
    fn request(self: *Client, op: protocol.Op) !Request {
        var out = protocol.Out.init(self.a);
        errdefer out.deinit();
        const id = self.allocRequestId();
        try out.buf.append(self.a, '{');
        try out.field("v", protocol.version);
        try out.field("id", id);
        try out.field("op", @tagName(op));
        return .{ .owner = self, .out = out, .id = id };
    }

    /// Structural envelope verdict. Kept separate from the view so a candidate
    /// connection can be validated without touching the session on screen.
    const Verdict = union(enum) { ok, rejected: protocol.ErrorCode };

    fn validateEnvelope(resp: *Response, expected: u64) !Verdict {
        const version = resp.uint("v") orelse return error.ProtocolError;
        if (version != protocol.version) return error.ProtocolError;
        const id = resp.uint("id") orelse return error.ProtocolError;
        if (id != expected) return error.ProtocolError;
        const ok = switch (resp.field("ok") orelse return error.ProtocolError) {
            .bool => |flag| flag,
            else => return error.ProtocolError,
        };
        if (ok) return .ok;
        return .{ .rejected = protocol.codeFromName(resp.text("err") orelse "internal") };
    }

    /// Validate version/id/ok on every reply. A mismatched envelope means the
    /// byte stream is no longer trustworthy, so the view is dropped.
    fn checkEnvelope(self: *Client, resp: *Response, expected: u64) !void {
        const verdict = validateEnvelope(resp, expected) catch |err| {
            self.loseView();
            return err;
        };
        return switch (verdict) {
            .ok => {},
            .rejected => |code| wireError(code),
        };
    }

    /// Read exactly one reply. Timeouts retry within the caller's budget because
    /// `unix.Connection` keeps a partial frame; anything else loses the view.
    fn readResponse(self: *Client, expected: u64, timeout_ms: u32) !Response {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const conn = if (self.conn) |*value| value else return error.Unavailable;
            const frame = conn.readFrame(self.waitFor(timeout_ms)) catch |err| switch (err) {
                error.Timeout => {
                    if (attempt < 3) continue;
                    self.loseView();
                    return error.Transport;
                },
                else => {
                    self.loseView();
                    return transport(err);
                },
            };
            const payload = frame orelse {
                self.loseView();
                return error.Transport;
            };
            defer self.a.free(payload);
            var resp = parseObject(self.a, payload) catch |err| {
                self.loseView();
                return err;
            };
            errdefer resp.deinit();
            try self.checkEnvelope(&resp, expected);
            return resp;
        }
    }

    fn runtimeDirectory(self: *Client) !*unix.Directory {
        if (self.dir == null) self.dir = try unix.Directory.resolve(self.a, self.environ, self.uid);
        return &self.dir.?;
    }

    fn ensureRegistry(self: *Client) !*Registry {
        if (self.reg == null) self.reg = try Registry.init(self.a, self.io, self.environ orelse return error.Unavailable);
        return &self.reg.?;
    }

    fn ensureWorkers(self: *Client) !*Workers {
        if (self.workers == null) self.workers = try Workers.init(self.a, self.io, self.environ orelse return error.Unavailable);
        return &self.workers.?;
    }

    /// Drop the view without sending anything: the worker keeps running.
    fn loseView(self: *Client) void {
        self.closeStream();
        self.stream_expected = false;
        self.clearPending();
        if (self.conn) |*conn| conn.close();
        self.conn = null;
        if (self.view_project) |project| self.a.free(project);
        self.view_project = null;
        self.epoch = 0;
        self.cursor = 0;
        self.need_history = false;
        self.cache.valid = false;
        self.cache.subagents.deinitOwned(self.a);
        self.cache.subagents_supported = false;
        self.rebuild();
    }

    /// Control was taken over by another console: close only this view and fall
    /// back to the launcher. Owned foreground workers are untouched.
    fn revokeView(self: *Client) void {
        self.loseView();
        self.session = null;
        self.rebuild();
    }

    fn closeStream(self: *Client) void {
        self.stream_recovery_pending = false;
        if (self.stream) |stream| stream.deinit();
        self.stream = null;
        if (self.stream_snapshot) |bytes| self.a.free(bytes);
        self.stream_snapshot = null;
        self.resume_snapshot_pending = false;
    }

    fn closeControl(self: *Client) void {
        if (self.control) |*conn| conn.close();
        self.control = null;
    }

    fn clearPending(self: *Client) void {
        for (self.pending.items) |*item| item.deinit();
        self.pending.clearRetainingCapacity();
    }

    // -- published projection ---------------------------------------------

    fn rebuild(self: *Client) void {
        const slot = self.arena_index ^ 1;
        _ = self.arenas[slot].reset(.retain_capacity);
        const arena = self.arenas[slot].allocator();
        const snap = self.buildSnapshot(arena) catch return;
        const state = self.buildState(arena) catch return;
        self.snap = snap;
        self.state = state;
        self.arena_index = slot;
        self.publication_revision +%= 1;
    }

    fn buildSnapshot(self: *Client, arena: std.mem.Allocator) !session_client.Snapshot {
        const cache = &self.cache;
        var previews: []session_client.QueuePreview = &.{};
        if (cache.valid and cache.preview_count != 0) {
            const count = @min(@as(usize, cache.preview_count), session_client.max_previews);
            previews = try arena.alloc(session_client.QueuePreview, count);
            for (previews, 0..) |*entry, index| {
                const cached = cache.previews[index];
                entry.* = .{
                    .id = cached.id,
                    .kind = cached.kind,
                    .text = try arena.dupe(u8, cached.text[0..cached.len]),
                };
            }
        }
        return .{
            // Serving readiness is backend capability, not the current view: a
            // worker transport, or a launcher that can still get one. A revoked
            // foreground/attach view starts its own worker on the next explicit
            // submit; only --connect needs a live control socket for that.
            .available = !self.initial_settings_loading and !self.stream_recovery_pending and !(self.stream_expected and self.need_history) and (self.conn != null or switch (self.mode) {
                .foreground, .attach => true,
                .connect => self.control != null,
                else => false,
            }),
            // Attachment is still only a worker connection with a control epoch.
            .attached = self.conn != null and self.epoch != 0,
            .busy = (cache.valid and cache.busy) or (self.need_history and self.snap.busy),
            .mode = if (cache.valid) cache.phase else null,
            .task_kind = if (cache.valid) cache.kind else .prompt,
            .session_id = self.session,
            .session_label = if (cache.valid and cache.label_len != 0) try arena.dupe(u8, cache.label[0..cache.label_len]) else null,
            .launcher_dir = try arena.dupe(u8, self.launcher),
            .control_epoch = self.epoch,
            .queue_revision = if (cache.valid) cache.revision else 0,
            .queue_paused = cache.valid and cache.paused,
            .steering = if (cache.valid) cache.steering else 0,
            .follow_up = if (cache.valid) cache.follow_up else 0,
            .newest_id = if (cache.valid) cache.newest_id else null,
            .newest_bytes = if (cache.valid) cache.newest_bytes else 0,
            .previews = previews,
            .running_sessions = 0,
            .memory = cache.memory,
            .background = cache.background,
            .subagents = try cache.subagents.clone(arena),
            .subagents_supported = cache.subagents_supported,
        };
    }

    /// Pure projection of the cached owner reply plus public settings data. No
    /// pointer, no credential, no key and no native replay reaches the UI.
    fn buildState(self: *Client, arena: std.mem.Allocator) !tui.Connection.State {
        const cfg = &self.pubcfg;
        const cache = &self.cache;
        var state: tui.Connection.State = baseState();
        state.codex_login = cache.codex_login;
        state.memory = cache.memory;
        state.background = cache.background;
        state.subagents = try cache.subagents.clone(arena);
        state.subagents_supported = cache.subagents_supported;
        state.available = cfg.available and (self.conn != null or self.control != null);
        state.busy = (cache.valid and cache.busy) or (self.need_history and self.snap.busy);
        state.session_label = if (cache.valid and cache.label_len != 0) try arena.dupe(u8, cache.label[0..cache.label_len]) else null;
        state.launcher_dir = try arena.dupe(u8, self.launcher);
        state.control_epoch = self.epoch;
        state.initial_context = if (cache.valid) cache.context else null;
        state.model = try arena.dupe(u8, cfg.model);
        state.session_id = self.session;
        state.models = try cloneModels(arena, cfg.models);
        const providers = try arena.dupe(picker_module.Provider, cfg.providers);
        for (providers) |*provider| provider.name = try arena.dupe(u8, provider.name);
        state.model_providers = providers;
        state.model_context_official = try arena.dupe(bool, cfg.context_official);
        state.model_disabled = try arena.dupe(bool, cfg.disabled);
        state.selection_name = if (cfg.selection.len != 0) try arena.dupe(u8, cfg.selection) else null;
        state.provider = cfg.provider;
        state.configured_providers = cfg.configured;
        state.allow_custom_models = cfg.allow_custom;
        state.context_limit = cfg.context_limit;
        state.low_price_input = cfg.low_price_active;
        state.low_price_input_enabled = cfg.low_price_enabled;
        state.image_enabled = cfg.image_enabled;
        state.image_models = try cloneModels(arena, cfg.image_models);
        state.image_model = if (cfg.image_model) |name| try arena.dupe(u8, name) else null;
        state.memory_auto = cfg.memory_auto;
        state.decision_enabled = cfg.decision_enabled;
        state.decision_models = try cloneModels(arena, cfg.decision_models);
        state.decision_model = if (cfg.decision_model) |name| try arena.dupe(u8, name) else null;
        state.proxy_configured = cfg.proxy_configured;
        state.proxy_address = if (cfg.proxy_address) |address| try arena.dupe(u8, address) else null;
        state.proxy_port = cfg.proxy_port;
        // Each name is copied into the arena: the published projection must not
        // outlive the settings document it was parsed from.
        if (cfg.proxy_models.len != 0) {
            const names = try arena.alloc([]const u8, cfg.proxy_models.len);
            for (cfg.proxy_models, 0..) |name, index| names[index] = try arena.dupe(u8, name);
            state.proxy_models = names;
        }
        state.global_settings_available = !cfg.read_only;
        state.limits = cfg.limits;
        state.reasoning_effort = cfg.effort;
        state.pending_default_effort = cfg.pending_effort;
        state.effort_levels = cfg.effort_levels;
        state.metadata_notice = if (cfg.metadata_notice) |text| try arena.dupe(u8, text) else null;
        state.metadata_notice_ttl_ms = if (cfg.metadata_notice != null) 4000 else 0;
        state.settings_notice = if (cfg.notice) |text| try arena.dupe(u8, text) else null;
        state.base_url = try arena.dupe(u8, cfg.base_url);
        return state;
    }

    fn cloneModels(arena: std.mem.Allocator, models: []const core_config.Model) ![]core_config.Model {
        const copy = try arena.alloc(core_config.Model, models.len);
        for (models, 0..) |model, index| {
            copy[index] = model;
            copy[index].name = try arena.dupe(u8, model.name);
            copy[index].reasoning_effort = if (model.reasoning_effort) |value| try arena.dupe(u8, value) else null;
            if (copy[index].reasoning) |*reasoning| {
                inline for (.{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |name| {
                    if (@field(reasoning.map, name)) |value| @field(reasoning.map, name) = try arena.dupe(u8, value);
                }
            }
        }
        return copy;
    }

    /// Immutable, independently owned publication. Unlike the legacy borrowed
    /// double arena, this may be transferred to another thread and freed there.
    pub const Projection = struct {
        configuration_revision: u64 = 0,
        task_id: ?u64 = null,
        a: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        state: tui.Connection.State,
        snapshot: session_client.Snapshot,

        pub fn deinit(self: *Projection) void {
            const a = self.a;
            self.arena.deinit();
            a.destroy(self);
        }
    };

    pub fn exportProjection(self: *Client) !*Projection {
        const view = try self.a.create(Projection);
        errdefer self.a.destroy(view);
        view.* = .{ .configuration_revision = self.configuration_revision, .task_id = if (self.cache.task == 0) null else self.cache.task, .a = self.a, .arena = .init(self.a), .state = undefined, .snapshot = undefined };
        errdefer view.arena.deinit();
        view.state = try self.buildState(view.arena.allocator());
        view.snapshot = try self.buildSnapshot(view.arena.allocator());
        return view;
    }

    /// Sole-owner asynchronous command execution. Only the communication task
    /// calls this; the UI receives a ticket first and this result later.
    pub fn perform(self: *Client, epoch: u64, action: remote_action.Action) !remote_action.Value {
        if (epoch != self.epoch) return error.StaleControl;
        switch (action) {
            .submit => |v| try submitFn(self, epoch, v.kind, v.text),
            .cancel => try cancelFn(self, epoch),
            .cancel_clear => |revision| try cancelClearFn(self, epoch, revision),
            .confirming => |active| try setConfirmingFn(self, epoch, active),
            .approve => |v| try approveFn(self, epoch, v.id, v.decision),
            .enqueue => |v| try enqueueFn(self, epoch, v.kind, v.text),
            .withdraw => |id| return .{ .withdrawn = try withdrawFn(self, self.a, epoch, id) },
            .queue_resume => try queueResumeFn(self, epoch),
            .manage => |command| return .{ .managed = try manageFn(self, self.a, command) },
            .configure => |v| if (v.provider) |provider| try configureProviderFn(self, provider, v.key) else try configureFn(self, v.key),
            .model => |name| try selectModelFn(self, name),
            .effort => |effort| try setEffortFn(self, effort),
            .cycle_effort => return .{ .effort = try cycleEffortFn(self) },
            .preference => |v| try preferenceFn(self, v.key, v.value),
            .setting => |v| try settingFn(self, switch (v.key) {
                .low_price_input => .low_price_input,
                .decision_enabled => .decision_enabled,
            }, v.value),
            .decision => |choice| try decisionFn(self, choice),
            .image => |choice| try imageFn(self, choice),
            .proxy => |v| try proxyFn(self, v.model, v.enabled),
            .proxy_address => |address| try proxyAddressFn(self, address),
            .refresh_models => try refreshModelsFn(self),
            .codex_login => |v| try codexLoginFn(self, v.action, v.generation),
            .poll_metadata => |wait| return .{ .changed = pollModelsFn(self, wait) },
        }
        return .none;
    }

    /// Nonblocking UI admission of one already-displayed inclusive range
    /// (`first == 0` is the prefix `[0, last]`). No socket I/O happens on the
    /// calling thread; the receiver coalesces and writes the frame. While the
    /// subscription is missing this reports Unavailable so the caller keeps its
    /// exact proof for retry instead of pretending it was acknowledged.
    pub fn admitAckRange(self: *Client, epoch: u64, first: u64, last: u64) !void {
        if (last == 0) return;
        if (first != 0 and first > last) return error.InvalidInput;
        if (epoch == 0 or epoch != self.epoch) return error.StaleControl;
        const stream = self.stream orelse return error.Unavailable;
        try stream.acknowledgeRange(epoch, first, last);
    }

    /// Cumulative prefix admission retained for existing callers.
    pub fn admitAck(self: *Client, epoch: u64, sequence: u64) !void {
        return self.admitAckRange(epoch, 0, sequence);
    }

    /// Local pending events are transferred before any next stream frame is
    /// consumed. With a real subscription this never polls the worker socket.
    pub fn nextDisplay(self: *Client) !?session_client.Item {
        if (self.in_wait_progress) {
            // Never issue a nested control RPC while a reply owns that socket.
            if (self.pending.items.len == 0 and self.stream != null) try self.pumpStream();
            return if (self.pending.items.len != 0) self.pending.orderedRemove(0) else null;
        }
        return pollFn(self, self.a);
    }

    pub fn dropDisplayView(self: *Client) void {
        self.loseView();
    }

    // -- owner refresh -----------------------------------------------------

    fn refreshSnapshot(self: *Client) void {
        var req = self.request(.snapshot) catch return;
        defer req.deinit();
        req.put("row_cursor", self.row_cursor) catch return;
        req.put("row_group", self.row_group) catch return;
        var resp = req.exchange(quick_timeout_ms) catch |err| {
            self.poll_error = err;
            return;
        };
        defer resp.deinit();
        self.adoptSnapshot(&resp) catch |err| {
            self.poll_error = err;
        };
    }

    fn adoptSnapshot(self: *Client, resp: *const Response) !void {
        const object = switch (resp.field("snapshot") orelse return error.ProtocolError) {
            .object => |value| value,
            else => return error.ProtocolError,
        };
        var cache: SnapshotCache = .{};
        var adopted = false;
        defer if (!adopted) cache.subagents.deinitOwned(self.a);
        const get = struct {
            fn field(map: std.json.ObjectMap, name: []const u8) ?std.json.Value {
                return map.get(name);
            }
            fn text(map: std.json.ObjectMap, name: []const u8) ?[]const u8 {
                return switch (field(map, name) orelse return null) {
                    .string => |s| s,
                    else => null,
                };
            }
            fn flag(map: std.json.ObjectMap, name: []const u8) bool {
                return switch (field(map, name) orelse return false) {
                    .bool => |b| b,
                    else => false,
                };
            }
            fn uint(map: std.json.ObjectMap, name: []const u8) ?u64 {
                return valueU64(field(map, name) orelse return null);
            }
        };
        cache.valid = true;
        cache.memory = try decodeMemoryView(object.get("memory") orelse return error.ProtocolError);
        cache.background = try decodeBackgroundView(object.get("background") orelse return error.ProtocolError);
        if (object.get("subagents")) |value| {
            cache.subagents = try decodeSubagentView(self.a, value);
            if (cache.subagents.page_offset != null and self.cache.subagents_supported and self.cache.subagents.group_id == cache.subagents.group_id) {
                const previous = self.cache.subagents;
                const page = cache.subagents;
                const Agent = @import("../core/subagent_status.zig").AgentView;
                var rows: std.ArrayList(Agent) = .empty;
                defer rows.deinit(self.a);
                try rows.appendSlice(self.a, previous.agents);
                for (page.agents) |row| {
                    var found = false;
                    for (rows.items) |*old| if (old.id == row.id) {
                        if (row.revision >= old.revision) old.* = row;
                        found = true;
                        break;
                    };
                    if (!found) try rows.append(self.a, row);
                }
                if (rows.items.len > @max(page.total, previous.total)) return error.ProtocolError;
                const merged = try rows.toOwnedSlice(self.a);
                cache.subagents.deinitOwned(self.a);
                cache.subagents = page;
                cache.subagents.agents = merged;
                if (previous.revision > page.revision) {
                    const merged_rows = cache.subagents.agents;
                    cache.subagents = previous;
                    cache.subagents.agents = merged_rows;
                    cache.subagents.page_offset = page.page_offset;
                    cache.subagents.page_total = page.page_total;
                }
            }
            cache.subagents_supported = true;
        }
        if (object.get("codex_login")) |value| {
            const login_view = switch (value) {
                .object => |map| map,
                else => return error.ProtocolError,
            };
            cache.codex_login.generation = get.uint(login_view, "generation") orelse return error.ProtocolError;
            cache.codex_login.status = std.meta.stringToEnum(codex_login.Status, get.text(login_view, "status") orelse return error.ProtocolError) orelse return error.ProtocolError;
            const code = get.text(login_view, "code") orelse return error.ProtocolError;
            if (code.len > cache.codex_login.code.len) return error.ProtocolError;
            for (code) |c| if (c < 0x21 or c > 0x7e) return error.ProtocolError;
            if (code.len != 0 and cache.codex_login.status != .pending) return error.ProtocolError;
            @memcpy(cache.codex_login.code[0..code.len], code);
            cache.codex_login.code_len = @intCast(code.len);
            const failure = login_view.get("failure") orelse return error.ProtocolError;
            cache.codex_login.failure = switch (failure) {
                .null => null,
                .string => |name| std.meta.stringToEnum(codex_login.Failure, name) orelse return error.ProtocolError,
                else => return error.ProtocolError,
            };
        }
        cache.busy = get.flag(object, "busy");
        cache.phase = if (get.text(object, "phase")) |name| std.meta.stringToEnum(r.State, name) else null;
        cache.task = get.uint(object, "task") orelse 0;
        cache.kind = if (get.text(object, "task_kind")) |name| std.meta.stringToEnum(session_client.TaskKind, name) orelse .prompt else .prompt;
        if (get.field(object, "epoch")) |value| if (valueU64(value)) |epoch| {
            cache.epoch = epoch;
            cache.epoch_known = true;
        };
        cache.revision = get.uint(object, "queue_revision") orelse 0;
        cache.paused = get.flag(object, "queue_paused");
        cache.steering = @intCast(@min(get.uint(object, "steering") orelse 0, std.math.maxInt(u32)));
        cache.follow_up = @intCast(@min(get.uint(object, "follow_up") orelse 0, std.math.maxInt(u32)));
        cache.newest_id = get.uint(object, "newest_id");
        cache.newest_bytes = get.uint(object, "newest_bytes") orelse 0;
        if (get.field(object, "ctx")) |value| switch (value) {
            .object => |ctx| cache.context = .{
                .tokens = valueU64(ctx.get("tokens") orelse .{ .integer = 0 }) orelse 0,
                .limit = valueU64(ctx.get("limit") orelse .{ .integer = 0 }) orelse 0,
                .known = valueBool(ctx.get("known") orelse .{ .bool = false }) orelse false,
            },
            else => {},
        };
        if (get.text(object, "label")) |label| {
            var clipped = @min(label.len, max_label_bytes);
            while (clipped > 0 and clipped < label.len and label[clipped] & 0xc0 == 0x80) clipped -= 1;
            @memcpy(cache.label[0..clipped], label[0..clipped]);
            cache.label_len = @intCast(clipped);
        }
        var preview_count: usize = 0;
        if (get.field(object, "previews")) |value| switch (value) {
            .array => |array| for (array.items) |entry| {
                if (preview_count == session_client.max_previews) break;
                const item = switch (entry) {
                    .object => |object_value| object_value,
                    else => continue,
                };
                var preview: SnapshotCache.Preview = .{};
                preview.id = valueU64(item.get("id") orelse .{ .integer = 0 }) orelse 0;
                preview.kind = if (get.text(item, "kind")) |name| std.meta.stringToEnum(session_client.QueueKind, name) orelse .steering else .steering;
                const text_value = get.text(item, "text") orelse "";
                var n = @min(text_value.len, max_preview_bytes);
                while (n > 0 and n < text_value.len and text_value[n] & 0xc0 == 0x80) n -= 1;
                @memcpy(preview.text[0..n], text_value[0..n]);
                preview.len = @intCast(n);
                cache.previews[preview_count] = preview;
                preview_count += 1;
            },
            else => {},
        };
        cache.preview_count = @intCast(preview_count);
        // Control was revoked. The owner reports `epoch: 0` to a connection that
        // is no longer the controller (it never hands out another console's
        // epoch), so any epoch other than the one this view holds — including 0
        // — means this frontend lost control. Keeping such a connection would
        // make every later input fail as stale forever, so it returns to the
        // launcher. The owner and any worker this launcher owns keep running;
        // nothing is cancelled or shut down here.
        if (self.epoch != 0 and cache.epoch_known and cache.epoch != self.epoch) {
            self.revokeView();
            return;
        }
        if (cache.codex_login.status == .succeeded and
            (self.cache.codex_login.status != .succeeded or self.cache.codex_login.generation != cache.codex_login.generation)) self.dirty = true;
        if (!std.meta.eql(self.cache.memory, cache.memory)) self.dirty = true;
        if (!std.meta.eql(self.cache.background, cache.background)) self.dirty = true;
        if (cache.subagents.page_offset) |offset| {
            self.row_group = cache.subagents.group_id;
            // Merged rows can contain earlier pages; use the decoded page length.
            const wire_agents = object.get("subagents").?.object.get("agents").?.array.items.len;
            const page_end = offset + wire_agents;
            self.row_cursor = if (page_end < cache.subagents.page_total) page_end else 0;
        } else {
            self.row_cursor = 0;
            self.row_group = cache.subagents.group_id;
        }
        self.cache.subagents.deinitOwned(self.a);
        self.cache = cache;
        adopted = true;
        if (resp.uint("through")) |through| self.cache_floor = @max(self.cache_floor, through);
    }

    fn refreshSettings(self: *Client) void {
        // Progress may consume the initial subscription baseline while this
        // reply is pending. Baseline availability must not advertise Ready
        // using the old/default settings. Ordinary metadata refreshes do not
        // interrupt an already initialized view.
        self.initial_settings_loading = self.need_history;
        defer self.initial_settings_loading = false;
        var req = (self.trySettingsRequest(.settings) catch |err| {
            switch (err) {
                error.Unsupported, error.ProtocolError, error.RemoteFailure => return,
                else => {
                    self.poll_error = err;
                    return;
                },
            }
        }) orelse return;
        defer req.deinit();
        var resp = req.exchange(quick_timeout_ms) catch |err| switch (err) {
            error.Unsupported, error.ProtocolError, error.RemoteFailure => return,
            else => {
                self.poll_error = err;
                return;
            },
        };
        defer resp.deinit();
        self.adoptSettings(resp.object) catch {
            self.state.settings_error = error.ProtocolError;
        };
    }

    fn adoptSettings(self: *Client, object: std.json.ObjectMap) !void {
        var next: Pub = .{};
        next.doc = resp_doc: {
            // The caller's document is released after this call; re-parse the
            // public object into a document this projection keeps.
            const bytes = try std.json.Stringify.valueAlloc(self.a, std.json.Value{ .object = object }, .{});
            defer self.a.free(bytes);
            break :resp_doc std.json.parseFromSlice(std.json.Value, self.a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch return error.ProtocolError;
        };
        // A later catalog can fail after an earlier one was already assigned to
        // `next`, so the error path releases the whole partial projection
        // (arrays plus doc). `parseModels` errdefers only its own unassigned
        // temporaries, so nothing handed over here is freed twice.
        errdefer self.freePubValue(next);
        const view = switch (next.doc.?.value) {
            .object => |value| value,
            else => return error.ProtocolError,
        };
        const read = struct {
            fn field(map: std.json.ObjectMap, name: []const u8) ?std.json.Value {
                return map.get(name);
            }
            fn text(map: std.json.ObjectMap, name: []const u8) ?[]const u8 {
                return switch (field(map, name) orelse return null) {
                    .string => |s| s,
                    else => null,
                };
            }
            fn flag(map: std.json.ObjectMap, name: []const u8, default: bool) bool {
                return valueBool(field(map, name) orelse return default) orelse default;
            }
            fn uint(map: std.json.ObjectMap, name: []const u8) ?u64 {
                return valueU64(field(map, name) orelse return null);
            }
        };
        next.model = read.text(view, "model") orelse "";
        next.available = read.flag(view, "available", false);
        next.selection = read.text(view, "selection_name") orelse read.text(view, "selection") orelse next.model;
        next.base_url = read.text(view, "base_url") orelse "";
        if (read.text(view, "provider")) |name| next.provider = std.meta.stringToEnum(core_config.providers.Id, name);
        next.effort = shared.ReasoningEffort.fromName(read.text(view, "effort"));
        if (read.field(view, "effort_levels")) |value| next.effort_levels = parseEfforts(value);
        if (read.field(view, "configured")) |value| next.configured = parseConfigured(value);
        next.read_only = read.flag(view, "read_only", false);
        // `low_price_input` is the active protection marker, not the switch;
        // `low_price_input_enabled` is the configured global switch.
        next.low_price_active = read.flag(view, "low_price_input", false);
        next.low_price_enabled = read.flag(view, "low_price_input_enabled", next.low_price_active);
        next.memory_auto = read.flag(view, "memory_auto", true);
        next.decision_enabled = read.flag(view, "decision_enabled", false);
        next.image_enabled = read.flag(view, "image_enabled", false);
        next.decision_model = read.text(view, "decision_model");
        next.image_model = read.text(view, "image_model");
        next.proxy_configured = read.flag(view, "proxy_configured", false);
        adoptProxyEndpoint(&next, read.field(view, "proxy_address"), read.field(view, "proxy_port"), next.proxy_configured);
        try parseProxyModels(self.a, &next, read.field(view, "proxy_models"));
        next.context_limit = @intCast(@min(read.uint(view, "context_limit") orelse 0, std.math.maxInt(u32)));
        next.allow_custom = read.flag(view, "allow_custom_models", true);
        next.pending_effort = if (read.text(view, "pending_effort")) |name| shared.ReasoningEffort.fromName(name) else null;
        next.notice = read.text(view, "settings_notice");
        next.metadata_notice = read.text(view, "metadata_notice");
        if (read.field(view, "limits")) |value| next.limits = parseLimits(value, next.limits);
        try parseModels(self.a, &next, read.field(view, "models"), .models);
        try parseModels(self.a, &next, read.field(view, "decision_models"), .decision_models);
        try parseModels(self.a, &next, read.field(view, "image_models"), .image_models);
        try parseProviders(self.a, &next, read.field(view, "providers"));

        const changed = if (self.pubcfg.doc) |old_doc|
            !publicSettingsEqual(old_doc.value, next.doc.?.value, 0)
        else
            true;
        const stale = self.pubcfg;
        self.pubcfg = next;
        if (changed) self.configuration_revision +%= 1;
        self.freePubValue(stale);
    }

    fn freePub(self: *Client) void {
        self.freePubValue(self.pubcfg);
        self.pubcfg = .{};
    }

    fn freePubValue(self: *Client, value: Pub) void {
        if (value.models.len != 0) self.a.free(value.models);
        if (value.decision_models.len != 0) self.a.free(value.decision_models);
        if (value.image_models.len != 0) self.a.free(value.image_models);
        // Only the name array is owned here; each name is a window into
        // `doc`, which is released below.
        if (value.proxy_models.len != 0) self.a.free(value.proxy_models);
        if (value.providers.len != 0) self.a.free(value.providers);
        if (value.context_official.len != 0) self.a.free(value.context_official);
        if (value.disabled.len != 0) self.a.free(value.disabled);
        if (value.doc) |doc| {
            var owned = doc;
            owned.deinit();
        }
    }

    // -- upstream stream ---------------------------------------------------

    fn pump(self: *Client) void {
        if (self.conn == null) return;
        if (self.pending.items.len >= max_pending) return;
        if (self.dirty) {
            self.dirty = false;
            self.refreshSettings();
            self.rebuild();
        }
        if (self.stream_expected) {
            self.pumpStream() catch |err| {
                self.loseView();
                self.poll_error = err;
            };
            return;
        }
        self.refreshSnapshot();
        self.rebuild();
        if (self.need_history) {
            self.need_history = false;
            self.readHistory() catch |err| {
                if (err != error.Transport) self.need_history = true;
                self.poll_error = err;
            };
            return;
        }
        self.readEvents() catch |err| {
            self.poll_error = err;
        };
    }

    /// Local queue consumption only. The receiver continues socket reads even
    /// while the TUI is drawing or waiting for a separate control RPC.
    fn pumpStream(self: *Client) !void {
        if (self.stream_recovery_pending) {
            if (self.in_wait_progress) return;
            self.stream_recovery_pending = false;
            try self.recoverStream();
            return;
        }
        const stream = self.stream orelse return error.Unavailable;
        const bytes = (stream.pop() catch |err| {
            if (err == error.OutOfMemory) return err;
            if (self.in_wait_progress) {
                self.stream_recovery_pending = true;
                self.rebuild();
                return;
            }
            try self.recoverStream();
            return;
        }) orelse return;
        defer self.a.free(bytes);
        var response = try parseObject(self.a, bytes);
        defer response.deinit();
        if (try validateEnvelope(&response, 1) != .ok) return error.ProtocolError;
        if (response.uint("epoch") != self.epoch) return error.StaleControl;
        const kind = response.text("stream") orelse return error.ProtocolError;
        const through = response.uint("through") orelse return error.ProtocolError;
        if (std.mem.eql(u8, kind, "snapshot")) {
            const state = switch (response.field("snapshot") orelse return error.ProtocolError) {
                .object => |value| value,
                else => return error.ProtocolError,
            };
            if (valueU64(state.get("epoch") orelse return error.ProtocolError) != self.epoch) return error.StaleControl;
            if (self.resume_snapshot_pending) {
                // A reconnect snapshot can be ahead of already-owned events;
                // never publish it before their ordered stream pages.
                self.resume_snapshot_pending = false;
                return;
            }
            if (self.need_history) {
                if (self.stream_snapshot != null) return error.ProtocolError;
                self.stream_snapshot = try self.a.dupe(u8, bytes);
                return;
            }
            if (through != self.cursor) return error.ProtocolError;
            if (through < self.cache_floor) return;
            try self.adoptSnapshot(&response);
            self.stream_publication_revision +%= 1;
            self.rebuild();
            return;
        }
        if (std.mem.eql(u8, kind, "baseline")) {
            if (!self.need_history) return error.ProtocolError;
            const snapshot_bytes = self.stream_snapshot orelse return error.ProtocolError;
            var snapshot = try parseObject(self.a, snapshot_bytes);
            defer snapshot.deinit();
            const snapshot_through = snapshot.uint("through") orelse return error.ProtocolError;
            if (snapshot_through < through or response.uint("base") != through) return error.ProtocolError;
            try self.adoptHistory(&response, true);
            // The snapshot is the CURRENT state projection, not ordered content:
            // it may be ahead of the baseline cutoff while retained live deltas
            // follow through the ordered event pages. It must never move the
            // cursor, so adopting it here cannot skip a retained entry.
            if (snapshot_through >= through and snapshot_through >= self.cache_floor) try self.adoptSnapshot(&snapshot);
            self.a.free(snapshot_bytes);
            self.stream_snapshot = null;
            self.need_history = false;
            self.stream_publication_revision +%= 1;
            self.rebuild();
            return;
        }
        if (!std.mem.eql(u8, kind, "events") or self.need_history or response.uint("from") != self.cursor or through <= self.cursor) return error.ProtocolError;
        const entries = switch (response.field("events") orelse return error.ProtocolError) {
            .array => |array| array,
            else => return error.ProtocolError,
        };
        if (entries.items.len > protocol.max_events or self.pending.items.len != 0) return error.ProtocolError;
        errdefer self.clearPending();
        var previous = self.cursor;
        for (entries.items) |entry| {
            const object = switch (entry) {
                .object => |value| value,
                else => return error.ProtocolError,
            };
            const sequence = valueU64(object.get("seq") orelse return error.ProtocolError) orelse return error.ProtocolError;
            if (sequence <= previous or sequence > through) return error.ProtocolError;
            try self.pushEventMode(entry, true);
            const item = &self.pending.items[self.pending.items.len - 1];
            item.delivery_epoch = self.epoch;
            item.delivery_sequence = sequence;
            // One raw wire event is exactly one position; coalescing later
            // widens this span instead of forgetting the older position.
            item.delivery_first_sequence = sequence;
            previous = sequence;
        }
        if (response.flag("incomplete", false)) self.pubcfg.notice = "Some earlier live events are unavailable; display continues.";
        self.cursor = through;
    }

    /// A drained dead stream can rebuild its display baseline, never resubmit
    /// inference. Persistent failure is paced; a saturated queue is drained
    /// first, so it cannot trigger an eager reconnect loop.
    fn recoverStream(self: *Client) !void {
        const now = Io.Clock.awake.now(self.io).toMilliseconds();
        if (now < self.stream_retry_after) return;
        self.stream_retry_after = @intCast(@min(now + 1000, std.math.maxInt(i64)));
        const old = self.stream orelse return;
        self.stream = null;
        const need_baseline = self.need_history;
        self.rebuild();
        defer old.deinit();
        if (self.stream_snapshot) |bytes| self.a.free(bytes);
        self.stream_snapshot = null;
        // Revocation is read from the real control socket, not guessed from an
        // event EOF. This never changes task ownership or sends submit again.
        self.refreshSnapshot();
        if (self.conn == null or self.epoch == 0) return;
        // Unconfirmed ranges belong to the SAME viewer and epoch: carry them to
        // the replacement connection instead of losing already-shown positions.
        const carried = old.takeRanges();
        self.stream = try StreamReceiver.startBound(self.a, self.io, old.endpoint, self.uid, self.epoch, if (need_baseline) null else self.cursor, old.expected_pid);
        try self.stream.?.adoptRanges(carried);
        self.resume_snapshot_pending = !need_baseline;
    }

    fn pageEpoch(self: *Client, resp: *const Response) ?u64 {
        const epoch = resp.uint("epoch") orelse return null;
        if (epoch == 0 or self.epoch == 0) return null;
        return if (epoch == self.epoch) epoch else 0;
    }

    fn readHistory(self: *Client) !void {
        var req = try self.request(.history);
        defer req.deinit();
        try req.put("limit", max_history);
        var resp = try req.exchange(poll_timeout_ms);
        defer resp.deinit();
        try self.adoptHistory(&resp, false);
    }

    fn adoptHistory(self: *Client, resp: *const Response, strict: bool) !void {
        const base = resp.uint("base") orelse return error.ProtocolError;
        if (resp.flag("truncated", false)) self.pubcfg.notice = "History is incomplete; retained live events follow.";
        const entries = switch (resp.field("entries") orelse return error.ProtocolError) {
            .array => |array| array,
            else => return error.ProtocolError,
        };
        // A page from another control epoch is stale: drop it completely.
        const page = self.pageEpoch(resp);
        if (page) |epoch| if (epoch == 0) return;
        // The page replaces the queue: an entry that fails after earlier ones
        // were decoded must not publish a partial replay, so the previous
        // cursor and an empty queue are restored before the error escapes.
        const previous_cursor = self.cursor;
        self.clearPending();
        errdefer {
            self.clearPending();
            self.cursor = previous_cursor;
        }
        self.cursor = base;
        // Only the items this page produced are marked, and only after each one
        // passed its own epoch check inside `pushEvent`. An empty page marks
        // nothing: the UI already resets on the epoch switch, so no synthetic
        // content event is fabricated.
        const before = self.pending.items.len;
        if (strict and entries.items.len > max_pending) return error.ProtocolError;
        for (entries.items) |entry| try self.pushEventMode(entry, strict);
        if (self.pending.items.len == before) return;
        for (0..self.pending.items.len - before) |offset| {
            const item = &self.pending.items[before + offset];
            item.history_replay = true;
            item.history_reset = offset == 0;
            item.history_display_reset = offset == 0 and strict and base >= self.cache_floor;
        }
    }

    fn readEvents(self: *Client) !void {
        var req = try self.request(.events);
        defer req.deinit();
        try req.put("since", self.cursor);
        try req.put("max", max_events);
        try req.put("wait_ms", @as(u32, 0));
        var resp = try req.exchange(poll_timeout_ms);
        defer resp.deinit();
        if (resp.flag("reset", false)) {
            // The window was evicted: rebuild from the owned history snapshot.
            self.need_history = true;
            return;
        }
        const page = self.pageEpoch(&resp);
        if (page) |epoch| if (epoch == 0) {
            // Another console owns this epoch now; keep the cursor, render
            // nothing from a replaced controller.
            return;
        };
        const next = resp.uint("next") orelse self.cursor;
        if (resp.field("events")) |value| switch (value) {
            .array => |array| for (array.items) |entry| try self.pushEvent(entry),
            else => return error.ProtocolError,
        };
        if (next > self.cursor) self.cursor = next;
    }

    /// Decode one encoded display event into an independent owned item.
    fn pushEvent(self: *Client, entry: std.json.Value) !void {
        return self.pushEventMode(entry, false);
    }

    fn pushEventMode(self: *Client, entry: std.json.Value, strict: bool) !void {
        if (self.pending.items.len >= max_pending) return if (strict) error.QueueFull else {};
        var owned_bytes: ?[]u8 = null;
        defer if (owned_bytes) |bytes| self.a.free(bytes);
        const json = switch (entry) {
            .string => |text| text,
            .object => blk: {
                owned_bytes = try std.json.Stringify.valueAlloc(self.a, entry, .{});
                break :blk owned_bytes.?;
            },
            else => return error.ProtocolError,
        };
        if (json.len == 0 or json.len > protocol.max_response) return error.ProtocolError;
        var decoded = protocol.decodeEvent(self.a, json) catch |err| {
            if (strict) return err;
            return;
        };
        defer decoded.deinit();
        // A wire epoch is authority-bearing: it must match the controller epoch
        // this view holds, otherwise the event belongs to a replaced console.
        const epoch = itemEpoch(self.epoch, &decoded) orelse return if (strict) error.StaleControl else {};
        var item = try session_client.ownEvent(self.a, epoch, decoded.event);
        errdefer item.deinit();
        mergeFlags(&item, &decoded);
        try self.pending.append(self.a, item);
    }

    // -- VTable ------------------------------------------------------------

    fn fromContext(context: *anyopaque) *Client {
        return @ptrCast(@alignCast(context));
    }

    fn snapshotFn(context: *anyopaque) *const session_client.Snapshot {
        return &fromContext(context).snap;
    }

    fn bufferedFn(context: *anyopaque) bool {
        const self = fromContext(context);
        return self.pending.items.len != 0 or if (self.stream) |stream| stream.buffered() else false;
    }

    /// Direct (non-Communication) adapter admission: the same coalesced
    /// watermark path, never a synchronous control RPC.
    fn acknowledgeFn(context: *anyopaque, epoch: u64, sequence: u64) anyerror!void {
        return fromContext(context).admitAck(epoch, sequence);
    }

    fn acknowledgeRangeFn(context: *anyopaque, epoch: u64, first: u64, last: u64) anyerror!void {
        return fromContext(context).admitAckRange(epoch, first, last);
    }

    fn pollFn(context: *anyopaque, a: std.mem.Allocator) anyerror!?session_client.Item {
        _ = a;
        const self = fromContext(context);
        if (self.pending.items.len == 0) {
            self.poll_error = null;
            self.pump();
        }
        if (self.pending.items.len != 0) {
            // Remove before refreshing: a refresh may drop the view and clear the
            // queue, which must never free the item this poll returns.
            const item = self.pending.orderedRemove(0);
            if (item.event == .finished and !self.stream_expected) {
                // A finished event only says one task ended; a follow-up may
                // already run. Use the owner's current state, never a guess.
                self.refreshSnapshot();
                self.rebuild();
            }
            return item;
        }
        if (self.poll_error) |err| return err;
        return null;
    }

    fn submitFn(context: *anyopaque, epoch: u64, kind: session_client.TaskKind, text: []const u8) anyerror!void {
        const self = fromContext(context);
        // An empty text is the typed contract of a manual compaction: the owner
        // builds the summary from history alone and no user prompt exists. Every
        // other kind still needs non-empty input.
        if (text.len > protocol.max_text or (kind != .compact and text.len == 0)) return error.InputTooLarge;
        // Epoch 0 is the launcher before any session exists; the owner grants the
        // epoch together with the created session (checked below). Epoch 0 on a
        // live connection means this view lost control, so nothing is submitted.
        if (epoch == 0 and self.conn != null) return error.StaleControl;

        const digest = submissionDigest(kind, text);
        // A pending receipt is only retried through an owner query, never by a
        // blind resend. Reuse stays bound to the session identity.
        const pending = reusableReceipt(self.receipt, self.session, kind, &digest);
        // A lost view must not silently create a replacement session and resend
        // an unconfirmed task: only the original session id may answer.
        if (pending != null and self.conn == null) {
            self.uncertainReceipt();
            return error.Unavailable;
        }
        if (self.conn == null) try self.ensureSession();
        if (epoch != 0 and epoch != self.epoch) return error.StaleControl;

        if (pending) |known| {
            switch (self.queryReceipt(known.req) catch {
                self.uncertainReceipt();
                return error.Unavailable;
            }) {
                // The owner accepted the original submission: it is confirmed and
                // must not be submitted (or charged) a second time.
                .accepted => |task| {
                    self.confirmReceipt(kind, &digest, task);
                    return;
                },
                // The owner rejected it earlier, so this explicit action may mint
                // a fresh nonce and proceed as a new logical submission.
                .rejected => {
                    const nonce = try self.allocReceiptId();
                    self.receipt = .{ .req = nonce, .kind = kind, .digest = digest, .session = self.session };
                },
                // Unknown or evicted: refuse to guess and keep the pending state.
                .unknown => {
                    self.uncertainReceipt();
                    return error.Unavailable;
                },
            }
        } else if (self.receipt != null) {
            // A different logical submission, or an explicit session switch,
            // abandons the old pending receipt without replaying it.
            self.receipt = null;
        }

        const req_id = if (self.receipt) |receipt| receipt.req else fresh: {
            const nonce = try self.allocReceiptId();
            self.receipt = .{ .req = nonce, .kind = kind, .digest = digest, .session = self.session };
            break :fresh nonce;
        };

        var req = try self.request(.submit);
        defer req.deinit();
        try req.put("epoch", self.epoch);
        try req.put("req", req_id);
        try req.put("kind", kindName(kind));
        try req.put("text", text);
        var resp = req.exchange(finish_timeout_ms) catch |err| {
            // Never auto-resubmit a billable task; keep the receipt for an
            // explicit retry and let the draft stay with the caller.
            return err;
        };
        defer resp.deinit();
        const accepted = resp.flag("accepted", false);
        if (!accepted) return error.Rejected;
        self.receipt = null;
        const duplicate = resp.flag("duplicate", false);
        _ = duplicate;
        // The TUI already rendered this prompt once; suppress the owner echo.
        self.suppress = .{ .digest = digest, .armed = true };
        self.cache.busy = true;
        self.cache.task = resp.uint("task") orelse self.cache.task;
        self.cache_floor = @max(self.cache_floor, resp.uint("through") orelse 0);
        self.cache.kind = kind;
        self.dirty = true;
        self.rebuild();
    }

    /// Ask the live owner about one unconfirmed receipt before an explicit
    /// retry. The snapshot request is side-effect free.
    fn queryReceipt(self: *Client, nonce: u64) !ReceiptQuery {
        var req = try self.request(.snapshot);
        defer req.deinit();
        try req.put("receipt", nonce);
        var resp = req.exchange(quick_timeout_ms) catch return error.Unavailable;
        defer resp.deinit();
        // Keep the public projection fresh, but receipt state is authoritative
        // only from the explicit fields below.
        self.adoptSnapshot(&resp) catch |err| {
            self.poll_error = err;
        };
        if (!resp.flag("receipt_known", false)) return .unknown;
        if (resp.flag("receipt_accepted", false)) return .{ .accepted = resp.uint("receipt_task") orelse 0 };
        return .rejected;
    }

    /// The original submission is confirmed by the owner; never resubmit it.
    fn confirmReceipt(self: *Client, kind: session_client.TaskKind, digest: *const [32]u8, task: u64) void {
        self.receipt = null;
        if (task != 0) self.cache.task = task;
        self.cache.kind = kind;
        self.cache.busy = true;
        self.suppress = .{ .digest = digest.*, .armed = true };
        self.dirty = true;
        self.rebuild();
    }

    /// A pending receipt cannot be proven; surface that instead of guessing.
    fn uncertainReceipt(self: *Client) void {
        self.pubcfg.notice = receipt_unknown_notice;
        self.rebuild();
    }

    fn cancelFn(context: *anyopaque, epoch: u64) anyerror!void {
        const self = fromContext(context);
        var req = try self.request(.cancel);
        defer req.deinit();
        try req.put("epoch", epoch);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.rebuild();
    }

    fn cancelClearFn(context: *anyopaque, epoch: u64, revision: u64) anyerror!void {
        const self = fromContext(context);
        var req = try self.request(.cancel_clear);
        defer req.deinit();
        try req.put("epoch", epoch);
        try req.put("revision", revision);
        var resp = req.exchange(quick_timeout_ms) catch |err| {
            // The owner barrier must not outlive a dead view: releasing it here
            // (and on the host's EOF path) is the only way back to a live queue.
            self.revokeView();
            return err;
        };
        defer resp.deinit();
        const canceled = resp.flag("canceled", false);
        // A refused clear still proves the owner queue moved (revision bump or
        // a released barrier), so publish the real snapshot instead of the
        // stale revision this call was built from.
        self.refreshSnapshot();
        self.dirty = true;
        self.rebuild();
        if (!canceled) return error.QueueChanged;
    }

    /// Owner barrier for a local stop/approval modal. The host replies with the
    /// complete post-change snapshot, so the revision after `pauseClaims` is
    /// adopted immediately; the UI never keeps a pre-barrier revision.
    fn setConfirmingFn(context: *anyopaque, epoch: u64, active: bool) anyerror!void {
        const self = fromContext(context);
        var req = try self.request(.confirming);
        defer req.deinit();
        try req.put("epoch", epoch);
        try req.put("active", active);
        var resp = req.exchange(quick_timeout_ms) catch |err| {
            self.revokeView();
            return err;
        };
        defer resp.deinit();
        self.adoptSnapshot(&resp) catch |err| {
            self.revokeView();
            return err;
        };
        self.dirty = true;
        self.rebuild();
    }

    fn approveFn(context: *anyopaque, epoch: u64, permission_id: u64, decision: r.Decision) anyerror!void {
        const self = fromContext(context);
        var req = try self.request(.approve);
        defer req.deinit();
        try req.put("epoch", epoch);
        // The envelope `id` is the request id; the permission travels as its
        // own field so the two can never be confused.
        try req.put("permission_id", permission_id);
        try req.put("allow", decision == .allow_once);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.rebuild();
    }

    fn enqueueFn(context: *anyopaque, epoch: u64, kind: session_client.QueueKind, text: []const u8) anyerror!void {
        const self = fromContext(context);
        if (text.len == 0 or text.len > protocol.max_text) return error.InputTooLarge;
        var req = try self.request(.enqueue);
        defer req.deinit();
        try req.put("epoch", epoch);
        try req.put("kind", @tagName(kind));
        try req.put("text", text);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.rebuild();
    }

    fn withdrawFn(context: *anyopaque, a: std.mem.Allocator, epoch: u64, id: u64) anyerror!?[]u8 {
        const self = fromContext(context);
        var req = try self.request(.withdraw);
        defer req.deinit();
        try req.put("epoch", epoch);
        try req.put("queue_id", id);
        var resp = req.exchange(quick_timeout_ms) catch |err| switch (err) {
            error.QueueEmpty => {
                self.dirty = true;
                return null;
            },
            else => return err,
        };
        defer resp.deinit();
        self.dirty = true;
        self.rebuild();
        const text = resp.text("text") orelse return null;
        if (text.len == 0) return null;
        return try a.dupe(u8, text);
    }

    fn queueResumeFn(context: *anyopaque, epoch: u64) anyerror!void {
        const self = fromContext(context);
        var req = try self.request(.queue_resume);
        defer req.deinit();
        try req.put("epoch", epoch);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.rebuild();
    }

    fn detachFn(context: *anyopaque) void {
        const self = fromContext(context);
        if (self.conn != null and self.epoch != 0) {
            // Release control without touching the task; bounded, best effort.
            if (self.request(.detach)) |*req| {
                var owned = req.*;
                defer owned.deinit();
                owned.put("epoch", self.epoch) catch {};
                if (owned.exchange(quick_timeout_ms)) |*resp| {
                    var released = resp.*;
                    released.deinit();
                } else |_| {}
            } else |_| {}
        }
        self.loseView();
    }

    // -- session lifecycle (launcher) --------------------------------------

    /// One candidate worker view, opened but not yet shown. Nothing in the live
    /// projection changes until `adoptView`, so a refused/unknown attach keeps
    /// the session already on screen.
    const Candidate = struct {
        conn: unix.Connection,
        session: ids.Id,
        owner: cli.WorkerOwner,
        epoch: u64,
        stream: ?*StreamReceiver = null,
        project: ?[]u8 = null,

        fn deinit(self: *Candidate, a: std.mem.Allocator) void {
            if (self.stream) |stream| stream.deinit();
            if (self.project) |project| a.free(project);
            self.conn.close();
        }
    };

    /// Send one request over an explicitly supplied connection. A failure drops
    /// only that candidate; unlike the live path it never calls `loseView`.
    fn exchangeOn(self: *Client, conn: *unix.Connection, req: *Request, timeout_ms: u32) !Response {
        const bytes = try req.out.finish();
        defer self.a.free(bytes);
        conn.writeFrame(bytes, self.waitFor(timeout_ms)) catch |err| return switch (err) {
            error.Canceled, error.OutOfMemory => err,
            else => transport(err),
        };
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const frame = conn.readFrame(self.waitFor(timeout_ms)) catch |err| switch (err) {
                error.Timeout => {
                    if (attempt < 3) continue;
                    return error.Transport;
                },
                error.Canceled, error.OutOfMemory => return err,
                else => return transport(err),
            };
            const payload = frame orelse return error.Transport;
            defer self.a.free(payload);
            var resp = parseObject(self.a, payload) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ProtocolError,
            };
            errdefer resp.deinit();
            const verdict = try validateEnvelope(&resp, req.id);
            return switch (verdict) {
                .ok => resp,
                .rejected => |code| return wireError(code),
            };
        }
    }

    /// Greet and take write control on an already dialed candidate. This path
    /// does not start a watch, so it is also suitable for close-only requests.
    fn openController(self: *Client, conn: unix.Connection, id: ?ids.Id, takeover: bool, expected: ?*const registry.Record) !Candidate {
        var owned = conn;
        errdefer owned.close();
        var session: ids.Id = undefined;
        var owner: cli.WorkerOwner = undefined;
        {
            var req = try self.request(.hello);
            defer req.deinit();
            try req.put("view", "controller");
            var resp = self.exchangeOn(&owned, &req, join_timeout_ms) catch |err| return switch (err) {
                // The dial succeeded but the peer did not complete this exact
                // IPC greeting. A v1 worker rejects the v4 frame (and a v1 reply
                // fails the v4 envelope), so this is fail-closed: no attach, no
                // session adoption, no cursor and no display claim. Nothing is
                // restarted, migrated or killed to make it compatible.
                error.ProtocolError, error.Transport => error.ProtocolMismatch,
                else => err,
            };
            defer resp.deinit();
            // A compatible worker must announce this exact IPC version and the
            // watch capability the lossless selective-ACK protocol depends on.
            // This is checked BEFORE any controller claim or display adoption.
            if (resp.uint("protocol") != protocol.version) return error.ProtocolMismatch;
            if (!resp.flag("watch", false)) return error.ProtocolMismatch;
            const pid = resp.uint("pid") orelse return error.ProtocolError;
            owner = std.meta.stringToEnum(cli.WorkerOwner, resp.text("owner") orelse return error.ProtocolError) orelse return error.ProtocolError;
            if (pid != owned.peer.pid) return error.PeerPidMismatch;
            if (expected) |record| {
                if (pid != record.pid or owner != record.owner) return error.OwnerMismatch;
            }
            // The greeting carries the authoritative session identity for this
            // view, even when the caller already knows the endpoint.
            const raw = resp.text("session") orelse return error.ProtocolError;
            if (raw.len != 32) return error.ProtocolError;
            const greeted: ids.Id = raw[0..32].*;
            if (!ids.valid(greeted)) return error.ProtocolError;
            if (id) |want| {
                if (!std.mem.eql(u8, &greeted, &want)) return error.SessionNotFound;
            }
            session = greeted;
        }
        var epoch: u64 = 0;
        {
            var req = try self.request(.attach);
            defer req.deinit();
            try req.put("write", true);
            try req.put("takeover", takeover);
            var resp = try self.exchangeOn(&owned, &req, join_timeout_ms);
            defer resp.deinit();
            epoch = resp.uint("epoch") orelse return error.ProtocolError;
            if (epoch == 0) return error.ProtocolError;
        }
        return .{ .conn = owned, .session = session, .owner = owner, .epoch = epoch };
    }

    /// Validate both initial pages using the same snapshot/history decoders as
    /// the normal consumer, but against an isolated scratch view. The original
    /// pages stay queued in the receiver, so history, deltas and ACK ordering
    /// are unchanged when the candidate is committed.
    fn completeCandidate(self: *Client, view: *Candidate, endpoint: []const u8, expected_project: []const u8) !void {
        view.stream = try StreamReceiver.startBound(self.a, self.io, endpoint, self.uid, view.epoch, null, view.conn.peer.pid);
        const frames = try view.stream.?.copyInitial(self.waitFor(self.candidate_timeout_ms));
        defer for (frames) |bytes| self.a.free(bytes);
        var snapshot = try parseObject(self.a, frames[0]);
        defer snapshot.deinit();
        var baseline = try parseObject(self.a, frames[1]);
        defer baseline.deinit();
        if (try validateEnvelope(&snapshot, 1) != .ok or try validateEnvelope(&baseline, 1) != .ok) return error.ProtocolError;
        if (!std.mem.eql(u8, snapshot.text("stream") orelse return error.ProtocolError, "snapshot") or
            !std.mem.eql(u8, baseline.text("stream") orelse return error.ProtocolError, "baseline")) return error.ProtocolError;
        if (snapshot.uint("epoch") != view.epoch or baseline.uint("epoch") != view.epoch) return error.StaleControl;
        const through = snapshot.uint("through") orelse return error.ProtocolError;
        const base = baseline.uint("through") orelse return error.ProtocolError;
        if (baseline.uint("base") != base or through < base) return error.ProtocolError;
        _ = valueBool(baseline.field("truncated") orelse return error.ProtocolError) orelse return error.ProtocolError;
        const state = switch (snapshot.field("snapshot") orelse return error.ProtocolError) {
            .object => |value| value,
            else => return error.ProtocolError,
        };
        const session = switch (state.get("session") orelse return error.ProtocolError) {
            .string => |value| value,
            else => return error.ProtocolError,
        };
        const project = switch (state.get("project") orelse return error.ProtocolError) {
            .string => |value| value,
            else => return error.ProtocolError,
        };
        const owner = switch (state.get("owner") orelse return error.ProtocolError) {
            .string => |value| value,
            else => return error.ProtocolError,
        };
        if (!std.mem.eql(u8, session, &view.session) or !std.mem.eql(u8, project, expected_project) or
            !std.mem.eql(u8, owner, @tagName(view.owner))) return error.OwnerMismatch;
        if (valueU64(state.get("epoch") orelse return error.ProtocolError) != view.epoch) return error.StaleControl;
        _ = valueBool(state.get("busy") orelse return error.ProtocolError) orelse return error.ProtocolError;
        if (!(valueBool(state.get("attached") orelse return error.ProtocolError) orelse return error.ProtocolError)) return error.StaleControl;
        _ = valueBool(state.get("queue_paused") orelse return error.ProtocolError) orelse return error.ProtocolError;
        for ([_][]const u8{ "task", "queue_revision", "steering", "follow_up" }) |name| {
            _ = valueU64(state.get(name) orelse return error.ProtocolError) orelse return error.ProtocolError;
        }
        const kind = switch (state.get("task_kind") orelse return error.ProtocolError) {
            .string => |value| value,
            else => return error.ProtocolError,
        };
        _ = std.meta.stringToEnum(session_client.TaskKind, kind) orelse return error.ProtocolError;
        switch (state.get("previews") orelse return error.ProtocolError) {
            .array => {},
            else => return error.ProtocolError,
        }
        const scratch = try Client.init(self.a, self.io, null, self.mode, self.launcher, self.root);
        defer scratch.deinit();
        scratch.epoch = view.epoch;
        scratch.session = view.session;
        try scratch.adoptSnapshot(&snapshot);
        try scratch.adoptHistory(&baseline, true);
        view.project = try self.a.dupe(u8, project);
        try progressWait(@ptrCast(self));
        if (self.wait_cancel) |cancel| if (cancel.isRequested()) return error.Canceled;
        try view.stream.?.checkRunning();
    }

    /// Commit one candidate: only now is the previous view released. Its socket
    /// EOF is what revokes the old controller epoch on the owner side.
    fn adoptView(self: *Client, view: *Candidate) void {
        self.closeStream();
        self.stream = view.stream;
        self.stream_expected = view.stream != null;
        self.cache_floor = 0;
        view.stream = null;
        self.clearPending();
        if (self.conn) |*previous| previous.close();
        self.conn = view.conn;
        self.session = view.session;
        if (self.view_project) |project| self.a.free(project);
        self.view_project = view.project;
        view.project = null;
        self.epoch = view.epoch;
        self.cursor = 0;
        self.need_history = true;
        self.dirty = true;
        // A different session identity invalidates every cached owner field.
        self.cache.subagents.deinitOwned(self.a);
        self.cache = .{};
        self.rebuild();
    }

    /// Attach the endpoint of one worker and take write control. Typed control
    /// outcomes survive; any dial/protocol failure of the new view is a
    /// transport failure (the old view was already untouched).
    fn joinWorker(self: *Client, endpoint: []const u8, id: ?ids.Id, takeover: bool, project: []const u8) !void {
        const conn = unix.connect(self.a, endpoint, self.uid, self.waitFor(join_timeout_ms)) catch |err| return switch (err) {
            error.Canceled, error.OutOfMemory => err,
            else => transport(err),
        };
        var view = self.openController(conn, id, takeover, null) catch |err| return switch (err) {
            error.Busy, error.StaleControl, error.SessionNotFound, error.ProtocolMismatch, error.Canceled, error.OutOfMemory => err,
            else => transport(err),
        };
        errdefer view.deinit(self.a);
        self.completeCandidate(&view, endpoint, project) catch |err| return switch (err) {
            error.Canceled, error.OutOfMemory => err,
            else => transport(err),
        };
        self.adoptView(&view);
    }

    /// Only failure of the initial controller dial can prove an endpoint gone.
    /// Once connected, no greeting, attach, watch or baseline failure can
    /// authorize creation of a second owner.
    fn attachEndpoint(self: *Client, record: *const registry.Record, id: ids.Id, takeover: bool) !AttachStage {
        const conn = unix.connect(self.a, record.endpoint, self.uid, self.waitFor(join_timeout_ms)) catch |err| return switch (err) {
            error.Canceled, error.OutOfMemory => err,
            else => dialStage(err),
        };
        var view = self.openController(conn, id, takeover, record) catch |err| return switch (err) {
            error.Busy, error.StaleControl => .busy,
            error.ProtocolMismatch => .outdated,
            error.Canceled, error.OutOfMemory => return err,
            else => .unknown,
        };
        self.completeCandidate(&view, record.endpoint, record.project) catch |err| {
            view.deinit(self.a);
            return switch (err) {
                error.Canceled, error.OutOfMemory => err,
                else => .unknown,
            };
        };
        self.adoptView(&view);
        return .attached;
    }

    /// Publish one owner endpoint this launcher really owns. A failure closes
    /// that worker: an unindexed owner is never left behind.
    fn publishOwned(self: *Client, record: registry.Record) !void {
        try self.published.ensureUnusedCapacity(self.a, 1);
        const project = try self.a.dupe(u8, record.project);
        errdefer self.a.free(project);
        const endpoint = try self.a.dupe(u8, record.endpoint);
        errdefer self.a.free(endpoint);
        const reg = try self.ensureRegistry();
        try reg.register(record);
        self.published.appendAssumeCapacity(.{ .id = record.id, .project = project, .endpoint = endpoint });
    }

    fn ownsAnyWorker(self: *const Client) bool {
        return self.published.items.len != 0;
    }

    fn ownsSession(self: *const Client, id: ?ids.Id) bool {
        const target = id orelse return false;
        for (self.published.items) |entry| {
            if (std.mem.eql(u8, &entry.id, &target)) return true;
        }
        return false;
    }

    /// Retire this launcher's locator after its worker is gone. A complete
    /// checkpoint keeps the durable locator (liveness is still only the endpoint
    /// probe), and an entry already published by a later owner_instance or
    /// generation is never rewritten or removed by this one.
    fn retirePublished(self: *Client, entry: Published) void {
        const reg = if (self.reg) |*value| value else return;
        var record = (reg.resolve(self.a, entry.id, entry.project) catch return) orelse return;
        defer registry.freeRecord(self.a, &record);
        if (!std.mem.eql(u8, record.endpoint, entry.endpoint)) return;
        if (hasCheckpoint(self.a, self.io, entry.project, entry.id)) return;
        reg.unpublish(entry.id, entry.project) catch {};
    }

    fn retireAllPublished(self: *Client) void {
        for (self.published.items) |entry| self.retirePublished(entry);
        for (self.published.items) |entry| {
            self.a.free(entry.project);
            self.a.free(entry.endpoint);
        }
        self.published.clearRetainingCapacity();
    }

    fn forgetPublished(self: *Client, id: ids.Id) void {
        var index: usize = 0;
        while (index < self.published.items.len) {
            if (!std.mem.eql(u8, &self.published.items[index].id, &id)) {
                index += 1;
                continue;
            }
            const entry = self.published.items[index];
            self.retirePublished(entry);
            self.a.free(entry.project);
            self.a.free(entry.endpoint);
            _ = self.published.orderedRemove(index);
        }
    }

    /// Create one foreground-owned worker and publish its locator. Used by the
    /// ordinary foreground launcher and by an explicit history resume that must
    /// not touch the local view until it is really attached.
    fn startOwnedWorker(self: *Client, project: []const u8, resume_id: ?ids.Id, restore_selection: ?ids.Id) !registry.Record {
        const workers = try self.ensureWorkers();
        const record = workers.create(.{
            .project = project,
            .owner = .foreground,
            .@"resume" = resume_id,
            .restore_selection = restore_selection,
            .auto_refresh_models = self.auto_refresh,
        }) catch |err| {
            // The management-UI aliases (Busy/SessionNotFound) are for an
            // implicit "run in this project" start. An explicit resume must
            // surface the real refusal instead of a generic not-found.
            if (resume_id == null) return switch (err) {
                error.SessionInUse => error.Busy,
                error.ResumeNotFound, error.InvalidResumeLength, error.UnsafeResumeFile, error.ResumeReadOnly => error.SessionNotFound,
                else => err,
            };
            return err;
        };
        self.publishOwned(record) catch |err| {
            workers.close(record.id, record.project) catch {};
            return err;
        };
        return record;
    }

    fn connectDaemonControl(self: *Client) !void {
        const dir = try self.runtimeDirectory();
        const path = try dir.join(self.a, control_socket);
        defer self.a.free(path);
        const conn = unix.connect(self.a, path, self.uid, self.waitFor(quick_timeout_ms)) catch |err| {
            return transport(err);
        };
        self.control = conn;
        // From here the stored connection owns the descriptor exactly once.
        errdefer self.closeControl();
        // The daemon socket is part of the same IPC version. A v1 daemon rejects
        // this v4 greeting (or answers a v1 envelope), so it is refused here
        // before any create/list/attach command is sent.
        var hello = try self.request(.hello);
        defer hello.deinit();
        var greeting = self.controlExchange(&hello, quick_timeout_ms) catch |err| return switch (err) {
            error.OutOfMemory, error.Canceled => err,
            else => error.ProtocolMismatch,
        };
        defer greeting.deinit();
        if (greeting.uint("protocol") != protocol.version) return error.ProtocolMismatch;
        if (!greeting.flag("daemon", false)) return error.ProtocolMismatch;
    }

    fn worksFromDaemon(self: *const Client) bool {
        return self.mode == .connect;
    }

    /// Create the session this launcher owns (foreground worker) or ask the
    /// daemon to create one (connect mode). Only explicit user actions reach it.
    fn ensureSession(self: *Client) !void {
        if (self.conn != null) return;
        if (self.worksFromDaemon()) {
            var req = try self.controlRequest(.create);
            defer req.deinit();
            try req.put("project", self.launcher);
            try req.put("auto_refresh_models", self.auto_refresh);
            var resp = try req.exchange(join_timeout_ms);
            defer resp.deinit();
            const endpoint = resp.text("endpoint") orelse return error.ProtocolError;
            // The envelope already owns `id`; the session identity travels as
            // `session`. Never treat the reply envelope id as the session.
            const raw = resp.text("session") orelse return error.ProtocolError;
            if (raw.len != 32) return error.ProtocolError;
            const id: ids.Id = raw[0..32].*;
            if (!ids.valid(id)) return error.ProtocolError;
            try self.joinWorker(endpoint, id, true, self.launcher);
            return;
        }
        // The foreground owner publishes its endpoint so `/ls`, SSH and
        // `--attach` can discover it; a failed publication closes it again.
        const record = try self.startOwnedWorker(self.launcher, null, null);
        try self.joinWorker(record.endpoint, record.id, true, record.project);
    }

    /// `hello`-verified readiness probe used before an attach decision. Liveness
    /// is never inferred from the index, a pid or a marker.
    fn probeEndpoint(self: *Client, endpoint: []const u8, id: ids.Id) bool {
        const greeting = registry.helloEndpoint(self.a, self.io, self.uid, endpoint, quick_timeout_ms) catch return false;
        if (!std.mem.eql(u8, &greeting.session, &id)) return false;
        return greeting.pid == greeting.peer_pid and greeting.protocol == protocol.version;
    }

    /// One complete, bounded checkpoint in `project`. Read-only: no writer lock is
    /// taken here and nothing is created, so the original `.resume-lock` inode
    /// stays the only execution authority.
    fn hasCheckpoint(a: std.mem.Allocator, io: std.Io, project: []const u8, id: ids.Id) bool {
        var root = fs.Root.open(a, io, project) catch return false;
        defer root.deinit();
        var lease = resume_store.Lease.open(&root, id, false) catch return false;
        defer lease.deinit();
        const bytes = lease.load(&root) catch return false;
        defer a.free(bytes);
        return bytes.len != 0;
    }

    fn controlRequest(self: *Client, op: protocol.Op) !Request {
        if (self.control == null) try self.connectDaemonControl();
        var req = try self.request(op);
        req.target = .control;
        return req;
    }

    /// Route one settings-related request without spawning or registering a
    /// session. A live worker gets the control epoch; a --connect launcher with
    /// no worker sends the setup op over the control connection with the
    /// launcher project and no epoch; anything else has no owner to ask.
    fn trySettingsRequest(self: *Client, op: protocol.Op) !?Request {
        if (self.conn != null) {
            var req = try self.request(op);
            errdefer req.deinit();
            try req.put("epoch", self.epoch);
            return req;
        }
        if (!self.worksFromDaemon()) return null;
        var req = try self.controlRequest(op);
        errdefer req.deinit();
        try req.put("project", self.launcher);
        return req;
    }

    /// A settings callback may start the local foreground worker. --connect
    /// never creates or registers an empty session just to change a setting.
    fn settingsRequest(self: *Client, op: protocol.Op) !Request {
        if (self.conn == null and !self.worksFromDaemon()) try self.ensureSession();
        return (try self.trySettingsRequest(op)) orelse error.Unavailable;
    }

    /// Send one request over the daemon control socket. The framing/envelope is
    /// identical to the worker protocol, only the socket differs.
    fn controlExchange(self: *Client, req: *Request, timeout_ms: u32) !Response {
        const bytes = try req.out.finish();
        defer {
            std.crypto.secureZero(u8, bytes);
            self.a.free(bytes);
        }
        const conn = if (self.control) |*value| value else return error.Unavailable;
        conn.writeFrame(bytes, self.waitFor(timeout_ms)) catch |err| {
            self.closeControl();
            return transport(err);
        };
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const frame = conn.readFrame(self.waitFor(timeout_ms)) catch |err| switch (err) {
                error.Timeout => {
                    if (attempt < 3) continue;
                    self.closeControl();
                    return error.Transport;
                },
                else => {
                    self.closeControl();
                    return transport(err);
                },
            };
            const payload = frame orelse {
                self.closeControl();
                return error.Transport;
            };
            defer self.a.free(payload);
            var resp = parseObject(self.a, payload) catch |err| {
                self.closeControl();
                return err;
            };
            errdefer resp.deinit();
            const version = resp.uint("v") orelse return error.ProtocolError;
            if (version != protocol.version) return error.ProtocolError;
            const id = resp.uint("id") orelse return error.ProtocolError;
            if (id != req.id) return error.ProtocolError;
            const ok = resp.flag("ok", false);
            if (!ok) return wireError(protocol.codeFromName(resp.text("err") orelse "internal"));
            return resp;
        }
    }

    // -- management --------------------------------------------------------

    fn manageFn(context: *anyopaque, a: std.mem.Allocator, options: session_client.Manage) anyerror!session_client.Outcome {
        const self = fromContext(context);
        return switch (options) {
            .saved_sessions => self.manageSavedSessions(a),
            .@"resume" => |id| self.manageResume(a, id),
            .list => |args| self.manageList(a, args.running_only, args.page),
            .cd => |path| self.manageCd(path),
            .attach => |args| self.manageAttach(args.id, args.takeover),
            .detach => self.manageDetach(),
            .exit => .{ .exit = true },
            .close => |args| self.manageClose(args.id, args.force),
        };
    }

    fn manageSavedSessions(self: *Client, a: std.mem.Allocator) !session_client.Outcome {
        var root = try fs.Root.open(a, self.io, self.launcher);
        defer root.deinit();
        return .{ .saved_sessions = try resume_store.list(&root, a) };
    }

    fn manageResume(self: *Client, a: std.mem.Allocator, text: []const u8) !session_client.Outcome {
        if (text.len != 32) return error.SessionNotFound;
        const id: ids.Id = text[0..32].*;
        if (!ids.valid(id)) return error.SessionNotFound;
        if (self.conn != null) if (self.session) |current| if (self.view_project) |project| {
            if (std.mem.eql(u8, &current, &id) and std.mem.eql(u8, project, self.launcher)) return .{ .notice = try a.dupe(u8, "Already attached") };
        };
        // Reserve the one caller-owned result before registry or filesystem I/O.
        const notice = try a.dupe(u8, session_client.restored_notice);
        errdefer a.free(notice);
        const reg = try self.ensureRegistry();
        var record = try reg.resolve(self.a, id, self.launcher);
        if (record) |*found| {
            defer registry.freeRecord(self.a, found);
            if (try self.attachRecorded(found, id, false)) return .{ .switched = true, .notice = notice };
        }
        if (!hasCheckpoint(self.a, self.io, self.launcher, id)) return error.SessionNotFound;
        try self.resumeSession(self.launcher, id);
        return .{ .switched = true, .notice = notice };
    }

    fn manageList(self: *Client, a: std.mem.Allocator, running_only: bool, page: usize) !session_client.Outcome {
        const reg = try self.ensureRegistry();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        const records = reg.list(a, running_only, page) catch |err| switch (err) {
            error.FileNotFound => &.{},
            error.TooManySessions => return error.Unavailable,
            else => return err,
        };
        defer if (records.len != 0) registry.freeRecords(a, records);
        self.snap.running_sessions = records.len;

        if (records.len == 0) {
            try out.appendSlice(a, "no sessions");
        } else {
            const header = if (page == 0)
                try std.fmt.allocPrint(a, "{d} session(s)\n", .{records.len})
            else
                try std.fmt.allocPrint(a, "{d} session(s), page {d}\n", .{ records.len, page + 1 });
            defer a.free(header);
            try out.appendSlice(a, header);
        }
        for (records, 0..) |record, index| {
            if (out.items.len >= max_listing_bytes) break;
            const project = record.project[0..@min(record.project.len, 64)];
            const line = if (index + 1 == records.len)
                try std.fmt.allocPrint(a, "{s}  {s}  {s}  {s}", .{ record.id, @tagName(record.owner), record.state, project })
            else
                try std.fmt.allocPrint(a, "{s}  {s}  {s}  {s}\n", .{ record.id, @tagName(record.owner), record.state, project });
            defer a.free(line);
            const room = max_listing_bytes - out.items.len;
            try out.appendSlice(a, line[0..@min(line.len, room)]);
        }
        return .{ .listing = try out.toOwnedSlice(a) };
    }

    /// `/cd` only changes the launcher after the canonical directory is proven
    /// usable; the current view is released (never canceled) afterwards.
    fn manageCd(self: *Client, path: []const u8) !session_client.Outcome {
        if (path.len == 0 or path.len > 4096) return error.InvalidPath;
        if (std.mem.findScalar(u8, path, 0) != null) return error.InvalidPath;
        const resolved = try self.resolveDirectory(path);
        defer self.a.free(resolved);
        // Prove the canonical directory is accessible before changing anything.
        var dir = std.Io.Dir.openDirAbsolute(self.io, resolved, .{}) catch return error.InvalidPath;
        dir.close(self.io);
        Client.detachFn(@ptrCast(self));
        self.a.free(self.launcher);
        self.launcher = try self.a.dupe(u8, resolved);
        self.session = null;
        self.cache.subagents.deinitOwned(self.a);
        self.cache = .{};
        self.dirty = true;
        // The launcher readiness belongs to the new directory's setup owner, so
        // `/cd` in --connect must not fall back to the old project's state.
        if (self.worksFromDaemon()) self.refreshSettings();
        self.rebuild();
        return .{ .notice = try std.fmt.allocPrint(self.a, "Launcher directory: {s}", .{resolved}) };
    }

    fn resolveDirectory(self: *Client, path: []const u8) ![]u8 {
        const absolute = if (std.fs.path.isAbsolute(path))
            try self.a.dupe(u8, path)
        else
            try std.fs.path.join(self.a, &.{ self.launcher, path });
        defer self.a.free(absolute);
        // Canonicalise below the launcher root, allowing anything absolute: the
        // worker gets the real path, never a shell string.
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, absolute, self.a) catch return error.InvalidPath;
        defer self.a.free(canonical);
        return self.a.dupe(u8, canonical);
    }

    /// `/attach` and `--attach`: prefer the launcher project, then the unique
    /// cross-project entry. A live owner is attached directly, a confirmed-dead
    /// endpoint with a complete checkpoint is resumed into a new worker, and an
    /// unreachable or foreign owner refuses instead of starting a second writer.
    fn attachSession(self: *Client, id: ids.Id, takeover: bool) !session_client.Outcome {
        // Re-attaching to the session already on screen is a no-op (only
        // `--takeover` re-establishes the same control deliberately).
        if (!takeover) if (self.conn != null) if (self.session) |current| {
            if (std.mem.eql(u8, &current, &id)) return .{ .notice = try self.a.dupe(u8, "Already attached") };
        };

        const reg = try self.ensureRegistry();
        var record: ?registry.Record = try reg.resolve(self.a, id, self.launcher);
        if (record == null) record = try reg.resolve(self.a, id, null);
        if (record == null) {
            // No index entry: only this launcher project's own checkpoint may
            // locate the history. A missing one keeps the current view as is.
            if (!hasCheckpoint(self.a, self.io, self.launcher, id)) return error.SessionNotFound;
            return self.resumeForAttach(self.launcher, id);
        }
        var found = record.?;
        defer registry.freeRecord(self.a, &found);

        const notice = try self.a.dupe(u8, "Attached");
        const attached = self.attachRecorded(&found, id, takeover) catch |err| {
            self.a.free(notice);
            return err;
        };
        if (attached) return .{ .switched = true, .notice = notice };
        self.a.free(notice);
        if (!hasCheckpoint(self.a, self.io, found.project, id)) return error.SessionNotFound;
        const project = try self.a.dupe(u8, found.project);
        defer self.a.free(project);
        return self.resumeForAttach(project, id);
    }

    /// A false result means the endpoint is confirmed gone. The caller owns a
    /// preallocated notice, and retains it across a possible checkpoint restore.
    fn attachRecorded(self: *Client, found: *const registry.Record, id: ids.Id, takeover: bool) !bool {
        return switch (try self.attachEndpoint(found, id, takeover)) {
            .attached => true,
            .busy => error.Busy,
            .unknown => error.Unavailable,
            .outdated => error.ProtocolMismatch,
            .gone => false,
        };
    }

    fn resumeForAttach(self: *Client, project: []const u8, id: ids.Id) !session_client.Outcome {
        const notice = try self.a.dupe(u8, session_client.restored_notice);
        errdefer self.a.free(notice);
        try self.resumeSession(project, id);
        return .{ .switched = true, .notice = notice };
    }

    /// Restore one history into a brand-new worker without submitting anything.
    /// The `.resume-lock` inside that project stays the final authority: a busy
    /// lease refuses the resume and leaves the current view untouched.
    fn resumeSession(self: *Client, project: []const u8, id: ids.Id) !void {
        if (self.worksFromDaemon()) {
            var req = try self.controlRequest(.create);
            defer req.deinit();
            try req.put("project", project);
            try req.put("auto_refresh_models", self.auto_refresh);
            try req.put("resume", id[0..]);
            var resp = try req.exchange(join_timeout_ms);
            defer resp.deinit();
            const endpoint = resp.text("endpoint") orelse return error.ProtocolError;
            const raw = resp.text("session") orelse return error.ProtocolError;
            if (raw.len != 32) return error.ProtocolError;
            const session: ids.Id = raw[0..32].*;
            if (!ids.valid(session) or !std.mem.eql(u8, &session, &id)) return error.ProtocolError;
            try self.joinWorker(endpoint, id, false, project);
            return;
        }
        // Local mode keeps the same ownership rule as `--resume`: this launcher
        // owns the restored worker and publishes its locator.
        const record = try self.startOwnedWorker(project, id, null);
        self.joinWorker(record.endpoint, record.id, false, record.project) catch |err| {
            if (self.workers) |*workers| {
                workers.close(record.id, record.project) catch {};
            }
            return err;
        };
    }

    fn manageAttach(self: *Client, id_text: []const u8, takeover: bool) !session_client.Outcome {
        if (id_text.len != 32) return error.SessionNotFound;
        const id: ids.Id = id_text[0..32].*;
        if (!ids.valid(id)) return error.SessionNotFound;
        return self.attachSession(id, takeover);
    }

    fn manageDetach(self: *Client) !session_client.Outcome {
        Client.detachFn(@ptrCast(self));
        return .{ .notice = try self.a.dupe(u8, "Detached; the session keeps running") };
    }

    fn manageClose(self: *Client, id_text: []const u8, force: bool) !session_client.Outcome {
        if (id_text.len != 32) return error.SessionNotFound;
        const id: ids.Id = id_text[0..32].*;
        if (!ids.valid(id)) return error.SessionNotFound;

        // 1. The session on this connection: the owner decides about a busy task
        //    and its epoch must authorize this very controller.
        if (self.conn != null) if (self.session) |current| {
            if (std.mem.eql(u8, &current, &id)) {
                var req = try self.request(.close);
                defer req.deinit();
                try req.put("epoch", self.epoch);
                try req.put("force", force);
                var resp = try req.exchange(finish_timeout_ms);
                defer resp.deinit();
                if (!resp.flag("accepted", false)) return error.Busy;
                self.loseView();
                self.session = null;
                self.forgetPublished(id);
                self.rebuild();
                return .{ .notice = try self.a.dupe(u8, "Session closed and saved") };
            }
        };

        // A worker this launcher owns but this view does not show: whether its
        // task is busy cannot be confirmed atomically from here, so closing it
        // is always an explicit confirmation. Nothing is probed, stopped,
        // cancelled or unpublished before the operator asks for `--force`.
        if (self.ownsSession(id) and !force) {
            return .{ .notice = try std.fmt.allocPrint(self.a, "Closing an owned session outside this view requires /close {s} --force", .{&id}) };
        }

        // 2. A worker this launcher owns: stop exactly that process, never a
        //    cached pid and never somebody else's endpoint.
        if (self.workers) |*workers| {
            if (workers.isAlive(id)) {
                const project = self.publishedProject(id);
                workers.close(id, project) catch |err| return err;
                self.forgetPublished(id);
                return .{ .notice = try self.a.dupe(u8, "Session closed and saved") };
            }
        }

        const reg = try self.ensureRegistry();
        var record = (try reg.resolve(self.a, id, self.launcher)) orelse (try reg.resolve(self.a, id, null)) orelse return error.SessionNotFound;
        defer registry.freeRecord(self.a, &record);
        // 3. A daemon-owned session is closed by its owner through the control
        //    socket. A daemon that did not create this worker (or no longer runs)
        //    falls through to the endpoint path instead of claiming success.
        if (record.owner == .daemon) {
            // Managed by this launcher's daemon rather than by the worker's own
            // control channel: a busy task cannot be checked atomically here, so
            // the stop is confirmed first and nothing is asked of the daemon.
            if (!force) return .{ .notice = try std.fmt.allocPrint(self.a, "Closing an owned session outside this view requires /close {s} --force", .{&id}) };
            var handled = true;
            self.closeViaDaemon(id, force) catch |err| switch (err) {
                error.Busy => return error.Busy,
                error.SessionNotFound, error.Transport, error.Unavailable => handled = false,
                else => return err,
            };
            if (handled) return .{ .notice = try self.a.dupe(u8, "Session closed and saved") };
        }
        // 4. Another foreground owner: attach control on a fresh connection
        //    first. An occupied console is refused; its process is never killed.
        try self.closeViaEndpoint(&record, id, force);
        if (self.session) |current| if (std.mem.eql(u8, &current, &id)) {
            Client.detachFn(@ptrCast(self));
            self.session = null;
            self.rebuild();
        };
        return .{ .notice = try self.a.dupe(u8, "Session closed and saved") };
    }

    fn publishedProject(self: *Client, id: ids.Id) ?[]const u8 {
        for (self.published.items) |entry| {
            if (std.mem.eql(u8, &entry.id, &id)) return entry.project;
        }
        return null;
    }

    /// Ask the daemon to close one of its own sessions. `not_found` falls through
    /// to the endpoint path because a previous daemon generation may still be
    /// recorded while this service never created that worker.
    fn closeViaDaemon(self: *Client, id: ids.Id, force: bool) !void {
        var req = try self.controlRequest(.close);
        defer req.deinit();
        try req.put("session", id[0..]);
        try req.put("force", force);
        var resp = try req.exchange(finish_timeout_ms);
        defer resp.deinit();
        if (resp.flag("accepted", false)) return;
        const reason = resp.text("reason") orelse "";
        if (std.mem.eql(u8, reason, "busy")) return error.Busy;
        return error.SessionNotFound;
    }

    /// Close a session owned by another foreground launcher: take control on a
    /// dedicated connection (no takeover, so an attached console refuses), then
    /// ask that owner to cancel/join/save and exit.
    fn closeViaEndpoint(self: *Client, record: *const registry.Record, id: ids.Id, force: bool) !void {
        const conn = unix.connect(self.a, record.endpoint, self.uid, self.waitFor(join_timeout_ms)) catch |err| return switch (err) {
            error.Canceled, error.OutOfMemory => err,
            else => transport(err),
        };
        var view = self.openController(conn, id, false, record) catch |err| return switch (err) {
            error.Busy, error.StaleControl => error.Busy,
            error.SessionNotFound, error.Canceled, error.OutOfMemory => err,
            else => transport(err),
        };
        defer view.conn.close();
        var req = try self.request(.close);
        defer req.deinit();
        try req.put("epoch", view.epoch);
        try req.put("force", force);
        var resp = try self.exchangeOn(&view.conn, &req, finish_timeout_ms);
        defer resp.deinit();
        if (!resp.flag("accepted", false)) return error.Busy;
    }

    // -- UI settings callbacks --------------------------------------------

    fn currentFn(context: *anyopaque) tui.Connection.State {
        return fromContext(context).state;
    }

    fn settingsCall(self: *Client, op: protocol.Op, timeout_ms: u32) !Response {
        var req = try self.settingsRequest(op);
        defer req.deinit();
        try self.applySettingsArgs(&req, op);
        var resp = try req.exchange(timeout_ms);
        errdefer resp.deinit();
        self.dirty = false;
        self.refreshSettings();
        self.refreshSnapshot();
        self.rebuild();
        return resp;
    }

    fn applySettingsArgs(self: *Client, req: *Request, op: protocol.Op) !void {
        _ = self;
        switch (op) {
            .poll_metadata => try req.put("wait", true),
            else => {},
        }
    }

    fn configureFn(context: *anyopaque, key: []const u8) anyerror!void {
        const self = fromContext(context);
        try self.login(null, key);
    }

    fn codexLoginFn(context: *anyopaque, action: codex_login.Action, generation: u64) anyerror!void {
        const self = fromContext(context);
        // Authentication belongs to an actual session owner, not daemon setup.
        if (self.conn == null) try self.ensureSession();
        var req = try self.settingsRequest(.codex_login);
        defer req.deinit();
        try req.put("action", @tagName(action));
        try req.put("generation", generation);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.refreshSnapshot();
        self.rebuild();
    }

    fn configureProviderFn(context: *anyopaque, provider: core_config.providers.Id, key: []const u8) anyerror!void {
        const self = fromContext(context);
        try self.login(provider.slug(), key);
    }

    fn login(self: *Client, provider: ?[]const u8, key: []const u8) !void {
        if (key.len == 0) return error.InvalidInput;
        var req = try self.settingsRequest(.login);
        defer req.deinit();
        if (provider) |name| try req.put("provider", name);
        try req.put("key", key);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.refreshSnapshot();
        self.rebuild();
    }

    fn selectModelFn(context: *anyopaque, name: []const u8) anyerror!void {
        const self = fromContext(context);
        if (name.len == 0 or name.len > protocol.max_name) return error.InvalidInput;
        var req = try self.settingsRequest(.model_select);
        defer req.deinit();
        try req.put("name", name);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.refreshSnapshot();
        self.rebuild();
    }

    fn setEffortFn(context: *anyopaque, effort: shared.ReasoningEffort) anyerror!void {
        const self = fromContext(context);
        const name = effort.name() orelse return error.InvalidInput;
        var req = try self.settingsRequest(.effort);
        defer req.deinit();
        try req.put("value", name);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
    }

    fn cycleEffortFn(context: *anyopaque) anyerror!shared.ReasoningEffort {
        const self = fromContext(context);
        var req = try self.settingsRequest(.cycle_effort);
        defer req.deinit();
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
        const value = resp.text("value") orelse return error.ProtocolError;
        return shared.ReasoningEffort.fromName(value);
    }

    fn preferenceFn(context: *anyopaque, key: preferences.Key, value: ?u32) anyerror!void {
        const self = fromContext(context);
        var req = try self.settingsRequest(.preference);
        defer req.deinit();
        try req.put("key", @tagName(key));
        if (value) |number| try req.put("value", number);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
    }

    fn settingFn(context: *anyopaque, setting: tui.Connection.Setting, enabled: bool) anyerror!void {
        const self = fromContext(context);
        var req = try self.settingsRequest(.setting);
        defer req.deinit();
        try req.put("key", @tagName(setting));
        try req.put("value", enabled);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
    }

    fn decisionFn(context: *anyopaque, choice: decision_picker.Choice) anyerror!void {
        const self = fromContext(context);
        try self.helperSelection(.decision_model, choice);
    }

    fn imageFn(context: *anyopaque, choice: decision_picker.Choice) anyerror!void {
        const self = fromContext(context);
        try self.helperSelection(.image_model, choice);
    }

    /// One explicit proxy allowlist mutation. The callback carries the complete
    /// provider/raw-model id and the enable flag; this adapter never invents an
    /// endpoint and never sends proxy credentials or addresses on the wire.
    fn proxyFn(context: *anyopaque, name: []const u8, enabled: bool) anyerror!void {
        const self = fromContext(context);
        if (name.len == 0 or name.len > protocol.max_name) return error.InvalidInput;
        var req = try self.settingsRequest(.proxy_model);
        defer req.deinit();
        try req.put("name", name);
        try req.put("enabled", enabled);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
    }

    /// Explicit proxy endpoint mutation: one strict `value` string, or an empty
    /// string to clear. The endpoint is parsed locally first, so malformed input
    /// produces zero wire traffic. The request carries the existing controller
    /// epoch (worker) or project (setup control), never a new field.
    fn proxyAddressFn(context: *anyopaque, value: []const u8) anyerror!void {
        const self = fromContext(context);
        if (value.len > core_config.max_proxy_endpoint_bytes) return error.InvalidInput;
        _ = core_config.parseProxyEndpoint(value) catch return error.InvalidInput;
        var req = try self.settingsRequest(.proxy_address);
        defer req.deinit();
        try req.put("value", value);
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
    }

    fn helperSelection(self: *Client, op: protocol.Op, choice: decision_picker.Choice) !void {
        var req = try self.settingsRequest(op);
        defer req.deinit();
        switch (choice) {
            .off => try req.put("off", true),
            .model => |name| {
                try req.put("off", false);
                try req.put("name", name);
            },
        }
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
    }

    fn refreshModelsFn(context: *anyopaque) anyerror!void {
        const self = fromContext(context);
        var req = try self.settingsRequest(.refresh_models);
        defer req.deinit();
        var resp = try req.exchange(quick_timeout_ms);
        defer resp.deinit();
        self.dirty = true;
        self.refreshSettings();
        self.rebuild();
    }

    fn pollModelsFn(context: *anyopaque, wait: bool) bool {
        const self = fromContext(context);
        // Metadata polling is a background probe: it must never create or
        // register a session on either route.
        var req = (self.trySettingsRequest(.poll_metadata) catch return false) orelse return false;
        defer req.deinit();
        req.put("wait", wait) catch return false;
        var resp = req.exchange(quick_timeout_ms) catch return false;
        defer resp.deinit();
        const changed = resp.flag("changed", false);
        if (changed) {
            self.dirty = true;
            self.refreshSettings();
            self.rebuild();
        }
        return changed;
    }

    // -- foreground ownership ---------------------------------------------

    /// Ask the worker this launcher owns to cancel, join and save, then stop all
    /// created workers. Returns the saved session id when the owner confirmed a
    /// successful save; otherwise null (no resume line is printed).
    /// Owner-only final shutdown on an explicitly supplied connection: greet,
    /// verify this socket serves the very worker whose id we own, then accept
    /// only a truthful `saved` carrying that same identity. Never guesses.
    fn shutdownOwnedOn(self: *Client, conn: *unix.Connection, id: ids.Id) ?ids.Id {
        var hello = self.request(.hello) catch return null;
        defer hello.deinit();
        var greeting = self.exchangeOn(conn, &hello, join_timeout_ms) catch return null;
        defer greeting.deinit();
        const peer_pid: ?u64 = @intCast(conn.peer.pid);
        if (greeting.uint("pid") != peer_pid) return null;
        if (greeting.uint("protocol") != protocol.version) return null;
        const announced = greeting.text("session") orelse return null;
        if (!std.mem.eql(u8, announced, &id)) return null;
        var req = self.request(.shutdown) catch return null;
        defer req.deinit();
        var resp = self.exchangeOn(conn, &req, finish_timeout_ms) catch return null;
        defer resp.deinit();
        if (!resp.flag("saved", false)) return null;
        const saved_id = resp.text("session") orelse return null;
        if (!std.mem.eql(u8, saved_id, &id)) return null;
        return id;
    }

    fn finishForeground(self: *Client) ?ids.Id {
        var saved: ?ids.Id = null;
        // `shutdown` is owner-only, so it is only sent to a session this launcher
        // really created; an attached daemon session is never asked to exit.
        // A detached view has already released the socket, so its own published
        // locator is dialed once for the final ack and never adopted as a view.
        if (self.session) |id| {
            if (self.ownsSession(id)) {
                if (self.conn) |*conn| {
                    saved = self.shutdownOwnedOn(conn, id);
                } else {
                    for (self.published.items) |entry| {
                        if (!std.mem.eql(u8, &entry.id, &id)) continue;
                        var conn = unix.connect(self.a, entry.endpoint, self.uid, self.waitFor(join_timeout_ms)) catch break;
                        defer conn.close();
                        saved = self.shutdownOwnedOn(&conn, id);
                        break;
                    }
                }
            }
        }
        self.loseView();
        if (self.workers) |*workers| {
            workers.shutdown() catch {};
        }
        // Clean close keeps the durable locator of any complete checkpoint; an
        // empty session's entry is removed only while it still points at this
        // launcher's own endpoint.
        self.retireAllPublished();
        return saved;
    }
};

/// Per-mode request table. Every function copies before returning.
const table = session_client.VTable{
    .snapshot_fn = Client.snapshotFn,
    .submit_fn = Client.submitFn,
    .poll_fn = Client.pollFn,
    .buffered_fn = Client.bufferedFn,
    .acknowledge_fn = Client.acknowledgeFn,
    .acknowledge_range_fn = Client.acknowledgeRangeFn,
    .cancel_fn = Client.cancelFn,
    .cancel_clear_fn = Client.cancelClearFn,
    .set_confirming_fn = Client.setConfirmingFn,
    .approve_fn = Client.approveFn,
    .enqueue_fn = Client.enqueueFn,
    .withdraw_fn = Client.withdrawFn,
    .queue_resume_fn = Client.queueResumeFn,
    .manage_fn = Client.manageFn,
    .detach_fn = Client.detachFn,
};

fn kindName(kind: session_client.TaskKind) []const u8 {
    return @tagName(kind);
}

/// The epoch an item may be displayed under: the wire epoch when the codec
/// supplied one (and it matches), else the current control epoch. Null means
/// "drop this event": it belongs to a control epoch this view no longer owns.
fn itemEpoch(current: u64, decoded: *const protocol.DecodedEvent) ?u64 {
    if (decoded.epoch == 0) return current;
    if (decoded.epoch != current) return null;
    return decoded.epoch;
}

/// Merge the codec's independent provenance into the owned copy. Both are
/// lossy only in the safe direction: one truncated block list or an already
/// clipped payload can never be promoted to a complete final answer.
fn mergeFlags(item: *session_client.Item, decoded: *const protocol.DecodedEvent) void {
    item.display_truncated = item.display_truncated or decoded.display_truncated;
    item.canonical_complete = item.canonical_complete and decoded.canonical_complete;
}

// ---------------------------------------------------------------------------
// Settings sub-decoding
// ---------------------------------------------------------------------------

fn effortBit(effort: shared.ReasoningEffort) ?u8 {
    for (shared.activity.effort_order, 0..) |level, index| {
        if (level == effort) return @as(u8, 1) << @intCast(index);
    }
    return null;
}

fn parseEfforts(value: std.json.Value) shared.activity.EffortSet {
    var mask: u8 = 0;
    switch (value) {
        .array => |array| for (array.items) |entry| switch (entry) {
            .string => |name| if (effortBit(shared.ReasoningEffort.fromName(name))) |bit| {
                mask |= bit;
            },
            else => {},
        },
        .integer => |raw| if (raw >= 0 and raw <= 0x7f) {
            mask = @intCast(raw);
        },
        .string => |name| if (effortBit(shared.ReasoningEffort.fromName(name))) |bit| {
            mask |= bit;
        },
        else => {},
    }
    return .{ .mask = mask };
}

fn parseConfigured(value: std.json.Value) u8 {
    return switch (value) {
        .bool => |flag| if (flag) 0xff else 0,
        .integer => |mask| if (mask > 0) @intCast(@min(mask, @as(i64, 0xff))) else 0,
        .array => |array| blk: {
            var mask: u8 = 0;
            for (array.items) |entry| switch (entry) {
                .string => |name| if (std.meta.stringToEnum(core_config.providers.Id, name)) |id| {
                    mask |= @as(u8, 1) << @intCast(@backingInt(id));
                },
                else => {},
            };
            break :blk mask;
        },
        else => 0,
    };
}

fn parseLimits(value: std.json.Value, base: core_config.Limits) core_config.Limits {
    var limits = base;
    const object = switch (value) {
        .object => |map| map,
        else => return limits,
    };
    inline for (.{ "command_timeout_ms", "command_max_timeout_ms", "read_bytes", "output_bytes", "request_timeout_ms", "task_timeout_ms" }) |name| {
        if (object.get(name)) |entry| {
            if (valueU64(entry)) |number| @field(limits, name) = @intCast(@min(number, std.math.maxInt(u32)));
        }
    }
    if (object.get("compaction_enabled")) |entry| {
        if (valueBool(entry)) |flag| limits.compaction_enabled = flag;
    }
    return limits;
}

/// One accepted model row plus the inline flags the owner projects with it.
/// `official` and `disabled` are index-aligned with the accepted catalog, so
/// one accepted-row set produces both the models and their flags.
const ModelRow = struct {
    model: core_config.Model,
    official: bool = false,
    disabled: bool = false,
};

fn parseModelRow(value: std.json.Value) ?ModelRow {
    const object = switch (value) {
        .object => |map| map,
        else => return null,
    };
    const name = switch (object.get("name") orelse return null) {
        .string => |text| text,
        else => return null,
    };
    if (name.len == 0 or name.len > protocol.max_name) return null;
    var row: ModelRow = .{ .model = .{
        .name = name,
        .context_tokens = @intCast(@min(valueU64(object.get("context_tokens") orelse .{ .integer = 0 }) orelse 0, std.math.maxInt(u32))),
    } };
    if (object.get("protocol")) |entry| switch (entry) {
        .string => |text| if (std.meta.stringToEnum(ProtocolKind, text)) |kind| {
            row.model.protocol = kind;
        },
        else => {},
    };
    // Public capability number only. It is the owner's projected value, never
    // a user declaration, so it stays metadata-sourced rather than explicit.
    if (object.get("output_tokens")) |entry| if (valueU64(entry)) |tokens| {
        row.model.output_tokens = @intCast(@min(tokens, std.math.maxInt(u32)));
        row.model.output_source = .metadata;
    };
    row.official = valueBool(object.get("official") orelse .{ .bool = false }) orelse false;
    row.disabled = valueBool(object.get("disabled") orelse .{ .bool = false }) orelse false;
    return row;
}

const ModelSlot = enum { models, decision_models, image_models };

fn parseModels(a: std.mem.Allocator, next: *Pub, value: ?std.json.Value, slot: ModelSlot) !void {
    const array = switch (value orelse return) {
        .array => |items| items,
        else => return,
    };
    var used: usize = 0;
    for (array.items) |entry| {
        if (parseModelRow(entry) != null) used += 1;
    }
    if (used == 0) return;
    const models = try a.alloc(core_config.Model, used);
    errdefer a.free(models);
    var official: ?[]bool = null;
    errdefer if (official) |flags| a.free(flags);
    var disabled: ?[]bool = null;
    errdefer if (disabled) |flags| a.free(flags);
    if (slot == .models) {
        official = try a.alloc(bool, used);
        disabled = try a.alloc(bool, used);
    }
    var index: usize = 0;
    for (array.items) |entry| {
        const row = parseModelRow(entry) orelse continue;
        models[index] = row.model;
        if (official) |flags| flags[index] = row.official;
        if (disabled) |flags| flags[index] = row.disabled;
        index += 1;
    }
    switch (slot) {
        .models => {
            next.models = models;
            next.context_official = official.?;
            next.disabled = disabled.?;
        },
        .decision_models => next.decision_models = models,
        .image_models => next.image_models = models,
    }
}

/// Strict public proxy endpoint adoption. A legacy snapshot that omits BOTH
/// new fields keeps `proxy_configured` readable without inventing an endpoint.
/// When a field is present the pair must be complete and truthful: a bare host
/// (no scheme, credentials or path) plus a 1..65535 port, validated against the
/// canonical parser on its bracketed IPv6 form. A configured=false snapshot may
/// only carry null/0. The adopted string stays a window into the retained doc.
fn adoptProxyEndpoint(next: *Pub, address_value: ?std.json.Value, port_value: ?std.json.Value, configured: bool) void {
    if (address_value == null and port_value == null) return;
    const address: ?[]const u8 = switch (address_value orelse .null) {
        .string => |text| text,
        .null => null,
        else => return,
    };
    const number = valueU64(port_value orelse .{ .integer = 0 }) orelse return;
    if (number > std.math.maxInt(u16)) return;
    const port: u16 = @intCast(number);
    if (!configured) return;
    const host = address orelse return;
    if (host.len == 0 or host.len > 253 or port == 0) return;
    // Reusing the strict parser on `host:port` / `[IPv6]:port` rejects schemes,
    // credentials, paths and smuggled second ports without a second grammar.
    var buffer: [core_config.max_proxy_endpoint_bytes + 8]u8 = undefined;
    const text = if (std.mem.findScalar(u8, host, ':') != null)
        std.fmt.bufPrint(&buffer, "[{s}]:{d}", .{ host, port }) catch return
    else
        std.fmt.bufPrint(&buffer, "{s}:{d}", .{ host, port }) catch return;
    const endpoint = (core_config.parseProxyEndpoint(text) catch return) orelse return;
    if (endpoint.port != port or !std.mem.eql(u8, endpoint.address, host)) return;
    next.proxy_address = host;
    next.proxy_port = port;
}

/// Bounded proxy allowlist decode: non-empty name strings only, exact count so
/// the owned array is freed with its own length. Every name stays a window into
/// the retained settings document.
fn parseProxyModels(a: std.mem.Allocator, next: *Pub, value: ?std.json.Value) !void {
    const array = switch (value orelse return) {
        .array => |items| items,
        else => return,
    };
    var used: usize = 0;
    for (array.items) |entry| switch (entry) {
        .string => |name| used += @intFromBool(name.len != 0),
        else => {},
    };
    if (used == 0) return;
    const names = try a.alloc([]const u8, used);
    var index: usize = 0;
    for (array.items) |entry| switch (entry) {
        .string => |name| {
            if (name.len == 0) continue;
            names[index] = name;
            index += 1;
        },
        else => {},
    };
    next.proxy_models = names;
}

fn parseProviders(a: std.mem.Allocator, next: *Pub, value: ?std.json.Value) !void {
    const array = switch (value orelse return) {
        .array => |items| items,
        else => return,
    };
    if (array.items.len == 0) return;
    const providers = try a.alloc(picker_module.Provider, array.items.len);
    var used: usize = 0;
    for (array.items) |entry| {
        const provider: picker_module.Provider = switch (entry) {
            .string => |name| .{ .name = name },
            .object => |object| .{
                .name = switch (object.get("name") orelse continue) {
                    .string => |name| name,
                    else => continue,
                },
                .allow_custom = valueBool(object.get("allow_custom") orelse .{ .bool = false }) orelse false,
            },
            else => continue,
        };
        if (provider.name.len == 0) continue;
        providers[used] = provider;
        used += 1;
    }
    if (used == 0) {
        a.free(providers);
        return;
    }
    next.providers = providers[0..used];
}

// ---------------------------------------------------------------------------
// Entry point used by `daemon/entry.zig`
// ---------------------------------------------------------------------------

pub fn run(init: std.process.Init, options: cli.Options) !u8 {
    const a = init.gpa;
    const io = init.io;
    if (options.mode == .daemon or options.mode == .worker) return error.Unsupported;

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &buf) catch return error.Unavailable;
    const cwd = buf[0..cwd_len];
    const home = blk: {
        const map = init.environ_map;
        const value = map.get("HOME") orelse break :blk cwd;
        if (value.len == 0 or !std.fs.path.isAbsolute(value)) break :blk cwd;
        break :blk value;
    };
    // Worker projects and registry keys use the canonical path, while HOME
    // itself remains unchanged as the credentials/index root.
    var connect_root: ?fs.Root = if (options.mode == .connect) try fs.Root.open(a, io, home) else null;
    defer if (connect_root) |*root| root.deinit();
    const launcher = if (connect_root) |root| root.path else cwd;

    const client = try Client.init(a, io, init.environ_map, options.mode, launcher, home);
    defer client.deinit();
    // Any startup failure after a worker is published still releases it before
    // `deinit` runs: `deinit` only fails the owner stop, it never cancels a
    // live daemon-owned worker. LIFO keeps this cleanup ahead of `deinit`.
    errdefer {
        if (client.ownsAnyWorker()) _ = client.finishForeground();
    }
    client.auto_refresh = options.auto_refresh_models;

    switch (options.mode) {
        .foreground => {
            // One foreground-owned worker, published before the TUI can block on
            // it. A failed publication closes the worker again.
            const record = client.startOwnedWorker(client.launcher, options.resume_session, options.restore_selection) catch |err| {
                report(io, "thin: could not start the session worker", err);
                return err;
            };
            client.joinWorker(record.endpoint, record.id, true, record.project) catch |err| {
                report(io, "thin: could not attach the session worker", err);
                return err;
            };
        },
        .connect => {
            client.connectDaemonControl() catch |err| {
                report(io, "thin: no running thin --daemon service for this user", err);
                return err;
            };
            // Owner-reported setup readiness before the first frame, so the
            // launcher never claims "Not configured" for a working service.
            client.refreshSettings();
            client.rebuild();
        },
        .attach => {
            const id = options.attach_session orelse return error.InvalidArguments;
            // Same resolution as `/attach`: live owner, or a confirmed-dead
            // endpoint with a complete checkpoint. Never starts a daemon.
            var outcome = client.attachSession(id, options.takeover) catch |err| {
                report(io, "thin: could not attach that session", err);
                return err;
            };
            outcome.deinit(a);
        },
        else => return error.Unsupported,
    }

    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(a, io, &cancel);
    defer bridge.deinit();

    const code = blk: {
        const frontend = try @import("frontend.zig").Frontend.start(client);
        defer frontend.deinit(); // Join before foreground shutdown or Client teardown.
        const result = tui.run(a, io, frontend.connection(), &bridge, &cancel);
        break :blk try result;
    };

    if (client.ownsAnyWorker()) {
        // Foreground or a locally restored history: cancel/join/save and stop
        // every worker this frontend owns, then print the resume line.
        if (client.finishForeground()) |saved| {
            if (code == 0) {
                const line = @import("../app/resume_command.zig").format(a, saved) catch null;
                if (line) |text| {
                    defer a.free(text);
                    writeOut(io, text);
                }
            }
        }
    } else {
        // Pure view (daemon-owned session): release control only.
        Client.detachFn(@ptrCast(client));
    }
    return code;
}

fn report(io: std.Io, message: []const u8, err: anyerror) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}: {s}\n", .{ message, @errorName(err) }) catch return;
    writeErr(io, text);
}

fn writeOut(io: std.Io, bytes: []const u8) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch {};
}

// ---------------------------------------------------------------------------
// Tests: focused, offline, driven by a real AF_UNIX socketpair-style fixture.
// ---------------------------------------------------------------------------

// Preserve the fixtures' blocking sockets; production pairs are nonblocking.
// Connection.init only takes ownership, so raw Darwin pairs need SIGPIPE safety.

// Serve control frames until the client really asks for a snapshot. The
// communication task may interleave its own metadata probe. A real cancel
// marks settings dirty, so exactly one settings refresh precedes recovery.
// Every other op is a failure of this fixture, never something to ignore.

// Serve control frames until the client really sends a cancel. The
// communication task may interleave its own metadata probe.

// Read one watch frame exactly. The receiver keeps reading while a page is
// ACKed, so pages and ACK replies must be identified by content.

// Emit the same two initial pages a real watch sends, including a history row.

// Fake worker for the protocol-mismatch regression. The first connection
// answers like a v1 worker (a v1 envelope), the second closes without replying
// (a v1 worker's actual parse behaviour), the third is an exact v4 worker and
// proves the compatible path still adopts normally. `saw_v4` proves the client
// really sent v4 greetings, since `parseRequest` only accepts this version.

// One real written submit frame: its sequential envelope id and receipt nonce.

// A --connect launcher with only a control socket: no worker and no session.

// Parse one request the client actually wrote; the frame buffer is released.

// Assert the client wrote nothing else on this socket.

// Minimal view over a real owner `Connection`: only the fields this wire
// regression needs are overridden, everything else stays the Host's own.

// ---------------------------------------------------------------------------
// Tests: launcher/attach/close wiring (offline, no worker process is started).
// ---------------------------------------------------------------------------

// Parse one request the client wrote on an explicit connection.

// Assert the peer wrote nothing else.

// A private HOME/runtime/project so the registry and checkpoint helpers can be
// exercised without touching the real user directories.

// Real AF_UNIX listener: a bad hello must receive zero attach frames; every
// later failure is after a real attach and cannot become a cold restore.
