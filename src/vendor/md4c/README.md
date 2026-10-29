# MD4C terminal parser dependency

Based on upstream MD4C **0.5.2**, MIT license (see `LICENSE.md`).
Source: https://github.com/mity/md4c/tree/release-0.5.2/src

This parser provides CommonMark structure plus GFM tables, task lists,
strikethrough and autolinks. Thin's renderer is responsible for bounded display,
colors and terminal sanitization. Raw HTML is literal, images are alt text plus
URL, and equations are textual; no resources are fetched. `abi.c` is a local
layout check for `src/ui/md4c.zig`, not an upstream file.

`zig build` compiles the vendored C sources offline; no system MD4C package or
runtime shared library is needed. Direct root/UI `zig test` commands must also
include `src/vendor/md4c/{md4c,entity,abi}.c -lc`; a full unit root also needs
`src/tests/md4c_fault_test.c`. That test-only parser copy is not linked into the
product and injects every allocation failure with always-moving realloc.

## Local ownership repairs

Local changes to `md4c.c` include:

- Store successful types realloc immediately, before the offsets realloc can fail.
- Clear attribute builds after freeing owned storage, making error cleanup idempotent.
- Initialize both fenced-code attribute builds before any fallible setup.
- Publish reference-definition capacity only after successful realloc and return
  native `-1` on failure; propagate errors from both previously unchecked
  end-current-block calls.
- Propagate every nonzero callback result through processing helpers, including
  link spans, table cells/rows and leaf blocks. Recognition helpers retain their
  positive-match semantics. Fault tests cover reference-array creation/growth and
  every callback ordinal with exact return codes, immediate stop and clean ownership.
  Unrelated optional reference-preprocessing literal fallback remains permitted.

Upstream `md4c.c` SHA256 before these repairs:
`52e39843b96b64d0281bf795128bcc88c9c4dc52d7436737e9f4306648dc4590`.
The license and upstream entity files remain unchanged; `md4c.h` also declares the local inline entry point.

Pinned current file SHA256:

```
14337551a2c35952771d869a523bc303a878ebdc41021b1e026361b98757d251  md4c.c
df85b75992545b3c89f962c091aad1e1fbe3b0e30fb99b2396ecceb53b679569  md4c.h
bd89e0cd9e39f73e3b46a4bb17bb1b4d9eb75b820132cfe5b937636cad4636f3  md4c_stream_blocks.h
3da6eed4f426f67cae1fed82694797119781a0e39dc1f2c5049052fd2f89aedd  md4c_stream_blocks.inc
69d9362cd3b61261c3ed9d9f226ae1c66a3209f9db03805b1d114841ee3a6c1f  entity.c
7d021cb683c0e7643df6ce0db51d75f8cbc313be9ec754cb4dc18c40ebaa400b  entity.h
d30937367d5413e7eaa218b1640b8946ff76fd34d97152f6979fd96169d5d0fc  LICENSE.md
```

## Streaming continuation

The batch `md_parse` ABI is unchanged. On top of it the local additions expose
source facts needed to continue streaming display without re-scanning retired
bytes. The existing candidate callback reports possible table headers and
partial-input reference definitions with undecided optional titles; the callback
receives `MD_CANDIDATE_TABLE` (1) or `MD_CANDIDATE_REFERENCE` (2) after the
range. Ranges use physical source offsets. An opened incomplete reference title
is reported before rejection but is not committed as a definition. A bare valid
destination at the partial tail remains eligible for a later optional title;
a blank line closes that possibility. A generic table candidate can share the
same starting offset, so consumers retain reference priority on ties. These
source reports do not themselves determine current rendering:

* `md_parse_spans` / `md_parse_inline_spans` report confirmed inline span
  markers (emphasis, strong, code, strikethrough, link, image, underline,
  wiki-link and math); `md_parse_source` additionally reports the native fenced
  code opener length and the closing fence range the block recognizer consumed.
* `md_parse_table_fragment` re-analyzes known continuation rows with native
  pipe/inline analysis, per-column skip offsets and a `cell_content` callback so
  a retired cell opener can be replayed from owned state instead of being
  reparsed or degraded to plain text. Its `MD_TABLE_RESUME` can carry the native
  container snapshot (`MD_TABLE_CONTAINER`, captured during block analysis and
  reported once through `SourceCallbacks.table`). That callback also reports
  `header_begin` at the raw physical header start including parent prefixes,
  `body_begin` after the delimiter's actual LF/CRLF or at EOF, and
  `header_complete` when the delimiter has LF or the input is final; no line
  ending is synthesized. The zeroed triple means absent header context.
  Each physical row start then
  reuses the same native parent-matching grammar as document line analysis
  (list marks, `>` and tab columns), while a `first_line_partial` cut after an
  already consumed prefix is exempt. A blank/container-only line or a dedent
  below the snapshot ends the table and is reported through
  `MD_TABLE_FRAGMENT_RESULT` at the original raw line start, so following prose
  is never swallowed into a cell. Prefix bytes are only skipped, never compacted
  or synthesized; cell offsets stay real source offsets. `trim_leading` defaults
  to zero; set it only when a partially retired first cell is still entirely
  leading whitespace. `partial_cell` must remain set to distinguish the next
  pipe as a separator. Only the first resumed cell is affected.
  `MD_CELL_SOURCE.present` distinguishes actual cells (including empty at
  offset zero) from synthetic missing columns. For present cells `raw_begin`
  and `raw_end` describe the half-open input range before trim/skip;
  `next_begin` is raw_end for an incomplete cell (not proof of visible
  payload), or the first byte after a known separator for a complete cell.
  For the last actual cell in a complete row it additionally passes the
  physical LF/CRLF if present. Synthetic offsets are zero and completion plus
  row completion proves only logical emptiness. All offsets refer to the
  actual parser input, and callback values are borrowed only during callback.
* Before reference definitions are emitted, the document parser rejoins a
  paragraph and an adjacent table block in place when native inline mark
  collection over their combined `MD_LINE`s resolves a code span that opens in
  the paragraph and crosses the table header. That prevents a multiline inline
  code span from being misread as a table; it uses the existing native code-span
  resolver (no second backtick lexer, no duplicate callbacks) and leaves source
  offsets, escaped ticks, genuinely adjacent tables and indented/fenced blocks
  untouched.
* `md_stream_code_*` (in `md4c_stream_blocks.inc`) continues an already
  recognized fenced block from LF-normalized container-stripped bytes with real
  source offsets, arbitrary fence lengths, transactional checkpoints and a
  distinct end-of-input state. It does not recognize containers or documents.

The renderer still uses the native grammar for every decision; none of these
entry points guesses Markdown syntax from byte suffixes or chunk boundaries.
