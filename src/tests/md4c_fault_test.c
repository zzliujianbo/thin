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
#define md_parse_spans thin_md4c_fault_parse_spans
#define md_parse_source thin_md4c_fault_parse_source
#define md_parse_inline_source thin_md4c_fault_parse_inline_source
#define md_reference_store_create thin_fault_reference_store_create
#define md_reference_store_destroy thin_fault_reference_store_destroy
#define md_reference_store_prepare thin_fault_reference_store_prepare
#define md_reference_store_commit thin_fault_reference_store_commit
#define md_reference_store_abort thin_fault_reference_store_abort
#define md_parse_table_fragment thin_md4c_fault_parse_table_fragment
#define md_stream_code_create_with_allocator thin_fault_code_create_with_allocator
#define md_stream_code_create thin_fault_code_create
#define md_stream_code_destroy thin_fault_code_destroy
#define md_stream_code_feed thin_fault_code_feed
#define md_stream_code_feed_at thin_fault_code_feed_at
#define md_stream_code_step thin_fault_code_step
#define md_stream_code_literalize thin_fault_code_literalize
#define md_stream_code_checkpoint thin_fault_code_checkpoint
#define md_stream_code_commit thin_fault_code_commit
#define md_stream_code_abort thin_fault_code_abort
#define md_parse_inline thin_md4c_fault_parse_inline
#define md_parse_inline_spans thin_md4c_fault_parse_inline_spans
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

static int inline_test_mode;
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
    result = inline_test_mode
        ? thin_md4c_fault_parse_inline(source, (MD_SIZE)strlen(source), &parser, NULL)
        : thin_md4c_fault_parse(source, (MD_SIZE)strlen(source), &parser, NULL);
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
    *result = inline_test_mode
        ? thin_md4c_fault_parse_inline(source, (MD_SIZE)strlen(source), &parser, state)
        : thin_md4c_fault_parse(source, (MD_SIZE)strlen(source), &parser, state);
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

static int inline_faults(void)
{
    const char* source = "# literal **bold** [link](x&amp;y)\n- *next* `code`";
    struct callback_state state = {0};
    size_t count, observed, n;
    int result, code;
    inline_test_mode = 1;
    if(run(source, 0, &count) || count == 0) return 1;
    for(n = 1; n <= count; n++)
        if(run(source, n, &observed) || observed < n) return 1;
    if(callback_run(source, &state, &result) || result != 0) return 1;
    count = state.seen;
    for(code = -2; code <= 7; code += 9) {
        for(n = 1; n <= count; n++) {
            memset(&state, 0, sizeof(state));
            state.stop = n; state.code = code;
            if(callback_run(source, &state, &result) || result != code || state.seen != n)
                return 1;
        }
    }
    inline_test_mode = 0;
    return 0;
}

struct span_capture {
    MD_INLINE_SPAN events[16];
    size_t count, stop;
};
static int capture_span(const MD_INLINE_SPAN* event, void* userdata)
{
    struct span_capture* state = userdata;
    if(state->count >= 16) return -9;
    state->events[state->count++] = *event;
    return state->stop == state->count ? 17 : 0;
}
static int span_case(const char* source, const MD_INLINE_SPAN* expected, size_t count)
{
    MD_PARSER parser = {0};
    struct span_capture state;
    size_t n, i, k, total;
    int result, leaked;
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_NOHTML;
    parser.enter_block = block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = text;
    /* Success, then abort at each event, then fail every allocation. */
    for(n = 0; n <= count; n++) {
        memset(allocations, 0, sizeof(allocations));
        calls = fail_at = 0; invalid = 0;
        memset(&state, 0, sizeof(state)); state.stop = n;
        result = thin_md4c_fault_parse_inline_spans(source, (MD_SIZE)strlen(source), &parser, capture_span, &state);
        if((n == 0 && (result != 0 || state.count != count)) ||
           (n != 0 && (result != 17 || state.count != n))) return 1;
        for(i = 0; i < state.count; i++) {
            const MD_INLINE_SPAN* a = &state.events[i];
            const MD_INLINE_SPAN* b = &expected[i];
            if(a->type != b->type || a->opener_begin != b->opener_begin ||
               a->opener_end != b->opener_end || a->closer_begin != b->closer_begin ||
               a->closer_end != b->closer_end) return 1;
        }
        if(n == 0) total = calls;
        for(k = 0; k < 1024; k++) if(allocations[k].pointer != NULL) return 1;
        if(invalid) return 1;
    }
    for(n = 1; n <= total; n++) {
        memset(allocations, 0, sizeof(allocations));
        calls = 0; fail_at = n; invalid = 0;
        memset(&state, 0, sizeof(state));
        result = thin_md4c_fault_parse_inline_spans(source, (MD_SIZE)strlen(source), &parser, capture_span, &state);
        leaked = 0;
        for(k = 0; k < 1024; k++) if(allocations[k].pointer != NULL) { free(allocations[k].pointer); leaked = 1; }
        if(invalid || leaked || (result != 0 && result != -1)) return 1;
    }
    return 0;
}
static int inline_span_faults(void)
{
    static const MD_INLINE_SPAN nested[] = {
        { MD_SPAN_EM, 0, 1, 8, 9 }, { MD_SPAN_STRONG, 1, 3, 6, 8 }
    };
    static const MD_INLINE_SPAN code[] = { { MD_SPAN_CODE, 0, 2, 3, 5 } };
    static const MD_INLINE_SPAN link[] = { { MD_SPAN_A, 0, 1, 2, 9 } };
    static const MD_INLINE_SPAN strike[] = { { MD_SPAN_DEL, 0, 2, 3, 5 } };
    static const MD_INLINE_SPAN image[] = { { MD_SPAN_IMG, 0, 2, 3, 7 } };
    static const MD_INLINE_SPAN escaped[] = { { MD_SPAN_STRONG, 3, 5, 10, 12 } };
    return span_case("***a\nb***", nested, 2) || span_case("``x``", code, 1) ||
           span_case("[l](dest)", link, 1) || span_case("![x](y)", image, 1) ||
           span_case("~~z~~", strike, 1) || span_case("\\* **&amp;**", escaped, 1) ||
           span_case("*unclosed", NULL, 0);
}

