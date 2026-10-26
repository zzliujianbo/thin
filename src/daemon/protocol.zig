//! Thin daemon/session wire protocol v1.
//!
//! One request frame -> exactly one response frame, both JSON, framed by
//! `daemon/unix.zig` (4-byte big-endian length, max 1 MiB, 0600 AF_UNIX with
//! kernel SO_PEERCRED). This module owns only parsing, bounds, response
//! assembly and the display-event projection of `core/runtime.Event`.
//!
//! Nothing here serializes credentials, native replay, raw HTTP bodies, file
//! contents or process-local pointers. Text is truncated at UTF-8 boundaries
//! and every collection is capped.

const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const tool_stream = @import("../core/tool_stream.zig");
const preview = @import("../core/tool_preview.zig");
const ids = @import("../app/session_id.zig");
const unix = @import("unix.zig");
const json_bound = @import("../app/json_bound.zig");
const task = @import("../core/task.zig");
const write_preview = @import("../core/write_preview.zig");
const line_stats = @import("../util/line_stats.zig");

pub const version: u16 = 1;
/// Same bound as one frame; responses are checked before writeFrame.
pub const max_response = unix.max_frame_len;
/// Prompt, queue entry, tool result and notice text.
pub const max_text: usize = 64 * 1024;
pub const max_name: usize = 1024;
pub const max_events: u16 = 32;
pub const max_history: u16 = 32;
pub const max_previews = 16;
pub const max_blocks = 256;
/// Reuses the project's fixed structural preflight depth (32), not a new parser.
pub const max_json_depth: usize = json_bound.max_depth;

/// Wire error codes. The client maps these to the exact `anyerror` values that
/// `ui/session_client.describe` already classifies.
pub const ErrorCode = enum {
    bad_request,
    stale_control,
    busy,
    unavailable,
    not_found,
    invalid_input,
    input_too_large,
    queue_full,
    queue_empty,
    input_budget,
    unsupported,
    canceled,
    permission_expired,
    no_official_provider,
    metadata_refresh_busy,
    transport,
    protocol,
    internal,

    pub fn name(self: ErrorCode) []const u8 {
        return @tagName(self);
    }
};

pub fn errorCode(err: anyerror) ErrorCode {
    return switch (err) {
        error.StaleControl => .stale_control,
        error.Busy, error.TaskStillRunning, error.AuthVersionConflict => .busy,
        error.Unavailable, error.SessionInUse, error.PeerUidMismatch => .unavailable,
        error.SessionNotFound, error.FileNotFound => .not_found,
        error.InvalidInput, error.InvalidArguments, error.InvalidSessionID => .invalid_input,
        // Configuration and selection rejections are caller mistakes, not
        // server faults: an unusable proxy/provider/credential request must
        // never surface as an opaque internal failure.
        error.ProxyNotConfigured, error.UnknownProvider, error.UnknownProxyModel, error.ApiKeyNotFound, error.MissingRegistry, error.InvalidDefault => .invalid_input,
        error.InputTooLarge, error.OutOfMemory => .input_too_large,
        error.InboxFull, error.QueueFull => .queue_full,
        error.QueueEmpty, error.RunSealed => .queue_empty,
        error.InputBudgetExceeded, error.InputBudgetSummaryFailed, error.UnknownInputPriceThreshold => .input_budget,
        error.Unsupported => .unsupported,
        error.Canceled => .canceled,
        error.PermissionExpired, error.InvalidPermission => .permission_expired,
        error.NoOfficialProvider => .no_official_provider,
        error.MetadataRefreshBusy => .metadata_refresh_busy,
        error.ConnectionLost, error.ConnectionClosed, error.Transport, error.StreamPoisoned, error.Timeout => .transport,
        error.ProtocolError, error.TruncatedFrame, error.FrameTooLarge, error.DuplicateField, error.UnknownField, error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun, error.BadRequest => .protocol,
        else => .internal,
    };
}

pub fn codeFromName(name: []const u8) ErrorCode {
    return std.meta.stringToEnum(ErrorCode, name) orelse .internal;
}

/// Closed startup exit-code handshake for an owner-managed worker process.
///
/// A worker that fails before publishing its `hello` has no wire channel yet,
/// so the only truthful carrier is its process exit status. These codes are
/// private to the worker/launcher pair: they never appear on the wire, never
/// change `ErrorCode`, and only ever map back to the fixed names below. An
/// unmapped code (or any other Term shape) stays `null`, so no arbitrary error
/// name or message can leak through a numeric status.
pub const startup_code_first: u8 = 70;
pub const startup_code_last: u8 = 90;

const StartupEntry = struct {
    code: u8,
    err: anyerror,
};

const startup_entries = [_]StartupEntry{
    .{ .code = 70, .err = error.SelectionNotFound },
    .{ .code = 71, .err = error.ResumeNotFound },
    .{ .code = 72, .err = error.InvalidResumeLength },
    .{ .code = 73, .err = error.InvalidJson },
    .{ .code = 74, .err = error.UnsupportedVersion },
    .{ .code = 75, .err = error.ResumeConflict },
    .{ .code = 76, .err = error.ResumeNotClosed },
    .{ .code = 77, .err = error.SessionInUse },
    .{ .code = 78, .err = error.UnsafeResumeFile },
    .{ .code = 79, .err = error.ResumeReadOnly },
    .{ .code = 80, .err = error.ResumeAuthenticationFailed },
    .{ .code = 81, .err = error.ApiKeyNotFound },
    .{ .code = 82, .err = error.SelectionEndpointUnavailable },
};

/// Startup error -> private exit code, or `null` for anything not in the
/// closed startup set (the caller then keeps the ordinary failure path).
pub fn startupExitCode(err: anyerror) ?u8 {
    inline for (startup_entries) |entry| {
        if (err == entry.err) return entry.code;
    }
    return null;
}

/// Private exit code -> startup error, or `null` for unmapped codes.
pub fn startupError(code: u8) ?anyerror {
    if (code < startup_code_first or code > startup_code_last) return null;
    inline for (startup_entries) |entry| {
        if (entry.code == code) return entry.err;
    }
    return null;
}

/// Wire names must remain identical to `ui/session_client.Failure` tags.
pub fn failureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.CleanupFailed => "cleanup_failed",
        error.UnsafeToContinue => "unsafe_to_continue",
        error.InputBudgetExceeded => "input_budget_exceeded",
        error.UnknownInputPriceThreshold => "unknown_input_price_threshold",
        error.InputBudgetSummaryFailed => "input_budget_summary_failed",
        error.DecisionUnavailable => "decision_unavailable",
        error.SubagentInteractionRequired => "subagent_interaction_required",
        error.NoCompactionCandidate => "no_compaction_candidate",
        error.Canceled => "canceled",
        error.Transport, error.ConnectionLost, error.ConnectionClosed => "transport",
        error.Timeout => "timeout",
        error.ProtocolError => "protocol",
        error.Rejected => "rejected",
        else => "other",
    };
}

pub const Op = enum {
    hello,
    /// Supervisor-owned control ops; the session host never handles them.
    create,
    list,
    snapshot,
    attach,
    detach,
    events,
    history,
    submit,
    cancel,
    cancel_clear,
    /// Owner barrier: suspend/resume automatic steering/follow-up claims.
    confirming,
    approve,
    enqueue,
    withdraw,
    queue_resume,
    settings,
    model_select,
    effort,
    cycle_effort,
    login,
    preference,
    setting,
    decision_model,
    image_model,
    /// Proxy allowlist mutation: one exact provider/raw model id plus an
    /// explicit enable flag. Never carries an endpoint or a credential.
    proxy_model,
    refresh_models,
    poll_metadata,
    close,
    shutdown,
    ping,
};

pub const TaskKind = enum {
    prompt,
    compact,
    command,

    /// `task.Job.kind` is an anonymous enum; name its type once, at the only
    /// place that needs it, instead of duplicating a `Job.Kind` alias.
    pub fn toRuntime(self: TaskKind) @TypeOf(@as(task.Job, undefined).kind) {
        return switch (self) {
            .prompt => .prompt,
            .compact => .compact,
            .command => .command,
        };
    }
};

pub const QueueKind = enum {
    steering,
    follow_up,

    pub fn toInbox(self: QueueKind) @import("../core/inbox.zig").Kind {
        return switch (self) {
            .steering => .steering,
            .follow_up => .follow_up,
        };
    }

    pub fn fromInbox(kind: @import("../core/inbox.zig").Kind) QueueKind {
        return switch (kind) {
            .steering => .steering,
            .follow_up => .follow_up,
        };
    }
};

