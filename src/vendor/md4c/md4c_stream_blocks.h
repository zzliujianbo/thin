#ifndef MD4C_STREAM_BLOCKS_H
#define MD4C_STREAM_BLOCKS_H
#include <stddef.h>
#include <stdint.h>

/* Byte-oriented continuation for an already recognized fenced code block.
 * The caller supplies container-stripped physical-line bytes in contiguous
 * source order, using feed_at for source gaps. Input must be LF-normalized;
 * CR is rejected. This does not recognize containers or remove code indentation.
 * Events are transactional: discard events after abort; publish after commit.
 * Text events contain one owned byte; close ranges include the LF if present. */
typedef struct md_stream_code md_stream_code;
typedef enum { MD_STREAM_CODE_OK, MD_STREAM_CODE_NEED_INPUT,
    MD_STREAM_CODE_NEED_DRAIN, MD_STREAM_CODE_CLOSED, MD_STREAM_CODE_DONE,
    MD_STREAM_CODE_ERROR } md_stream_code_result;
typedef enum { MD_STREAM_CODE_TEXT, MD_STREAM_CODE_CLOSE } md_stream_code_event_type;
typedef struct {
    md_stream_code_event_type type;
    uint64_t begin, end;
    unsigned char byte; /* valid for TEXT */
} md_stream_code_event;

/* capacity bounds both retained input and candidate bytes. indent_limit is the
 * exclusive column limit, normally 4; initial_column is the column at which
 * indentation starts after native container stripping. */
typedef void *(*md_stream_code_alloc_fn)(void *user, size_t size);
typedef void (*md_stream_code_free_fn)(void *user, void *ptr);
typedef struct { md_stream_code_alloc_fn alloc; md_stream_code_free_fn free; void *user; } md_stream_code_allocator;
md_stream_code *md_stream_code_create_with_allocator(unsigned char fence, size_t fence_length,
    unsigned indent_limit, unsigned initial_column, size_t capacity, uint64_t base,
    const md_stream_code_allocator *allocator);
md_stream_code *md_stream_code_create(unsigned char fence, size_t fence_length,
    unsigned indent_limit, unsigned initial_column, size_t capacity, uint64_t base);
void md_stream_code_destroy(md_stream_code *s);
/* Copies up to available capacity. final is accepted only when all bytes were
 * copied; no further feed is permitted thereafter. consumed is always set. */
md_stream_code_result md_stream_code_feed(md_stream_code *s, const void *data,
    size_t length, int final, size_t *consumed);
/* start is the real source offset of data[0], monotonic and non-overlapping.
 * Discontinuities must occur only at physical-line boundaries. CR is invalid. */
md_stream_code_result md_stream_code_feed_at(md_stream_code *s, uint64_t start,
    const void *data, size_t length, int final, size_t *consumed);
/* At most budget input bytes or candidate output bytes are processed. One event
 * per call. work reports the actual units consumed, including event emission. */
md_stream_code_result md_stream_code_step(md_stream_code *s, size_t budget,
    size_t *work, md_stream_code_event *event, int *has_event);
/* Explicitly freeze the current possible closing line as literal code; useful
 * to drain a candidate larger than capacity. Never done at chunk boundaries. */
md_stream_code_result md_stream_code_literalize(md_stream_code *s);
/* One active checkpoint. Abort restores parser state and input cursor but retains
 * bytes fed after the checkpoint, including the final marker. Commit discards
 * consumed input and makes staged state the new checkpoint. */
md_stream_code_result md_stream_code_checkpoint(md_stream_code *s);
md_stream_code_result md_stream_code_commit(md_stream_code *s);
md_stream_code_result md_stream_code_abort(md_stream_code *s);
#endif
