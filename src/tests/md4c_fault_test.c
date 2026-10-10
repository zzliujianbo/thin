/* Test-only parser copy: force each allocation failure and moving realloc.
 * Tracks ownership before calling libc, so an old double-free is a deterministic
 * failed test instead of crashing the entire unit executable. Never linked into
 * the product. Define MD4C_FAULT_TEST_MAIN for an independent ASan/UBSan run. */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct allocation { void* pointer; size_t size; };
static struct allocation allocations[1024];
static size_t calls, fail_at;
static int invalid;

static int find_allocation(void* pointer)
{
    int i;
    for(i = 0; i < 1024; i++)
        if(allocations[i].pointer == pointer) return i;
    return -1;
}

static int own(void* pointer, size_t size)
{
    int slot = find_allocation(NULL);
    if(slot < 0) { invalid = 1; free(pointer); return 0; }
    allocations[slot].pointer = pointer;
    allocations[slot].size = size;
    return 1;
}

static void* fault_malloc(size_t size)
{
    void* pointer;
    calls++;
    if(calls == fail_at) return NULL;
    pointer = malloc(size);
    if(pointer != NULL && !own(pointer, size)) return NULL;
    return pointer;
}

static void fault_free(void* pointer)
{
    int slot;
    if(pointer == NULL) return;
    slot = find_allocation(pointer);
    if(slot < 0) { invalid = 1; return; }
    allocations[slot].pointer = NULL;
    allocations[slot].size = 0;
    free(pointer);
}

static void* fault_realloc(void* pointer, size_t size)
{
    int slot;
    void* next;
    calls++;
    if(calls == fail_at) return NULL;
    if(pointer == NULL) {
        next = malloc(size);
        if(next != NULL && !own(next, size)) return NULL;
        return next;
    }
    slot = find_allocation(pointer);
    if(slot < 0) { invalid = 1; return NULL; }
    /* Allocate before free: successful growth ALWAYS invalidates the old
     * pointer, including the first realloc in a pair whose second then fails. */
    next = malloc(size);
    if(next == NULL) return NULL;
    memcpy(next, pointer, allocations[slot].size < size ? allocations[slot].size : size);
    free(pointer);
    allocations[slot].pointer = next;
    allocations[slot].size = size;
    return next;
}

#define malloc fault_malloc
#define realloc fault_realloc
#define free fault_free
#define md_parse thin_md4c_fault_parse
#include "../vendor/md4c/md4c.c"
#undef malloc
#undef realloc
#undef free
#undef md_parse

static int block(MD_BLOCKTYPE type, void* detail, void* userdata)
{
    (void)type; (void)detail; (void)userdata;
    return 0;
}

static int span(MD_SPANTYPE type, void* detail, void* userdata)
{
    (void)type; (void)detail; (void)userdata;
    return 0;
}

static int text(MD_TEXTTYPE type, const MD_CHAR* value, MD_SIZE size, void* userdata)
{
    (void)type; (void)value; (void)size; (void)userdata;
    return 0;
}

static int run(const char* source, size_t failure, size_t* total)
{
    MD_PARSER parser = {0};
    int result, i, leaked = 0;
    memset(allocations, 0, sizeof(allocations));
    calls = 0; fail_at = failure; invalid = 0;
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_NOHTML;
    parser.enter_block = block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = text;
    result = thin_md4c_fault_parse(source, (MD_SIZE)strlen(source), &parser, NULL);
    *total = calls;
    for(i = 0; i < 1024; i++) {
        if(allocations[i].pointer != NULL) {
            leaked = 1;
            free(allocations[i].pointer);
            allocations[i].pointer = NULL;
        }
    }
    /* Optional reference preprocessing can fall back to literal text on OOM.
     * That success is valid; ownership must still be clean on every path. */
    if(invalid || leaked) return 1;
    if(failure != 0 && calls >= failure) {
        if(result != 0 && result != -1) return 1;
    } else if(result != 0) return 1;
    return 0;
}

int thin_md4c_fault_test(void)
{
    const char* cases[] = {
        "[a](https://example.org/&amp; \"title &copy;\")",
        "[a](a&amp;x&amp;x&amp;x&amp;x&amp;x&amp;x&amp;x&amp;x&amp;x \"&copy;x&copy;x&copy;x&copy;x&copy;x\")",
        "![alt](./a\\-b&amp;c \"image &quot;title&quot;\")",
        "[a][r]\n\n[r]: /&amp; \"title &copy;\"",
        "```l&amp;ng info &copy;\ncode\n```\n",
        "> - [x] item\n>\n> | A | B |\n> | --- | --- |\n> | [a](x&amp;y) | code |\n"
    };
    size_t i, n, count, observed;
    for(i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        if(run(cases[i], 0, &count) != 0 || count == 0) return 1;
        for(n = 1; n <= count; n++)
            if(run(cases[i], n, &observed) != 0 || observed < n) return 1;
        /* No failure when the chosen ordinal is beyond the success path. */
        if(run(cases[i], count + 1, &observed) != 0) return 1;
    }
    return 0;
}

#ifdef MD4C_FAULT_TEST_MAIN
int main(void)
{
    int result = thin_md4c_fault_test();
    puts(result ? "MD4C allocation-failure ownership FAILED" : "MD4C allocation-failure ownership PASS");
    return result;
}
#endif
