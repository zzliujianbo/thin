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
static size_t realloc_sizes[4096];
static size_t fault_checks, callback_checks, reference_checks;
static int last_result;

static const char* reference_cases[] = {
    "[a]: /a\n\n[b]: /b\n\n",
    "[a]: /a\n\n[b]: /b\n\n[c]: /c\n\n[d]: /d\n\n"
    "[e]: /e\n\n[f]: /f\n\n[g]: /g\n\n[h]: /h\n\n"
    "[i]: /i\n\n[j]: /j\n\n[k]: /k\n\n[l]: /l\n\n"
    "[m]: /m\n\n[n]: /n\n\n[o]: /o\n\n[p]: /p\n\n"
    "[q]: /q\n\n[r]: /r\n\n",
    "[a]: /a",                 /* Final md_end_current_block(). */
    "[a]: /a\n- item\n"         /* md_enter_child_containers(). */
};

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
    if(calls < sizeof(realloc_sizes)/sizeof(realloc_sizes[0]))
        realloc_sizes[calls] = size;
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
    memset(realloc_sizes, 0, sizeof(realloc_sizes));
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_NOHTML;
    parser.enter_block = block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = text;
    result = thin_md4c_fault_parse(source, (MD_SIZE)strlen(source), &parser, NULL);
    last_result = result;
    *total = calls;
    fault_checks++;
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

/* Only reference-vector allocation failures must return -1 here; unrelated
 * optional preprocessing retains its documented literal-text fallback. */
static int reference_faults(void)
{
    size_t i, n, count, observed, ordinals[2], found, j;
    for(i = 0; i < sizeof(reference_cases)/sizeof(reference_cases[0]); i++) {
        if(run(reference_cases[i], 0, &count)) return 1;
        if(count >= sizeof(realloc_sizes)/sizeof(realloc_sizes[0])) return 1;
        found = 0;
        for(n = 1; n <= count; n++) {
            if(realloc_sizes[n] == 16 * sizeof(MD_REF_DEF) ||
               realloc_sizes[n] == 24 * sizeof(MD_REF_DEF)) {
                if(found == 2) return 1;
                ordinals[found++] = n;
            }
        }
        if(found != (i == 1 ? 2u : 1u)) return 1;
        for(j = 0; j < found; j++) {
            if(run(reference_cases[i], ordinals[j], &observed) || last_result != -1)
                return 1;
            reference_checks++;
        }
        for(n = 1; n <= count; n++)
            if(run(reference_cases[i], n, &observed) || observed < n) return 1;
    }
    return 0;
}

struct callback_state {
    size_t seen, stop, categories[5];
    int code;
};
static int callback(void* userdata, int category)
{
    struct callback_state* state = userdata;
    state->seen++;
    state->categories[category]++;
    /* Only the selected callback fails: later successes must not mask it. */
    return state->stop != 0 && state->seen == state->stop ? state->code : 0;
}
static int enter_block(MD_BLOCKTYPE t, void* d, void* u)
{ (void)t; (void)d; return callback(u, 0); }
static int leave_block(MD_BLOCKTYPE t, void* d, void* u)
{ (void)t; (void)d; return callback(u, 1); }
static int enter_span(MD_SPANTYPE t, void* d, void* u)
{ (void)t; (void)d; return callback(u, 2); }
static int leave_span(MD_SPANTYPE t, void* d, void* u)
{ (void)t; (void)d; return callback(u, 3); }
static int callback_text(MD_TEXTTYPE t, const MD_CHAR* s, MD_SIZE n, void* u)
{ (void)t; (void)s; (void)n; return callback(u, 4); }

static int callback_run(const char* source, struct callback_state* state, int* result)
{
    MD_PARSER parser = {0};
    int i, leaked = 0;
    memset(allocations, 0, sizeof(allocations));
    calls = fail_at = 0; invalid = 0;
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_LATEXMATHSPANS | MD_FLAG_WIKILINKS;
    parser.enter_block = enter_block; parser.leave_block = leave_block;
    parser.enter_span = enter_span; parser.leave_span = leave_span;
    parser.text = callback_text;
    *result = thin_md4c_fault_parse(source, (MD_SIZE)strlen(source), &parser, state);
    for(i = 0; i < 1024; i++) {
        if(allocations[i].pointer != NULL) {
            leaked = 1;
            free(allocations[i].pointer);
            allocations[i].pointer = NULL;
        }
    }
    callback_checks++;
    return invalid || leaked;
}

static int callback_faults(void)
{
    const char* source = "> - **nested** [link](x&amp;y \"title &copy;\")\n>\n"
        ">   | A | B |\n>   | --- | --- |\n>   | *cell* | `code` |\n"
        ">   | ![alt](a&amp;b) | $math$ |\n>   | tail |\n\n"
        "[[target|wiki]] <https://example.org> www.example.org\n\n"
        "```l&amp;ng\ncode\n```\n\n<div>raw</div>\n";
    struct callback_state state = {0};
    size_t count, n, i;
    int result, code;
    /* hello: DOC enter, P enter, text (the third callback). */
    state.stop = 3; state.code = 7;
    if(callback_run("hello", &state, &result)) return 1;
#ifdef MD4C_FAULT_TEST_MAIN
    printf("hello callback result=%d expected=7 callbacks=%zu expected=3\n", result, state.seen);
#endif
    if(result != 7 || state.seen != 3) return 1;
    memset(&state, 0, sizeof(state));
    if(callback_run(source, &state, &result) || result != 0) return 1;
    count = state.seen;
    for(i = 0; i < 5; i++) if(state.categories[i] == 0) return 1;
    for(code = -2; code <= 7; code += 9) {
        for(n = 1; n <= count; n++) {
            memset(&state, 0, sizeof(state));
            state.stop = n; state.code = code;
            if(callback_run(source, &state, &result) || result != code || state.seen != n)
                return 1;
        }
    }
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
    fault_checks = callback_checks = reference_checks = 0;
    if(reference_faults() || callback_faults()) return 1;
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
int main(int argc, char** argv)
{
    int result;
    if(argc == 2 && strcmp(argv[1], "callbacks") == 0) result = callback_faults();
    else if(argc == 2 && strcmp(argv[1], "references") == 0) result = reference_faults();
    else result = thin_md4c_fault_test();
    printf("checks: allocations=%zu targeted_references=%zu callbacks=%zu\n",
           fault_checks, reference_checks, callback_checks);
    puts(result ? "MD4C allocation/callback ownership FAILED" : "MD4C allocation/callback ownership PASS");
    return result;
}
#endif
