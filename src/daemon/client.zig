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

const Io = std.Io;
const Registry = registry.Registry;
const Workers = spawn.Workers;
/// Wire protocol id type used by `core/config.Model.protocol`.
const ProtocolKind = @TypeOf(@as(core_config.Model, undefined).protocol);

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
const AttachStage = enum { attached, busy, unknown, gone };

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
    const doc = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch return error.ProtocolError;
    errdefer doc.deinit();
    const object = switch (doc.value) {
        .object => |value| value,
        else => return error.ProtocolError,
    };
    if (object.count() > 64) return error.ProtocolError;
    return .{ .doc = doc, .object = object, .a = a };
}

test "response integers preserve u64 and reject coercion without trapping" {
    var response = try parseObject(std.testing.allocator,
        \\{"id":18446744073709551615,"large":9223372036854775808,"zero":0,"negative":-1,"fraction":1.5,"float":1.0,"exponent":1e3,"string":"1","overflow":18446744073709551616}
    );
    defer response.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), response.uint("id").?);
    try std.testing.expectEqual(@as(u64, 9223372036854775808), response.uint("large").?);
    try std.testing.expectEqual(@as(u64, 0), response.uint("zero").?);
    for ([_][]const u8{ "negative", "fraction", "float", "exponent", "string", "overflow" }) |field| {
        try std.testing.expect(response.uint(field) == null);
    }
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
    valid: bool = false,
    busy: bool = false,
    phase: ?r.State = null,
    task: u64 = 0,
    kind: session_client.TaskKind = .prompt,
    attached: bool = false,
    epoch: u64 = 0,
    /// The owner published an `epoch` field. Only an explicit value may revoke
    /// control; an absent field is "unknown", not "no controller".
    epoch_known: bool = false,
    pending: ?u64 = null,
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
    logging: bool = true,
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
    control: ?unix.Connection = null,
    session: ?ids.Id = null,
    epoch: u64 = 0,
    next_req: u64 = 0,

    /// One submission that may or may not have been accepted. Kept across a
    /// transport failure so an explicit re-submit reuses the same receipt.
    receipt: ?Receipt = null,
    /// Suppress the owner echo of the prompt this UI already rendered.
    suppress: ?struct { digest: [32]u8, armed: bool } = null,

    reg: ?Registry = null,
    workers: ?Workers = null,
    dir: ?unix.Directory = null,
    logging: bool = true,
    auto_refresh: bool = true,

    /// Display cursors for the ordered snapshot+delta stream.
    cursor: u64 = 0,
    need_history: bool = false,
    dirty: bool = true,
    poll_error: ?anyerror = null,

    /// Published projections with a stable address for the VTable.
    snap: session_client.Snapshot = .{},
    state: tui.Connection.State = baseState(),
    /// Ping-pong arenas: the published projection stays valid until the next
    /// rebuild, so the UI never reads freed wire memory.
    arenas: [2]std.heap.ArenaAllocator = undefined,
    arena_index: u1 = 0,

    cache: SnapshotCache = .{},
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
        self.* = .{
            .a = a,
            .io = io,
            .uid = @intCast(std.c.getuid()),
            .environ = environ,
            .mode = mode,
            .root = try a.dupe(u8, root),
            .launcher = try a.dupe(u8, launcher),
        };
        self.arenas[0] = std.heap.ArenaAllocator.init(a);
        self.arenas[1] = std.heap.ArenaAllocator.init(a);
        self.rebuild();
        return self;
    }

    pub fn deinit(self: *Client) void {
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
        return .{ .io = self.io, .timeout_ms = timeout_ms };
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
        self.clearPending();
        if (self.conn) |*conn| conn.close();
        self.conn = null;
        self.epoch = 0;
        self.cursor = 0;
        self.need_history = false;
        self.cache.valid = false;
        self.rebuild();
    }

    /// Control was taken over by another console: close only this view and fall
    /// back to the launcher. Owned foreground workers are untouched.
    fn revokeView(self: *Client) void {
        self.loseView();
        self.session = null;
        self.rebuild();
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
        self.snap = self.buildSnapshot(arena) catch self.snap;
        self.state = self.buildState(arena) catch self.state;
        self.arena_index = slot;
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
            .available = self.conn != null or switch (self.mode) {
                .foreground, .attach => true,
                .connect => self.control != null,
                else => false,
            },
            // Attachment is still only a worker connection with a control epoch.
            .attached = self.conn != null and self.epoch != 0,
            .busy = cache.valid and cache.busy,
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
        };
    }

    /// Pure projection of the cached owner reply plus public settings data. No
    /// pointer, no credential, no key and no native replay reaches the UI.
    fn buildState(self: *Client, arena: std.mem.Allocator) !tui.Connection.State {
        const cfg = &self.pubcfg;
        const cache = &self.cache;
        var state: tui.Connection.State = baseState();
        state.available = cfg.available and (self.conn != null or self.control != null);
        state.busy = cache.valid and cache.busy;
        state.session_label = if (cache.valid and cache.label_len != 0) try arena.dupe(u8, cache.label[0..cache.label_len]) else null;
        state.launcher_dir = try arena.dupe(u8, self.launcher);
        state.control_epoch = self.epoch;
        state.initial_context = if (cache.valid) cache.context else null;
        state.model = try arena.dupe(u8, cfg.model);
        state.session_id = self.session;
        state.models = try cloneModels(arena, cfg.models);
        state.model_providers = try arena.dupe(picker_module.Provider, cfg.providers);
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
        state.logging_enabled = cfg.logging;
        return state;
    }

    fn cloneModels(arena: std.mem.Allocator, models: []const core_config.Model) ![]core_config.Model {
        const copy = try arena.alloc(core_config.Model, models.len);
        for (models, 0..) |model, index| {
            copy[index] = model;
            copy[index].name = try arena.dupe(u8, model.name);
            copy[index].reasoning_effort = if (model.reasoning_effort) |value| try arena.dupe(u8, value) else null;
        }
        return copy;
    }

    // -- owner refresh -----------------------------------------------------

    fn refreshSnapshot(self: *Client) void {
        var req = self.request(.snapshot) catch return;
        defer req.deinit();
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
        cache.busy = get.flag(object, "busy");
        cache.phase = if (get.text(object, "phase")) |name| std.meta.stringToEnum(r.State, name) else null;
        cache.task = get.uint(object, "task") orelse 0;
        cache.kind = if (get.text(object, "task_kind")) |name| std.meta.stringToEnum(session_client.TaskKind, name) orelse .prompt else .prompt;
        cache.attached = get.flag(object, "attached");
        if (get.field(object, "epoch")) |value| if (valueU64(value)) |epoch| {
            cache.epoch = epoch;
            cache.epoch_known = true;
        };
        cache.pending = get.uint(object, "pending");
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
        self.cache = cache;
    }

    fn refreshSettings(self: *Client) void {
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
            break :resp_doc std.json.parseFromSlice(std.json.Value, self.a, bytes, .{ .allocate = .alloc_always }) catch return error.ProtocolError;
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
        next.logging = read.flag(view, "logging", next.logging);
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

        const stale = self.pubcfg;
        self.pubcfg = next;
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
        const base = resp.uint("base") orelse return error.ProtocolError;
        const entries = switch (resp.field("entries") orelse return error.ProtocolError) {
            .array => |array| array,
            else => return error.ProtocolError,
        };
        // A page from another control epoch is stale: drop it completely.
        const page = self.pageEpoch(&resp);
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
        for (entries.items) |entry| try self.pushEvent(entry);
        if (self.pending.items.len == before) return;
        for (0..self.pending.items.len - before) |offset| {
            const item = &self.pending.items[before + offset];
            item.history_replay = true;
            item.history_reset = offset == 0;
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
        if (self.pending.items.len >= max_pending) return;
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
        var decoded = protocol.decodeEvent(self.a, json) catch return;
        defer decoded.deinit();
        // A wire epoch is authority-bearing: it must match the controller epoch
        // this view holds, otherwise the event belongs to a replaced console.
        const epoch = itemEpoch(self.epoch, &decoded) orelse return;
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
            if (item.event == .finished) {
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
        self.adoptSnapshot(&resp) catch {};
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
    const Candidate = struct { conn: unix.Connection, session: ?ids.Id, epoch: u64 };

    /// Send one request over an explicitly supplied connection. A failure drops
    /// only that candidate; unlike the live path it never calls `loseView`.
    fn exchangeOn(self: *Client, conn: *unix.Connection, req: *Request, timeout_ms: u32) !Response {
        const bytes = try req.out.finish();
        defer self.a.free(bytes);
        conn.writeFrame(bytes, self.waitFor(timeout_ms)) catch |err| return transport(err);
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const frame = conn.readFrame(self.waitFor(timeout_ms)) catch |err| switch (err) {
                error.Timeout => {
                    if (attempt < 3) continue;
                    return error.Transport;
                },
                else => return transport(err),
            };
            const payload = frame orelse return error.Transport;
            defer self.a.free(payload);
            var resp = parseObject(self.a, payload) catch return error.ProtocolError;
            errdefer resp.deinit();
            const verdict = try validateEnvelope(&resp, req.id);
            return switch (verdict) {
                .ok => resp,
                .rejected => |code| return wireError(code),
            };
        }
    }

    /// Dial, greet and take write control on a candidate connection. The raw
    /// dial error is preserved so the caller can tell an absent listener from a
    /// merely unreachable or foreign owner.
    fn openController(self: *Client, endpoint: []const u8, id: ?ids.Id, takeover: bool) !Candidate {
        var conn = try unix.connect(self.a, endpoint, self.uid, self.waitFor(join_timeout_ms));
        errdefer conn.close();
        var session: ?ids.Id = null;
        {
            var req = try self.request(.hello);
            defer req.deinit();
            try req.put("view", "controller");
            var resp = try self.exchangeOn(&conn, &req, join_timeout_ms);
            defer resp.deinit();
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
            var resp = try self.exchangeOn(&conn, &req, join_timeout_ms);
            defer resp.deinit();
            epoch = resp.uint("epoch") orelse return error.ProtocolError;
            if (epoch == 0) return error.ProtocolError;
        }
        return .{ .conn = conn, .session = session, .epoch = epoch };
    }

    /// Commit one candidate: only now is the previous view released. Its socket
    /// EOF is what revokes the old controller epoch on the owner side.
    fn adoptView(self: *Client, view: *Candidate, fallback: ?ids.Id) void {
        self.clearPending();
        if (self.conn) |*previous| previous.close();
        self.conn = view.conn;
        self.session = view.session orelse fallback;
        self.epoch = view.epoch;
        self.cursor = 0;
        self.need_history = true;
        self.dirty = true;
        // A different session identity invalidates every cached owner field.
        self.cache = .{};
        self.rebuild();
    }

    /// Attach the endpoint of one worker and take write control. Typed control
    /// outcomes survive; any dial/protocol failure of the new view is a
    /// transport failure (the old view was already untouched).
    fn joinWorker(self: *Client, endpoint: []const u8, id: ?ids.Id, takeover: bool) !void {
        var view = self.openController(endpoint, id, takeover) catch |err| return switch (err) {
            error.Busy, error.StaleControl, error.SessionNotFound => err,
            else => transport(err),
        };
        self.adoptView(&view, id);
    }

    /// Attach a recorded endpoint, mapping the failure stage instead of
    /// collapsing everything into `Transport`.
    fn attachEndpoint(self: *Client, endpoint: []const u8, id: ids.Id, takeover: bool) AttachStage {
        var view = self.openController(endpoint, id, takeover) catch |err| return switch (err) {
            error.Busy, error.StaleControl => .busy,
            error.FileNotFound, error.ConnectionRefused, error.NotDir => .gone,
            else => .unknown,
        };
        self.adoptView(&view, id);
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
            .logging = self.logging,
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
        var conn = unix.connect(self.a, path, self.uid, self.waitFor(quick_timeout_ms)) catch |err| {
            return transport(err);
        };
        errdefer conn.close();
        self.control = conn;
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
            try req.put("logging", self.logging);
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
            try self.joinWorker(endpoint, id, true);
            return;
        }
        // The foreground owner publishes its endpoint so `/ls`, SSH and
        // `--attach` can discover it; a failed publication closes it again.
        const record = try self.startOwnedWorker(self.launcher, null, null);
        try self.joinWorker(record.endpoint, record.id, true);
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
            .list => |args| self.manageList(a, args.running_only, args.page),
            .cd => |path| self.manageCd(path),
            .attach => |args| self.manageAttach(args.id, args.takeover),
            .detach => self.manageDetach(),
            .exit => .{ .exit = true },
            .close => |args| self.manageClose(args.id, args.force),
        };
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
            return self.resumeSession(self.launcher, id);
        }
        var found = record.?;
        defer registry.freeRecord(self.a, &found);

        switch (self.attachEndpoint(found.endpoint, id, takeover)) {
            .attached => return .{ .switched = true, .notice = try self.a.dupe(u8, "Attached") },
            // An occupied console is an explicit refusal, never an implicit
            // takeover and never a reason to kill the existing owner.
            .busy => return error.Busy,
            // Timeout, permission, identity or protocol: the owner is merely
            // unreachable, so no second writer may start.
            .unknown => return error.Unavailable,
            .gone => {},
        }
        if (!hasCheckpoint(self.a, self.io, found.project, id)) return error.SessionNotFound;
        const project = try self.a.dupe(u8, found.project);
        defer self.a.free(project);
        return self.resumeSession(project, id);
    }

    /// Restore one history into a brand-new worker without submitting anything.
    /// The `.resume-lock` inside that project stays the final authority: a busy
    /// lease refuses the resume and leaves the current view untouched.
    fn resumeSession(self: *Client, project: []const u8, id: ids.Id) !session_client.Outcome {
        if (self.worksFromDaemon()) {
            var req = try self.controlRequest(.create);
            defer req.deinit();
            try req.put("project", project);
            try req.put("logging", self.logging);
            try req.put("auto_refresh_models", self.auto_refresh);
            try req.put("resume", id[0..]);
            var resp = try req.exchange(join_timeout_ms);
            defer resp.deinit();
            const endpoint = resp.text("endpoint") orelse return error.ProtocolError;
            const raw = resp.text("session") orelse return error.ProtocolError;
            if (raw.len != 32) return error.ProtocolError;
            const session: ids.Id = raw[0..32].*;
            if (!ids.valid(session) or !std.mem.eql(u8, &session, &id)) return error.ProtocolError;
            try self.joinWorker(endpoint, id, false);
            return .{ .switched = true, .notice = try self.a.dupe(u8, "Restored session history") };
        }
        // Local mode keeps the same ownership rule as `--resume`: this launcher
        // owns the restored worker and publishes its locator.
        const record = try self.startOwnedWorker(project, id, null);
        self.joinWorker(record.endpoint, record.id, false) catch |err| {
            if (self.workers) |*workers| {
                workers.close(record.id, record.project) catch {};
            }
            return err;
        };
        return .{ .switched = true, .notice = try self.a.dupe(u8, "Restored session history") };
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
        var view = self.openController(record.endpoint, id, false) catch |err| return switch (err) {
            error.Busy, error.StaleControl => error.Busy,
            error.SessionNotFound => error.SessionNotFound,
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
    // `--connect` has no project cwd of its own: its launcher root is HOME.
    const launcher = if (options.mode == .connect) home else cwd;

    const client = try Client.init(a, io, init.environ_map, options.mode, launcher, home);
    defer client.deinit();
    // Any startup failure after a worker is published still releases it before
    // `deinit` runs: `deinit` only fails the owner stop, it never cancels a
    // live daemon-owned worker. LIFO keeps this cleanup ahead of `deinit`.
    errdefer {
        if (client.ownsAnyWorker()) _ = client.finishForeground();
    }
    client.logging = options.logging;
    client.auto_refresh = options.auto_refresh_models;

    switch (options.mode) {
        .foreground => {
            // One foreground-owned worker, published before the TUI can block on
            // it. A failed publication closes the worker again.
            const record = client.startOwnedWorker(client.launcher, options.resume_session, options.restore_selection) catch |err| {
                report(io, "thin: could not start the session worker", err);
                return err;
            };
            client.joinWorker(record.endpoint, record.id, true) catch |err| {
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

    const code = try tui.run(a, io, client.connection(), &bridge, &cancel);

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

fn reportMessage(io: std.Io, message: []const u8) void {
    writeErr(io, message);
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

const testing = std.testing;

const Pair = struct {
    client: *Client,
    server: unix.Connection,

    fn deinit(self: *Pair) void {
        self.server.close();
        self.client.deinit();
    }

    fn closeServer(self: *Pair) void {
        self.server.close();
        self.server = unix.Connection.init(self.client.a, -1, .{ .pid = 0, .uid = 0, .gid = 0 });
    }

    /// The id the client will use for its very next request.
    fn nextId(self: *Pair) u64 {
        const id = self.client.next_req +% 1;
        return if (id == 0) 1 else id;
    }

    /// Write one reply frame with the given extra fields, then let the client
    /// read it. Single-threaded: the reply is queued before the client reads.
    fn reply(self: *Pair, id: u64, fields: []const u8) !void {
        const a = self.client.a;
        const bytes = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":true,{s}}}", .{ protocol.version, id, fields });
        defer a.free(bytes);
        try self.server.writeFrame(bytes, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    }

    fn replyError(self: *Pair, id: u64, code: []const u8) !void {
        const a = self.client.a;
        const bytes = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":{d},\"ok\":false,\"err\":\"{s}\"}}", .{ protocol.version, id, code });
        defer a.free(bytes);
        try self.server.writeFrame(bytes, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    }
};

fn pairOf(a: std.mem.Allocator) !Pair {
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(std.testing.io, &root_buf);
    const client = try Client.init(a, std.testing.io, null, .foreground, root_buf[0..n], root_buf[0..n]);
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds) != 0) {
        client.deinit();
        return error.SocketPairFailed;
    }
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.conn = unix.Connection.init(a, fds[0], peer);
    client.epoch = 5;
    return .{ .client = client, .server = unix.Connection.init(a, fds[1], peer) };
}

/// One real written submit frame: its sequential envelope id and receipt nonce.
const SubmitFrame = struct { id: u64, req: u64 };

fn readSubmitFrame(pair: *Pair, a: std.mem.Allocator) !SubmitFrame {
    const frame = (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(frame);
    var request = try protocol.parseRequest(a, frame);
    defer request.deinit();
    return .{ .id = request.id, .req = try request.u64Field("req") };
}

/// A --connect launcher with only a control socket: no worker and no session.
fn connectClientWithControl(a: std.mem.Allocator) !Pair {
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPath(std.testing.io, &root_buf);
    const client = try Client.init(a, std.testing.io, null, .connect, root_buf[0..n], root_buf[0..n]);
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds) != 0) {
        client.deinit();
        return error.SocketPairFailed;
    }
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    return .{ .client = client, .server = unix.Connection.init(a, fds[1], peer) };
}

/// Parse one request the client actually wrote; the frame buffer is released.
fn readFrameJson(pair: *Pair, a: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const frame = (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(frame);
    return std.json.parseFromSlice(std.json.Value, a, frame, .{});
}

/// Assert the client wrote nothing else on this socket.
fn expectNoFrame(pair: *Pair) !void {
    try std.testing.expectError(error.Timeout, pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 }));
}

test "refused cancel clear refreshes and reports QueueChanged" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // The host kept the barrier (`canceled:false`), so the caller must not see a
    // success; the following real snapshot is what proves the refusal moved the
    // queue revision instead of leaving a stale one behind.
    try pair.reply(1, "\"canceled\":false");
    try pair.reply(2, "\"snapshot\":{}");
    try testing.expectError(error.QueueChanged, Client.cancelClearFn(@ptrCast(client), 5, 9));

    const clear = try readFrameJson(&pair, a);
    defer clear.deinit();
    try testing.expectEqualStrings("cancel_clear", clear.value.object.get("op").?.string);
    try testing.expectEqual(@as(i64, 5), clear.value.object.get("epoch").?.integer);
    try testing.expectEqual(@as(i64, 9), clear.value.object.get("revision").?.integer);

    const refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try testing.expectEqualStrings("snapshot", refresh.value.object.get("op").?.string);
}

test "settings requests route to worker epoch or connect setup project" {
    const a = testing.allocator;
    const ops = [_]protocol.Op{
        .settings,      .model_select,   .effort,
        .cycle_effort,  .login,          .preference,
        .setting,       .decision_model, .image_model,
        .proxy_model,   .proxy_address,  .refresh_models,
        .poll_metadata,
    };

    var worker = try pairOf(a);
    defer worker.deinit();
    for (ops) |op| {
        var req = (try worker.client.trySettingsRequest(op)).?;
        defer req.deinit();
        try std.testing.expectEqual(Request.Target.worker, req.target);
        const bytes = try req.out.finish();
        defer worker.client.a.free(bytes);
        var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer doc.deinit();
        try std.testing.expectEqualStrings(@tagName(op), doc.value.object.get("op").?.string);
        try std.testing.expectEqual(@as(i64, 5), doc.value.object.get("epoch").?.integer);
        try std.testing.expect(doc.value.object.get("project") == null);
    }

    var connect_pair = try connectClientWithControl(a);
    defer connect_pair.deinit();
    for (ops) |op| {
        var req = (try connect_pair.client.trySettingsRequest(op)).?;
        defer req.deinit();
        try std.testing.expectEqual(Request.Target.control, req.target);
        const bytes = try req.out.finish();
        defer connect_pair.client.a.free(bytes);
        var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer doc.deinit();
        try std.testing.expectEqualStrings(@tagName(op), doc.value.object.get("op").?.string);
        try std.testing.expectEqualStrings(connect_pair.client.launcher, doc.value.object.get("project").?.string);
        try std.testing.expect(doc.value.object.get("epoch") == null);
    }
    try std.testing.expect(connect_pair.client.conn == null and connect_pair.client.workers == null);
}

test "connect create uses control and reads the session field" {
    const a = testing.allocator;
    const id = "0123456789abcdef0123456789abcdef";
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;

    // The envelope id is not the session identity: a reply without `session`
    // is rejected before any worker endpoint is dialled.
    try pair.reply(1, "\"endpoint\":\"/nonexistent/thin/worker.sock\"");
    try std.testing.expectError(error.ProtocolError, client.ensureSession());
    const create = try readFrameJson(&pair, a);
    defer create.deinit();
    try std.testing.expectEqualStrings("create", create.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, create.value.object.get("project").?.string);
    try std.testing.expect(client.conn == null and client.session == null);

    // With the session field the request continues to the published endpoint.
    try pair.reply(2, "\"session\":\"" ++ id ++ "\",\"endpoint\":\"/nonexistent/thin/worker.sock\"");
    try std.testing.expectError(error.Transport, client.ensureSession());
    const second = try readFrameJson(&pair, a);
    defer second.deinit();
    try std.testing.expectEqualStrings("create", second.value.object.get("op").?.string);
    try std.testing.expect(client.conn == null and client.session == null);
}

test "connect settings stay on control and readiness comes from the owner" {
    const a = testing.allocator;
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;

    // login and its settings refresh both stay on control: no session is made.
    try pair.reply(1, "\"configured\":1");
    try pair.reply(2, "\"available\":true,\"model\":\"m2\",\"configured\":1");
    try Client.configureFn(@ptrCast(client), "test-key");

    const login = try readFrameJson(&pair, a);
    defer login.deinit();
    try std.testing.expectEqualStrings("login", login.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, login.value.object.get("project").?.string);
    try std.testing.expect(login.value.object.get("epoch") == null);

    const settings = try readFrameJson(&pair, a);
    defer settings.deinit();
    try std.testing.expectEqualStrings("settings", settings.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, settings.value.object.get("project").?.string);
    try std.testing.expect(settings.value.object.get("epoch") == null);

    try std.testing.expect(client.conn == null and client.workers == null);
    // Owner readiness enables the next explicit submit without pre-creating.
    try std.testing.expect(client.state.available);
    // A live control transport makes the launcher serve-able for its first
    // submit, but it is still not attached to any session.
    try std.testing.expect(client.snap.available);
    try std.testing.expect(!client.snap.attached);

    // A later projection without the field is fail-closed even on live control.
    // The failed snapshot refresh before it consumed envelope id 3 without a
    // frame, so this settings request is id 4.
    try pair.reply(4, "\"model\":\"m2\"");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(!client.pubcfg.available);
    try std.testing.expect(!client.state.available);
    const refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expectEqualStrings("settings", refresh.value.object.get("op").?.string);

    // Metadata polling also uses the setup route and never creates a session.
    try pair.reply(5, "\"changed\":false");
    try std.testing.expect(!Client.pollModelsFn(@ptrCast(client), true));
    const poll = try readFrameJson(&pair, a);
    defer poll.deinit();
    try std.testing.expectEqualStrings("poll_metadata", poll.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, poll.value.object.get("project").?.string);
    try std.testing.expect(poll.value.object.get("wait").?.bool);
    try std.testing.expect(client.conn == null and client.workers == null);
}

test "worker settings callbacks carry the control epoch" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // model_select, then the settings refresh and the snapshot refresh.
    try pair.reply(1, "\"selected\":true");
    try pair.reply(2, "\"available\":true,\"model\":\"m3\"");
    try pair.reply(3, "\"snapshot\":{}");
    try Client.selectModelFn(@ptrCast(client), "m3");

    const select = try readFrameJson(&pair, a);
    defer select.deinit();
    try std.testing.expectEqualStrings("model_select", select.value.object.get("op").?.string);
    try std.testing.expectEqualStrings("m3", select.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 5), select.value.object.get("epoch").?.integer);

    const settings = try readFrameJson(&pair, a);
    defer settings.deinit();
    try std.testing.expectEqualStrings("settings", settings.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), settings.value.object.get("epoch").?.integer);
    try std.testing.expect(settings.value.object.get("project") == null);
    try std.testing.expect(client.state.available);
}

