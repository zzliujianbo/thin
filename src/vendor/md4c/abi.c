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
int thin_md4c_abi(void) { return 1; }