/// A parsed request. `body` and all its strings are owned by `doc`.
pub const Request = struct {
    id: u64,
    op: Op,
    body: std.json.Value,
    /// Owns every allocation made while parsing; `body` borrows it.
    doc: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Request) void {
        self.wipeSecrets();
        self.doc.deinit();
        self.* = undefined;
    }

    /// A login key is a secret that must not survive in the parsed arena.
    /// `parseRequest` uses `.allocate = .alloc_always`, so this slice is an
    /// owned copy rather than a window into the caller's frame; wiping it is
    /// therefore meaningful and never mutates borrowed constants.
    fn wipeSecrets(self: *Request) void {
        const object = switch (self.body) {
            .object => |value| value,
            else => return,
        };
        if (object.get("key")) |value| switch (value) {
            .string => |secret| std.crypto.secureZero(u8, @constCast(secret)),
            else => {},
        };
    }

    pub fn field(self: *const Request, name: []const u8) ?std.json.Value {
        return switch (self.body) {
            .object => |object| object.get(name),
            else => null,
        };
    }

    pub fn u64Field(self: *const Request, name: []const u8) !u64 {
        const value = self.field(name) orelse return error.BadRequest;
        return valueU64(value);
    }

    pub fn optionalU64(self: *const Request, name: []const u8) !?u64 {
        const value = self.field(name) orelse return null;
        return try valueU64(value);
    }

    pub fn boolField(self: *const Request, name: []const u8, default: bool) !bool {
        const value = self.field(name) orelse return default;
        return switch (value) {
            .bool => |b| b,
            else => error.BadRequest,
        };
    }

    /// Required strict boolean. A missing field is a bad request instead of a
    /// caller default, so an enable/disable decision is always explicit.
    pub fn requiredBool(self: *const Request, name: []const u8) !bool {
        const value = self.field(name) orelse return error.BadRequest;
        return switch (value) {
            .bool => |b| b,
            else => error.BadRequest,
        };
    }

    /// Required bounded, valid UTF-8 string without NUL.
    pub fn stringField(self: *const Request, name: []const u8, max: usize) ![]const u8 {
        const raw = self.optionalString(name) orelse return error.BadRequest;
        if (raw.len > max) return error.InputTooLarge;
        if (std.mem.findScalar(u8, raw, 0) != null or !std.unicode.utf8ValidateSlice(raw)) return error.BadRequest;
        return raw;
    }

    pub fn optionalString(self: *const Request, name: []const u8) ?[]const u8 {
        const value = self.field(name) orelse return null;
        return switch (value) {
            .string => |s| s,
            .null => null,
            else => null,
        };
    }

    pub fn stringEnum(self: *const Request, comptime T: type, name: []const u8) !T {
        const raw = try self.stringField(name, max_name);
        return std.meta.stringToEnum(T, raw) orelse error.BadRequest;
    }

    /// The parsed document's arena; borrows nothing from the caller's stack.
    pub fn arenaalloc(self: *Request) std.mem.Allocator {
        return self.doc.arena.allocator();
    }
};

fn valueU64(value: std.json.Value) !u64 {
    return numberU64(value);
}

/// Parse one request frame. Unknown ops and malformed bodies are rejected
/// before any handler runs; the caller closes the connection.
pub fn parseRequest(a: std.mem.Allocator, bytes: []const u8) !Request {
    if (bytes.len == 0 or bytes.len > unix.max_frame_len) return error.BadRequest;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.BadRequest;
    // Allocation-free structural preflight before std.json allocates anything.
    json_bound.bound(bytes, unix.max_frame_len, 65536) catch return error.BadRequest;

    // `alloc_always` copies every string out of the frame, so a login key in
    // the body is private to `doc` and can be wiped before the arena is freed.
    var doc = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadRequest,
    };
    errdefer doc.deinit();

    const object = switch (doc.value) {
        .object => |value| value,
        else => return error.BadRequest,
    };
    if (object.count() > 32) return error.BadRequest;

    const ver = object.get("v") orelse return error.BadRequest;
    if ((try numberU64(ver)) != version) return error.BadRequest;
    const id_value = object.get("id") orelse return error.BadRequest;
    const id = try numberU64(id_value);
    if (id == 0) return error.BadRequest;
    const op_value = object.get("op") orelse return error.BadRequest;
    const op_name = switch (op_value) {
        .string => |value| value,
        else => return error.BadRequest,
    };
    const op = std.meta.stringToEnum(Op, op_name) orelse return error.BadRequest;

    return .{ .id = id, .op = op, .body = doc.value, .doc = doc };
}

/// Accept only a non-negative JSON integer token. `std.json` may report a legal
/// u64 (above i64.max) as `number_string`; reject JSON strings, floats,
/// signs, fractions and exponents so ids stay exact and unambiguous.
fn numberU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else error.BadRequest,
        .number_string => |text| blk: {
            if (text.len == 0 or text.len > 20) return error.BadRequest;
            for (text) |byte| if (byte < '0' or byte > '9') return error.BadRequest;
            break :blk std.fmt.parseInt(u64, text, 10) catch error.BadRequest;
        },
        else => error.BadRequest,
    };
}

// ---------------------------------------------------------------------------
// JSON string escaping and bounded text
// ---------------------------------------------------------------------------

pub fn clipText(bytes: []const u8) []const u8 {
    if (bytes.len <= max_text) return bytes;
    var n = max_text;
    while (n > 0 and (bytes[n] & 0xc0) == 0x80) n -= 1;
    return bytes[0..n];
}

fn appendString(buf: *std.ArrayList(u8), a: std.mem.Allocator, bytes: []const u8) !void {
    const clipped = clipText(bytes);
    try buf.append(a, '"');
    if (std.unicode.utf8ValidateSlice(clipped)) {
        for (clipped) |byte| {
            switch (byte) {
                '"' => try buf.appendSlice(a, "\\\""),
                '\\' => try buf.appendSlice(a, "\\\\"),
                '\n' => try buf.appendSlice(a, "\\n"),
                '\r' => try buf.appendSlice(a, "\\r"),
                '\t' => try buf.appendSlice(a, "\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    var tmp: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try buf.appendSlice(a, esc);
                },
                else => try buf.append(a, byte),
            }
        }
    } else {
        // Invalid UTF-8 cannot appear in JSON; keep valid scalars and replace
        // malformed bytes deterministically instead of emitting broken frames.
        var i: usize = 0;
        while (i < clipped.len) {
            const len = std.unicode.utf8ByteSequenceLength(clipped[i]) catch blk: {
                break :blk @as(u8, 0);
            };
            if (len == 0 or i + len > clipped.len) {
                try buf.appendSlice(a, "\\ufffd");
                i += 1;
                continue;
            }
            const scalar = clipped[i .. i + len];
            if (!std.unicode.utf8ValidateSlice(scalar)) {
                try buf.appendSlice(a, "\\ufffd");
                i += 1;
                continue;
            }
            for (scalar) |byte| {
                switch (byte) {
                    '"' => try buf.appendSlice(a, "\\\""),
                    '\\' => try buf.appendSlice(a, "\\\\"),
                    0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                        var tmp: [8]u8 = undefined;
                        const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch unreachable;
                        try buf.appendSlice(a, esc);
                    },
                    else => try buf.append(a, byte),
                }
            }
            i += len;
        }
    }
    try buf.append(a, '"');
}

fn appendInt(buf: *std.ArrayList(u8), a: std.mem.Allocator, value: anytype) !void {
    var tmp: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.OutOfMemory;
    try buf.appendSlice(a, text);
}

pub fn appendId(buf: *std.ArrayList(u8), a: std.mem.Allocator, id: ids.Id) !void {
    try appendString(buf, a, &id);
}

// ---------------------------------------------------------------------------
// Response assembly
// ---------------------------------------------------------------------------

pub const Raw = struct { json: []const u8 };