test "snapshot and settings project into the UI state without pointers" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try pair.reply(1, "\"available\":true,\"model\":\"m1\",\"provider\":\"deepseek\",\"effort\":\"high\",\"logging\":false,\"configured\":1,\"providers\":[{\"name\":\"deepseek\"}]");
    var settings = try client.readResponse(1, quick_timeout_ms);
    try client.adoptSettings(settings.object);
    settings.deinit();
    try std.testing.expectEqualStrings("m1", client.pubcfg.model);
    try std.testing.expectEqual(shared.ReasoningEffort.high, client.pubcfg.effort);
    try std.testing.expectEqual(@as(usize, 1), client.pubcfg.providers.len);
    try std.testing.expectEqual(@as(u8, 1), client.pubcfg.configured);
    try std.testing.expect(!client.pubcfg.logging);

    try pair.reply(2, "\"snapshot\":{\"session\":\"0123456789abcdef0123456789abcdef\",\"project\":\"/p\",\"owner\":\"foreground\",\"busy\":true,\"phase\":\"calling_model\",\"task\":4,\"task_kind\":\"prompt\",\"epoch\":5,\"attached\":true,\"queue_revision\":9,\"steering\":1,\"follow_up\":0,\"previews\":[{\"id\":5,\"kind\":\"steering\",\"text\":\"next\"}],\"ctx\":{\"tokens\":10,\"limit\":100,\"known\":true}}");
    var snapshot = try client.readResponse(2, quick_timeout_ms);
    try client.adoptSnapshot(&snapshot);
    snapshot.deinit();
    client.rebuild();

    const published = Client.snapshotFn(@ptrCast(client));
    try std.testing.expect(published.available);
    try std.testing.expect(published.busy);
    try std.testing.expect(published.attached);
    try std.testing.expectEqual(@as(u64, 5), published.control_epoch);
    try std.testing.expectEqual(@as(u64, 9), published.queue_revision);
    try std.testing.expectEqual(@as(usize, 1), published.previews.len);
    try std.testing.expectEqualStrings("next", published.previews[0].text);

    const state = Client.currentFn(@ptrCast(client));
    try std.testing.expect(state.available);
    try std.testing.expect(state.runtime == null);
    try std.testing.expectEqual(@as(?r.ContextSnapshot, .{ .tokens = 10, .limit = 100, .known = true }), state.initial_context);
    try std.testing.expectEqualStrings("m1", state.model);
    try std.testing.expectEqual(@as(u8, 1), state.configured_providers);
    // The projection copies: mutating the wire bytes later cannot reach the UI.
    try std.testing.expect(state.models.len == 0);
}

