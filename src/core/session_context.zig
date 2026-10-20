//! Session preface: two AGENTS.md sources plus cwd, shell, project root and process platform.
//! Global files live in the thin home (`<HOME>/.thin`). Project files live only at the
//! git root of the session cwd, or at that cwd when it is not inside a git work tree.
//! Intermediate parents and subdirectories are not searched. Override files win over
//! the base name at the same directory. Missing or unreadable files are skipped.
//! 中文：只注入两处 AGENTS（thin 主目录、仓库根），缺文件就跳过；总正文不超过 32KiB。

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("../platform/filesystem.zig");

/// Combined raw AGENTS file bytes injected into one session preface.
pub const max_agents_bytes: usize = 32 * 1024;

/// Body used when a later turn drops previously injected AGENTS text.
pub const agents_cleared = "source: none\n";

pub const Source = enum { global, project };

pub const Snapshot = struct {
    cwd: []const u8,
    shell: []const u8,
    project_root: []const u8,
    /// Platform of the running Thin binary, not a remote host or physical CPU probe.
    os: std.Target.Os.Tag = builtin.os.tag,
    arch: std.Target.Cpu.Arch = builtin.cpu.arch,
    /// Formatted layer text. Empty when both sources are absent.
    agents: []const u8,
    /// Concatenated file bytes only, in discovery order. Never above max_agents_bytes.
    agents_text: []const u8,
    truncated: bool,
};

pub const Environment = struct {
    cwd: []const u8,
    shell: []const u8,
    project_root: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
};

/// SHELL is used when it is a single UTF-8 line. Otherwise the session reports bash.
pub fn shellName(value: ?[]const u8) []const u8 {
    const raw = value orelse return "bash";
    if (raw.len == 0 or raw.len > 256 or !std.unicode.utf8ValidateSlice(raw)) return "bash";
    for (raw) |byte| if (byte < 32 or byte == 127) return "bash";
    return raw;
}

pub fn validateSnapshot(snap: Snapshot) !void {
    try requireField(snap.cwd, true);
    try requireField(snap.shell, false);
    try requireField(snap.project_root, true);
    if (snap.agents_text.len > max_agents_bytes) return error.AgentsTooLarge;
    if (snap.agents.len != 0 and !std.unicode.utf8ValidateSlice(snap.agents)) return error.InvalidSessionContext;
}

fn requireField(value: []const u8, absolute: bool) !void {
    if (value.len == 0 or value.len > 4096 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidSessionContext;
    if (std.mem.findScalar(u8, value, '\n') != null or std.mem.findScalar(u8, value, '\r') != null) return error.InvalidSessionContext;
    if (absolute and !std.fs.path.isAbsolute(value)) return error.InvalidSessionContext;
}

pub fn environmentOf(snap: Snapshot) Environment {
    return .{ .cwd = snap.cwd, .shell = snap.shell, .project_root = snap.project_root, .os = snap.os, .arch = snap.arch };
}

pub fn formatEnvironment(a: std.mem.Allocator, env: Environment, update: bool) ![]u8 {
    try requireField(env.cwd, true);
    try requireField(env.shell, false);
    try requireField(env.project_root, true);
    return std.fmt.allocPrint(a, "{s}\ncwd: {s}\nshell: {s}\nproject_root: {s}\nos: {s}\narch: {s}\n", .{
        if (update) "environment update" else "environment",
        env.cwd,
        env.shell,
        env.project_root,
        @tagName(env.os),
        @tagName(env.arch),
    });
}

pub fn parseEnvironment(text: []const u8) ?Environment {
    const nl = std.mem.findScalar(u8, text, '\n') orelse return null;
    const header = text[0..nl];
    if (!std.mem.eql(u8, header, "environment") and !std.mem.eql(u8, header, "environment update")) return null;
    var rest = text[nl + 1 ..];
    const cwd = oneField(&rest, "cwd: ") orelse return null;
    const shell = oneField(&rest, "shell: ") orelse return null;
    const project_root = oneField(&rest, "project_root: ") orelse return null;
    const os = oneField(&rest, "os: ") orelse return null;
    const arch = oneField(&rest, "arch: ") orelse return null;
    if (rest.len != 0) return null;
    requireField(cwd, true) catch return null;
    requireField(shell, false) catch return null;
    requireField(project_root, true) catch return null;
    return .{
        .cwd = cwd,
        .shell = shell,
        .project_root = project_root,
        .os = std.meta.stringToEnum(std.Target.Os.Tag, os) orelse return null,
        .arch = std.meta.stringToEnum(std.Target.Cpu.Arch, arch) orelse return null,
    };
}

pub fn parseAgentsBody(text: []const u8) ?[]const u8 {
    const update = "agents update\n";
    const fresh = "agents\n";
    if (std.mem.startsWith(u8, text, update)) return text[update.len..];
    if (std.mem.startsWith(u8, text, fresh)) return text[fresh.len..];
    return null;
}

pub fn agentsEquivalent(body: []const u8, current: []const u8) bool {
    const normalized = if (std.mem.eql(u8, body, agents_cleared)) "" else body;
    return std.mem.eql(u8, normalized, current);
}

fn oneField(rest: *[]const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rest.*, prefix)) return null;
    const after = rest.*[prefix.len..];
    const nl = std.mem.findScalar(u8, after, '\n') orelse return null;
    rest.* = after[nl + 1 ..];
    return after[0..nl];
}