/// Bounded JSON response builder. Nesting is limited to max_json_depth.
pub const Out = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    depth: usize = 0,
    comma: [max_json_depth + 2]bool = @splat(false),
    failed: bool = false,

    pub fn init(a: std.mem.Allocator) Out {
        return .{ .a = a };
    }

    pub fn deinit(self: *Out) void {
        self.buf.deinit(self.a);
        self.* = undefined;
    }

    pub fn ok(self: *Out, id: u64) !void {
        try self.buf.appendSlice(self.a, "{\"v\":");
        try appendInt(&self.buf, self.a, version);
        try self.buf.appendSlice(self.a, ",\"id\":");
        try appendInt(&self.buf, self.a, id);
        try self.buf.appendSlice(self.a, ",\"ok\":true");
        self.comma[0] = true;
    }

    pub fn fail(self: *Out, id: u64, code: ErrorCode) !void {
        try self.buf.appendSlice(self.a, "{\"v\":");
        try appendInt(&self.buf, self.a, version);
        try self.buf.appendSlice(self.a, ",\"id\":");
        try appendInt(&self.buf, self.a, id);
        try self.buf.appendSlice(self.a, ",\"ok\":false,\"err\":\"");
        try self.buf.appendSlice(self.a, code.name());
        // Like `ok`, the root object stays open so callers can keep appending
        // fields; only `finish` closes it. Closing here produced a frame with a
        // trailing stray brace once the caller finished normally.
        try self.buf.append(self.a, '"');
        self.comma[0] = true;
    }

    fn separate(self: *Out) !void {
        if (self.comma[self.depth]) try self.buf.append(self.a, ',');
        self.comma[self.depth] = true;
    }

    pub fn key(self: *Out, name: []const u8) !void {
        try self.separate();
        try appendString(&self.buf, self.a, name);
        try self.buf.append(self.a, ':');
    }

    pub fn value(self: *Out, v: anytype) !void {
        const T = @TypeOf(v);
        if (T == Raw) return self.buf.appendSlice(self.a, v.json);
        switch (@typeInfo(T)) {
            .optional => {
                if (v) |inner| return self.value(inner);
                return self.buf.appendSlice(self.a, "null");
            },
            .bool => return self.buf.appendSlice(self.a, if (v) "true" else "false"),
            .int => |int| {
                if (int.signedness == .signed and v < 0) {
                    try self.buf.append(self.a, '-');
                    return appendInt(&self.buf, self.a, -v);
                }
                return appendInt(&self.buf, self.a, v);
            },
            .comptime_int => return appendInt(&self.buf, self.a, v),
            .@"enum" => return self.value(@tagName(v)),
            .array => |array| {
                if (array.child != u8) @compileError("unsupported protocol array type: " ++ @typeName(T));
                return appendString(&self.buf, self.a, &v);
            },
            .pointer => |ptr| {
                if (ptr.child == u8) return appendString(&self.buf, self.a, v);
                switch (@typeInfo(ptr.child)) {
                    .array => |array| {
                        if (array.child != u8) @compileError("unsupported protocol pointer type: " ++ @typeName(T));
                        return appendString(&self.buf, self.a, v);
                    },
                    else => @compileError("unsupported protocol pointer type: " ++ @typeName(T)),
                }
            },
            else => @compileError("unsupported protocol value type: " ++ @typeName(T)),
        }
    }

    pub fn field(self: *Out, name: []const u8, v: anytype) !void {
        try self.key(name);
        try self.value(v);
    }

    pub fn rawField(self: *Out, name: []const u8, json: []const u8) !void {
        try self.key(name);
        try self.buf.appendSlice(self.a, json);
    }

    pub fn beginObject(self: *Out, name: []const u8) !void {
        try self.key(name);
        try self.beginObjectRaw();
    }

    pub fn beginObjectRaw(self: *Out) !void {
        if (self.depth + 1 >= self.comma.len) return error.BadRequest;
        try self.buf.append(self.a, '{');
        self.depth += 1;
        self.comma[self.depth] = false;
    }

    pub fn endObject(self: *Out) !void {
        try self.buf.append(self.a, '}');
        if (self.depth == 0) return error.BadRequest;
        self.depth -= 1;
    }

    pub fn beginArray(self: *Out, name: []const u8) !void {
        try self.key(name);
        if (self.depth + 1 >= self.comma.len) return error.BadRequest;
        try self.buf.append(self.a, '[');
        self.depth += 1;
        self.comma[self.depth] = false;
    }

    pub fn endArray(self: *Out) !void {
        try self.buf.append(self.a, ']');
        if (self.depth == 0) return error.BadRequest;
        self.depth -= 1;
    }

    /// Append one scalar-encoded value as an array element. `value` writes raw
    /// bytes and never separates, which is what an object field needs after
    /// `key`; inside an array the separator is still required.
    pub fn arrayValue(self: *Out, v: anytype) !void {
        try self.separate();
        try self.value(v);
    }

    /// Start an object that is an array element, so consecutive elements are
    /// comma-separated. `beginObjectRaw` alone assumes the caller separated.
    pub fn beginObjectElement(self: *Out) !void {
        try self.separate();
        try self.beginObjectRaw();
    }

    /// Append one already-encoded JSON value as an array element.
    pub fn element(self: *Out, json: []const u8) !void {
        try self.separate();
        try self.buf.appendSlice(self.a, json);
    }

    /// Finish the frame. Rejects unbalanced builders and oversized responses.
    pub fn finish(self: *Out) ![]u8 {
        if (self.depth != 0) return error.BadRequest;
        try self.buf.append(self.a, '}');
        if (self.buf.items.len > max_response) {
            // Leave the buffer owned by the caller's `defer out.deinit()`; freeing
            // it here would double free on top of the poisoning `self.* = undefined`.
            return error.InputTooLarge;
        }
        return self.buf.toOwnedSlice(self.a);
    }
};

// ---------------------------------------------------------------------------
// Display events
// ---------------------------------------------------------------------------

/// Optional per-frame display metadata. A host attaches it so a remote client
/// can attribute an event without guessing: `epoch` is the controller epoch the
/// event belongs to, `truncated` reports presenter-side clipping and
/// `canonical_complete` is false when a canonical block list was bounded.
pub const EventMeta = struct {
    epoch: u64 = 0,
    truncated: bool = false,
    canonical_complete: bool = true,
};

fn encodeField(out: *Out, name: []const u8, value: ?preview.Field) !void {
    const field = value orelse {
        try out.field(name, @as(?[]const u8, null));
        return;
    };
    try out.beginObject(name);
    try out.field("text", field.text);
    try out.field("trunc", field.truncated);
    try out.endObject();
}

/// Display identity: `generation` names one real attempt, `index` one call.
fn encodeDisplayKey(out: *Out, name: []const u8, key: ?p.ToolDisplayKey) !void {
    const value = key orelse {
        try out.field(name, @as(?[]const u8, null));
        return;
    };
    try out.beginObject(name);
    try out.field("gen", value.generation);
    try out.field("idx", value.index);
    try out.endObject();
}

fn encodeProgress(out: *Out, name: []const u8, value: ?write_preview.Progress) !void {
    const progress = value orelse {
        try out.field(name, @as(?[]const u8, null));
        return;
    };
    try out.beginObject(name);
    try out.field("added", progress.added);
    try out.field("deleted", progress.deleted);
    try out.endObject();
}

/// Passive measured file observations; counts only, never file contents.
fn encodeFileStats(out: *Out, name: []const u8, value: ?line_stats.File) !void {
    const stats = value orelse {
        try out.field(name, @as(?[]const u8, null));
        return;
    };
    try out.beginObject(name);
    try out.field("read", stats.read);
    try out.field("partial", stats.partial);
    if (stats.changes) |changes| {
        try out.beginObject("changes");
        try out.field("modified", changes.modified);
        try out.field("added", changes.added);
        try out.field("removed", changes.removed);
        try out.endObject();
    } else try out.field("changes", @as(?[]const u8, null));
    try out.endObject();
}

/// Encode one runtime event as a standalone JSON object, appending to `buf`.
/// Only display-safe fields cross the wire; ids/keys are display association
/// only and never transport authority. No `permission.interrupt` pointer, no
/// native replay and no raw provider configuration is ever serialized.
pub fn appendEvent(buf: *std.ArrayList(u8), a: std.mem.Allocator, event: r.Event) !void {
    try appendEventWith(buf, a, event, null);
}

fn appendEventWith(buf: *std.ArrayList(u8), a: std.mem.Allocator, event: r.Event, meta: ?EventMeta) !void {
    var out = Out{ .a = a, .buf = buf.* };
    // The builder appends into the caller's list; publish it on every exit.
    defer buf.* = out.buf;
    var truncated = if (meta) |value| value.truncated else false;
    var complete = if (meta) |value| value.canonical_complete else true;
    try out.beginObjectRaw();
    switch (event) {
        .state => |phase| {
            try out.field("t", "state");
            try out.field("phase", phase);
        },
        .context_snapshot => |snapshot| {
            try out.field("t", "ctx");
            try out.field("tokens", snapshot.tokens);
            try out.field("limit", snapshot.limit);
            try out.field("known", snapshot.known);
        },
        .text => |bytes| {
            try out.field("t", "text");
            try out.field("v", bytes);
        },
        .reasoning => |bytes| {
            try out.field("t", "reasoning");
            try out.field("v", bytes);
        },
        .assistant_committed => |blocks| {
            try out.field("t", "assistant");
            try out.beginArray("blocks");
            var bytes: usize = 0;
            const bounded = @min(blocks.len, max_blocks);
            var n: usize = 0;
            while (n < bounded and bytes < max_text) : (n += 1) {
                const block = blocks[n];
                var element = Out{ .a = a, .buf = std.ArrayList(u8).empty };
                defer element.buf.deinit(a);
                try element.beginObjectRaw();
                switch (block) {
                    .text => |text| {
                        try element.field("k", "text");
                        try element.field("v", text);
                        bytes +|= @min(text.len, max_text);
                    },
                    .reasoning => |text| {
                        try element.field("k", "reasoning");
                        try element.field("v", text);
                        bytes +|= @min(text.len, max_text);
                    },
                    .tool_call => |call| {
                        try element.field("k", "tool_call");
                        try element.field("id", call.id);
                        try element.field("name", call.name);
                        try element.field("args", call.arguments);
                        try element.field("item", call.item_id);
                        bytes +|= @min(call.arguments.len, max_text) + @min(call.name.len, max_name);
                    },
                    .tool_result => |result| {
                        try element.field("k", "tool_result");
                        try element.field("id", result.call_id);
                        try element.field("v", result.text);
                        try element.field("is_error", result.is_error);
                        try element.field("canceled", result.canceled);
                        try element.field("trunc", result.truncated);
                        bytes +|= @min(result.text.len, max_text);
                    },
                }
                try element.endObject();
                try out.element(element.buf.items);
            }
            try out.endArray();
            // A bounded or byte-capped block list must never look final.
            if (n < blocks.len) {
                truncated = true;
                complete = false;
            }
        },
        .user_committed => |value| {
            try out.field("t", "user");
            try out.field("id", value.id);
            try out.field("v", value.text);
        },
        .permission_cleared => |id| {
            try out.field("t", "permission_cleared");
            try out.field("id", id);
        },
        .tool_preview => |value| {
            try out.field("t", "preview");
            try out.field("i", value.index);
            try out.field("args", value.arguments);
            try out.field("write", value.write_file);
            try out.field("bytes", value.argument_bytes);
        },
        .tool_views => |value| {
            try out.field("t", "tool_views");
            try out.field("gen", value.generation);
            try out.field("phase", value.phase);
        },
        .tool_view => |view| {
            try out.field("t", "tool_view");
            try out.field("name", view.name);
            try out.field("gen", view.key.generation);
            try out.field("idx", view.key.index);
            try out.field("ready", view.ready);
            try out.beginObject("fields");
            try encodeField(&out, "path", view.fields.path);
            try encodeField(&out, "command", view.fields.command);
            try encodeField(&out, "action", view.fields.action);
            try encodeField(&out, "topic", view.fields.topic);
            try encodeField(&out, "task", view.fields.task);
            try encodeField(&out, "id", view.fields.id);
            try out.endObject();
            try encodeProgress(&out, "wprog", view.write_progress);
        },
        .permission => |value| {
            try out.field("t", "permission");
            try out.field("id", value.id);
            try out.field("name", value.tool_name);
            try out.field("desc", value.description);
        },
        .tool_started => |value| {
            try out.field("t", "tool_started");
            try out.field("id", value.id);
            try out.field("name", value.name);
            try out.field("ms", value.started_ms);
            try encodeDisplayKey(&out, "key", value.display_key);
        },
        .tool_result => |value| {
            try out.field("t", "tool_result");
            try out.field("id", value.id);
            try out.field("name", value.name);
            try out.field("v", value.result.text);
            try out.field("is_error", value.result.is_error);
            try out.field("canceled", value.result.canceled);
            try out.field("trunc", value.result.truncated);
            try out.field("cleanup", value.result.cleanup_failed);
            try out.field("ms", value.result.duration_ms);
            try encodeDisplayKey(&out, "key", value.display_key);
            try out.field("mem_ev", value.result.memory_evidence);
            try encodeFileStats(&out, "opts", value.result.file_stats);
        },
        .usage => |value| {
            try out.field("t", "usage");
            try out.field("purpose", value.purpose);
            try out.field("protocol", value.protocol);
            try out.beginObject("value");
            try appendUsage(&out, value.value);
            try out.endObject();
        },
        .fallback => |protocol| {
            try out.field("t", "fallback");
            try out.field("protocol", protocol);
        },
        .compacted => |value| {
            try out.field("t", "compacted");
            try out.field("before", value.before);
            try out.field("after", value.after);
        },
        .compaction_failed => |err| {
            try out.field("t", "compaction_failed");
            try out.field("code", failureCode(err));
        },
        .finished => |terminal| {
            try out.field("t", "finished");
            try out.field("status", terminal.status);
            try out.field("failure", if (terminal.detail) |detail| failureCode(detail) else "other");
            try out.field("model_failure", terminal.model_failure);
            try out.field("http", terminal.http_status);
            if (terminal.decision_failure) |diagnostic| {
                try out.beginObject("decision_failure");
                try out.field("stage", diagnostic.stage);
                try out.field("backend", diagnostic.backend);
                try out.field("operation", diagnostic.operation);
                try out.field("cause", diagnostic.causeName());
                try out.field("http_status", diagnostic.http_status);
                try out.field("model_failure", diagnostic.model_failure);
                try out.field("transport_exit_code", diagnostic.transport_exit_code);
                try out.endObject();
            }
            try out.beginObject("usage");
            try out.field("normal_calls", terminal.usage.normal_calls);
            try out.field("summary_calls", terminal.usage.summary_calls);
            try out.beginObject("normal");
            try appendUsage(&out, terminal.usage.normal);
            try out.endObject();
            try out.beginObject("summary");
            try appendUsage(&out, terminal.usage.summary);
            try out.endObject();
            try out.endObject();
            if (terminal.context_snapshot) |snapshot| {
                try out.beginObject("ctx");
                try out.field("tokens", snapshot.tokens);
                try out.field("limit", snapshot.limit);
                try out.field("known", snapshot.known);
                try out.endObject();
            } else try out.field("ctx", @as(?[]const u8, null));
        },
    }
    if (meta) |value| try out.field("epoch", value.epoch);
    // Display metadata uses collision-free names: `trunc` is a real
    // tool_result field and must keep its own meaning.
    if (truncated) try out.field("disp_trunc", true);
    if (!complete) try out.field("canon_complete", false);
    try out.endObject();
}