/// Minimal view over a real owner `Connection`: only the fields this wire
/// regression needs are overridden, everything else stays the Host's own.
const HostSettingsView = struct {
    prev_fn: *const fn (*anyopaque) tui.Connection.State,
    prev_context: *anyopaque,
    models: []const core_config.Model,
    official: []const bool,
    disabled: []const bool,
    providers: []const picker_module.Provider,

    fn current(context: *anyopaque) tui.Connection.State {
        const self: *HostSettingsView = @ptrCast(@alignCast(context));
        var state = self.prev_fn(self.prev_context);
        state.models = self.models;
        state.model_context_official = self.official;
        state.model_disabled = self.disabled;
        state.model_providers = self.providers;
        state.pending_default_effort = .medium;
        // Active protection and the global switch are different facts.
        state.low_price_input = true;
        state.low_price_input_enabled = false;
        return state;
    }
};

test "real host settings reply projects providers flags price states and pending effort" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const host_id = try ids.generate(io);
    const session_host = @import("../app/session_host.zig");
    const host = try session_host.SessionHost.init(a, io, &environ, .{ .project = project, .id = host_id, .logging = false, .owner = .daemon });
    defer host.deinit();

    const models = [_]core_config.Model{
        .{ .name = "native/official-model", .context_tokens = 32_000, .output_tokens = 4_000 },
        .{ .name = "native/disabled-model", .context_tokens = 64_000 },
    };
    const official = [_]bool{ true, false };
    const disabled = [_]bool{ false, true };
    const providers = [_]picker_module.Provider{
        .{ .name = "native", .allow_custom = true },
        .{ .name = "family", .allow_custom = true },
    };
    var view = HostSettingsView{
        .prev_fn = host.connection.current_fn,
        .prev_context = host.connection.context,
        .models = &models,
        .official = &official,
        .disabled = &disabled,
        .providers = &providers,
    };
    defer {
        host.connection.current_fn = view.prev_fn;
        host.connection.context = view.prev_context;
    }
    host.connection.current_fn = HostSettingsView.current;
    host.connection.context = &view;

    // The real owner frame, not a hand-written fixture object.
    var request = try protocol.parseRequest(a, "{\"v\":1,\"id\":60,\"op\":\"settings\"}");
    defer request.deinit();
    const frame = try host.dispatch(a, &request, 7, true);
    defer a.free(frame);
    var doc = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
    defer doc.deinit();
    const object = switch (doc.value) {
        .object => |map| map,
        else => return error.ProtocolError,
    };

    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    try client.adoptSettings(object);

    // The owner publishes `providers`, so the picker can match model prefixes.
    try std.testing.expectEqual(@as(usize, 2), client.pubcfg.providers.len);
    try std.testing.expectEqualStrings("native", client.pubcfg.providers[0].name);
    try std.testing.expect(client.pubcfg.providers[0].allow_custom);
    try std.testing.expectEqual(@as(usize, 3), decision_picker.count(client.pubcfg.models, client.pubcfg.providers, ""));
    try std.testing.expectEqual(@as(usize, 1), decision_picker.indexOf(client.pubcfg.models, client.pubcfg.providers, "", "native/official-model"));
    try std.testing.expectEqual(@as(usize, 2), decision_picker.indexOf(client.pubcfg.models, client.pubcfg.providers, "", "native/disabled-model"));

    // Both inline flags are index-aligned with the accepted model rows.
    try std.testing.expectEqual(@as(usize, 2), client.pubcfg.context_official.len);
    try std.testing.expectEqual(@as(usize, 2), client.pubcfg.disabled.len);
    for (client.pubcfg.models, 0..) |model, index| {
        if (std.mem.eql(u8, model.name, "native/official-model")) {
            try std.testing.expect(client.pubcfg.context_official[index] and !client.pubcfg.disabled[index]);
            try std.testing.expectEqual(@as(?u32, 4_000), model.output_tokens);
            try std.testing.expectEqual(core_config.ReasoningSource.metadata, model.output_source);
        } else {
            try std.testing.expect(!client.pubcfg.context_official[index] and client.pubcfg.disabled[index]);
            try std.testing.expectEqual(@as(?u32, null), model.output_tokens);
        }
    }

    // Active price protection is not the configured switch, and the pending
    // default effort keeps the owner's `pending_effort` name.
    try std.testing.expect(client.pubcfg.low_price_active);
    try std.testing.expect(!client.pubcfg.low_price_enabled);
    try std.testing.expectEqual(shared.ReasoningEffort.medium, client.pubcfg.pending_effort.?);

    // rebuild/currentFn really publish every parsed field to the UI state.
    client.rebuild();
    const state = Client.currentFn(@ptrCast(client));
    try std.testing.expectEqual(@as(usize, 2), state.models.len);
    try std.testing.expectEqualStrings("native/disabled-model", state.models[1].name);
    try std.testing.expect(state.model_disabled[1] and !state.model_context_official[1]);
    try std.testing.expectEqual(@as(usize, 2), state.model_providers.len);
    try std.testing.expectEqualStrings("native", state.model_providers[0].name);
    try std.testing.expect(state.low_price_input and !state.low_price_input_enabled);
    try std.testing.expectEqual(shared.ReasoningEffort.medium, state.pending_default_effort.?);

    // The real limits object carries the owner's request/task budgets, so the
    // client keeps them instead of the base defaults the decoder started from.
    const limits_object = switch (object.get("limits") orelse return error.ProtocolError) {
        .object => |map| map,
        else => return error.ProtocolError,
    };
    // A missing field or a wrong type is a protocol failure here, never a
    // silent zero that the real Host settings would otherwise pass.
    const decoded_request_timeout_ms = valueU64(limits_object.get("request_timeout_ms") orelse return error.ProtocolError) orelse return error.ProtocolError;
    const decoded_task_timeout_ms = valueU64(limits_object.get("task_timeout_ms") orelse return error.ProtocolError) orelse return error.ProtocolError;
    try std.testing.expectEqual(@as(u64, client.pubcfg.limits.request_timeout_ms), decoded_request_timeout_ms);
    try std.testing.expectEqual(@as(u64, client.pubcfg.limits.task_timeout_ms), decoded_task_timeout_ms);
    try std.testing.expect(client.pubcfg.limits.request_timeout_ms != 0 and client.pubcfg.limits.task_timeout_ms != 0);
}