const Read = union(enum) {
    missing,
    invalid,
    data: struct { bytes: []u8, truncated: bool },
};

/// Read the two allowed AGENTS sources and the project root for `cwd`.
/// `home` is the user home directory, not the `.thin` directory itself.
/// An empty home skips the global source. Allocations belong to `a`.
pub fn load(a: std.mem.Allocator, io: std.Io, home: []const u8, cwd: []const u8, shell: []const u8) !Snapshot {
    if (home.len != 0) try requireField(home, true);
    const shell_text = shellName(shell);
    var opened = try fs.Root.open(a, io, cwd);
    const canonical_cwd = try a.dupe(u8, opened.path);
    opened.deinit();
    errdefer a.free(canonical_cwd);

    const project_root = try findProjectRoot(a, io, canonical_cwd);
    errdefer a.free(project_root);

    var raw: std.ArrayList(u8) = .empty;
    var formatted: std.ArrayList(u8) = .empty;
    var budget: usize = max_agents_bytes;
    var truncated = false;

    var global_opt = try openThinHome(a, io, home);
    if (global_opt) |*global| {
        defer global.deinit();
        try takeLayer(a, io, global.dir.handle, global.path, .global, &budget, &truncated, &raw, &formatted);
    }

    var project = try fs.Root.open(a, io, project_root);
    defer project.deinit();
    try takeLayer(a, io, project.dir.handle, project.path, .project, &budget, &truncated, &raw, &formatted);

    const snap = Snapshot{
        .cwd = canonical_cwd,
        .shell = try a.dupe(u8, shell_text),
        .project_root = project_root,
        .agents = formatted.items,
        .agents_text = raw.items,
        .truncated = truncated,
    };
    try validateSnapshot(snap);
    return snap;
}

fn openThinHome(a: std.mem.Allocator, io: std.Io, home: []const u8) !?fs.Root {
    if (home.len == 0) return null;
    // Follow the HOME directory itself (the same path config.json uses), then
    // refuse to follow a symlinked AGENTS file inside .thin.
    var home_dir = std.Io.Dir.cwd().openDir(io, home, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer home_dir.close(io);
    var canonical: [4096]u8 = undefined;
    const n = try home_dir.realPath(io, &canonical);
    const thin = try std.fs.path.join(a, &.{ canonical[0..n], ".thin" });
    defer a.free(thin);
    return fs.Root.open(a, io, thin) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymlinkNotAllowed, error.AccessDenied => return null,
        else => return err,
    };
}

fn takeLayer(
    a: std.mem.Allocator,
    io: std.Io,
    dirfd: c_int,
    dir_path: []const u8,
    source: Source,
    budget: *usize,
    truncated: *bool,
    raw: *std.ArrayList(u8),
    formatted: *std.ArrayList(u8),
) !void {
    const choice = try preferred(a, io, dirfd, budget.*);
    switch (choice) {
        .missing, .invalid => return,
        .data => |data| {
            defer if (data.bytes.len != 0) a.free(data.bytes);
            if (data.truncated) truncated.* = true;
            // A later source can be nonempty while the shared budget is already
            // spent. Still name that source and mark the cut; an empty body with
            // no marker looks like the project file was absent.
            if (data.bytes.len == 0 and !data.truncated) return;
            const path = try std.fs.path.join(a, &.{ dir_path, data.name });
            defer a.free(path);
            try formatted.appendSlice(a, "source: ");
            try formatted.appendSlice(a, @tagName(source));
            try formatted.appendSlice(a, "\npath: ");
            try formatted.appendSlice(a, path);
            try formatted.appendSlice(a, "\n");
            if (data.bytes.len != 0) {
                try raw.appendSlice(a, data.bytes);
                try formatted.appendSlice(a, data.bytes);
                if (data.bytes[data.bytes.len - 1] != '\n') try formatted.append(a, '\n');
            }
            if (data.truncated) {
                try formatted.appendSlice(a, "[truncated]\n");
                budget.* = 0;
            } else {
                budget.* -= data.bytes.len;
            }
        },
    }
}

