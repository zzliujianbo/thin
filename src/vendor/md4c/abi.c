/* Local ABI checks for the explicit Zig declarations, not an upstream file. */
#include <stddef.h>
#include "md4c.h"
#include "entity.h"
_Static_assert(sizeof(MD_PARSER) == 64, "MD_PARSER ABI");
_Static_assert(offsetof(MD_PARSER, text) == 40, "MD_PARSER callbacks ABI");
_Static_assert(sizeof(MD_ATTRIBUTE) == 32, "MD_ATTRIBUTE ABI");
_Static_assert(offsetof(MD_ATTRIBUTE, substr_types) == 16, "MD_ATTRIBUTE pointers ABI");
_Static_assert(sizeof(MD_BLOCK_UL_DETAIL) == 8, "UL ABI");
_Static_assert(sizeof(MD_BLOCK_OL_DETAIL) == 12, "OL ABI");
_Static_assert(sizeof(MD_BLOCK_LI_DETAIL) == 12, "LI ABI");
_Static_assert(sizeof(MD_BLOCK_CODE_DETAIL) == 72, "code ABI");
_Static_assert(sizeof(MD_BLOCK_TABLE_DETAIL) == 12, "table ABI");
_Static_assert(sizeof(MD_SPAN_A_DETAIL) == 72, "link ABI");
_Static_assert(sizeof(MD_SPAN_IMG_DETAIL) == 64, "image ABI");
_Static_assert(sizeof(ENTITY) == 16, "entity ABI");
_Static_assert(sizeof(MD_INLINE_SPAN) == 20, "inline source ABI");
_Static_assert(sizeof(MD_FENCE_SOURCE) == 28, "fence source ABI");
_Static_assert(offsetof(MD_FENCE_SOURCE, closing_begin) == 20, "fence close ABI");
_Static_assert(sizeof(MD_CELL_SOURCE) == 52, "cell source ABI");
_Static_assert(offsetof(MD_CELL_SOURCE, raw_begin) == 36, "cell raw begin ABI");
_Static_assert(offsetof(MD_CELL_SOURCE, raw_end) == 40, "cell raw end ABI");
_Static_assert(offsetof(MD_CELL_SOURCE, next_begin) == 44, "cell next begin ABI");
_Static_assert(offsetof(MD_CELL_SOURCE, present) == 48, "cell present ABI");
_Static_assert(sizeof(MD_TABLE_CONTAINER) == 12, "table container ABI");
_Static_assert(offsetof(MD_TABLE_CONTAINER, mark_indent) == 4, "table container indent ABI");
_Static_assert(sizeof(MD_TABLE_SOURCE) == 24, "table source ABI");
_Static_assert(offsetof(MD_TABLE_SOURCE, header_begin) == 12, "table header begin ABI");
_Static_assert(offsetof(MD_TABLE_SOURCE, body_begin) == 16, "table body begin ABI");
_Static_assert(offsetof(MD_TABLE_SOURCE, header_complete) == 20, "table header complete ABI");
_Static_assert(MD_CANDIDATE_TABLE == 1 && MD_CANDIDATE_REFERENCE == 2, "candidate reasons ABI");
_Static_assert(sizeof(MD_SOURCE_CALLBACKS) == 72, "source callbacks ABI");
_Static_assert(offsetof(MD_SOURCE_CALLBACKS, candidate) == 48, "candidate callback ABI");
_Static_assert(offsetof(MD_SOURCE_CALLBACKS, table) == 56, "table source callback ABI");
_Static_assert(offsetof(MD_SOURCE_CALLBACKS, partial_input) == 64, "partial input ABI");
_Static_assert(sizeof(MD_TABLE_RESUME) == 56, "table continuation ABI");
_Static_assert(offsetof(MD_TABLE_RESUME, containers) == 32, "table resume containers ABI");
_Static_assert(offsetof(MD_TABLE_RESUME, first_line_partial) == 44, "table resume partial line ABI");
_Static_assert(offsetof(MD_TABLE_RESUME, trim_leading) == 48, "table resume trim ABI");
_Static_assert(sizeof(MD_TABLE_FRAGMENT_RESULT) == 8, "table fragment result ABI");
_Static_assert(offsetof(MD_TABLE_FRAGMENT_RESULT, end) == 4, "table fragment end ABI");
int thin_md4c_abi(void) { return 1; }