test "limits decode the request and task budgets with the strict u32 rule" {
    const base = core_config.Limits{
        .command_timeout_ms = 1_000,
        .command_max_timeout_ms = 2_000,
        .read_bytes = 3_000,
        .output_bytes = 4_000,
        .request_timeout_ms = 300_000,
        .task_timeout_ms = 1_800_000,
    };
    const Decoder = struct {
        fn limits(text: []const u8, start: core_config.Limits) !core_config.Limits {
            var doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
            defer doc.deinit();
            return parseLimits(doc.value, start);
        }
    };

    // Non-default budgets decode next to the limits already handled inline.
    const decoded = try Decoder.limits("{\"request_timeout_ms\":10000,\"task_timeout_ms\":20000,\"command_timeout_ms\":123456}", base);
    try std.testing.expectEqual(@as(u32, 10_000), decoded.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 20_000), decoded.task_timeout_ms);
    try std.testing.expectEqual(@as(u32, 123_456), decoded.command_timeout_ms);

    // A larger configured pair is decoded exactly, not clamped by the base.
    const raised = try Decoder.limits("{\"request_timeout_ms\":60000,\"task_timeout_ms\":900000}", base);
    try std.testing.expectEqual(@as(u32, 60_000), raised.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 900_000), raised.task_timeout_ms);

    // Unparsable text, null, and a negative number keep the inherited values.
    const junk = try Decoder.limits("{\"request_timeout_ms\":\"abc\",\"task_timeout_ms\":null}", base);
    try std.testing.expectEqual(@as(u32, 300_000), junk.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 1_800_000), junk.task_timeout_ms);
    const negative = try Decoder.limits("{\"request_timeout_ms\":-1,\"task_timeout_ms\":-1}", base);
    try std.testing.expectEqual(@as(u32, 300_000), negative.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 1_800_000), negative.task_timeout_ms);

    // A non-object limits value leaves every field at its base value.
    const missing = try Decoder.limits("null", base);
    try std.testing.expectEqual(@as(u32, 300_000), missing.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 1_800_000), missing.task_timeout_ms);
    try std.testing.expectEqual(@as(u32, 1_000), missing.command_timeout_ms);
}

test "lost window resets to an owned history snapshot then resumes deltas" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try pair.reply(1, "\"reset\":true,\"base\":40,\"next\":40,\"epoch\":5,\"events\":[]");
    client.need_history = false;
    try client.readEvents();
    try std.testing.expect(client.need_history);

    const user = try protocol.encodeEvent(a, .{ .user_committed = .{ .id = 1, .text = "hello" } });
    defer a.free(user);
    const assistant = try protocol.encodeEvent(a, .{ .assistant_committed = &.{.{ .text = "hi" }} });
    defer a.free(assistant);
    const permission = try protocol.encodeEvent(a, .{ .permission = .{ .id = 9, .tool_name = "bash", .description = "run" } });
    defer a.free(permission);
    const history = try std.fmt.allocPrint(a, "\"base\":42,\"epoch\":5,\"entries\":[{s},{s},{s}]", .{ user, assistant, permission });
    defer a.free(history);
    try pair.reply(2, history);
    try client.readHistory();
    try std.testing.expectEqual(@as(u64, 42), client.cursor);
    try std.testing.expectEqual(@as(usize, 3), client.pending.items.len);
    // A snapshot page is local replay metadata: the whole page is marked and
    // only its first item announces the reset.
    try std.testing.expect(client.pending.items[0].history_replay);
    try std.testing.expect(client.pending.items[0].history_reset);
    try std.testing.expect(client.pending.items[1].history_replay and !client.pending.items[1].history_reset);
    try std.testing.expect(client.pending.items[2].history_replay and !client.pending.items[2].history_reset);

    var first = client.pending.orderedRemove(0);
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 5), first.epoch);
    // Moving the owned item preserves its local history metadata.
    try std.testing.expect(first.history_replay and first.history_reset);
    try std.testing.expectEqualStrings("hello", first.event.user_committed.text);
    var second = client.pending.orderedRemove(0);
    defer second.deinit();
    try std.testing.expectEqualStrings("hi", second.event.assistant_committed[0].text);
    var third = client.pending.orderedRemove(0);
    defer third.deinit();
    try std.testing.expectEqualStrings("run", third.event.permission.description);
    try std.testing.expect(third.event.permission.interrupt == null);

    const delta = try protocol.encodeEvent(a, .{ .text = "more" });
    defer a.free(delta);
    const page = try std.fmt.allocPrint(a, "\"base\":42,\"next\":43,\"epoch\":5,\"events\":[{s}]", .{delta});
    defer a.free(page);
    try pair.reply(3, page);
    try client.readEvents();
    try std.testing.expectEqual(@as(u64, 43), client.cursor);
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expectEqualStrings("more", client.pending.items[0].event.text);
    // A live delta is display-only: it must never enter input history.
    try std.testing.expect(!client.pending.items[0].history_replay);
    try std.testing.expect(!client.pending.items[0].history_reset);
}