struct source_capture { struct span_capture spans; MD_FENCE_SOURCE fence; int fence_count, stop_fence; };
static int source_span(const MD_INLINE_SPAN* event, void* userdata)
{ return capture_span(event, &((struct source_capture*)userdata)->spans); }
static int source_fence(const MD_FENCE_SOURCE* event, void* userdata)
{
    struct source_capture* state = userdata;
    state->fence = *event; state->fence_count++;
    return state->stop_fence ? 23 : 0;
}
static int document_source_faults(void)
{
    const char* source = "# h\n\n**x**\n\n````lang\nx\n````\n";
    MD_PARSER parser = {0};
    MD_SOURCE_CALLBACKS callbacks = { source_span, source_fence };
    struct source_capture state;
    int mode, result, i, leaked;
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_NOHTML;
    parser.enter_block = block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = text;
    for(mode = 0; mode < 3; mode++) {
        memset(allocations, 0, sizeof(allocations));
        calls = fail_at = 0; invalid = 0;
        memset(&state, 0, sizeof(state));
        state.spans.stop = mode == 1 ? 1 : 0;
        state.stop_fence = mode == 2;
        result = thin_md4c_fault_parse_source(source, (MD_SIZE)strlen(source), &parser, &callbacks, &state);
        leaked = 0;
        for(i = 0; i < 1024; i++) if(allocations[i].pointer != NULL) { free(allocations[i].pointer); leaked = 1; }
        if(invalid || leaked || result != (mode == 1 ? 17 : mode == 2 ? 23 : 0)) return 1;
        if(state.spans.count != 1 || state.spans.events[0].type != MD_SPAN_STRONG ||
           state.spans.events[0].opener_begin != 5 || state.spans.events[0].opener_end != 7 ||
           state.spans.events[0].closer_begin != 8 || state.spans.events[0].closer_end != 10) return 1;
        if(state.fence_count != (mode == 1 ? 0 : 1)) return 1;
        if(mode != 1 && (state.fence.fence_begin != 12 || state.fence.fence_end != 16 ||
           state.fence.header_begin != 12 || state.fence.header_end != 20 || state.fence.fence_char != '`')) return 1;
    }
    memset(allocations, 0, sizeof(allocations));
    calls = fail_at = 0; invalid = 0;
    memset(&state, 0, sizeof(state));
    result = thin_md4c_fault_parse_spans(source, (MD_SIZE)strlen(source), &parser, source_span, &state);
    leaked = 0;
    for(i = 0; i < 1024; i++) if(allocations[i].pointer != NULL) { free(allocations[i].pointer); leaked = 1; }
    if(invalid || leaked || result != 0 || state.spans.count != 1 ||
       state.spans.events[0].opener_begin != 5 || state.spans.events[0].closer_end != 10) return 1;
    return 0;
}

struct persisted_ref_case { MD_REFERENCE_STORE *store; MD_REFERENCE_UPDATE *update; int seen, links; };
static int persist_definition(const MD_REFERENCE_DEFINITION *d, void *userdata)
{
    struct persisted_ref_case *s = userdata;
    s->seen++;
    if(d->begin != 0 || d->end != 22) return 29;
    return thin_fault_reference_store_prepare(s->store, d, 1, &s->update);
}
static int persist_span(MD_SPANTYPE type, void *detail, void *userdata)
{
    struct persisted_ref_case *s = userdata;
    MD_SPAN_A_DETAIL *a = detail;
    if(type == MD_SPAN_A) {
        s->links++;
        if(a->href.size != 7 || memcmp(a->href.text, "/x&amp;", 7) ||
           a->title.size != 3 || memcmp(a->title.text, "one", 3)) return 31;
    }
    return 0;
}
static int persisted_reference_faults(void)
{
    static const char def[] = "[Name]: /x&amp; \"one\"\n\n";
    static const char use[] = "[text][NAME]";
    MD_PARSER parser = {0};
    MD_SOURCE_CALLBACKS callbacks = {0};
    size_t n, total = 0;
    parser.flags = MD_DIALECT_GITHUB;
    parser.enter_block = block; parser.leave_block = block;
    parser.enter_span = persist_span; parser.leave_span = span; parser.text = text;
    for(n = 0; n == 0 || n <= total; n++) {
        struct persisted_ref_case state = {0};
        int result, i, leaked = 0;
        memset(allocations, 0, sizeof(allocations));
        calls = 0; fail_at = n; invalid = 0;
        state.store = thin_fault_reference_store_create(8, 1024);
        if(state.store) {
            callbacks.definition = persist_definition;
            result = thin_md4c_fault_parse_source(def, sizeof(def)-1, &parser, &callbacks, &state);
            if(result == 0 && state.update) {
                thin_fault_reference_store_commit(state.store, state.update); state.update = NULL;
                callbacks.definition = NULL; callbacks.references = state.store;
                result = thin_md4c_fault_parse_inline_source(use, sizeof(use)-1, &parser, &callbacks, &state);
                if(result == 0 && state.links != 1) result = 31;
            }
            thin_fault_reference_store_abort(state.update);
            thin_fault_reference_store_destroy(state.store);
        } else result = -1;
        if(n == 0) { total = calls; if(result != 0 || state.seen != 1 || total == 0) return 1; }
        else if(result != 0 && result != -1) return 1;
        for(i = 0; i < 1024; i++) if(allocations[i].pointer) { free(allocations[i].pointer); leaked = 1; }
        if(invalid || leaked) return 1;
        callbacks.references = NULL;
    }
    return 0;
}

