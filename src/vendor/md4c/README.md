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

Only `md4c.c` differs from the imported upstream files:

- Store successful types realloc immediately, before the offsets realloc can fail.
- Clear attribute builds after freeing owned storage, making error cleanup idempotent.
- Initialize both fenced-code attribute builds before any fallible setup.

Upstream `md4c.c` SHA256 before these repairs:
`52e39843b96b64d0281bf795128bcc88c9c4dc52d7436737e9f4306648dc4590`.
The license and all other upstream files remain unchanged.

Pinned current file SHA256:

```
1b5510c57014536ce51a1b965e2bda19fc0a9de998d40414a38c65d1c5c29902  md4c.c
4efd19bf7ec270691d5b4189f496886e421768a814b5e817eb945aa85e859f18  md4c.h
69d9362cd3b61261c3ed9d9f226ae1c66a3209f9db03805b1d114841ee3a6c1f  entity.c
7d021cb683c0e7643df6ce0db51d75f8cbc313be9ec754cb4dc18c40ebaa400b  entity.h
d30937367d5413e7eaa218b1640b8946ff76fd34d97152f6979fd96169d5d0fc  LICENSE.md
```