test "a refetched history page resets its first item and an empty page marks nothing" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // Codec provenance (truncation, incomplete canonical list) travels beside
    // the local history markers instead of replacing them.
    const clipped = try protocol.encodeEventMeta(a, .{ .text = "partial" }, .{ .epoch = 5, .truncated = true, .canonical_complete = false });
    defer a.free(clipped);
    const page = try std.fmt.allocPrint(a, "\"base\":12,\"epoch\":5,\"entries\":[{s}]", .{clipped});
    defer a.free(page);
    try pair.reply(1, page);
    try client.readHistory();
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expect(client.pending.items[0].history_replay);
    try std.testing.expect(client.pending.items[0].history_reset);
    try std.testing.expect(client.pending.items[0].display_truncated);
    try std.testing.expect(!client.pending.items[0].canonical_complete);

    // An empty page replaces the queue and fabricates no content event; the UI
    // already resets on the epoch switch, so nothing needs a fake "reset" item.
    try pair.reply(2, "\"base\":13,\"epoch\":5,\"entries\":[]");
    try client.readHistory();
    try std.testing.expectEqual(@as(u64, 13), client.cursor);
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
}

test "a history page that fails mid-decode publishes nothing and stays retryable" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // A known resume point: a broken page must not move it forward.
    client.cursor = 7;
    const user = try protocol.encodeEvent(a, .{ .user_committed = .{ .id = 1, .text = "kept" } });
    defer a.free(user);
    // The valid entry decodes first, then a numeric entry is rejected by
    // `pushEvent`: the earlier decoded item is already sitting in the queue.
    const broken = try std.fmt.allocPrint(a, "\"base\":11,\"epoch\":5,\"entries\":[{s},7]", .{user});
    defer a.free(broken);
    try pair.reply(1, broken);
    try testing.expectError(error.ProtocolError, client.readHistory());
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try std.testing.expectEqual(@as(u64, 7), client.cursor);

    // The same page, now whole, replays from scratch and marks its first item.
    const page = try std.fmt.allocPrint(a, "\"base\":11,\"epoch\":5,\"entries\":[{s}]", .{user});
    defer a.free(page);
    try pair.reply(2, page);
    try client.readHistory();
    try std.testing.expectEqual(@as(u64, 11), client.cursor);
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expect(client.pending.items[0].history_replay);
    try std.testing.expect(client.pending.items[0].history_reset);
    try std.testing.expectEqualStrings("kept", client.pending.items[0].event.user_committed.text);
}

test "proxy allowlist mutation carries the exact model id and publishes an owned list" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // The mutation frame and the settings refresh the adapter sends right after
    // it are both queued before the call reads them.
    try pair.reply(1, "\"note\":0");
    try pair.reply(2, "\"proxy_configured\":true,\"proxy_models\":[\"opencode-go/deepseek-v3\",\"deepseek/deepseek-chat\"],\"proxy_models_truncated\":false");
    try Client.proxyFn(@ptrCast(client), "opencode-go/deepseek-v3", true);

    var mutation = try readFrameJson(&pair, a);
    defer mutation.deinit();
    const root = mutation.value.object;
    try std.testing.expectEqualStrings("proxy_model", root.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), root.get("epoch").?.integer);
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", root.get("name").?.string);
    try std.testing.expectEqual(true, root.get("enabled").?.bool);

    var refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expectEqualStrings("settings", refresh.value.object.get("op").?.string);

    // The published projection owns exact copies of the bounded name list.
    try std.testing.expect(client.state.proxy_configured);
    try std.testing.expectEqual(@as(usize, 2), client.state.proxy_models.len);
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", client.state.proxy_models[0]);
    try std.testing.expectEqualStrings("deepseek/deepseek-chat", client.state.proxy_models[1]);
}

test "proxy mutations refuse unusable names before any wire traffic" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try std.testing.expectError(error.InvalidInput, Client.proxyFn(@ptrCast(client), "", true));
    const too_long = try a.alloc(u8, protocol.max_name + 1);
    defer a.free(too_long);
    @memset(too_long, 'm');
    try std.testing.expectError(error.InvalidInput, Client.proxyFn(@ptrCast(client), too_long, true));
    try expectNoFrame(&pair);

    // Disabling an entry is still a real mutation with the same exact name.
    try pair.reply(1, "\"note\":0");
    try pair.reply(2, "\"proxy_configured\":false,\"proxy_models\":[]");
    try Client.proxyFn(@ptrCast(client), "opencode-go/deepseek-v3", false);
    var mutation = try readFrameJson(&pair, a);
    defer mutation.deinit();
    try std.testing.expectEqual(false, mutation.value.object.get("enabled").?.bool);
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", mutation.value.object.get("name").?.string);
    var refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expect(client.state.proxy_models.len == 0);
    try std.testing.expect(!client.state.proxy_configured);
}

test "proxy endpoint request carries the exact value and publishes an owned IPv6 pair" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try pair.reply(1, "\"note\":0");
    try pair.reply(2, "\"proxy_configured\":true,\"proxy_address\":\"2001:db8::1\",\"proxy_port\":8080,\"proxy_models\":[\"p/m\"]");
    try Client.proxyAddressFn(@ptrCast(client), "[2001:db8::1]:8080");

    var mutation = try readFrameJson(&pair, a);
    defer mutation.deinit();
    const root = mutation.value.object;
    try std.testing.expectEqualStrings("proxy_address", root.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), root.get("epoch").?.integer);
    try std.testing.expectEqualStrings("[2001:db8::1]:8080", root.get("value").?.string);
    try std.testing.expect(root.get("project") == null);

    var refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expectEqualStrings("settings", refresh.value.object.get("op").?.string);

    try std.testing.expectEqualStrings("2001:db8::1", client.state.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 8080), client.state.proxy_port);
    // The published address is an arena-owned copy, not a window into the doc.
    try std.testing.expect(client.state.proxy_address.?.ptr != client.pubcfg.proxy_address.?.ptr);
    try std.testing.expectEqual(@as(usize, 1), client.state.proxy_models.len);

    // An empty value is a real clear request, not an omitted field.
    try pair.reply(3, "\"note\":0");
    try pair.reply(4, "\"proxy_configured\":false,\"proxy_address\":null,\"proxy_port\":0,\"proxy_models\":[]");
    try Client.proxyAddressFn(@ptrCast(client), "");
    var clear = try readFrameJson(&pair, a);
    defer clear.deinit();
    try std.testing.expectEqualStrings("", clear.value.object.get("value").?.string);
    var cleared = try readFrameJson(&pair, a);
    defer cleared.deinit();
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(u16, 0), client.state.proxy_port);
}

test "proxy endpoint rejects unusable input before any wire traffic" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    for ([_][]const u8{
        "host",
        "2001:db8::1",
        "host:0",
        "host:70000",
        "[2001:db8::1]",
        "user@host:8080",
        "http://host:8080",
        "host:8080/path",
        "bad host:8080",
    }) |value| {
        try std.testing.expectError(error.InvalidInput, Client.proxyAddressFn(@ptrCast(client), value));
    }
    const too_long = try a.alloc(u8, core_config.max_proxy_endpoint_bytes + 1);
    defer a.free(too_long);
    @memset(too_long, 'a');
    try std.testing.expectError(error.InvalidInput, Client.proxyAddressFn(@ptrCast(client), too_long));
    try expectNoFrame(&pair);
}

test "settings keep legacy proxy snapshots readable and never invent endpoints" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // An older owner omits both new fields entirely: configured + allowlist stay
    // readable, the endpoint stays absent and the list is not cleared.
    try pair.reply(1, "\"proxy_configured\":true,\"proxy_models\":[\"opencode-go/deepseek-v3\"]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(client.state.proxy_configured);
    try std.testing.expectEqual(@as(usize, 1), client.state.proxy_models.len);
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(u16, 0), client.state.proxy_port);

    // A configured snapshot with a malformed pair is dropped as an endpoint but
    // still keeps the allowlist.
    try pair.reply(2, "\"proxy_configured\":true,\"proxy_address\":\"bad host\",\"proxy_port\":8080,\"proxy_models\":[\"opencode-go/deepseek-v3\"]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(usize, 1), client.state.proxy_models.len);

    // A configured=false snapshot carrying a host is not trusted either.
    try pair.reply(3, "\"proxy_configured\":false,\"proxy_address\":\"10.0.0.9\",\"proxy_port\":3128,\"proxy_models\":[]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(u16, 0), client.state.proxy_port);

    // A complete IPv4 pair is adopted exactly.
    try pair.reply(4, "\"proxy_configured\":true,\"proxy_address\":\"10.0.0.9\",\"proxy_port\":3128,\"proxy_models\":[]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expectEqualStrings("10.0.0.9", client.state.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 3128), client.state.proxy_port);
}

test "stale control epoch pages are dropped instead of rendered" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const delta = try protocol.encodeEvent(a, .{ .text = "old controller" });
    defer a.free(delta);
    const page = try std.fmt.allocPrint(a, "\"base\":1,\"next\":2,\"epoch\":99,\"events\":[{s}]", .{delta});
    defer a.free(page);
    try pair.reply(1, page);
    try client.readEvents();
    // Nothing from a replaced console is rendered and the cursor does not move;
    // control revocation itself comes from the owner snapshot, not a delta page.
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try std.testing.expectEqual(@as(u64, 0), client.cursor);
    try std.testing.expectEqual(@as(u64, 5), client.epoch);

    // Same rule when the codec reports the foreign epoch on the event itself.
    try pair.reply(2, "\"base\":1,\"next\":2,\"epoch\":5,\"events\":[]");
    try client.readEvents();
    try std.testing.expectEqual(@as(u64, 0), client.pending.items.len);
}

test "approve and withdraw carry their own payload ids" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    var approve = try client.request(.approve);
    defer approve.deinit();
    try approve.put("epoch", client.epoch);
    try approve.put("permission_id", @as(u64, 77));
    try approve.put("allow", true);
    const approve_bytes = try approve.out.finish();
    defer a.free(approve_bytes);
    var approve_doc = try std.json.parseFromSlice(std.json.Value, a, approve_bytes, .{});
    defer approve_doc.deinit();
    try std.testing.expectEqualStrings("approve", approve_doc.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 77), approve_doc.value.object.get("permission_id").?.integer);
    try std.testing.expect(approve_doc.value.object.get("id").?.integer != 77);
    try std.testing.expectEqual(@as(i64, 1), approve_doc.value.object.get("v").?.integer);

    var withdraw = try client.request(.withdraw);
    defer withdraw.deinit();
    try withdraw.put("epoch", client.epoch);
    try withdraw.put("queue_id", @as(u64, 12));
    const withdraw_bytes = try withdraw.out.finish();
    defer a.free(withdraw_bytes);
    var withdraw_doc = try std.json.parseFromSlice(std.json.Value, a, withdraw_bytes, .{});
    defer withdraw_doc.deinit();
    try std.testing.expectEqual(@as(i64, 12), withdraw_doc.value.object.get("queue_id").?.integer);

    // A reply carrying its own text still round-trips through withdraw.
    try pair.reply(3, "\"text\":\"queued text\"");
    var resp = try client.readResponse(3, quick_timeout_ms);
    defer resp.deinit();
    try std.testing.expectEqualStrings("queued text", resp.text("text").?);
}