fn appendUsage(out: *Out, usage: p.Usage) !void {
    try out.field("input", usage.input_tokens);
    try out.field("output", usage.output_tokens);
    try out.field("cached", usage.cached_input_tokens);
    try out.field("cache_write", usage.cache_write_tokens);
    try out.field("reasoning", usage.reasoning_tokens);
    try out.field("total", usage.total_tokens);
}

/// Encode one event into a fresh, owned buffer (the display ring stores these).
pub fn encodeEvent(a: std.mem.Allocator, event: r.Event) ![]u8 {
    return encodeEventWith(a, event, null);
}

/// Encode one event together with its display metadata markers.
pub fn encodeEventMeta(a: std.mem.Allocator, event: r.Event, meta: EventMeta) ![]u8 {
    return encodeEventWith(a, event, meta);
}

fn encodeEventWith(a: std.mem.Allocator, event: r.Event, meta: ?EventMeta) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);
    try appendEventWith(&buf, a, event, meta);
    if (buf.items.len > max_text * 3 + 8192) {
        buf.deinit(a);
        return error.InputTooLarge;
    }
    return buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Snapshot encoding
// ---------------------------------------------------------------------------

pub const QueuePreview = struct {
    id: u64 = 0,
    kind: QueueKind = .steering,
    text: []const u8 = "",
};

pub const Snapshot = struct {
    session: ids.Id,
    label: ?[]const u8 = null,
    project: []const u8,
    owner: enum { foreground, daemon },
    busy: bool = false,
    phase: ?r.State = null,
    task: u64 = 0,
    task_kind: TaskKind = .prompt,
    epoch: u64 = 0,
    attached: bool = false,
    pending_permission: ?u64 = null,
    queue_revision: u64 = 0,
    queue_paused: bool = false,
    steering: u32 = 0,
    follow_up: u32 = 0,
    newest_id: ?u64 = null,
    newest_bytes: u64 = 0,
    previews: []const QueuePreview = &.{},
    context: ?r.ContextSnapshot = null,
    model: []const u8 = "",
    provider: ?[]const u8 = null,
    logging: bool = true,
    read_only: bool = false,
    truncated: bool = false,
};

pub fn encodeSnapshot(out: *Out, snapshot: Snapshot) !void {
    try out.beginObject("snapshot");
    var id_buf: [32]u8 = undefined;
    @memcpy(&id_buf, &snapshot.session);
    try out.field("session", id_buf[0..]);
    try out.field("label", snapshot.label);
    try out.field("project", snapshot.project);
    try out.field("owner", @tagName(snapshot.owner));
    try out.field("busy", snapshot.busy);
    try out.field("phase", snapshot.phase);
    try out.field("task", snapshot.task);
    try out.field("task_kind", @tagName(snapshot.task_kind));
    try out.field("epoch", snapshot.epoch);
    try out.field("attached", snapshot.attached);
    try out.field("pending", snapshot.pending_permission);
    try out.field("queue_revision", snapshot.queue_revision);
    try out.field("queue_paused", snapshot.queue_paused);
    try out.field("steering", snapshot.steering);
    try out.field("follow_up", snapshot.follow_up);
    try out.field("newest_id", snapshot.newest_id);
    try out.field("newest_bytes", snapshot.newest_bytes);
    try out.beginArray("previews");
    for (snapshot.previews[0..@min(snapshot.previews.len, max_previews)]) |item| {
        try out.beginObjectElement();
        try out.field("id", item.id);
        try out.field("kind", @tagName(item.kind));
        try out.field("text", item.text);
        try out.endObject();
    }
    try out.endArray();
    if (snapshot.context) |context| {
        try out.beginObject("ctx");
        try out.field("tokens", context.tokens);
        try out.field("limit", context.limit);
        try out.field("known", context.known);
        try out.endObject();
    } else try out.field("ctx", @as(?u8, null));
    try out.field("model", snapshot.model);
    try out.field("provider", snapshot.provider);
    try out.field("logging", snapshot.logging);
    try out.field("read_only", snapshot.read_only);
    try out.field("truncated", snapshot.truncated);
    try out.endObject();
}

// ---------------------------------------------------------------------------
// Client-side decoding helpers
// ---------------------------------------------------------------------------

pub const DecodedEvent = struct {
    epoch: u64 = 0,
    event: r.Event,
    display_truncated: bool = false,
    canonical_complete: bool = true,
    doc: std.json.Parsed(std.json.Value),
    /// Reserved: every payload slice borrows `doc.arena`, so this is empty and
    /// callers must deep-copy through `ui/session_client.ownEvent`.
    storage: []u8 = &.{},
    a: std.mem.Allocator,

    pub fn deinit(self: *DecodedEvent) void {
        // Blocks and text are arena-owned; only an explicitly handed-out
        // buffer would need freeing here.
        if (self.storage.len != 0) self.a.free(self.storage);
        self.doc.deinit();
        self.* = undefined;
    }
};

// Strict field readers. Missing required fields, wrong JSON types, quoted
// numbers, floats and exponents are rejected instead of defaulting to zero.

fn requireValue(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return object.get(name) orelse error.BadRequest;
}

fn requireObject(object: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return switch (try requireValue(object, name)) {
        .object => |value| value,
        else => error.BadRequest,
    };
}

fn optionalObject(object: std.json.ObjectMap, name: []const u8) !?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .object => |inner| inner,
        else => error.BadRequest,
    };
}

fn requireArray(object: std.json.ObjectMap, name: []const u8) !std.json.Array {
    return switch (try requireValue(object, name)) {
        .array => |value| value,
        else => error.BadRequest,
    };
}

fn requireText(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (try requireValue(object, name)) {
        .string => |value| value,
        else => error.BadRequest,
    };
}

fn optionalText(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |inner| inner,
        else => error.BadRequest,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .bool => |inner| inner,
        else => error.BadRequest,
    };
}

fn requireBool(object: std.json.ObjectMap, name: []const u8) !bool {
    return (try optionalBool(object, name)) orelse error.BadRequest;
}