static int persisted_reference_transactions(void)
{
    MD_REFERENCE_STORE *s;
    MD_REFERENCE_UPDATE *u = NULL;
    MD_REFERENCE_DEFINITION d[2] = {{0}};
    const MD_STORED_REFERENCE *p;
    int i, failed = 0;
    memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
    s = thin_fault_reference_store_create(1, 32);
    if(!s) return 1;
    d[0].label.text = "Name"; d[0].label.size = 4;
    d[0].destination.text = "/first"; d[0].destination.size = 6;
    d[1] = d[0]; d[1].label.text = "name"; d[1].destination.text = "/other";
    if(thin_fault_reference_store_prepare(s, d, 2, &u) || !u) failed = 1;
    if(md_stored_lookup(s, "name", 4, md_link_label_hash("name", 4))) failed = 1;
    thin_fault_reference_store_abort(u); u = NULL;
    if(md_stored_lookup(s, "name", 4, md_link_label_hash("name", 4))) failed = 1;
    if(thin_fault_reference_store_prepare(s, d, 2, &u) || !u) failed = 1;
    thin_fault_reference_store_commit(s, u); u = NULL;
    p = md_stored_lookup(s, "NAME", 4, md_link_label_hash("NAME", 4));
    if(!p || p->dest_size != 6 || memcmp(p->dest, "/first", 6)) failed = 1;
    d[1].label.text = "else";
    if(thin_fault_reference_store_prepare(s, &d[1], 1, &u) != -2 || u) failed = 1;
    thin_fault_reference_store_destroy(s);
    for(i = 0; i < 1024; i++) if(allocations[i].pointer) { free(allocations[i].pointer); failed = 1; }
    return failed || invalid;
}

