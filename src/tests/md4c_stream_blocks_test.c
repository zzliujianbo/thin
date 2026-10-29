/* Standalone harness: link against md4c.c after it includes the .inc. */
#include "../vendor/md4c/md4c_stream_blocks.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

static void feed_all(md_stream_code *s, const char *p, size_t n, int final)
{
    size_t used;
    assert(md_stream_code_feed(s, p, n, final, &used) == MD_STREAM_CODE_OK);
    assert(used == n);
}
static size_t drain(md_stream_code *s, char *out, size_t cap, int *closed)
{
    size_t len = 0, work;
    int has;
    md_stream_code_event e;
    md_stream_code_result r;
    *closed = 0;
    for (;;) {
        r = md_stream_code_step(s, 1, &work, &e, &has);
        assert(work <= 1);
        assert(r != MD_STREAM_CODE_ERROR && r != MD_STREAM_CODE_NEED_DRAIN);
        if (has && e.type == MD_STREAM_CODE_CLOSE) { *closed = 1; break; }
        if (has && e.type == MD_STREAM_CODE_TEXT) {
            assert(e.end == e.begin + 1 && len < cap);
            out[len++] = (char)e.byte;
        }
        if (r == MD_STREAM_CODE_NEED_INPUT || r == MD_STREAM_CODE_CLOSED || r == MD_STREAM_CODE_DONE) break;
    }
    return len;
}
static void split_fences(void)
{
    const char *input = "```\n````x\n````  \n";
    const char *expected = "```\n````x\n";
    md_stream_code *s = md_stream_code_create('`', 4, 4, 0, 128, 100);
    char out[128]; size_t n = 0, i; int closed = 0;
    assert(s);
    for (i = 0; i < strlen(input); i++) {
        size_t got;
        assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
        feed_all(s, input + i, 1, 0);
        got = drain(s, out + n, sizeof(out) - n, &closed); n += got;
        assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
        if (closed) break;
    }
    assert(closed && n == strlen(expected) && !memcmp(out, expected, n));
    md_stream_code_destroy(s);
}
static void empty_and_final(void)
{
    md_stream_code *s = md_stream_code_create('~', 4, 4, 0, 64, 0);
    char out[32]; int closed; size_t n;
    assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    feed_all(s, "~~~~", 4, 0);
    n = drain(s, out, sizeof(out), &closed); assert(!closed && n == 0);
    feed_all(s, NULL, 0, 1);
    n = drain(s, out, sizeof(out), &closed); assert(closed && n == 0);
    assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
    md_stream_code_destroy(s);
}
static void literal_and_abort(void)
{
    md_stream_code *s = md_stream_code_create('`', 4, 4, 0, 32, 9);
    char out[64]; int closed; size_t n;
    assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    feed_all(s, "````", 4, 0);
    assert(drain(s, out, sizeof(out), &closed) == 0 && !closed);
    assert(md_stream_code_literalize(s) == MD_STREAM_CODE_OK);
    n = drain(s, out, sizeof(out), &closed); assert(n == 4 && !closed);
    assert(md_stream_code_abort(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    feed_all(s, "\n", 1, 0);
    n = drain(s, out, sizeof(out), &closed); assert(n == 0 && closed);
    assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
    md_stream_code_destroy(s);

    s = md_stream_code_create('`', 4, 4, 0, 32, 0);
    assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    feed_all(s, "````", 4, 0);
    assert(drain(s, out, sizeof(out), &closed) == 0);
    assert(md_stream_code_literalize(s) == MD_STREAM_CODE_OK);
    assert(drain(s, out, sizeof(out), &closed) == 4);
    assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    feed_all(s, "\n", 1, 0);
    assert(drain(s, out, sizeof(out), &closed) == 1 && !closed && out[0] == '\n');
    assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
    md_stream_code_destroy(s);
}
static void capacity_and_indent(void)
{
    md_stream_code *s = md_stream_code_create('`', 4, 4, 0, 4, 0);
    size_t used, work; int has; md_stream_code_event e;
    assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_feed(s, "`````", 5, 0, &used) == MD_STREAM_CODE_NEED_DRAIN && used == 4);
    assert(md_stream_code_step(s, 4, &work, &e, &has) == MD_STREAM_CODE_OK && work == 4 && !has);
    assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    feed_all(s, "`", 1, 0);
    assert(md_stream_code_step(s, 1, &work, &e, &has) == MD_STREAM_CODE_NEED_DRAIN);
    assert(md_stream_code_literalize(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_step(s, 1, &work, &e, &has) == MD_STREAM_CODE_OK && has && e.byte == '`');
    {
        char out[16]; int closed; size_t n = drain(s, out, sizeof(out), &closed);
        assert(n == 4 && !closed);
        assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
        assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
        feed_all(s, "\n", 1, 1);
        assert(drain(s, out, sizeof(out), &closed) == 1 && !closed && out[0] == '\n');
        assert(md_stream_code_commit(s) == MD_STREAM_CODE_OK);
    }
    md_stream_code_destroy(s);
    assert(!md_stream_code_create('x', 4, 4, 0, 4, 0));
    assert(!md_stream_code_create('`', 2, 4, 0, 4, 0));
    assert(!md_stream_code_create('`', 4, 4, 0, 0, 0));
}
typedef struct { size_t call, fail, live; } alloc_test;
static void *test_alloc(void *ctx, size_t size)
{
    alloc_test *a = (alloc_test *)ctx; void *p;
    if (a->call++ == a->fail) return NULL;
    p = malloc(size); if (p) a->live++; return p;
}
static void test_free(void *ctx, void *p)
{
    alloc_test *a = (alloc_test *)ctx; assert(p && a->live); a->live--; free(p);
}
static void allocation_failures(void)
{
    size_t i;
    for (i = 0; i < 7; i++) {
        alloc_test a = {0, i, 0};
        md_stream_code_allocator alloc = {test_alloc, test_free, &a};
        md_stream_code *s = md_stream_code_create_with_allocator('`', 4, 4, 0, 16, 0, &alloc);
        if (i < 6) assert(!s); else assert(s);
        md_stream_code_destroy(s); assert(a.live == 0);
    }
}
static void mapping_and_eof(void)
{
    md_stream_code *s = md_stream_code_create('`', 4, 4, 0, 32, 0);
    md_stream_code_event e; md_stream_code_result r; size_t used, work; int has;
    assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_feed_at(s, 10, "a\n", 2, 0, &used) == MD_STREAM_CODE_OK && used == 2);
    assert(md_stream_code_feed_at(s, 20, "b\n", 2, 1, &used) == MD_STREAM_CODE_OK && used == 2);
    assert(md_stream_code_abort(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    for (;;) {
        r = md_stream_code_step(s, 10, &work, &e, &has);
        if (has && e.type == MD_STREAM_CODE_TEXT) {
            assert(e.begin == 10 || e.begin == 11 || e.begin == 20 || e.begin == 21);
            assert(e.end == e.begin + 1);
        }
        if (r == MD_STREAM_CODE_DONE) break;
        assert(r == MD_STREAM_CODE_OK);
    }
    assert(md_stream_code_abort(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    do { r = md_stream_code_step(s, 10, &work, &e, &has); } while (r == MD_STREAM_CODE_OK);
    assert(r == MD_STREAM_CODE_DONE && md_stream_code_commit(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
    assert(md_stream_code_step(s, 1, &work, &e, &has) == MD_STREAM_CODE_DONE);
    md_stream_code_destroy(s);
}
static void indentation_and_cr(void)
{
    unsigned i;
    for (i = 0; i <= 4; i++) {
        md_stream_code *s = md_stream_code_create('`', 4, 4, 2, 64, 0);
        char text[16], out[32]; size_t n; int closed;
        memset(text, ' ', i); memcpy(text+i, "````\n", 5);
        assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
        feed_all(s, text, i+5, 1); n = drain(s, out, sizeof(out), &closed);
        assert((i < 4 && closed && !n) || (i == 4 && !closed && n == i+5));
        md_stream_code_destroy(s);
    }
    {
        md_stream_code *s = md_stream_code_create('`', 4, 4, 2, 64, 0);
        char out[32]; int closed; size_t used;
        assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
        assert(md_stream_code_feed(s, "\r\n", 2, 0, &used) == MD_STREAM_CODE_ERROR && !used);
        feed_all(s, "\t````\n", 6, 1);
        assert(drain(s, out, sizeof(out), &closed) == 0 && closed);
        md_stream_code_destroy(s);
    }
    {
        md_stream_code *s = md_stream_code_create('`', 4, 4, 0, 64, 0);
        char out[32]; int closed;
        assert(s && md_stream_code_checkpoint(s) == MD_STREAM_CODE_OK);
        feed_all(s, "\t````\n", 6, 1);
        assert(drain(s, out, sizeof(out), &closed) == 6 && !closed);
        md_stream_code_destroy(s);
    }
}
int thin_md4c_stream_blocks_test(void)
{
    split_fences(); empty_and_final(); literal_and_abort(); capacity_and_indent();
    allocation_failures(); mapping_and_eof(); indentation_and_cr();
    return 0;
}
#ifdef MD4C_STREAM_BLOCKS_TEST_MAIN
int main(void) { return thin_md4c_stream_blocks_test(); }
#endif
