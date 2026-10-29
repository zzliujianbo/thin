/* Included at the end of md4c.c; deliberately independent of MD_CTX.  This
 * is the resumable byte-by-byte equivalent of md_is_closing_code_fence: same
 * fence character, at least opener length, then ASCII spaces only.  The native
 * caller supplies the post-container indentation origin and exclusive limit. */
#include "md4c_stream_blocks.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct { size_t start, length; uint64_t source; } md_stream_code_mapping_run;
typedef struct {
    size_t cursor, candidate_len, candidate_pos, run;
    uint64_t candidate_base;
    unsigned column;
    unsigned phase; /* 0 indentation, 1 fence run, 2 trailing spaces, 3 literal */
    int closed, done;
} md_stream_code_state;
struct md_stream_code {
    unsigned char fence;
    size_t fence_length, capacity, input_len;
    unsigned limit, initial_column;
    uint64_t base;
    unsigned char *input, *candidate, *saved_candidate;
    uint64_t *offsets;
    md_stream_code_mapping_run *runs;
    size_t run_count;
    uint64_t next_source;
    int have_source, last_lf;
    md_stream_code_allocator allocator;
    md_stream_code_state state, saved;
    int final, checkpoint;
};

static void *md_stream_code_std_alloc(void *user, size_t size) { (void)user; return malloc(size); }
static void md_stream_code_std_free(void *user, void *ptr) { (void)user; free(ptr); }
md_stream_code *
md_stream_code_create_with_allocator(unsigned char fence, size_t length, unsigned limit,
                      unsigned column, size_t capacity, uint64_t base,
                      const md_stream_code_allocator *a)
{
    md_stream_code *s;
    if ((fence != '`' && fence != '~') || length < 3 || !limit || !capacity ||
        !a || !a->alloc || !a->free || capacity > SIZE_MAX / sizeof(uint64_t) ||
        capacity > SIZE_MAX / sizeof(md_stream_code_mapping_run)) return NULL;
    s = (md_stream_code *) a->alloc(a->user, sizeof(*s));
    if (!s) return NULL;
    memset(s, 0, sizeof(*s)); s->allocator = *a;
    s->input = (unsigned char *) a->alloc(a->user, capacity);
    s->candidate = (unsigned char *) a->alloc(a->user, capacity);
    s->saved_candidate = (unsigned char *) a->alloc(a->user, capacity);
    s->offsets = (uint64_t *) a->alloc(a->user, capacity * sizeof(*s->offsets));
    s->runs = (md_stream_code_mapping_run *) a->alloc(a->user, capacity * sizeof(*s->runs));
    if (!s->input || !s->candidate || !s->saved_candidate || !s->offsets || !s->runs) {
        md_stream_code_destroy(s); return NULL;
    }
    s->fence = fence; s->fence_length = length; s->limit = limit;
    s->initial_column = column; s->capacity = capacity; s->base = base;
    s->next_source = base; s->state.column = column;
    return s;
}
md_stream_code *md_stream_code_create(unsigned char fence, size_t length, unsigned limit,
                                      unsigned column, size_t capacity, uint64_t base)
{
    md_stream_code_allocator a = { md_stream_code_std_alloc, md_stream_code_std_free, NULL };
    return md_stream_code_create_with_allocator(fence, length, limit, column, capacity, base, &a);
}
void md_stream_code_destroy(md_stream_code *s)
{
    md_stream_code_allocator a;
    if (!s) return;
    a = s->allocator;
    if (s->input) a.free(a.user, s->input);
    if (s->candidate) a.free(a.user, s->candidate);
    if (s->saved_candidate) a.free(a.user, s->saved_candidate);
    if (s->offsets) a.free(a.user, s->offsets);
    if (s->runs) a.free(a.user, s->runs);
    a.free(a.user, s);
}
md_stream_code_result
md_stream_code_feed_at(md_stream_code *s, uint64_t start, const void *data, size_t length,
                       int final, size_t *consumed)
{
    size_t n, i; const unsigned char *p = (const unsigned char *)data;
    if (consumed) *consumed = 0;
    if (!s || !consumed || (length && !data) || s->final || s->state.closed || s->state.done)
        return MD_STREAM_CODE_ERROR;
    if (length && (start < s->next_source || (s->have_source && start != s->next_source && !s->last_lf)))
        return MD_STREAM_CODE_ERROR;
    if (length > UINT64_MAX - start) return MD_STREAM_CODE_ERROR;
    /* Validate the entire offered slice before accepting a prefix. */
    for (i = 0; i < length; i++) if (p[i] == '\r') return MD_STREAM_CODE_ERROR;
    n = s->capacity - s->input_len; if (n > length) n = length;
    if (n) {
        md_stream_code_mapping_run *r = s->run_count ? &s->runs[s->run_count-1] : NULL;
        if (r && r->source + r->length == start && r->start + r->length == s->input_len)
            r->length += n;
        else {
            r = &s->runs[s->run_count++]; r->start = s->input_len; r->length = n; r->source = start;
        }
        memcpy(s->input + s->input_len, data, n);
        for (i = 0; i < n; i++) s->offsets[s->input_len+i] = start+i;
        s->input_len += n; s->next_source = start+n; s->last_lf = p[n-1] == '\n'; s->have_source = 1;
    }
    *consumed = n;
    if (final && n == length) s->final = 1;
    return n == length ? MD_STREAM_CODE_OK : MD_STREAM_CODE_NEED_DRAIN;
}
md_stream_code_result md_stream_code_feed(md_stream_code *s, const void *data, size_t length,
                                          int final, size_t *consumed)
{
    return md_stream_code_feed_at(s, s ? s->next_source : 0, data, length, final, consumed);
}
static void md_stream_code_next_line(md_stream_code *s)
{
    s->state.phase = 0; s->state.column = s->initial_column; s->state.run = 0;
}
md_stream_code_result md_stream_code_literalize(md_stream_code *s)
{
    if (!s || s->state.closed) return MD_STREAM_CODE_ERROR;
    s->state.phase = 3;
    return MD_STREAM_CODE_OK;
}
md_stream_code_result md_stream_code_checkpoint(md_stream_code *s)
{
    if (!s || s->checkpoint) return MD_STREAM_CODE_ERROR;
    s->saved = s->state;
    memcpy(s->saved_candidate, s->candidate, s->state.candidate_len);
    s->checkpoint = 1;
    return MD_STREAM_CODE_OK;
}
md_stream_code_result md_stream_code_abort(md_stream_code *s)
{
    if (!s || !s->checkpoint) return MD_STREAM_CODE_ERROR;
    s->state = s->saved;
    memcpy(s->candidate, s->saved_candidate, s->state.candidate_len);
    s->checkpoint = 0;
    return MD_STREAM_CODE_OK;
}
md_stream_code_result md_stream_code_commit(md_stream_code *s)
{
    size_t n;
    if (!s || !s->checkpoint) return MD_STREAM_CODE_ERROR;
    n = s->state.cursor;
    memmove(s->input, s->input + n, s->input_len - n);
    memmove(s->offsets, s->offsets + n, (s->input_len - n) * sizeof(*s->offsets));
    {
        size_t i, count = 0;
        for (i = 0; i < s->run_count; i++) {
            md_stream_code_mapping_run r = s->runs[i];
            if (r.start + r.length <= n) continue;
            if (r.start < n) { size_t skip = n - r.start; r.source += skip; r.length -= skip; r.start = n; }
            r.start -= n; s->runs[count++] = r;
        }
        s->run_count = count;
    }
    s->input_len -= n; s->state.cursor = 0;
    s->checkpoint = 0;
    return MD_STREAM_CODE_OK;
}
md_stream_code_result
md_stream_code_step(md_stream_code *s, size_t budget, size_t *work,
                    md_stream_code_event *event, int *has_event)
{
    md_stream_code_state *p;
    if (work) *work = 0;
    if (has_event) *has_event = 0;
    if (!s || !work || !event || !has_event || !s->checkpoint)
        return MD_STREAM_CODE_ERROR;
    p = &s->state;
    while (*work < budget) {
        unsigned char c;
        uint64_t offset;
        if (p->candidate_pos < p->candidate_len && p->phase == 3) {
            c = s->candidate[p->candidate_pos];
            event->type = MD_STREAM_CODE_TEXT;
            event->begin = p->candidate_base + p->candidate_pos;
            event->end = event->begin + 1; event->byte = c;
            p->candidate_pos++; (*work)++; *has_event = 1;
            if (p->candidate_pos == p->candidate_len) {
                p->candidate_pos = p->candidate_len = 0;
                if (c == '\r' || c == '\n') md_stream_code_next_line(s);
            }
            return MD_STREAM_CODE_OK;
        }
        if (p->closed) return MD_STREAM_CODE_CLOSED;
        if (p->done) return MD_STREAM_CODE_DONE;
        if (p->cursor == s->input_len) {
            if (!s->final) return MD_STREAM_CODE_NEED_INPUT;
            if (p->phase != 3 && p->run >= s->fence_length &&
                (p->phase == 1 || p->phase == 2)) {
                event->type = MD_STREAM_CODE_CLOSE;
                event->begin = p->candidate_base; event->end = p->candidate_base + p->candidate_len;
                event->byte = 0; p->closed = 1; *has_event = 1; (*work)++;
                return MD_STREAM_CODE_OK;
            }
            if (p->candidate_len) { p->phase = 3; continue; }
            p->done = 1; (*work)++; return MD_STREAM_CODE_DONE;
        }
        c = s->input[p->cursor]; offset = s->offsets[p->cursor];
        if (p->phase == 3) {
            p->cursor++; (*work)++;
            event->type = MD_STREAM_CODE_TEXT; event->begin = offset;
            event->end = offset + 1; event->byte = c; *has_event = 1;
            if (c == '\r' || c == '\n') md_stream_code_next_line(s);
            return MD_STREAM_CODE_OK;
        }
        if (c == '\r' || c == '\n') {
            if (p->run >= s->fence_length && (p->phase == 1 || p->phase == 2)) {
                p->cursor++; (*work)++; p->closed = 1;
                event->type = MD_STREAM_CODE_CLOSE; event->begin = p->candidate_base;
                event->end = offset + 1; event->byte = 0; *has_event = 1;
                return MD_STREAM_CODE_OK;
            }
            p->phase = 3; continue;
        }
        if (p->phase == 0 && (c == ' ' || c == '\t')) {
            unsigned next;
            if (c == '\t') {
                if (p->column > UINT32_MAX - 4) { p->phase = 3; continue; }
                next = (p->column + 4) & ~3u;
            } else {
                if (p->column == UINT32_MAX) { p->phase = 3; continue; }
                next = p->column + 1;
            }
            if (next - s->initial_column >= s->limit) { p->phase = 3; continue; }
            if (p->candidate_len == s->capacity) return MD_STREAM_CODE_NEED_DRAIN;
            p->column = next;
        } else if ((p->phase == 0 || p->phase == 1) && c == s->fence) {
            if (p->candidate_len == s->capacity) return MD_STREAM_CODE_NEED_DRAIN;
            p->phase = 1; p->run++;
        } else if ((p->phase == 1 || p->phase == 2) && c == ' ') {
            if (p->candidate_len == s->capacity) return MD_STREAM_CODE_NEED_DRAIN;
            p->phase = 2;
        } else { p->phase = 3; continue; }
        if (!p->candidate_len) p->candidate_base = offset;
        s->candidate[p->candidate_len++] = c; p->cursor++; (*work)++;
    }
    return MD_STREAM_CODE_OK;
}