struct native_source_capture {
    int tables, paragraphs, candidates, candidate_stop, text_bytes, cells, definitions;
    MD_SIZE begin, end, begins[32], ends[32];
    unsigned reasons[32];
    MD_CELL_SOURCE cell[32];
};
static int native_block(MD_BLOCKTYPE type, void *detail, void *userdata)
{
    struct native_source_capture *s = userdata; (void)detail;
    if(type == MD_BLOCK_TABLE) s->tables++;
    if(type == MD_BLOCK_P) s->paragraphs++;
    return 0;
}
static int native_text(MD_TEXTTYPE type, const MD_CHAR *value, MD_SIZE size, void *userdata)
{
    struct native_source_capture *s = userdata; (void)type; (void)value;
    s->text_bytes += (int)size; return 0;
}
static int native_candidate(MD_SIZE begin, MD_SIZE end, unsigned reason, void *userdata)
{
    struct native_source_capture *s = userdata;
    if(s->candidates >= 32) return 39;
    s->begins[s->candidates] = begin; s->ends[s->candidates] = end;
    s->reasons[s->candidates] = reason;
    s->candidates++; s->begin = begin; s->end = end;
    return s->candidate_stop ? 37 : 0;
}
static int native_definition(const MD_REFERENCE_DEFINITION *def, void *userdata)
{
    struct native_source_capture *s = userdata; (void)def;
    s->definitions++; return 0;
}
static int native_cell(const MD_CELL_SOURCE *cell, void *userdata)
{
    struct native_source_capture *s = userdata;
    if(s->cells >= 32) return 39;
    s->cell[s->cells++] = *cell;
    return 0;
}
static int metadata_abort(const MD_CELL_SOURCE *cell, void *userdata)
{
    (void)cell; (void)userdata; return 47;
}
static int metadata_fragment(const char *input, MD_SIZE size, MD_TABLE_RESUME *resume,
                             int partial, size_t failure, int abort_cell,
                             struct native_source_capture *capture, size_t *total)
{
    MD_PARSER p = {0}; MD_SOURCE_CALLBACKS cb = {0}; int result, i, bad = 0;
    memset(allocations, 0, sizeof(allocations)); calls = 0; fail_at = failure; invalid = 0;
    memset(capture, 0, sizeof(*capture));
    p.flags = MD_DIALECT_GITHUB; p.enter_block = native_block; p.leave_block = block;
    p.enter_span = span; p.leave_span = span; p.text = native_text;
    cb.cell = abort_cell ? metadata_abort : native_cell; cb.partial_input = partial;
    result = thin_md4c_fault_parse_table_fragment(input, size, &p, &cb, resume, NULL, capture);
    *total = calls;
    for(i = 0; i < 1024; i++) if(allocations[i].pointer) { free(allocations[i].pointer); bad = 1; }
    return invalid || bad ? -999 : result;
}
_Static_assert(sizeof(MD_CELL_SOURCE) == 52, "cell source ABI");
_Static_assert(offsetof(MD_CELL_SOURCE, raw_begin) == 36, "cell raw ABI");
_Static_assert(offsetof(MD_CELL_SOURCE, present) == 48, "cell present ABI");
_Static_assert(sizeof(MD_TABLE_RESUME) == 56, "table resume ABI");
_Static_assert(offsetof(MD_TABLE_RESUME, trim_leading) == 48, "table trim ABI");
static int native_cell_metadata(void)
{
    MD_ALIGN align[2] = { MD_ALIGN_DEFAULT, MD_ALIGN_DEFAULT };
    MD_TABLE_RESUME r = {0}; struct native_source_capture s; size_t total, n;
    char spaces[5000]; int failed = 0;
    MD_TABLE_CONTAINER quote = {'>', 0, 0}, list = {'-', 0, 2};
    r.columns = 2; r.alignments = align; r.partial_cell = 1; r.first_line_partial = 1; r.trim_leading = 1;
    memset(spaces, ' ', sizeof(spaces));
    if(metadata_fragment(spaces, sizeof(spaces), &r, 1, 0, 0, &s, &total) || s.cells != 2 ||
       !s.cell[0].present || s.cell[0].raw_begin != 0 || s.cell[0].raw_end != sizeof(spaces) ||
       s.cell[0].next_begin != sizeof(spaces) || s.cell[0].begin != sizeof(spaces) || s.cell[0].cell_complete ||
       s.cell[1].present || s.cell[1].row_complete) failed = 1;
    if(metadata_fragment("| x\r\n", 5, &r, 1, 0, 0, &s, &total) || s.cells != 2 ||
       !s.cell[0].present || s.cell[0].raw_begin != 0 || s.cell[0].raw_end != 0 || s.cell[0].next_begin != 1 ||
       !s.cell[1].present || s.cell[1].raw_begin != 1 || s.cell[1].raw_end != 3 || s.cell[1].next_begin != 5) failed = 1;
    if(metadata_fragment("x\n", 2, &r, 1, 0, 0, &s, &total) || s.cells != 2 ||
       !s.cell[0].present || s.cell[1].present || !s.cell[1].cell_complete || !s.cell[1].row_complete) failed = 1;
    r.trim_leading = 0;
    if(metadata_fragment("  x | y\n", 8, &r, 1, 0, 0, &s, &total) || s.cells != 2 || s.cell[0].begin != 0 || s.cell[0].end != 3) failed = 1;
    r.trim_leading = 1; r.containers = &quote; r.n_containers = 1;
    if(metadata_fragment("  x | y\n> z | q\n", 16, &r, 1, 0, 0, &s, &total) || s.cells != 4 || s.cell[0].begin != 2 || s.cell[2].raw_begin != 10) failed = 1;
    r.containers = &list;
    if(metadata_fragment("  x | y\n  z | q\n", 16, &r, 1, 0, 0, &s, &total) || s.cells != 4 || s.cell[0].begin != 2 || s.cell[2].raw_begin != 10) failed = 1;
    r.containers = NULL; r.n_containers = 0;
    if(metadata_fragment("| x\r\n", 5, &r, 1, 0, 1, &s, &total) != 47) failed = 1;
    if(metadata_fragment("| x\r\n", 5, &r, 1, 0, 0, &s, &total)) failed = 1;
    for(n = 1; n <= total; n++) {
        size_t ignored; int result = metadata_fragment("| x\r\n", 5, &r, 1, n, 0, &s, &ignored);
        if(result != 0 && result != -1) failed = 1;
    }
    return failed;
}
static int native_source_run(const char *source, int partial, struct native_source_capture *s)
{
    MD_PARSER parser = {0}; MD_SOURCE_CALLBACKS cb = {0};
    parser.flags = MD_DIALECT_GITHUB;
    parser.enter_block = native_block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = native_text;
    cb.partial_input = partial; cb.candidate = native_candidate; cb.cell = native_cell;
    cb.definition = native_definition;
    return thin_md4c_fault_parse_source(source, (MD_SIZE)strlen(source), &parser, &cb, s);
}
static int native_source_regressions(void)
{
    static const struct { const char *source; int partial, tables; const char *candidate; } cases[] = {
        {"Architecture\nA | B\n--- | ---\nx | y\n", 0, 1, NULL},
        {"Architecture\nA | B\n", 1, 0, "A | B\n"},
        {"Architecture\r\nA | B\r\n", 1, 0, "A | B\r\n"},
        {"> Intro\n> A | B\n", 1, 0, "> A | B\n"},
        {"- Intro\n  A | B\n", 1, 0, "  A | B\n"},
        {"Architecture\nA | B\n--- |", 1, 0, "A | B\n"},
        {"Architecture\r\nA | B\r\n--- | ---\r\n", 1, 1, NULL},
        {"> Intro\n> A | B\n> --- | ---\n", 0, 1, NULL},
        {"- Intro\n  A | B\n  --- | ---\n", 0, 1, NULL},
        {"A | B | C\n--- | ---\n", 0, 0, NULL},
        {"`a|b` | c\n--- | ---\n", 0, 1, NULL},
        {"a\\|b | c\n--- | ---\n", 0, 1, NULL},
        {"```\na | b\n", 1, 0, NULL},
        {"    a | b\n", 1, 0, NULL},
        {"intro\n    | A |\n    |---|\n    | literal |\n", 0, 0, NULL},
        {"> intro\n>     | A |\n>     |---|\n>     | literal |\n", 0, 0, NULL},
        {"- intro\n      | A |\n      |---|\n      | literal |\n", 0, 0, NULL},
        {"<div>\na | b\n", 1, 0, NULL},
        {"a | b\n--- | ---\nx | y", 1, 1, NULL},
        {"[ref]: /a\n", 1, 0, "[ref]: /a\n"}
    };
    size_t i; int k, result, failed = 0;
    for(i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        struct native_source_capture s = {0};
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        result = native_source_run(cases[i].source, cases[i].partial, &s);
        if(result || s.tables != cases[i].tables || s.candidates != (cases[i].candidate != NULL)) failed = 1;
        if(cases[i].candidate) {
            const char *p = strstr(cases[i].source, cases[i].candidate);
            if(!p || s.begin != (MD_SIZE)(p - cases[i].source) ||
               s.end != s.begin + strlen(cases[i].candidate) ||
               s.reasons[0] != (i == sizeof(cases)/sizeof(cases[0]) - 1 ? MD_CANDIDATE_REFERENCE : MD_CANDIDATE_TABLE)) failed = 1;
        }
        for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
        if(invalid || failed) return 1;
    }
    {
        struct native_source_capture s = {0};
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        s.candidate_stop = 1;
        if(native_source_run("a | b\n", 1, &s) != 37 || s.candidates != 1) failed = 1;
        for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
        if(invalid || failed) return 1;
    }
    {
        static const struct { const char *src, *anchor; int partial; } refs[] = {
            {"[r]: /url", "[r]: /url", 1},
            {"[r]: /url\n", "[r]: /url\n", 1},
            {"[r]: /url\n  \"a\n", "[r]: /url\n", 1},
            {"[r]: /url\n  \"a\nb\"\n", NULL, 1},
            {"[r]: /url\n\n", NULL, 1},
            {"[r]: /url\nnot a title\n\n", NULL, 1},
            {"[r]: /url\n  \"a\n", NULL, 0},
            {"[r]: /one\n[r]: /two\n", "[r]: /two\n", 1},
            {"[r]: /url\n  \"a\n| b\n", "[r]: /url\n", 1},
            {"> [r]: /url\r\n", "> [r]: /url\r\n", 1}
        };
        for(i = 0; i < sizeof(refs)/sizeof(refs[0]); i++) {
            struct native_source_capture s = {0}; int found = 0, j;
            memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
            if(native_source_run(refs[i].src, refs[i].partial, &s)) failed = 1;
            for(j = 0; j < s.candidates; j++) {
                const char *p = refs[i].anchor ? strstr(refs[i].src, refs[i].anchor) : NULL;
                if(p && s.reasons[j] == MD_CANDIDATE_REFERENCE &&
                   s.begins[j] == (MD_SIZE)(p - refs[i].src) &&
                   s.ends[j] == s.begins[j] + strlen(refs[i].anchor)) found++;
            }
            if(refs[i].anchor ? found != 1 : s.candidates != 0) failed = 1;
            /* The unfinished title line is also a native table candidate. */
            if(strcmp(refs[i].src, "[r]: /url\n  \"a\n| b\n") == 0 && s.candidates != 2) failed = 1;
            for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
            if(invalid || failed) return 1;
        }
        {
            struct native_source_capture s = {0};
            memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
            s.candidate_stop = 1;
            if(native_source_run("[r]: /url\n", 1, &s) != 37 || s.candidates != 1) failed = 1;
            for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
            if(invalid || failed) return 1;
        }
    }
    {
        char long_title[4097]; const char *prefix = "[r]: /url \"";
        size_t prefix_len = strlen(prefix), total, n;
        struct native_source_capture s;
        memcpy(long_title, prefix, prefix_len);
        memset(long_title + prefix_len, 't', 4096 - prefix_len);
        long_title[4096] = '\0';
        memset(&s, 0, sizeof(s));
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        if(native_source_run(long_title, 1, &s) || s.definitions != 0 || s.candidates < 1 ||
           s.reasons[0] != MD_CANDIDATE_REFERENCE || s.begins[0] != 0 || s.ends[0] != 4096) failed = 1;
        total = calls;
        for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
        if(invalid || failed) return 1;
        for(n = 1; n <= total; n++) {
            int rc;
            memset(&s, 0, sizeof(s));
            memset(allocations, 0, sizeof(allocations)); calls = 0; fail_at = n; invalid = 0;
            rc = native_source_run(long_title, 1, &s);
            if(rc != 0 && rc != -1) failed = 1;
            for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
            if(invalid || failed) return 1;
        }
        memset(&s, 0, sizeof(s)); s.candidate_stop = 1;
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        if(native_source_run(long_title, 1, &s) != 37 || s.candidates != 1 ||
           s.reasons[0] != MD_CANDIDATE_REFERENCE || s.definitions) failed = 1;
        for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
        if(invalid || failed) return 1;
    }
    for(i = 0; i < 2; i++) {
        struct native_source_capture s = {0};
        const char *src = "a | b | c\n--- | --- | ---\nx||z";
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        if(native_source_run(src, (int)i, &s) || s.cells != 6 || s.tables != 1) failed = 1;
        if(s.cells == 6 && (s.cell[3].column != 0 || s.cell[3].cell_complete != 1 ||
           s.cell[4].column != 1 || s.cell[4].cell_complete != 1 ||
           s.cell[5].column != 2 || s.cell[5].cell_complete != !i ||
           s.cell[5].row_complete != !i)) failed = 1;
        for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
        if(invalid || failed) return 1;
    }
    {
        struct native_source_capture s = {0};
        const char *src = "a | b | c\n--- | --- | ---\nx|";
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        if(native_source_run(src, 1, &s) || s.cells != 6 ||
           (s.cells == 6 && (!s.cell[3].cell_complete || s.cell[3].row_complete ||
            s.cell[4].cell_complete || s.cell[4].row_complete ||
            s.cell[5].cell_complete || s.cell[5].row_complete))) failed = 1;
        for(k = 0; k < 1024; k++) if(allocations[k].pointer) { free(allocations[k].pointer); failed = 1; }
        if(invalid || failed) return 1;
    }
    return 0;
}