test "version and id are checked before ok/err, then the view is dropped" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // A typed wire error is attributable, so the view survives it.
    try pair.replyError(1, "stale_control");
    try std.testing.expectError(error.StaleControl, client.readResponse(1, quick_timeout_ms));
    try std.testing.expect(client.conn != null);
    try pair.replyError(2, "busy");
    try std.testing.expectError(error.Busy, client.readResponse(2, quick_timeout_ms));
    try std.testing.expect(client.conn != null);

    // A wrong id cannot be attributed to this request, so `ok` is irrelevant:
    // the frame is rejected as protocol error and the view is dropped.
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };
    try pair.server.writeFrame("{\"v\":1,\"id\":9,\"ok\":false,\"err\":\"busy\"}", wait);
    try std.testing.expectError(error.ProtocolError, client.readResponse(2, quick_timeout_ms));
    try std.testing.expect(client.conn == null);
    try std.testing.expectEqual(@as(u64, 0), client.epoch);
}

test "wrong protocol version is a protocol error even with ok true" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };
    try pair.server.writeFrame("{\"v\":9,\"id\":1,\"ok\":true}", wait);
    try std.testing.expectError(error.ProtocolError, client.readResponse(1, quick_timeout_ms));
    try std.testing.expect(client.conn == null);
}

test "mutating ops send a real frame and adopt the accepted reply" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };

    // The sequential envelope id is allocated first; the receipt nonce is a
    // separate cryptographically random value, so only one id is consumed.
    const submit_id = client.next_req + 1;
    try pair.reply(submit_id, "\"accepted\":true,\"duplicate\":false,\"task\":11");
    try Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello");
    const frame = (try pair.server.readFrame(wait)) orelse return error.Transport;
    defer a.free(frame);
    var parsed = try protocol.parseRequest(a, frame);
    defer parsed.deinit();
    try std.testing.expectEqual(submit_id, parsed.id);
    const receipt_nonce = try parsed.u64Field("req");
    try std.testing.expect(receipt_nonce != 0);
    var doc = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
    defer doc.deinit();
    const object = doc.value.object;
    try std.testing.expectEqual(@as(i64, protocol.version), object.get("v").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(submit_id)), object.get("id").?.integer);
    try std.testing.expectEqualStrings("submit", object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), object.get("epoch").?.integer);
    try std.testing.expectEqualStrings("prompt", object.get("kind").?.string);
    try std.testing.expectEqualStrings("hello", object.get("text").?.string);
    // Accepted: the receipt is confirmed, the task is mirrored and the owner
    // echo of this prompt is suppressed exactly once.
    try std.testing.expect(client.receipt == null);
    try std.testing.expect(client.cache.busy);
    try std.testing.expect(client.suppress != null);

    const cancel_id = client.next_req + 1;
    try pair.reply(cancel_id, "\"canceled\":true");
    try Client.cancelFn(@ptrCast(client), client.epoch);
    const cancel_frame = (try pair.server.readFrame(wait)) orelse return error.Transport;
    defer a.free(cancel_frame);
    var cancel_doc = try std.json.parseFromSlice(std.json.Value, a, cancel_frame, .{});
    defer cancel_doc.deinit();
    try std.testing.expectEqual(@as(i64, protocol.version), cancel_doc.value.object.get("v").?.integer);
    try std.testing.expectEqualStrings("cancel", cancel_doc.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), cancel_doc.value.object.get("epoch").?.integer);
}

test "submit receipts are random non-zero and bound to one unconfirmed session" {
    const a = testing.allocator;
    const session_a: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const session_b: ids.Id = "fedcba9876543210fedcba9876543210".*;

    var first_pair = try pairOf(a);
    defer first_pair.deinit();
    const first_client = first_pair.client;
    first_client.session = session_a;

    // A fresh logical submission takes the normal submit route and gets a
    // random non-zero receipt.
    const first_id = first_client.next_req + 1;
    try first_pair.replyError(first_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello"));
    const first = try readSubmitFrame(&first_pair, a);
    try std.testing.expectEqual(first_id, first.id);
    try std.testing.expect(first.req != 0);
    try std.testing.expect(first_client.receipt != null and first_client.receipt.?.req == first.req);

    // An explicit retry of the same session/kind/digest first asks the owner
    // about the old nonce. A rejected receipt lets the explicit action mint a
    // new nonce; it does not blindly reuse the old submit.
    try first_pair.reply(first_client.next_req + 1, "\"snapshot\":{},\"receipt_known\":true,\"receipt_accepted\":false");
    try first_pair.reply(first_client.next_req + 2, "\"accepted\":true,\"duplicate\":false,\"task\":12");
    try Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello");
    const query_frame = (try first_pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(query_frame);
    var query = try protocol.parseRequest(a, query_frame);
    defer query.deinit();
    try std.testing.expectEqual(protocol.Op.snapshot, query.op);
    try std.testing.expectEqual(first.req, try query.u64Field("receipt"));
    const retried = try readSubmitFrame(&first_pair, a);
    try std.testing.expect(retried.req != 0 and retried.req != first.req);
    try std.testing.expect(first_client.receipt == null);

    // A different digest is a new logical submission and mints a new nonce
    // without querying the abandoned pending receipt.
    const changed_id = first_client.next_req + 1;
    try first_pair.replyError(changed_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello again"));
    const changed = try readSubmitFrame(&first_pair, a);
    try std.testing.expect(changed.req != 0 and changed.req != first.req);
    try std.testing.expectEqual(session_a, first_client.receipt.?.session.?);

    // The same kind and digest in another session is not the same submission;
    // the old pending receipt is dropped, never replayed.
    first_client.session = session_b;
    const other_session_id = first_client.next_req + 1;
    try first_pair.replyError(other_session_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello again"));
    const other_session = try readSubmitFrame(&first_pair, a);
    try std.testing.expect(other_session.req != 0 and other_session.req != changed.req);
    try std.testing.expectEqual(session_b, first_client.receipt.?.session.?);

    // A different frontend has its own envelope sequence and must not reuse the
    // receipt of another frontend for the same prompt.
    var second_pair = try pairOf(a);
    defer second_pair.deinit();
    const second_client = second_pair.client;
    second_client.session = session_a;
    const second_id = second_client.next_req + 1;
    try second_pair.replyError(second_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(second_client), second_client.epoch, .prompt, "hello again"));
    const second = try readSubmitFrame(&second_pair, a);
    try std.testing.expectEqual(second_id, second.id);
    try std.testing.expect(second.req != 0 and second.req != changed.req);
    try std.testing.expectEqual(session_a, second_client.receipt.?.session.?);
}

test "accepted pending receipt is confirmed by query instead of resubmitted" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    client.receipt = .{ .req = 424242, .kind = .prompt, .digest = submissionDigest(.prompt, "hello"), .session = session_id };

    try pair.reply(1, "\"snapshot\":{},\"receipt_known\":true,\"receipt_accepted\":true,\"receipt_task\":42");
    try Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello");

    const query = try readFrameJson(&pair, a);
    defer query.deinit();
    try std.testing.expectEqualStrings("snapshot", query.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 424242), query.value.object.get("receipt").?.integer);
    // No submit follows: the original task is confirmed exactly once.
    try expectNoFrame(&pair);
    try std.testing.expect(client.receipt == null);
    try std.testing.expectEqual(@as(u64, 42), client.cache.task);
    try std.testing.expect(client.suppress != null);
}

test "unknown or evicted pending receipt refuses to resubmit" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    client.receipt = .{ .req = 777777, .kind = .prompt, .digest = submissionDigest(.prompt, "hello"), .session = session_id };

    try pair.reply(1, "\"snapshot\":{},\"receipt_known\":false");
    try std.testing.expectError(error.Unavailable, Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello"));
    const query = try readFrameJson(&pair, a);
    defer query.deinit();
    try std.testing.expectEqualStrings("snapshot", query.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 777777), query.value.object.get("receipt").?.integer);
    try expectNoFrame(&pair);
    try std.testing.expect(client.receipt != null and client.receipt.?.req == 777777);
    try std.testing.expect(std.mem.indexOf(u8, client.pubcfg.notice orelse "", "not resubmitted") != null);

    // A failed query is equally uncertain: keep the pending receipt.
    try pair.replyError(2, "busy");
    try std.testing.expectError(error.Unavailable, Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello"));
    const failed = try readFrameJson(&pair, a);
    defer failed.deinit();
    try std.testing.expectEqualStrings("snapshot", failed.value.object.get("op").?.string);
    try expectNoFrame(&pair);
    try std.testing.expect(client.receipt != null);
}

test "lost view cannot create a new session to resend a pending receipt" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    client.epoch = 5;
    client.receipt = .{ .req = 888888, .kind = .prompt, .digest = submissionDigest(.prompt, "hello"), .session = session_id };

    try std.testing.expectError(error.Unavailable, Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello"));
    // No create and no query: attaching the original session is required first.
    try expectNoFrame(&pair);
    try std.testing.expect(client.conn == null and client.session != null);
    try std.testing.expect(client.receipt != null and client.receipt.?.req == 888888);
    try std.testing.expect(std.mem.indexOf(u8, client.pubcfg.notice orelse "", "Attach the original session") != null);
}

test "codec flags merge conservatively and a wire epoch is verified" {
    const a = testing.allocator;
    const body = [_]u8{'a'};
    const blocks = [_]p.Block{.{ .text = &body }};
    var item = try session_client.ownEvent(a, 4, .{ .assistant_committed = &blocks });
    defer item.deinit();
    try std.testing.expect(item.canonical_complete);
    try std.testing.expect(!item.display_truncated);

    const doc = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    var decoded: protocol.DecodedEvent = .{
        .epoch = 0,
        .event = .{ .text = "" },
        .display_truncated = true,
        .canonical_complete = false,
        .doc = doc,
        .storage = &.{},
        .a = a,
    };
    defer decoded.deinit();
    mergeFlags(&item, &decoded);
    // A block list cut by the codec's 256-block bound is never a final answer.
    try std.testing.expect(!item.canonical_complete);
    try std.testing.expect(item.display_truncated);
    // No wire claim keeps this view's epoch; a foreign epoch drops the event.
    try std.testing.expectEqual(@as(?u64, 4), itemEpoch(4, &decoded));
    decoded.epoch = 9;
    try std.testing.expectEqual(@as(?u64, null), itemEpoch(4, &decoded));
    decoded.epoch = 4;
    try std.testing.expectEqual(@as(?u64, 4), itemEpoch(4, &decoded));
}

test "wire error codes keep the classification describe already knows" {
    try std.testing.expectEqual(error.StaleControl, wireError(.stale_control));
    try std.testing.expectEqual(error.Busy, wireError(.busy));
    try std.testing.expectEqual(error.QueueFull, wireError(.queue_full));
    try std.testing.expectEqual(error.QueueEmpty, wireError(.queue_empty));
    try std.testing.expectEqual(error.PermissionExpired, wireError(.permission_expired));
    try std.testing.expectEqual(error.SessionNotFound, wireError(.not_found));
    try std.testing.expectEqual(error.InputTooLarge, wireError(.input_too_large));
    try std.testing.expectEqual(error.ProtocolError, wireError(.bad_request));
    try std.testing.expect(std.mem.find(u8, session_client.describe(error.StaleControl), "takeover") != null);
}

test "refresh wire codes survive a real failing frame without collapsing" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };

    const cases = [_]struct { code: protocol.ErrorCode, expected: anyerror }{
        .{ .code = .no_official_provider, .expected = error.NoOfficialProvider },
        .{ .code = .metadata_refresh_busy, .expected = error.MetadataRefreshBusy },
    };
    for (cases, 1..) |case, id| {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.fail(id, case.code);
        const bytes = try out.finish();
        defer a.free(bytes);
        try pair.server.writeFrame(bytes, wait);

        // Full path: strict frame parse -> codeFromName -> wireError.
        try std.testing.expectError(case.expected, client.readResponse(id, quick_timeout_ms));
        try std.testing.expect(case.expected != error.Transport);
        try std.testing.expect(case.expected != error.RemoteFailure);
        try std.testing.expectEqual(case.expected, wireError(protocol.codeFromName(case.code.name())));
    }

    // An unknown name still degrades to the generic remote failure only.
    try std.testing.expectEqual(error.RemoteFailure, wireError(protocol.codeFromName("not_a_wire_code")));
}