const Chosen = union(enum) {
    missing,
    invalid,
    data: struct { name: []const u8, bytes: []u8, truncated: bool },
};

/// Override wins. A present override is never replaced by AGENTS.md, even when empty or unreadable.
fn preferred(a: std.mem.Allocator, io: std.Io, dirfd: c_int, budget: usize) !Chosen {
    switch (try readFile(a, io, dirfd, "AGENTS.override.md", budget)) {
        .missing => {},
        .invalid => return .invalid,
        .data => |data| return .{ .data = .{ .name = "AGENTS.override.md", .bytes = data.bytes, .truncated = data.truncated } },
    }
    switch (try readFile(a, io, dirfd, "AGENTS.md", budget)) {
        .missing => return .missing,
        .invalid => return .invalid,
        .data => |data| return .{ .data = .{ .name = "AGENTS.md", .bytes = data.bytes, .truncated = data.truncated } },
    }
}

fn readFile(a: std.mem.Allocator, io: std.Io, dirfd: c_int, name: [*:0]const u8, budget: usize) !Read {
    const fd = fs.linux.openat(dirfd, name, fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0);
    if (fd < 0) {
        return switch (std.c._errno().*) {
            2 => .missing, // ENOENT
            // EPERM and EACCES: an optional AGENTS layer must not abort the turn.
            // A present override stays preferred, so this does not fall through to AGENTS.md.
            1, 13 => .invalid,
            40 => .invalid, // ELOOP
            else => fs.osError(),
        };
    }
    defer fs.closeFd(fd);
    const stat = try fs.fileFromFd(fd).stat(io);
    if (stat.kind != .file) return .invalid;
    if (stat.size == 0) return .{ .data = .{ .bytes = &.{}, .truncated = false } };
    if (budget == 0) return .{ .data = .{ .bytes = &.{}, .truncated = true } };

    const want: usize = @intCast(@min(stat.size, @as(u64, budget)));
    const buf = try a.alloc(u8, want);
    errdefer a.free(buf);
    const n = try fs.fileFromFd(fd).readPositionalAll(io, buf, 0);
    if (n != want) return error.FileChanged;
    const keep = utf8Prefix(buf);
    if (keep < buf.len and stat.size == want) {
        a.free(buf);
        return .invalid;
    }
    const exact = if (keep == buf.len) buf else try a.dupe(u8, buf[0..keep]);
    if (exact.ptr != buf.ptr) a.free(buf);
    fs.validateText(exact) catch {
        a.free(exact);
        return .invalid;
    };
    return .{ .data = .{ .bytes = exact, .truncated = stat.size > keep } };
}

fn utf8Prefix(bytes: []const u8) usize {
    var end: usize = 0;
    while (end < bytes.len) {
        const width = std.unicode.utf8ByteSequenceLength(bytes[end]) catch return end;
        if (width > bytes.len - end) return end;
        end += width;
    }
    return end;
}

/// Git root of `cwd`, or `cwd` itself when no `.git` marker exists on the walk.
/// The walk only looks for the marker. It does not read AGENTS.md along the way.
fn findProjectRoot(a: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    var root = try fs.Root.open(a, io, cwd);
    errdefer root.deinit();
    const start = try a.dupe(u8, root.path);
    errdefer a.free(start);

    var hops: usize = 0;
    while (hops < 256) : (hops += 1) {
        if (try gitMarker(io, root.dir.handle)) {
            const found = try a.dupe(u8, root.path);
            root.deinit();
            a.free(start);
            return found;
        }
        if (std.mem.eql(u8, root.path, "/")) break;
        const parent = try openParent(a, io, &root) orelse break;
        root.deinit();
        root = parent;
    }
    root.deinit();
    return start;
}

fn openParent(a: std.mem.Allocator, io: std.Io, root: *const fs.Root) !?fs.Root {
    const fd = try fs.openDirectory(root.dir.handle, "..");
    errdefer fs.closeFd(fd);
    var dir: std.Io.Dir = .{ .handle = fd };
    var buf: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    if (std.mem.eql(u8, root.path, buf[0..n])) {
        fs.closeFd(fd);
        return null;
    }
    const path = try a.dupe(u8, buf[0..n]);
    errdefer a.free(path);
    return .{ .dir = dir, .path = path, .io = io, .allocator = a };
}

fn gitMarker(io: std.Io, dirfd: c_int) !bool {
    const fd = fs.linux.openat(dirfd, ".git", fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0);
    if (fd < 0) {
        return switch (std.c._errno().*) {
            2 => false,
            // A symlink still marks the work tree. Do not follow it.
            40 => true,
            else => fs.osError(),
        };
    }
    defer fs.closeFd(fd);
    const stat = try fs.fileFromFd(fd).stat(io);
    return stat.kind == .file or stat.kind == .directory;
}