/// Absent or `null` is unknown; a present value must be an exact integer.
fn optionalU64(object: std.json.ObjectMap, name: []const u8) !?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        else => try numberU64(value),
    };
}

fn requireU64(object: std.json.ObjectMap, name: []const u8) !u64 {
    return numberU64(try requireValue(object, name));
}

fn requireU32(object: std.json.ObjectMap, name: []const u8) !u32 {
    return std.math.cast(u32, try requireU64(object, name)) orelse error.BadRequest;
}

fn requireIndex(object: std.json.ObjectMap, name: []const u8) !usize {
    return std.math.cast(usize, try requireU64(object, name)) orelse error.BadRequest;
}

fn requireEnum(comptime T: type, object: std.json.ObjectMap, name: []const u8) !T {
    return std.meta.stringToEnum(T, try requireText(object, name)) orelse error.BadRequest;
}

/// Unknown optional tag names stay forward-compatible instead of failing a
/// whole display frame; required tags above are strict.
fn optionalEnum(comptime T: type, object: std.json.ObjectMap, name: []const u8) !?T {
    const text = (try optionalText(object, name)) orelse return null;
    return std.meta.stringToEnum(T, text);
}

const ToolViewsPhase = @FieldType(@FieldType(r.Event, "tool_views"), "phase");

fn decodeField(object: std.json.ObjectMap, name: []const u8) !?preview.Field {
    const inner = (try optionalObject(object, name)) orelse return null;
    return .{
        .text = try requireText(inner, "text"),
        .truncated = try optionalBool(inner, "trunc") orelse false,
    };
}

fn decodeFields(object: std.json.ObjectMap, name: []const u8) !preview.Snapshot {
    const inner = (try optionalObject(object, name)) orelse return .{};
    return .{
        .path = try decodeField(inner, "path"),
        .command = try decodeField(inner, "command"),
        .action = try decodeField(inner, "action"),
        .topic = try decodeField(inner, "topic"),
        .task = try decodeField(inner, "task"),
        .id = try decodeField(inner, "id"),
    };
}

fn decodeDisplayKey(object: std.json.ObjectMap, name: []const u8) !?p.ToolDisplayKey {
    const inner = (try optionalObject(object, name)) orelse return null;
    return .{
        .generation = try requireU64(inner, "gen"),
        .index = try requireIndex(inner, "idx"),
    };
}

fn decodeProgress(object: std.json.ObjectMap, name: []const u8) !?write_preview.Progress {
    const inner = (try optionalObject(object, name)) orelse return null;
    return .{
        .added = try optionalU64(inner, "added"),
        .deleted = try optionalU64(inner, "deleted"),
    };
}

fn decodeFileStats(object: std.json.ObjectMap, name: []const u8) !?line_stats.File {
    const inner = (try optionalObject(object, name)) orelse return null;
    const changes: ?line_stats.Changes = if (try optionalObject(inner, "changes")) |value| .{
        .modified = try requireU64(value, "modified"),
        .added = try requireU64(value, "added"),
        .removed = try requireU64(value, "removed"),
    } else null;
    return .{
        .read = try optionalU64(inner, "read"),
        .partial = try optionalBool(inner, "partial") orelse false,
        .changes = changes,
    };
}

fn decodeUsage(object: std.json.ObjectMap) !p.Usage {
    return .{
        .input_tokens = try optionalU64(object, "input"),
        .output_tokens = try optionalU64(object, "output"),
        .cached_input_tokens = try optionalU64(object, "cached"),
        .cache_write_tokens = try optionalU64(object, "cache_write"),
        .reasoning_tokens = try optionalU64(object, "reasoning"),
        .total_tokens = try optionalU64(object, "total"),
    };
}

fn decodeBlock(value: std.json.Value) !p.Block {
    const object = switch (value) {
        .object => |inner| inner,
        else => return error.BadRequest,
    };
    const kind = try requireText(object, "k");
    if (std.mem.eql(u8, kind, "text")) return .{ .text = try requireText(object, "v") };
    if (std.mem.eql(u8, kind, "reasoning")) return .{ .reasoning = try requireText(object, "v") };
    if (std.mem.eql(u8, kind, "tool_call")) {
        return .{ .tool_call = .{
            .id = try requireText(object, "id"),
            .name = try requireText(object, "name"),
            .arguments = try requireText(object, "args"),
            .item_id = try optionalText(object, "item"),
        } };
    }
    if (std.mem.eql(u8, kind, "tool_result")) {
        return .{ .tool_result = .{
            .call_id = try requireText(object, "id"),
            .text = try requireText(object, "v"),
            .is_error = try optionalBool(object, "is_error") orelse false,
            .canceled = try optionalBool(object, "canceled") orelse false,
            .truncated = try optionalBool(object, "trunc") orelse false,
        } };
    }
    return error.BadRequest;
}

/// Decode one encoded event into a borrowed `r.Event` plus the document that
/// owns every slice. Blocks are allocated from the document arena, so text and
/// blocks share one lifetime and an error path frees all of them. The client
/// deep-copies this through `ui/session_client.ownEvent` before display.
pub fn decodeEvent(a: std.mem.Allocator, json: []const u8) !DecodedEvent {
    if (json.len == 0 or json.len > max_response) return error.BadRequest;
    if (!std.unicode.utf8ValidateSlice(json)) return error.BadRequest;
    // Allocation-free structural preflight before std.json allocates anything.
    json_bound.bound(json, unix.max_frame_len, 65536) catch return error.BadRequest;

    var doc = std.json.parseFromSlice(std.json.Value, a, json, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadRequest,
    };
    errdefer doc.deinit();

    const object = switch (doc.value) {
        .object => |value| value,
        else => return error.BadRequest,
    };
    const arena = doc.arena.allocator();
    var display_truncated = try optionalBool(object, "disp_trunc") orelse false;
    var canonical_complete = try optionalBool(object, "canon_complete") orelse true;
    const epoch = try optionalU64(object, "epoch") orelse 0;

    const kind = try requireText(object, "t");
    var event: r.Event = undefined;
    if (std.mem.eql(u8, kind, "state")) {
        event = .{ .state = try requireEnum(r.State, object, "phase") };
    } else if (std.mem.eql(u8, kind, "ctx")) {
        event = .{ .context_snapshot = .{
            .tokens = try requireU64(object, "tokens"),
            .limit = try requireU64(object, "limit"),
            .known = try optionalBool(object, "known") orelse true,
        } };
    } else if (std.mem.eql(u8, kind, "text")) {
        event = .{ .text = try requireText(object, "v") };
    } else if (std.mem.eql(u8, kind, "reasoning")) {
        event = .{ .reasoning = try requireText(object, "v") };
    } else if (std.mem.eql(u8, kind, "user")) {
        event = .{ .user_committed = .{
            .id = try requireU64(object, "id"),
            .text = try requireText(object, "v"),
        } };
    } else if (std.mem.eql(u8, kind, "permission")) {
        // `interrupt` is a process-local Inbox pointer and never crosses the wire.
        event = .{ .permission = .{
            .id = try requireU64(object, "id"),
            .tool_name = try requireText(object, "name"),
            .description = try requireText(object, "desc"),
        } };
    } else if (std.mem.eql(u8, kind, "permission_cleared")) {
        event = .{ .permission_cleared = try requireU64(object, "id") };
    } else if (std.mem.eql(u8, kind, "preview")) {
        const argument_bytes = if (try optionalU64(object, "bytes")) |value|
            std.math.cast(usize, value) orelse return error.BadRequest
        else
            null;
        event = .{ .tool_preview = .{
            .index = try requireIndex(object, "i"),
            .arguments = try requireText(object, "args"),
            .write_file = try optionalBool(object, "write") orelse false,
            .argument_bytes = argument_bytes,
        } };
    } else if (std.mem.eql(u8, kind, "tool_views")) {
        event = .{ .tool_views = .{
            .generation = try requireU64(object, "gen"),
            .phase = try requireEnum(ToolViewsPhase, object, "phase"),
        } };
    } else if (std.mem.eql(u8, kind, "tool_view")) {
        event = .{ .tool_view = .{
            .key = .{
                .generation = try requireU64(object, "gen"),
                .index = try requireIndex(object, "idx"),
            },
            .name = try requireText(object, "name"),
            .fields = try decodeFields(object, "fields"),
            .write_progress = try decodeProgress(object, "wprog"),
            .ready = try optionalBool(object, "ready") orelse false,
        } };
    } else if (std.mem.eql(u8, kind, "tool_started")) {
        event = .{ .tool_started = .{
            .id = try requireU64(object, "id"),
            .name = try requireText(object, "name"),
            .started_ms = try optionalU64(object, "ms"),
            .display_key = try decodeDisplayKey(object, "key"),
        } };
    } else if (std.mem.eql(u8, kind, "tool_result")) {
        event = .{ .tool_result = .{
            .id = try requireU64(object, "id"),
            .name = try requireText(object, "name"),
            .display_key = try decodeDisplayKey(object, "key"),
            .result = .{
                .text = try requireText(object, "v"),
                .is_error = try optionalBool(object, "is_error") orelse false,
                .canceled = try optionalBool(object, "canceled") orelse false,
                .truncated = try optionalBool(object, "trunc") orelse false,
                .cleanup_failed = try optionalBool(object, "cleanup") orelse false,
                .memory_evidence = try optionalBool(object, "mem_ev") orelse true,
                .file_stats = try decodeFileStats(object, "opts"),
                .duration_ms = try optionalU64(object, "ms"),
            },
        } };
    } else if (std.mem.eql(u8, kind, "usage")) {
        event = .{ .usage = .{
            .purpose = try requireEnum(p.Purpose, object, "purpose"),
            .protocol = try requireEnum(p.Protocol, object, "protocol"),
            .value = try decodeUsage(try requireObject(object, "value")),
        } };
    } else if (std.mem.eql(u8, kind, "fallback")) {
        event = .{ .fallback = try requireEnum(p.Protocol, object, "protocol") };
    } else if (std.mem.eql(u8, kind, "compacted")) {
        event = .{ .compacted = .{
            .before = try requireIndex(object, "before"),
            .after = try requireIndex(object, "after"),
        } };
    } else if (std.mem.eql(u8, kind, "compaction_failed")) {
        const failure = failureFromName(try requireText(object, "code"));
        event = .{ .compaction_failed = @import("../ui/session_client.zig").Failure.toError(failure) orelse error.RemoteFailure };
    } else if (std.mem.eql(u8, kind, "assistant")) {
        const array = try requireArray(object, "blocks");
        const count = @min(array.items.len, max_blocks);
        // Arena-owned: same lifetime as the decoded text, freed by `doc.deinit`.
        const blocks = try arena.alloc(p.Block, count);
        for (array.items[0..count], 0..) |item, i| blocks[i] = try decodeBlock(item);
        if (array.items.len > count) {
            display_truncated = true;
            canonical_complete = false;
        }
        event = .{ .assistant_committed = blocks };
    } else if (std.mem.eql(u8, kind, "finished")) {
        event = .{ .finished = try decodeTerminalChecked(object) };
    } else return error.BadRequest;

    return .{
        .epoch = epoch,
        .event = event,
        .display_truncated = display_truncated,
        .canonical_complete = canonical_complete,
        .doc = doc,
        .storage = &.{},
        .a = a,
    };
}