test "over-deep or malformed frames are rejected before parsing" {
    const a = testing.allocator;
    try std.testing.expect(boundedDepth("{\"v\":1,\"id\":1,\"ok\":true}"));
    try std.testing.expect(boundedDepth("{\"a\":\"}}}}[[[[\"}"));
    var deep: [80]u8 = @splat('[');
    try std.testing.expect(!boundedDepth(&deep));
    try std.testing.expectError(error.ProtocolError, parseObject(a, "not json"));
    try std.testing.expectError(error.ProtocolError, parseObject(a, "[1,2,3]"));
}

test "effort levels and configured masks decode from either shape" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[\"off\",\"low\",\"high\"]", .{});
    defer parsed.deinit();
    const set = parseEfforts(parsed.value);
    try std.testing.expect(set.contains(.low));
    try std.testing.expect(set.contains(.high));
    try std.testing.expect(!set.contains(.max));
    try std.testing.expectEqual(@as(u8, 0xff), parseConfigured(.{ .bool = true }));
    try std.testing.expectEqual(@as(u8, 0), parseConfigured(.{ .integer = 0 }));
}

// ---------------------------------------------------------------------------
// Tests: launcher/attach/close wiring (offline, no worker process is started).
// ---------------------------------------------------------------------------

/// Parse one request the client wrote on an explicit connection.
fn readJsonFrame(conn: *unix.Connection, a: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const frame = (try conn.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(frame);
    return std.json.parseFromSlice(std.json.Value, a, frame, .{});
}

/// Assert the peer wrote nothing else.
fn expectNoFrameOn(conn: *unix.Connection) !void {
    try std.testing.expectError(error.Timeout, conn.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 }));
}

test "launcher readiness comes from the control transport, attachment from a worker epoch" {
    const a = testing.allocator;
    var worker = try pairOf(a);
    defer worker.deinit();
    Client.rebuild(worker.client);
    try std.testing.expect(Client.snapshotFn(@ptrCast(worker.client)).available);
    try std.testing.expect(Client.snapshotFn(@ptrCast(worker.client)).attached);

    var launcher = try connectClientWithControl(a);
    defer launcher.deinit();
    Client.rebuild(launcher.client);
    // A --connect launcher may serve its first explicit submit without owning a
    // session yet; that is not the same thing as being attached to one.
    try std.testing.expect(Client.snapshotFn(@ptrCast(launcher.client)).available);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(launcher.client)).attached);
    try std.testing.expectEqual(@as(u64, 0), Client.snapshotFn(@ptrCast(launcher.client)).control_epoch);

    Client.closeControl(launcher.client);
    Client.rebuild(launcher.client);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(launcher.client)).available);
    try std.testing.expect(!Client.currentFn(@ptrCast(launcher.client)).available);
}

test "a foreground or attach launcher may start its own worker without a connection" {
    const a = testing.allocator;
    // A takeover leaves no worker transport and no daemon control behind.
    var pair = try pairOf(a);
    defer pair.deinit();
    Client.loseView(pair.client);
    try std.testing.expect(pair.client.conn == null and pair.client.control == null);
    try std.testing.expect(pair.client.mode == .foreground);
    try std.testing.expect(Client.snapshotFn(@ptrCast(pair.client)).available);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(pair.client)).attached);
    try std.testing.expectEqual(@as(u64, 0), Client.snapshotFn(@ptrCast(pair.client)).control_epoch);

    pair.client.mode = .attach;
    Client.rebuild(pair.client);
    try std.testing.expect(Client.snapshotFn(@ptrCast(pair.client)).available);

    // --connect has no worker of its own: the control socket is the capability.
    var connect = try connectClientWithControl(a);
    defer connect.deinit();
    Client.closeControl(connect.client);
    Client.rebuild(connect.client);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(connect.client)).available);
    try std.testing.expect(connect.client.conn == null and connect.client.control == null);
}

test "a launcher submission asks for a session instead of refusing the draft" {
    const a = testing.allocator;
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;

    // Epoch 0 with no connection is the launcher: the create request is really
    // sent. A reply without the session identity stops as a protocol error, so
    // the draft was not refused up front as a lost controller.
    try pair.reply(1, "\"endpoint\":\"/nonexistent/thin/worker.sock\"");
    try std.testing.expectError(error.ProtocolError, Client.submitFn(@ptrCast(client), 0, .prompt, "hello"));
    const create = try readFrameJson(&pair, a);
    defer create.deinit();
    try std.testing.expectEqualStrings("create", create.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, create.value.object.get("project").?.string);
    try std.testing.expect(client.conn == null and client.epoch == 0);
    try std.testing.expect(client.receipt == null);
}

test "a live view without control refuses submissions without sending anything" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    try std.testing.expectError(error.StaleControl, Client.submitFn(@ptrCast(pair.client), 0, .prompt, "hello"));
    try expectNoFrame(&pair);
    try std.testing.expect(pair.client.receipt == null);
}

test "a replaced controller epoch drops the view and returns to the launcher" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;

    try pair.reply(1, "\"snapshot\":{\"session\":\"0123456789abcdef0123456789abcdef\",\"epoch\":99,\"attached\":true,\"busy\":true}");
    client.refreshSnapshot();
    // Only this view is released: no shutdown, no cancel, no epoch-0 connection
    // that would make every later input stale forever.
    try std.testing.expect(client.conn == null);
    try std.testing.expectEqual(@as(u64, 0), client.epoch);
    try std.testing.expect(client.session == null);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(client)).attached);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(client)).busy);
    // A foreground console keeps the capability to start its own worker, so the
    // next explicit input is not refused as a lost view.
    try std.testing.expect(Client.snapshotFn(@ptrCast(client)).available);
    // Only the snapshot request was written, then this view's socket closed:
    // no shutdown, detach or cancel ever reached the owner.
    const probe_frame = try readFrameJson(&pair, a);
    defer probe_frame.deinit();
    try std.testing.expectEqualStrings("snapshot", probe_frame.value.object.get("op").?.string);
    if (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 })) |extra| {
        defer a.free(extra);
        return error.TestUnexpectedResult;
    }
}