struct native_reference_capture { int links; };
static int native_reference_span(MD_SPANTYPE type, void *detail, void *userdata)
{
    struct native_reference_capture *s = userdata;
    if(type == MD_SPAN_A) {
        MD_SPAN_A_DETAIL *a = detail;
        s->links++;
        if(a->href.size != 4 || memcmp(a->href.text, "/x-y", 4) ||
           a->title.size != 3 || memcmp(a->title.text, "a\"b", 3)) return 41;
    }
    return 0;
}
static int native_reference_scopes(void)
{
    static const char doc[] = "[Ä]: /wrong\n\n[x][ä] [ä][] [ä]\n";
    static const char fragment[] = "[ä] | [ä][]";
    MD_REFERENCE_DEFINITION d = {0}; MD_REFERENCE_UPDATE *u = NULL;
    MD_REFERENCE_STORE *store; MD_SOURCE_CALLBACKS cb = {0}; MD_PARSER p = {0};
    MD_ALIGN alignments[2] = { MD_ALIGN_DEFAULT, MD_ALIGN_DEFAULT };
    MD_TABLE_RESUME resume = {2, 0, alignments, NULL, 0};
    struct native_reference_capture capture = {0}; int i, failed = 0;
    memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
    store = thin_fault_reference_store_create(8, 1024);
    if(!store) return 1;
    d.label.text = "Ä"; d.label.size = 2;
    d.destination.text = "/x\\-y"; d.destination.size = 5;
    d.title.text = "a\\\"b"; d.title.size = 4;
    if(thin_fault_reference_store_prepare(store, &d, 1, &u) || !u) failed = 1;
    thin_fault_reference_store_commit(store, u);
    p.flags = MD_DIALECT_GITHUB; p.enter_block = block; p.leave_block = block;
    p.enter_span = native_reference_span; p.leave_span = span; p.text = text;
    cb.references = store;
    if(thin_md4c_fault_parse_source(doc, sizeof(doc)-1, &p, &cb, &capture) || capture.links != 3) failed = 1;
    capture.links = 0;
    if(thin_md4c_fault_parse_inline_source(doc + sizeof("[Ä]: /wrong\n\n") - 1,
       sizeof(doc) - sizeof("[Ä]: /wrong\n\n"), &p, &cb, &capture) || capture.links != 3) failed = 1;
    capture.links = 0;
    if(thin_md4c_fault_parse_table_fragment(fragment, sizeof(fragment)-1, &p, &cb, &resume, NULL, &capture) || capture.links != 2) failed = 1;
    thin_fault_reference_store_destroy(store);
    for(i = 0; i < 1024; i++) if(allocations[i].pointer) { free(allocations[i].pointer); failed = 1; }
    return failed || invalid;
}