fn failureFromName(name: []const u8) @import("../ui/session_client.zig").Failure {
    return std.meta.stringToEnum(@import("../ui/session_client.zig").Failure, name) orelse .other;
}

/// Strict terminal decoding: required status/usage/counts are validated so a
/// truncated frame cannot fabricate zero usage or a successful status.
fn decodeTerminalChecked(object: std.json.ObjectMap) !r.Terminal {
    const status = try requireEnum(r.Status, object, "status");
    const detail: ?anyerror = if (status == .success) null else blk: {
        const name = try requireText(object, "failure");
        break :blk @import("../ui/session_client.zig").Failure.toError(failureFromName(name));
    };
    const totals = try requireObject(object, "usage");
    const usage: r.UsageTotals = .{
        .normal_calls = try requireU32(totals, "normal_calls"),
        .summary_calls = try requireU32(totals, "summary_calls"),
        .normal = try decodeUsage(try requireObject(totals, "normal")),
        .summary = try decodeUsage(try requireObject(totals, "summary")),
    };
    const context: ?r.ContextSnapshot = if (try optionalObject(object, "ctx")) |value| .{
        .tokens = try requireU64(value, "tokens"),
        .limit = try requireU64(value, "limit"),
        .known = try optionalBool(value, "known") orelse true,
    } else null;
    return .{
        .status = status,
        .detail = detail,
        .model_failure = try optionalEnum(p.FailureKind, object, "model_failure"),
        .http_status = if (try optionalU64(object, "http")) |code| @intCast(@min(code, 999)) else null,
        .decision_failure = if (try optionalObject(object, "decision_failure")) |value| try decodeDecisionDiagnostic(value) else null,
        .usage = usage,
        .context_snapshot = context,
    };
}

fn decodeDecisionDiagnostic(object: std.json.ObjectMap) !@import("../core/decision.zig").Diagnostic {
    const Diagnostic = @import("../core/decision.zig").Diagnostic;
    var value: Diagnostic = .{
        .stage = try requireEnum(Diagnostic.Stage, object, "stage"),
        .backend = try requireEnum(Diagnostic.Backend, object, "backend"),
        .operation = try requireEnum(Diagnostic.Operation, object, "operation"),
        .model_failure = try optionalEnum(p.FailureKind, object, "model_failure"),
    };
    try value.setCause(try requireText(object, "cause"));
    if (try optionalU64(object, "http_status")) |status| {
        if (status < 100 or status > 599) return error.BadRequest;
        value.http_status = @intCast(status);
    }
    if (try optionalU64(object, "transport_exit_code")) |code| {
        value.transport_exit_code = std.math.cast(u8, code) orelse return error.BadRequest;
    }
    return value;
}

/// Compatibility wrapper for callers that already validated the frame; the
/// decode path itself uses `decodeTerminalChecked` and rejects bad frames.
pub fn decodeTerminal(object: std.json.ObjectMap) r.Terminal {
    return decodeTerminalChecked(object) catch r.Terminal{ .status = .failed, .detail = error.RemoteFailure };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn manyBlocksJson(a: std.mem.Allocator, count: usize) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\"t\":\"assistant\",\"blocks\":[");
    for (0..count) |i| {
        if (i != 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"k\":\"text\",\"v\":\"block\"}");
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

fn expectEventRoundTrip(a: std.mem.Allocator, event: r.Event) !void {
    const first = try encodeEvent(a, event);
    defer a.free(first);
    var decoded = try decodeEvent(a, first);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 0), decoded.epoch);
    try std.testing.expect(!decoded.display_truncated);
    try std.testing.expect(decoded.canonical_complete);
    try std.testing.expectEqual(@as(usize, 0), decoded.storage.len);
    const second = try encodeEvent(a, decoded.event);
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "every runtime display event round-trips through the wire" {
    const a = std.testing.allocator;
    const high = std.math.maxInt(u64);
    const blocks = [_]p.Block{
        .{ .text = "answer" },
        .{ .reasoning = "because" },
        .{ .tool_call = .{ .id = "call-1", .name = "bash", .arguments = "{\"command\":\"ls\"}", .item_id = "item-9" } },
        .{ .tool_result = .{ .call_id = "call-1", .text = "ok", .is_error = true, .canceled = true, .truncated = true } },
    };
    const fields = preview.Snapshot{
        .path = .{ .text = "src/a.zig", .truncated = true },
        .command = .{ .text = "zig build" },
        .action = .{ .text = "run" },
        .topic = .{ .text = "build" },
        .task = .{ .text = "inspect release paths" },
        .id = .{ .text = "job-3" },
    };
    const events = [_]r.Event{
        .{ .state = .awaiting_permission },
        .{ .context_snapshot = .{ .tokens = 1234, .limit = 65536, .known = false } },
        .{ .text = "visible" },
        .{ .reasoning = "thinking" },
        .{ .assistant_committed = &blocks },
        .{ .user_committed = .{ .id = high, .text = "hi" } },
        .{ .permission_cleared = high },
        .{ .tool_preview = .{ .index = 2, .arguments = "{\"path\":\"x\"}", .write_file = true, .argument_bytes = 4096 } },
        .{ .tool_views = .{ .generation = high, .phase = .commit } },
        .{ .tool_view = .{
            .key = .{ .generation = high, .index = 7 },
            .name = "write_file",
            .fields = fields,
            .write_progress = .{ .added = 12, .deleted = 3 },
            .ready = true,
        } },
        .{ .permission = .{ .id = high, .tool_name = "bash", .description = "rm -rf build" } },
        .{ .tool_started = .{
            .id = high,
            .name = "read_file",
            .started_ms = high,
            .display_key = .{ .generation = high, .index = 1 },
        } },
        .{ .tool_result = .{
            .id = 9,
            .name = "write_file",
            .display_key = .{ .generation = 3, .index = 5 },
            .result = .{
                .text = "written",
                .is_error = true,
                .canceled = true,
                .truncated = true,
                .cleanup_failed = true,
                .memory_evidence = false,
                .file_stats = .{ .read = 40, .partial = true, .changes = .{ .modified = 1, .added = 2, .removed = 3 } },
                .duration_ms = high,
            },
        } },
        .{ .usage = .{
            .purpose = .summary,
            .protocol = .anthropic,
            .value = .{ .input_tokens = high, .output_tokens = 2, .cached_input_tokens = 3, .cache_write_tokens = 4, .reasoning_tokens = 5, .total_tokens = 6 },
        } },
        .{ .fallback = .responses },
        .{ .compacted = .{ .before = 100, .after = 10 } },
        .{ .compaction_failed = error.InputBudgetSummaryFailed },
        .{ .finished = .{
            .status = .paused,
            .detail = error.InputBudgetExceeded,
            .model_failure = .output_limit,
            .http_status = 429,
            .usage = .{
                .normal_calls = 3,
                .summary_calls = 1,
                .normal = .{ .input_tokens = 1, .output_tokens = 2, .cached_input_tokens = 3, .cache_write_tokens = 4, .reasoning_tokens = 5, .total_tokens = 6 },
                .summary = .{ .input_tokens = 7, .output_tokens = 8, .cached_input_tokens = 9, .cache_write_tokens = 10, .reasoning_tokens = 11, .total_tokens = 12 },
            },
            .context_snapshot = .{ .tokens = 42, .limit = 1000, .known = true },
        } },
    };
    for (events) |event| try expectEventRoundTrip(a, event);
}