test "a real takeover (owner reports epoch 0) returns to the launcher without touching owned work" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const owned_id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    // This launcher also owns a worker of its own; losing the console of the
    // attached session must not stop, close or unpublish that owned worker.
    try client.published.append(a, .{
        .id = owned_id,
        .project = try a.dupe(u8, client.launcher),
        .endpoint = try a.dupe(u8, "/nonexistent/thin/owned.sock"),
    });

    // The service never hands another console's epoch to the loser: a revoked
    // controller sees `epoch: 0` (still busy, still running).
    try pair.reply(1, "\"snapshot\":{\"session\":\"0123456789abcdef0123456789abcdef\",\"epoch\":0,\"attached\":false,\"busy\":true}");
    client.refreshSnapshot();

    const published = Client.snapshotFn(@ptrCast(client));
    try std.testing.expect(client.conn == null);
    try std.testing.expectEqual(@as(u64, 0), client.epoch);
    try std.testing.expect(client.session == null);
    try std.testing.expect(published.session_id == null);
    try std.testing.expectEqual(@as(u64, 0), published.control_epoch);
    try std.testing.expect(!published.attached);
    try std.testing.expect(!published.busy);
    // Back at the launcher: the next input creates a new session there.
    try std.testing.expect(Client.currentFn(@ptrCast(client)).session_id == null);
    // Owned work survives: the locator is kept and the launcher still owns it.
    try std.testing.expect(Client.ownsAnyWorker(client));
    try std.testing.expect(Client.ownsSession(client, owned_id));
    try std.testing.expectEqual(@as(usize, 1), client.published.items.len);
    try std.testing.expectEqualStrings("/nonexistent/thin/owned.sock", client.published.items[0].endpoint);

    // Exactly the snapshot probe reached the owner, then this view's socket
    // closed: no shutdown, close, detach or cancel frame follows.
    const probe_frame = try readFrameJson(&pair, a);
    defer probe_frame.deinit();
    try std.testing.expectEqualStrings("snapshot", probe_frame.value.object.get("op").?.string);
    if (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 })) |extra| {
        defer a.free(extra);
        return error.TestUnexpectedResult;
    }
}

test "closing the attached session carries its control epoch" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;

    // The owner refuses a busy task without force and the view survives.
    try pair.reply(1, "\"accepted\":false");
    try std.testing.expectError(error.Busy, Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &session_id, .force = false } }));
    const refused = try readFrameJson(&pair, a);
    defer refused.deinit();
    try std.testing.expectEqualStrings("close", refused.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), refused.value.object.get("epoch").?.integer);
    try std.testing.expect(!refused.value.object.get("force").?.bool);
    try std.testing.expect(client.conn != null and client.session != null);

    // Accepted: the owner saved and exited, so this view is gone.
    try pair.reply(2, "\"accepted\":true");
    var outcome = try Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &session_id, .force = true } });
    defer outcome.deinit(a);
    try std.testing.expect(client.conn == null and client.session == null);
    try std.testing.expect(outcome.notice != null);
}

test "closing an owned session outside this view demands --force" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);
    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    // No view and no connection: this launcher only owns a detached worker.
    const owned_id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    try client.published.append(a, .{
        .id = owned_id,
        .project = try a.dupe(u8, fixture.project),
        .endpoint = try a.dupe(u8, "/nonexistent/thin/owned.sock"),
    });

    var outcome = try Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &owned_id, .force = false } });
    defer outcome.deinit(a);
    try std.testing.expectEqualStrings(
        "Closing an owned session outside this view requires /close fedcbafedcbafedcbafedcbafedcbafe --force",
        outcome.notice.?,
    );
    // Refusal only: the locator is kept and no registry, worker manager or
    // control socket was opened, so nothing observed or stopped that process.
    try std.testing.expect(client.conn == null);
    try std.testing.expect(client.session == null);
    try std.testing.expect(client.workers == null);
    try std.testing.expect(client.control == null);
    try std.testing.expectEqual(@as(usize, 1), client.published.items.len);
    try std.testing.expect(Client.ownsSession(client, owned_id));
}

test "a daemon-owned session close demands --force before any control request" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);

    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    var server = unix.Connection.init(a, fds[1], peer);
    defer server.close();
    client.reg = try Registry.init(a, testing.io, &fixture.env);

    // An owner-managed record this launcher never published: only the daemon
    // can stop it, so a busy task cannot be ruled out from here.
    const id: ids.Id = "00112233445566778899aabbccddeeff".*;
    const endpoint = try std.fmt.allocPrint(a, "{s}/workers/0011223344556677.sock", .{client.reg.?.runtime.path});
    defer a.free(endpoint);
    try client.reg.?.register(.{
        .id = id,
        .project = fixture.project,
        .endpoint = endpoint,
        .owner = .daemon,
        .owner_instance = "0011223344556677",
        .state = "running",
        .pid = @intCast(std.os.linux.getpid()),
        .generation = 1,
    });

    var outcome = try Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &id, .force = false } });
    defer outcome.deinit(a);
    try std.testing.expectEqualStrings(
        "Closing an owned session outside this view requires /close 00112233445566778899aabbccddeeff --force",
        outcome.notice.?,
    );
    // No `close` frame reached the daemon and no worker manager was created:
    // the refusal stops nothing and only asks for the confirmation.
    try expectNoFrameOn(&server);
    try std.testing.expect(client.workers == null);
    try std.testing.expect(client.session == null and client.conn == null);
    var kept = (try client.reg.?.resolve(a, id, fixture.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(endpoint, kept.endpoint);
}

/// A private HOME/runtime/project so the registry and checkpoint helpers can be
/// exercised without touching the real user directories.
const AttachEnv = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    home: []u8,
    runtime: []u8,
    project: []u8,

    fn init(a: std.mem.Allocator) !AttachEnv {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const base = buf[0..n];
        const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
        errdefer a.free(home);
        const runtime = try std.fmt.allocPrint(a, "{s}/runtime", .{base});
        errdefer a.free(runtime);
        const project = try std.fmt.allocPrint(a, "{s}/project", .{base});
        errdefer a.free(project);
        try tmp.dir.createDir(testing.io, "home", .fromMode(0o700));
        try tmp.dir.createDir(testing.io, "runtime", .fromMode(0o700));
        // A resumable history must be a real private checkpoint namespace:
        // 0700 sessions directory plus the `*` ignore marker.
        _ = try tmp.dir.createDirPathStatus(testing.io, "project/.thin/sessions", .fromMode(0o700));
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "project/.thin/sessions/.gitignore",
            .data = "*\n",
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        var env = std.process.Environ.Map.init(a);
        errdefer env.deinit();
        try env.put("HOME", home);
        try env.put("XDG_RUNTIME_DIR", runtime);
        return .{ .tmp = tmp, .env = env, .home = home, .runtime = runtime, .project = project };
    }

    fn deinit(self: *AttachEnv, a: std.mem.Allocator) void {
        self.env.deinit();
        a.free(self.home);
        a.free(self.runtime);
        a.free(self.project);
        self.tmp.cleanup();
    }
};

test "attach resumes a confirmed-dead endpoint only with a complete checkpoint" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);

    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    var server = unix.Connection.init(a, fds[1], peer);
    defer server.close();
    client.reg = try Registry.init(a, testing.io, &fixture.env);

    const id: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    const record: registry.Record = .{
        .id = id,
        .project = fixture.project,
        .endpoint = try std.fmt.allocPrint(a, "{s}/workers/0123456789abcdef.sock", .{client.reg.?.runtime.path}),
        .owner = .daemon,
        .owner_instance = "0123456789abcdef",
        .state = "running",
        .pid = @intCast(std.os.linux.getpid()),
        .generation = 1,
    };
    defer a.free(@constCast(record.endpoint));
    try client.reg.?.register(record);

    // Registered endpoint that no longer exists and no checkpoint: nothing may
    // start, and no owner is asked to create one.
    try std.testing.expectError(error.SessionNotFound, Client.attachSession(client, id, false));
    try expectNoFrameOn(&server);

    // A complete checkpoint makes the same history resumable. In --connect the
    // daemon creates the replacement worker; it is never a local process.
    var name_buf: [128]u8 = undefined;
    const checkpoint = try std.fmt.bufPrint(&name_buf, "project/.thin/sessions/{s}.session", .{id});
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = checkpoint, .data = "complete checkpoint" });
    const create_reply = try std.fmt.allocPrint(a, "\"session\":\"{s}\",\"endpoint\":\"/nonexistent/thin/worker.sock\"", .{id});
    defer a.free(create_reply);
    const create_frame = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":1,\"ok\":true,{s}}}", .{ protocol.version, create_reply });
    defer a.free(create_frame);
    try server.writeFrame(create_frame, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    // The published endpoint does not exist, so the candidate attach fails; the
    // control request that asked for the resume is what this test proves.
    try std.testing.expectError(error.Transport, Client.attachSession(client, id, false));
    const create = try readJsonFrame(&server, a);
    defer create.deinit();
    try std.testing.expectEqualStrings("create", create.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(fixture.project, create.value.object.get("project").?.string);
    try std.testing.expectEqualStrings(&id, create.value.object.get("resume").?.string);
}

test "an unreachable-but-present endpoint is never treated as dead" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);

    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    var server = unix.Connection.init(a, fds[1], peer);
    defer server.close();
    client.reg = try Registry.init(a, testing.io, &fixture.env);

    const id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    const endpoint = try std.fmt.allocPrint(a, "{s}/workers/fedcba9876543210.sock", .{client.reg.?.runtime.path});
    defer a.free(endpoint);
    // The endpoint path exists but is a plain file, not a socket: that is an
    // unreadable owner, never proof that the history is free.
    _ = try fixture.tmp.dir.createDirPathStatus(testing.io, "runtime/thin/workers", .fromMode(0o700));
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = endpoint, .data = "not a socket" });
    try client.reg.?.register(.{
        .id = id,
        .project = fixture.project,
        .endpoint = endpoint,
        .owner = .daemon,
        .owner_instance = "fedcba9876543210",
        .state = "running",
        .pid = @intCast(std.os.linux.getpid()),
        .generation = 1,
    });
    var name_buf: [128]u8 = undefined;
    const checkpoint = try std.fmt.bufPrint(&name_buf, "project/.thin/sessions/{s}.session", .{id});
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = checkpoint, .data = "complete checkpoint" });

    try std.testing.expectError(error.Unavailable, Client.attachSession(client, id, false));
    try expectNoFrameOn(&server);
    try std.testing.expect(client.conn == null);
}