/* Multiline native code spans that cross a paragraph->table split must rejoin
 * the block in place; genuine adjacent tables and closed spans must not. */
struct merge_capture { int tables, paragraphs, code_spans, text_bytes; };
static int merge_block(MD_BLOCKTYPE type, void *detail, void *userdata)
{
    struct merge_capture *s = userdata; (void)detail;
    if(type == MD_BLOCK_TABLE) s->tables++;
    if(type == MD_BLOCK_P) s->paragraphs++;
    return 0;
}
static int merge_span(MD_SPANTYPE type, void *detail, void *userdata)
{
    struct merge_capture *s = userdata; (void)detail;
    if(type == MD_SPAN_CODE) s->code_spans++;
    return 0;
}
static int merge_text(MD_TEXTTYPE type, const MD_CHAR *value, MD_SIZE size, void *userdata)
{
    struct merge_capture *s = userdata; (void)type; (void)value;
    s->text_bytes += (int)size;
    return 0;
}
static int merge_run(const char *source, size_t failure, size_t *total, struct merge_capture *s)
{
    MD_PARSER parser = {0};
    int result, i, leaked = 0;
    memset(allocations, 0, sizeof(allocations));
    calls = 0; fail_at = failure; invalid = 0;
    memset(s, 0, sizeof(*s));
    parser.flags = MD_DIALECT_GITHUB | MD_FLAG_NOHTML;
    parser.enter_block = merge_block; parser.leave_block = block;
    parser.enter_span = merge_span; parser.leave_span = span; parser.text = merge_text;
    result = thin_md4c_fault_parse_source(source, (MD_SIZE)strlen(source), &parser, NULL, s);
    *total = calls;
    for(i = 0; i < 1024; i++) {
        if(allocations[i].pointer != NULL) {
            leaked = 1; free(allocations[i].pointer); allocations[i].pointer = NULL;
        }
    }
    return invalid || leaked || (failure == 0 ? result != 0 : (result != 0 && result != -1));
}
static int multiline_code_tables(void)
{
    static const struct { const char *source; int tables, paragraphs; } cases[] = {
        {"intro `\n|a|\n|---|\n` end\n", 0, 1},
        {"a `\nb\n|h|\n|---|\n` end\n", 0, 1},
        {"intro `\r\n|a|\r\n|---|\r\n` end\r\n", 0, 1},
        {"intro `\n|a`| b|\n|---|---|\n", 0, 1},
        {"intro `\n|a|\n|---|\n|b|\n", 1, 1},
        {"intro \\`\n|a|\n|---|\n` end\n", 1, 1},
        {"intro\n|a|\n|---|\n|b|\n", 1, 1},
        {"intro `x`\n|a|\n|---|\n` end\n", 1, 1},
        {"```\nintro `\n|a|\n|---|\n` end\n```\n", 0, 0},
        {"intro\n    |a|\n    |---|\n    ` end\n", 0, 1},
        {"> intro `\n> |a|\n> |---|\n> ` end\n", 0, 1},
        {"- intro `\n  |a|\n  |---|\n  ` end\n", 0, 0},
        {"1. intro `\n   |a|\n   |---|\n   ` end\n", 0, 0},
        {"intro `\n|a|\n|---|\n` end\n\nsecond\n|b|\n|---|\n|c|\n", 1, 2},
        {"> intro `\n> |a|\n> |---|\n> ` end\n\nafter\n", 0, 2},
        {"1. a | b\n   --- | ---\n   h | i\n", 1, 0}
    };
    size_t i, n, total;
    struct merge_capture s;
    int failed = 0;
    for(i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        if(merge_run(cases[i].source, 0, &total, &s) ||
           s.tables != cases[i].tables || s.paragraphs != cases[i].paragraphs) {
            failed = 1;
            continue;
        }
        for(n = 1; n <= total; n++) {
            struct merge_capture probe;
            if(merge_run(cases[i].source, n, &total, &probe)) failed = 1;
        }
    }
    return failed;
}