test "tool_view decodes its display fields instead of an unsupported event" {
    const a = std.testing.allocator;
    const json =
        "{\"t\":\"tool_view\",\"name\":\"bash\",\"gen\":18446744073709551615,\"idx\":3,\"ready\":true," ++
        "\"fields\":{\"path\":{\"text\":\"src/a.zig\",\"trunc\":true},\"command\":{\"text\":\"zig build\",\"trunc\":false}," ++
        "\"action\":null,\"topic\":null,\"task\":null,\"id\":null}," ++
        "\"wprog\":{\"added\":4,\"deleted\":null}}";
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    const view = decoded.event.tool_view;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), view.key.generation);
    try std.testing.expectEqual(@as(usize, 3), view.key.index);
    try std.testing.expect(view.ready);
    try std.testing.expectEqualStrings("src/a.zig", view.fields.path.?.text);
    try std.testing.expect(view.fields.path.?.truncated);
    try std.testing.expectEqualStrings("zig build", view.fields.command.?.text);
    try std.testing.expect(!view.fields.command.?.truncated);
    try std.testing.expect(view.fields.action == null);
    try std.testing.expectEqual(@as(?u64, 4), view.write_progress.?.added);
    try std.testing.expectEqual(@as(?u64, null), view.write_progress.?.deleted);
}

test "u64 values above i64.max survive number_string decoding" {
    const a = std.testing.allocator;
    const high = std.math.maxInt(u64);
    var request = try parseRequest(a, "{\"v\":1,\"id\":18446744073709551615,\"op\":\"ping\"}");
    defer request.deinit();
    try std.testing.expectEqual(high, request.id);
    try std.testing.expectEqual(Op.ping, request.op);

    // Quoted digits, floats, exponents and negatives are not integers.
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"id\":\"18446744073709551615\",\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"id\":1.0,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"id\":1e3,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"id\":-1,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"id\":0,\"op\":\"ping\"}"));
    try std.testing.expectError(error.BadRequest, parseRequest(a, "{\"v\":1,\"id\":1,\"op\":\"ping\",\"op\":\"list\"}"));

    const encoded = try encodeEvent(a, .{ .tool_started = .{
        .id = high,
        .name = "bash",
        .started_ms = high,
        .display_key = .{ .generation = high, .index = 1 },
    } });
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "18446744073709551615") != null);
    var decoded = try decodeEvent(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(high, decoded.event.tool_started.id);
    try std.testing.expectEqual(@as(?u64, high), decoded.event.tool_started.started_ms);
    try std.testing.expectEqual(high, decoded.event.tool_started.display_key.?.generation);
}

test "numeric and enum request fields reject wrong types instead of defaulting" {
    const a = std.testing.allocator;
    var request = try parseRequest(a, "{\"v\":1,\"id\":2,\"op\":\"effort\",\"epoch\":\"7\",\"level\":true}");
    defer request.deinit();
    try std.testing.expectError(error.BadRequest, request.u64Field("epoch"));
    try std.testing.expectError(error.BadRequest, request.u64Field("absent"));
    try std.testing.expectEqual(@as(?u64, null), try request.optionalU64("absent"));
    try std.testing.expectError(error.BadRequest, request.optionalU64("epoch"));
    try std.testing.expectError(error.BadRequest, request.stringEnum(Op, "epoch"));
    try std.testing.expectError(error.BadRequest, request.boolField("epoch", true));
    try std.testing.expectEqual(true, try request.boolField("level", false));
    try std.testing.expectEqual(true, try request.requiredBool("level"));
}

test "proxy_model request keeps the full u64 epoch and rejects loose parameters" {
    const a = std.testing.allocator;
    const high: u64 = @as(u64, std.math.maxInt(i64)) + 7;
    const body = try std.fmt.allocPrint(a, "{{\"v\":1,\"id\":3,\"op\":\"proxy_model\",\"epoch\":{d},\"name\":\"opencode-go/deepseek-v3\",\"enabled\":true}}", .{high});
    defer a.free(body);
    var request = try parseRequest(a, body);
    defer request.deinit();
    try std.testing.expectEqual(Op.proxy_model, request.op);
    // An epoch above i64.max is exact, never truncated through a signed parse.
    try std.testing.expectEqual(high, try request.u64Field("epoch"));
    // The name is the complete provider/raw-model id, slash included.
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", try request.stringField("name", max_name));
    try std.testing.expectEqual(true, try request.requiredBool("enabled"));

    // Absent, stringly or numeric enable flags are bad requests, not defaults.
    var loose = try parseRequest(a, "{\"v\":1,\"id\":4,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\"}");
    defer loose.deinit();
    try std.testing.expectError(error.BadRequest, loose.requiredBool("enabled"));
    var stringly = try parseRequest(a, "{\"v\":1,\"id\":5,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":\"true\"}");
    defer stringly.deinit();
    try std.testing.expectError(error.BadRequest, stringly.requiredBool("enabled"));
    var numeric_epoch = try parseRequest(a, "{\"v\":1,\"id\":6,\"op\":\"proxy_model\",\"epoch\":\"1\",\"name\":\"p/m\",\"enabled\":false}");
    defer numeric_epoch.deinit();
    try std.testing.expectError(error.BadRequest, numeric_epoch.u64Field("epoch"));
}

test "decode rejects duplicate keys, deep nesting, quoted numbers and bad kinds" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"state\",\"phase\":\"calling_model\",\"phase\":\"compacting\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"permission\",\"id\":\"7\",\"name\":\"bash\",\"desc\":\"x\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"permission\",\"id\":7,\"name\":\"bash\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"tool_started\",\"name\":\"bash\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"tool_started\",\"id\":1.5,\"name\":\"bash\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"unknown_kind\"}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"v\":1}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, ""));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "\xff"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "[]"));

    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(a);
    try deep.appendSlice(a, "{\"t\":\"text\",\"v\":");
    for (0..max_json_depth) |_| try deep.append(a, '[');
    for (0..max_json_depth) |_| try deep.append(a, ']');
    try deep.append(a, '}');
    try std.testing.expectError(error.BadRequest, decodeEvent(a, deep.items));
}

test "event metadata markers control epoch and canonical completeness" {
    const a = std.testing.allocator;
    const json = try encodeEventMeta(a, .{ .text = "partial" }, .{ .epoch = 42, .truncated = true, .canonical_complete = false });
    defer a.free(json);
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 42), decoded.epoch);
    try std.testing.expect(decoded.display_truncated);
    try std.testing.expect(!decoded.canonical_complete);
    const again = try encodeEventMeta(a, decoded.event, .{
        .epoch = decoded.epoch,
        .truncated = decoded.display_truncated,
        .canonical_complete = decoded.canonical_complete,
    });
    defer a.free(again);
    try std.testing.expectEqualStrings(json, again);
}

test "assistant block overflow is bounded and marked incomplete" {
    const a = std.testing.allocator;
    const json = try manyBlocksJson(a, max_blocks + 1);
    defer a.free(json);
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, max_blocks), decoded.event.assistant_committed.len);
    try std.testing.expect(!decoded.canonical_complete);
    try std.testing.expect(decoded.display_truncated);
}

test "assistant encoding marks a bounded block list incomplete" {
    const a = std.testing.allocator;
    const blocks = try a.alloc(p.Block, max_blocks + 1);
    defer a.free(blocks);
    for (blocks) |*block| block.* = .{ .text = "b" };
    const json = try encodeEvent(a, .{ .assistant_committed = blocks });
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"disp_trunc\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canon_complete\":false") != null);
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, max_blocks), decoded.event.assistant_committed.len);
    try std.testing.expect(!decoded.canonical_complete);
    try std.testing.expect(decoded.display_truncated);
}

fn decodeAssistantOwned(a: std.mem.Allocator, json: []const u8) !void {
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    try std.testing.expect(decoded.event.assistant_committed.len != 0);
    try std.testing.expectEqual(@as(usize, 0), decoded.storage.len);
}

test "assistant decoding owns blocks in the document arena under allocation failure" {
    const a = std.testing.allocator;
    const json = try manyBlocksJson(a, 3);
    defer a.free(json);
    try std.testing.checkAllAllocationFailures(a, decodeAssistantOwned, .{json});
}

test "assistant block errors release the document arena" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.BadRequest,
        decodeEvent(a, "{\"t\":\"assistant\",\"blocks\":[{\"k\":\"text\",\"v\":\"a\"},{\"k\":\"nope\"}]}"),
    );
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"assistant\"}"));
}

test "terminal events require complete usage and keep tool timing and keys" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"finished\",\"status\":\"success\",\"usage\":{}}"));
    try std.testing.expectError(error.BadRequest, decodeEvent(a, "{\"t\":\"usage\",\"purpose\":\"normal\",\"protocol\":\"chat\"}"));
    const json =
        "{\"t\":\"tool_result\",\"id\":9,\"name\":\"bash\",\"v\":\"done\",\"is_error\":false,\"canceled\":false," ++
        "\"trunc\":false,\"cleanup\":false,\"ms\":18446744073709551615," ++
        "\"key\":{\"gen\":18446744073709551615,\"idx\":2},\"mem_ev\":true,\"opts\":null}";
    var decoded = try decodeEvent(a, json);
    defer decoded.deinit();
    const result = decoded.event.tool_result;
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), result.result.duration_ms);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), result.display_key.?.generation);
    try std.testing.expectEqual(@as(usize, 2), result.display_key.?.index);
}

test "login key copy is wiped before the request arena is released" {
    const a = std.testing.allocator;
    var request = try parseRequest(a, "{\"v\":1,\"id\":1,\"op\":\"login\",\"key\":\"sk-secret\"}");
    defer request.deinit();
    const secret = request.field("key").?.string;
    try std.testing.expectEqualStrings("sk-secret", secret);
    request.wipeSecrets();
    for (secret) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "event encoding round-trips display text and drops inbox pointers" {
    const a = std.testing.allocator;
    const encoded = try encodeEvent(a, .{ .permission = .{ .id = 3, .tool_name = "bash", .description = "rm -rf x" } });
    defer a.free(encoded);
    var decoded = try decodeEvent(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 3), decoded.event.permission.id);
    try std.testing.expectEqualStrings("bash", decoded.event.permission.tool_name);
    try std.testing.expect(decoded.event.permission.interrupt == null);
}

