//! MD4C 0.5.2's UTF-8 C ABI, declared explicitly (Zig 0.17 has no @cImport).
//! Upstream headers and MIT license are vendored under src/vendor/md4c.
const std = @import("std");
pub const Attribute = extern struct { text: ?[*]const u8, size: c_uint, types: ?[*]const c_int, offsets: ?[*]const c_uint };
pub const Ul = extern struct { tight: c_int, mark: u8 };
pub const Ol = extern struct { start: c_uint, tight: c_int, delimiter: u8 };
pub const Li = extern struct { task: c_int, mark: u8, offset: c_uint };
pub const H = extern struct { level: c_uint };
pub const Code = extern struct { info: Attribute, lang: Attribute, fence: u8 };
pub const Table = extern struct { columns: c_uint, head_rows: c_uint, body_rows: c_uint };
pub const Td = extern struct { alignment: c_int };
pub const Link = extern struct { href: Attribute, title: Attribute, autolink: c_int };
pub const Image = extern struct { src: Attribute, title: Attribute };
pub const Parser = extern struct {
    version: c_uint = 0,
    flags: c_uint = 0x0004 | 0x0008 | 0x0020 | 0x0040 | 0x0100 | 0x0200 | 0x0400 | 0x0800 | 0x1000,
    enter_block: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    leave_block: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    enter_span: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    leave_span: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    text: *const fn (c_int, [*]const u8, c_uint, ?*anyopaque) callconv(.c) c_int,
    debug: ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void = null,
    syntax: ?*const fn () callconv(.c) void = null,
};
pub const Entity = extern struct { name: [*:0]const u8, codepoints: [2]c_uint };
pub extern "c" fn md_parse([*]const u8, c_uint, *const Parser, ?*anyopaque) c_int;
pub extern "c" fn md_parse_inline([*]const u8, c_uint, *const Parser, ?*anyopaque) c_int;
pub const InlineSpan = extern struct {
    kind: c_int,
    opener_begin: c_uint,
    opener_end: c_uint,
    closer_begin: c_uint,
    closer_end: c_uint,
};
pub const InlineSpanCallback = *const fn (*const InlineSpan, ?*anyopaque) callconv(.c) c_int;
pub extern "c" fn md_parse_inline_spans([*]const u8, c_uint, *const Parser, ?InlineSpanCallback, ?*anyopaque) c_int;
pub extern "c" fn md_parse_spans([*]const u8, c_uint, *const Parser, ?InlineSpanCallback, ?*anyopaque) c_int;
pub const FenceSource = extern struct { fence_begin: c_uint, fence_end: c_uint, header_begin: c_uint, header_end: c_uint, fence_char: u8, closing_begin: c_uint, closing_end: c_uint };
pub const FenceCallback = *const fn (*const FenceSource, ?*anyopaque) callconv(.c) c_int;
pub const CellSource = extern struct { column: c_uint, begin: c_uint, end: c_uint, row_begin: c_uint, row_end: c_uint, alignment: c_int, header: c_int, cell_complete: c_int, row_complete: c_int, raw_begin: c_uint, raw_end: c_uint, next_begin: c_uint, present: c_int };
pub const CellCallback = *const fn (*const CellSource, ?*anyopaque) callconv(.c) c_int;
pub const CellContentCallback = *const fn (c_uint, c_uint, *c_int, ?*anyopaque) callconv(.c) c_int;
pub const TableContainer = extern struct { mark: u8, mark_indent: c_uint, contents_indent: c_uint };
pub const TableSource = extern struct { containers: ?[*]const TableContainer, n_containers: c_uint, header_begin: c_uint, body_begin: c_uint, header_complete: c_uint };
pub const TableSourceCallback = *const fn (*const TableSource, ?*anyopaque) callconv(.c) c_int;
pub const ReferenceStore = opaque {};
pub const ReferenceUpdate = opaque {};
pub const ReferenceDefinition = extern struct { begin: c_uint, end: c_uint, label: Attribute, destination: Attribute, title: Attribute };
pub const DefinitionCallback = *const fn (*const ReferenceDefinition, ?*anyopaque) callconv(.c) c_int;
pub const candidate_table: c_uint = 1;
pub const candidate_reference: c_uint = 2;
pub const CandidateCallback = *const fn (c_uint, c_uint, c_uint, ?*anyopaque) callconv(.c) c_int;
pub extern "c" fn md_reference_store_create(c_uint, usize) ?*ReferenceStore;
pub extern "c" fn md_reference_store_destroy(?*ReferenceStore) void;
pub extern "c" fn md_reference_store_prepare(*ReferenceStore, [*]const ReferenceDefinition, c_uint, *?*ReferenceUpdate) c_int;
pub extern "c" fn md_reference_store_commit(*ReferenceStore, ?*ReferenceUpdate) void;
pub extern "c" fn md_reference_store_abort(?*ReferenceUpdate) void;
pub const SourceCallbacks = extern struct { span: ?InlineSpanCallback = null, fence: ?FenceCallback = null, cell: ?CellCallback = null, cell_content: ?CellContentCallback = null, references: ?*const ReferenceStore = null, definition: ?DefinitionCallback = null, candidate: ?CandidateCallback = null, table: ?TableSourceCallback = null, partial_input: c_int = 0 };
pub const TableResume = extern struct { columns: c_uint, first_column: c_uint, alignments: [*]const c_int, skip: ?[*]const c_uint, partial_cell: c_int, containers: ?[*]const TableContainer = null, n_containers: c_uint = 0, first_line_partial: c_int = 0, trim_leading: c_int = 0 };
pub const TableFragmentResult = extern struct { closed: c_int = 0, end: c_uint = 0 };
pub extern "c" fn md_parse_table_fragment([*]const u8, c_uint, *const Parser, ?*const SourceCallbacks, *const TableResume, ?*TableFragmentResult, ?*anyopaque) c_int;
pub extern "c" fn md_parse_source([*]const u8, c_uint, *const Parser, ?*const SourceCallbacks, ?*anyopaque) c_int;
pub extern "c" fn md_parse_inline_source([*]const u8, c_uint, *const Parser, ?*const SourceCallbacks, ?*anyopaque) c_int;
pub const CodeStream = opaque {};
pub const CodeEvent = extern struct { kind: c_int, begin: u64, end: u64, byte: u8 };
pub const CodeAllocator = extern struct {
    alloc: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
};
pub const code_ok: c_int = 0;
pub const code_need_input: c_int = 1;
pub const code_need_drain: c_int = 2;
pub const code_closed: c_int = 3;
pub const code_done: c_int = 4;
pub const code_error: c_int = 5;
pub extern "c" fn md_stream_code_create(u8, usize, c_uint, c_uint, usize, u64) ?*CodeStream;
pub extern "c" fn md_stream_code_create_with_allocator(u8, usize, c_uint, c_uint, usize, u64, *const CodeAllocator) ?*CodeStream;
pub extern "c" fn md_stream_code_destroy(?*CodeStream) void;
pub extern "c" fn md_stream_code_feed(*CodeStream, ?[*]const u8, usize, c_int, *usize) c_int;
pub extern "c" fn md_stream_code_feed_at(*CodeStream, u64, ?[*]const u8, usize, c_int, *usize) c_int;
pub extern "c" fn md_stream_code_step(*CodeStream, usize, *usize, *CodeEvent, *c_int) c_int;
pub extern "c" fn md_stream_code_literalize(*CodeStream) c_int;
pub extern "c" fn md_stream_code_checkpoint(*CodeStream) c_int;
pub extern "c" fn md_stream_code_commit(*CodeStream) c_int;
pub extern "c" fn md_stream_code_abort(*CodeStream) c_int;
pub extern "c" fn entity_lookup([*]const u8, usize) ?*const Entity;
extern "c" fn thin_md4c_abi() c_int;
extern "c" fn thin_md4c_fault_test() c_int;
extern "c" fn thin_md4c_stream_blocks_test() c_int;

test "native code continuation source mapping and allocation faults" {
    try std.testing.expectEqual(@as(c_int, 0), thin_md4c_stream_blocks_test());
}

test "vendored parser preserves ownership at every allocation failure" {
    try std.testing.expectEqual(@as(c_int, 0), thin_md4c_fault_test());
}

test "vendored Markdown C ABI matches explicit Zig declarations" {
    try std.testing.expectEqual(@as(c_int, 1), thin_md4c_abi());
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Parser));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Attribute));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Code));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Link));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Li));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(TableContainer));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(TableSource));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(TableSource, "header_begin"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(TableSource, "body_begin"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(TableSource, "header_complete"));
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(CellSource));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(CellSource, "raw_begin"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(CellSource, "present"));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(SourceCallbacks));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(TableResume));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(TableResume, "trim_leading"));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(TableFragmentResult));
}