struct container_capture {
    int tables, table_events, rows, cells, table_before_cell, bad_event;
    unsigned header_begin, body_begin, header_complete;
    MD_TABLE_CONTAINER containers[8];
    unsigned n_containers;
    MD_SIZE cell_begin[16], cell_end[16], cell_row[16];
    MD_SIZE row_begin[8];
};
static int container_block(MD_BLOCKTYPE type, void *detail, void *userdata)
{
    struct container_capture *s = userdata; (void)detail;
    if(type == MD_BLOCK_TABLE) s->tables++;
    return 0;
}
static int container_table(const MD_TABLE_SOURCE *source, void *userdata)
{
    struct container_capture *s = userdata;
    unsigned i;
    s->table_events++;
    s->header_begin = source->header_begin;
    s->body_begin = source->body_begin;
    s->header_complete = source->header_complete;
    if(source->body_begin <= source->header_begin) s->bad_event = 1;
    if(source->n_containers > sizeof(s->containers)/sizeof(s->containers[0]) ||
       (source->n_containers > 0 && source->containers == NULL)) {
        s->bad_event = 1;
        return 0;
    }
    s->n_containers = source->n_containers;
    for(i = 0; i < source->n_containers; i++)
        s->containers[i] = source->containers[i];
    return 0;
}
static int container_cell(const MD_CELL_SOURCE *cell, void *userdata)
{
    struct container_capture *s = userdata;
    if(s->table_events == 0) s->table_before_cell = 1;
    if(s->cells < 16) {
        s->cell_begin[s->cells] = cell->begin;
        s->cell_end[s->cells] = cell->end;
        s->cell_row[s->cells] = cell->row_begin;
    }
    s->cells++;
    if(s->rows < 8 && (s->rows == 0 || s->row_begin[s->rows-1] != cell->row_begin))
        s->row_begin[s->rows++] = cell->row_begin;
    return 0;
}
static int container_doc_run_at(const char *source, size_t failure,
                                int (*table_cb)(const MD_TABLE_SOURCE*, void*),
                                size_t *total, struct container_capture *s, int *result_out)
{
    MD_PARSER parser = {0}; MD_SOURCE_CALLBACKS cb = {0};
    int result, i, leaked = 0;
    memset(allocations, 0, sizeof(allocations));
    calls = 0; fail_at = failure; invalid = 0;
    memset(s, 0, sizeof(*s));
    parser.flags = MD_DIALECT_GITHUB;
    parser.enter_block = container_block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = text;
    cb.cell = container_cell; cb.table = table_cb;
    result = thin_md4c_fault_parse_source(source, (MD_SIZE)strlen(source), &parser, &cb, s);
    *total = calls;
    *result_out = result;
    for(i = 0; i < 1024; i++) if(allocations[i].pointer) { free(allocations[i].pointer); leaked = 1; }
    return invalid || leaked || s->bad_event;
}
static int container_doc_run(const char *source, struct container_capture *s)
{
    size_t total; int result;
    if(container_doc_run_at(source, 0, container_table, &total, s, &result)) return 1;
    return result != 0;
}
static int container_table_abort(const MD_TABLE_SOURCE *source, void *userdata)
{
    (void)source; (void)userdata;
    return 43;
}
static int container_fragment_run(const char *input, const struct container_capture *doc,
                                  int first_line_partial, int partial, size_t failure,
                                  size_t *total, struct container_capture *s,
                                  MD_TABLE_FRAGMENT_RESULT *fragment)
{
    static const MD_ALIGN alignments[2] = { MD_ALIGN_DEFAULT, MD_ALIGN_DEFAULT };
    MD_PARSER parser = {0}; MD_SOURCE_CALLBACKS cb = {0};
    MD_TABLE_RESUME resume;
    int result, i, leaked = 0;
    memset(allocations, 0, sizeof(allocations));
    calls = 0; fail_at = failure; invalid = 0;
    memset(s, 0, sizeof(*s));
    memset(&resume, 0, sizeof(resume));
    resume.columns = 2; resume.first_column = 0; resume.alignments = alignments;
    resume.skip = NULL; resume.partial_cell = 0;
    resume.containers = doc->n_containers ? doc->containers : NULL;
    resume.n_containers = doc->n_containers;
    resume.first_line_partial = first_line_partial;
    parser.flags = MD_DIALECT_GITHUB;
    parser.enter_block = container_block; parser.leave_block = block;
    parser.enter_span = span; parser.leave_span = span; parser.text = text;
    cb.cell = container_cell; cb.partial_input = partial;
    fragment->closed = -1; fragment->end = 0xffffffffu;
    result = thin_md4c_fault_parse_table_fragment(input, (MD_SIZE)strlen(input), &parser, &cb,
                                                  &resume, fragment, s);
    *total = calls;
    for(i = 0; i < 1024; i++) if(allocations[i].pointer) { free(allocations[i].pointer); leaked = 1; }
    if(invalid || leaked || s->bad_event) return 1;
    if(failure != 0 && (result != 0 && result != -1)) return 1;
    if(failure == 0 && result != 0) return 1;
    return 0;
}
static int native_table_header_offsets(void)
{
    static const struct { const char *source, *header, *body; int partial, events; } cases[] = {
        {"intro\na | b\n--- | ---\nx | y\n", "a | b", "x | y", 0, 1},
        {"> intro\n> a | b\n> --- | ---\n> x | y\n", "> a | b", "> x | y", 1, 1},
        {"- intro\n  a | b\n  --- | ---\n  x | y\n", "  a | b", "  x | y", 0, 1},
        {"> a | b\r\n> --- | ---\r\n> x | y\r\n", "> a | b", "> x | y", 1, 1},
        {"a | b\n--- | ---", "a | b", NULL, 0, 1},
        /* Partial EOF is not yet recognized as a table by the native parser. */
        {"a | b\n--- | ---", "a | b", NULL, 1, 0},
        {"a | b\n--- | ---\n", "a | b", NULL, 1, 1}
    };
    size_t n;
    for(n = 0; n < sizeof(cases)/sizeof(cases[0]); n++) {
        MD_PARSER p = {0}; MD_SOURCE_CALLBACKS cb = {0};
        struct container_capture s = {0}; int i, failed = 0;
        const char *header = strstr(cases[n].source, cases[n].header);
        const char *body = cases[n].body ? strstr(cases[n].source, cases[n].body) :
                                          cases[n].source + strlen(cases[n].source);
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        p.flags = MD_DIALECT_GITHUB; p.enter_block = container_block; p.leave_block = block;
        p.enter_span = span; p.leave_span = span; p.text = text;
        cb.table = container_table; cb.partial_input = cases[n].partial;
        if(thin_md4c_fault_parse_source(cases[n].source, (MD_SIZE)strlen(cases[n].source), &p, &cb, &s) ||
           s.table_events != cases[n].events || s.bad_event) failed = 1;
        if(cases[n].events && (!header || !body || s.header_begin != (unsigned)(header - cases[n].source) ||
           s.body_begin != (unsigned)(body - cases[n].source) || s.header_complete != 1)) failed = 1;
        for(i = 0; i < 1024; i++) if(allocations[i].pointer) { free(allocations[i].pointer); failed = 1; }
        if(invalid || failed) return 1;
    }
    return 0;
}
static int container_tables(void)
{
    static const char quote_doc[] = "> a | b\n> --- | ---\n> h | i\n";
    static const char list_doc[] = "- a | b\n  --- | ---\n  h | i\n";
    struct container_capture quote, list, fragment, probe;
    MD_TABLE_FRAGMENT_RESULT result;
    size_t total, calls0, n;
    int failed = 0;

    if(container_doc_run(quote_doc, &quote) || quote.tables != 1 || quote.table_events != 1 ||
       quote.n_containers != 1 || quote.containers[0].mark != '>' ||
       quote.table_before_cell || quote.cells != 4) failed = 1;
    if(container_doc_run(list_doc, &list) || list.tables != 1 || list.table_events != 1 ||
       list.n_containers != 1 || list.containers[0].mark != '-' ||
       list.containers[0].contents_indent != 2) failed = 1;
    if(container_doc_run("1. a | b\n   --- | ---\n   h | i\n", &probe) || probe.tables != 1 ||
       probe.n_containers != 1 || probe.containers[0].mark != '.' ||
       probe.containers[0].contents_indent != 3) failed = 1;

    /* Two quoted continuation rows reapply their native prefix. */
    if(container_fragment_run("> x | y\n> z | w\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || result.end != 16 || fragment.cells != 4 || fragment.rows != 2 ||
       fragment.cell_begin[0] != 2 || fragment.cell_end[0] != 3 ||
       fragment.cell_begin[1] != 6 || fragment.cell_begin[2] != 10) failed = 1;

    /* A container-only line closes the table at the raw line start. */
    if(container_fragment_run("> x | y\n> \n> prose\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(!result.closed || result.end != 8 || fragment.cells != 2) failed = 1;

    /* Dedent to a nonblank paragraph closes without consuming the prose. */
    if(container_fragment_run("> x | y\nz | w\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(!result.closed || result.end != 8 || fragment.cells != 2) failed = 1;
    if(container_fragment_run("> x | y\n|h|\n|---|\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(!result.closed || result.end != 8 || fragment.cells != 2) failed = 1;

    /* Native prefix variants: no space after '>' and a tab column. */
    if(container_fragment_run(">|x|y|\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || fragment.cells != 2 || fragment.cell_begin[0] != 2 ||
       fragment.cell_begin[1] != 4) failed = 1;
    if(container_fragment_run(">\tx | y\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || fragment.cells != 2 || fragment.cell_begin[0] != 2 ||
       fragment.cell_begin[1] != 6) failed = 1;

    /* A partial prefix-only line waits while more input is expected. */
    if(container_fragment_run("> x | y\n> ", &quote, 0, 1, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || result.end != 10 || fragment.cells != 2) failed = 1;
    if(container_fragment_run("> x | y\n> ", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(!result.closed || result.end != 8 || fragment.cells != 2) failed = 1;

    /* first_line_partial keeps an already-consumed prefix out of the grammar. */
    if(container_fragment_run("> x | y\n", &quote, 1, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || fragment.cells != 2 || fragment.cell_begin[0] != 0 ||
       fragment.cell_end[0] != 3) failed = 1;
    if(container_fragment_run("> x | y\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || fragment.cells != 2 || fragment.cell_begin[0] != 2) failed = 1;

    /* Extra container marks beyond the snapshot are ordinary cell content. */
    if(container_fragment_run("> > x | y\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || fragment.cells != 2 || fragment.cell_begin[0] != 2 ||
       fragment.cell_end[0] != 5) failed = 1;

    /* CRLF prefixes and a container-only CRLF closing line. */
    if(container_doc_run("> a | b\r\n> --- | ---\r\n> h | i\r\n", &quote)) failed = 1;
    if(container_fragment_run("> x | y\r\n> \r\n", &quote, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(!result.closed || result.end != 9 || fragment.cells != 2) failed = 1;

    /* List indentation comes from the captured native parent. */
    if(container_fragment_run("  x | y\nz | w\n", &list, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(!result.closed || result.end != 8 || fragment.cells != 2 ||
       fragment.cell_begin[0] != 2) failed = 1;
    if(container_fragment_run("   x | y\n   z | w\n", &probe, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || result.end != 18 || fragment.cells != 4 || fragment.rows != 2 ||
       fragment.cell_begin[0] != 3 || fragment.cell_begin[2] != 12) failed = 1;

    /* Top-level tables have no snapshot and keep the legacy line grammar. */
    memset(&probe, 0, sizeof(probe));
    if(container_fragment_run("x | y\nz | w\n", &probe, 0, 0, 0, &total, &fragment, &result))
        return 1;
    if(result.closed || fragment.cells != 4 || fragment.cell_begin[0] != 0) failed = 1;

    /* The table-source callback aborts with its exact code before any cell. */
    {
        struct container_capture aborted; size_t calls0; int result;
        if(container_doc_run_at(quote_doc, 0, container_table_abort, &calls0, &aborted, &result))
            return 1;
        if(result != 43 || aborted.cells != 0) failed = 1;
    }

    /* Native pool/callback allocation failures stay clean. */
    {
        struct container_capture probe2; size_t calls0, n; int result;
        if(container_doc_run_at(quote_doc, 0, container_table, &calls0, &probe2, &result))
            return 1;
        for(n = 1; n <= calls0; n++) {
            if(container_doc_run_at(quote_doc, n, container_table, &total, &probe2, &result))
                failed = 1;
            if(result != 0 && result != -1) failed = 1;
        }
    }

    /* Allocation failures in container reconstruction must stay clean. */
    if(container_fragment_run("  x | y\nz | w\n", &list, 0, 0, 0, &total, &fragment, &result))
        return 1;
    calls0 = total;
    for(n = 1; n <= calls0; n++)
        if(container_fragment_run("  x | y\nz | w\n", &list, 0, 0, n, &total, &probe, &result))
            failed = 1;

    /* Invalid container seeds are argument failures, never guessed prefixes. */
    {
        static const MD_ALIGN a[2] = { MD_ALIGN_DEFAULT, MD_ALIGN_DEFAULT };
        MD_TABLE_RESUME resume = {2, 0, a, NULL, 0, NULL, 1, 0};
        MD_PARSER parser = {0};
        parser.enter_block = container_block; parser.leave_block = block;
        parser.enter_span = span; parser.leave_span = span; parser.text = text;
        memset(allocations, 0, sizeof(allocations)); calls = fail_at = 0; invalid = 0;
        if(thin_md4c_fault_parse_table_fragment("x | y\n", 6, &parser, NULL, &resume, NULL, &quote) != -1)
            failed = 1;
        for(n = 0; n < 1024; n++) if(allocations[n].pointer) { free(allocations[n].pointer); failed = 1; }
        if(invalid) failed = 1;
    }
    return failed;
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
    if(reference_faults() || callback_faults() || inline_faults() || inline_span_faults() || document_source_faults() || persisted_reference_faults() || persisted_reference_transactions() || native_source_regressions() || native_cell_metadata() || native_reference_scopes() || multiline_code_tables() || native_table_header_offsets() || container_tables()) return 1;
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