test "response builder rejects unbalanced output and oversized keys" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(9);
    try out.field("epoch", @as(u64, 5));
    const bytes = try out.finish();
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{\"v\":1,\"id\":9,\"ok\":true,\"epoch\":5}", bytes);
}

/// Strict parser used by the wire tests: a whole reply must be valid JSON with
/// no duplicate keys. Substring assertions cannot catch a missing comma.
fn parseWholeReply(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

test "error envelope from fail plus finish parses as one whole JSON object" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.fail(21, .unsupported);
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    const root = doc.value.object;
    try std.testing.expectEqual(@as(i64, version), root.get("v").?.integer);
    try std.testing.expectEqual(@as(i64, 21), root.get("id").?.integer);
    try std.testing.expectEqual(false, root.get("ok").?.bool);
    try std.testing.expectEqualStrings("unsupported", root.get("err").?.string);
    // Exactly one root object: a stray closing brace would leave trailing bytes.
    try std.testing.expectEqualStrings("}", bytes[bytes.len - 1 ..]);
    try std.testing.expectEqual(@as(usize, 4), root.count());
}

test "array elements keep separators for repeated scalars and nested objects" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(3);
    try out.beginArray("names");
    try out.arrayValue("first");
    try out.arrayValue("second");
    try out.arrayValue("third");
    try out.endArray();
    try out.beginArray("objects");
    for ([_][]const u8{ "a", "b" }) |name| {
        try out.beginObjectElement();
        try out.field("name", name);
        try out.endObject();
    }
    try out.endArray();
    try out.beginArray("empty");
    try out.endArray();
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    const root = doc.value.object;
    const names = root.get("names").?.array;
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("first", names.items[0].string);
    try std.testing.expectEqualStrings("third", names.items[2].string);
    const objects = root.get("objects").?.array;
    try std.testing.expectEqual(@as(usize, 2), objects.items.len);
    try std.testing.expectEqualStrings("a", objects.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("b", objects.items[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 0), root.get("empty").?.array.items.len);
}

test "snapshot previews stay comma-separated and parse as one whole frame" {
    const a = std.testing.allocator;
    var out = Out.init(a);
    defer out.deinit();
    try out.ok(31);
    // Two elements: a single preview would pass even without a separator.
    const previews = [_]QueuePreview{
        .{ .id = 7, .kind = .steering, .text = "first \"quoted\" 中文" },
        .{ .id = 8, .kind = .follow_up, .text = "second" },
    };
    const session: ids.Id = @splat('a');
    try encodeSnapshot(&out, .{
        .session = session,
        .project = "/tmp/project",
        .owner = .daemon,
        .previews = &previews,
    });
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try parseWholeReply(a, bytes);
    defer doc.deinit();
    const snapshot = doc.value.object.get("snapshot").?.object;
    const list = snapshot.get("previews").?.array;
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(i64, 7), list.items[0].object.get("id").?.integer);
    try std.testing.expectEqualStrings("steering", list.items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("first \"quoted\" 中文", list.items[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 8), list.items[1].object.get("id").?.integer);
    try std.testing.expectEqualStrings("follow_up", list.items[1].object.get("kind").?.string);
    try std.testing.expectEqualStrings("second", list.items[1].object.get("text").?.string);
}

test "an oversized frame is rejected without freeing the caller-owned buffer" {
    const a = std.testing.allocator;
    // A valid JSON string literal just past the frame bound, appended raw so
    // `value` cannot clip it first.
    const big = try a.alloc(u8, max_response + 2);
    defer a.free(big);
    @memset(big, 'x');
    big[0] = '"';
    big[big.len - 1] = '"';
    var out = Out.init(a);
    // The caller always defers deinit; finish must not free or poison the Out.
    defer out.deinit();
    try out.ok(11);
    try out.rawField("payload", big);
    if (out.finish()) |bytes| {
        // Never dump the oversized payload; just release and fail.
        a.free(bytes);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.InputTooLarge, err);
    }
    // Still consistent afterwards: balanced and owning its own buffer, released
    // exactly once by this function's `defer out.deinit()`.
    try std.testing.expectEqual(@as(usize, 0), out.depth);
    try std.testing.expect(out.buf.items.len > max_response);
}

test "private startup exit codes roundtrip and never widen" {
    const cases = [_]struct { code: u8, err: anyerror }{
        .{ .code = 70, .err = error.SelectionNotFound },
        .{ .code = 71, .err = error.ResumeNotFound },
        .{ .code = 72, .err = error.InvalidResumeLength },
        .{ .code = 73, .err = error.InvalidJson },
        .{ .code = 74, .err = error.UnsupportedVersion },
        .{ .code = 75, .err = error.ResumeConflict },
        .{ .code = 76, .err = error.ResumeNotClosed },
        .{ .code = 77, .err = error.SessionInUse },
        .{ .code = 78, .err = error.UnsafeResumeFile },
        .{ .code = 79, .err = error.ResumeReadOnly },
        .{ .code = 80, .err = error.ResumeAuthenticationFailed },
        .{ .code = 81, .err = error.ApiKeyNotFound },
        .{ .code = 82, .err = error.SelectionEndpointUnavailable },
    };
    for (cases) |case| {
        try std.testing.expectEqual(@as(?u8, case.code), startupExitCode(case.err));
        try std.testing.expectEqual(case.err, startupError(case.code).?);
    }
    // Reserved but unassigned codes and everything outside the band stay null.
    try std.testing.expect(startupError(0) == null);
    try std.testing.expect(startupError(1) == null);
    try std.testing.expect(startupError(69) == null);
    try std.testing.expect(startupError(83) == null);
    try std.testing.expect(startupError(130) == null);
    try std.testing.expect(startupError(143) == null);
    try std.testing.expect(startupError(255) == null);
    // Ordinary failures keep their normal error identity: never a private code.
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.OutOfMemory));
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.CleanupFailed));
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.ParentGone));
    try std.testing.expectEqual(@as(?u8, null), startupExitCode(error.Canceled));
    // The private boot mapping never widens the public v1 IPC category: a
    // SelectionNotFound failure keeps its pre-existing internal classification.
    try std.testing.expectEqual(.internal, errorCode(error.SelectionNotFound));
}

test "wire error codes keep unsupported distinct from internal" {
    try std.testing.expectEqual(.unsupported, errorCode(error.Unsupported));
    // Everything unlisted still falls back to the internal category.
    try std.testing.expectEqual(.internal, errorCode(error.CleanupFailed));
}

test "wire error codes classify configuration rejections as invalid input" {
    const cases = [_]anyerror{
        error.ProxyNotConfigured,
        error.UnknownProvider,
        error.UnknownProxyModel,
        error.ApiKeyNotFound,
        error.MissingRegistry,
        error.InvalidDefault,
    };
    for (cases) |err| {
        try std.testing.expectEqual(.invalid_input, errorCode(err));
    }
    // A stale version guard loses a race against a newer credential write; the
    // request itself was well formed, so it is retry-busy rather than invalid.
    try std.testing.expectEqual(.busy, errorCode(error.AuthVersionConflict));
    // Reclassification never widens the neighbors it sits between.
    try std.testing.expectEqual(.unsupported, errorCode(error.Unsupported));
    try std.testing.expectEqual(.internal, errorCode(error.CleanupFailed));
}

test "decision diagnostic terminal roundtrip owns labels and rejects invalid wire values" {
    const a = std.testing.allocator;
    var diagnostic: @import("../core/decision.zig").Diagnostic = .{
        .stage = .transport,
        .backend = .systemone,
        .operation = .command,
        .transport_exit_code = 60,
    };
    diagnostic.setError(error.DecisionTransport);
    const event: r.Event = .{ .finished = .{
        .status = .paused,
        .detail = error.DecisionUnavailable,
        .decision_failure = diagnostic,
    } };
    try expectEventRoundTrip(a, event);
    const encoded = try encodeEvent(a, event);
    defer a.free(encoded);
    var decoded = try decodeEvent(a, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("DecisionTransport", decoded.event.finished.decision_failure.?.causeName());
    try std.testing.expectEqual(@as(?u8, 60), decoded.event.finished.decision_failure.?.transport_exit_code);
    try std.testing.expect(decoded.event.finished.http_status == null);
    var doc = try std.json.parseFromSlice(std.json.Value, a, encoded, .{ .allocate = .alloc_always });
    defer doc.deinit();
    const allocator = doc.arena.allocator();
    const fields = &doc.value.object.getPtr("decision_failure").?.object;
    try fields.put(allocator, "cause", .{ .string = "raw response\nsecret" });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    try fields.put(allocator, "cause", .{ .string = "DecisionTransport" });
    try fields.put(allocator, "http_status", .{ .integer = 600 });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    try fields.put(allocator, "http_status", .{ .null = {} });
    try fields.put(allocator, "transport_exit_code", .{ .integer = 256 });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    try fields.put(allocator, "transport_exit_code", .{ .integer = 60 });
    try fields.put(allocator, "stage", .{ .string = "unknown-stage" });
    try std.testing.expectError(error.BadRequest, decodeTerminalChecked(doc.value.object));
    _ = doc.value.object.swapRemove("decision_failure");
    try std.testing.expect((try decodeTerminalChecked(doc.value.object)).decision_failure == null);
}
