## TypeScript generation

- `Bool` is declared as `boolean` in `.d.ts` but the GHC Wasm FFI actually marshals it as `0`/`1` (`number`). Consider generating coercion wrappers in `index.mjs`.
- `Char` is declared as `string` but is actually a Unicode code point (`number`) at the FFI boundary.
- No support yet for compound types (records, ADTs, lists, `Maybe`, tuples).
- No support for `JSVal` or other opaque JS types.

## cabal-npm (the pack tool)

- `PackConfig` is populated from CLI arguments (a required `TARGET`, with the rest optional or derived from it); consider also supporting a config file. Note that the executable is named `cabal-npm` so that it can be invoked as `cabal npm` via cabal's [external command system](https://cabal.readthedocs.io/en/latest/external-commands.html), which dispatches purely by searching `PATH` for `cabal-<cmd>`. The dev shell provides a `cabal-npm` wrapper delegating to `cabal run`, avoiding any need for `cabal install`; downstream projects could get the same no-install experience via `extra-packages: cabal-npm` (plus their own PATH wrapper for the `cabal npm` spelling). (`build-tool-depends` and a doctest-style `--with-ghc` drop-in were considered and don't fit: pack drives cabal rather than running as part of a build, and it isn't a per-module compiler pass.)
- The wasm toolchain program names (`wasm32-unknown-wasi-ghc` etc.) that pack passes via `--with-ghc` etc. are hardcoded; they should become configurable alongside the rest of `PackConfig`.
- Every pack run does a full clean rebuild of all local packages, by passing a fresh `--builddir`. This is required for correctness: cabal's up-to-date check skips invoking GHC entirely when nothing has changed (even with `--ghc-options=-fforce-recomp`), so the TH-generated `.d.ts` fragments can only be trusted to be complete and fresh after a clean build. A future incremental strategy could instead derive/validate the export list from the export section of the compiled `.wasm` binary.
- Can't migrate paths to `OsPath` yet: as of `process-1.6.30.0` only `System.Process.Environment.OsString` exists; `CreateProcess`/`callProcess`/`readProcess` still take `FilePath`/`String` (and `temporary` has no `OsPath` API either).
- `runtime.mjs` is Node-specific (`node:fs/promises`, `node:url`). The browser demo works around this by inlining the init logic. Consider supporting browser targets (using `fetch` instead of `fs`), or providing separate runtime modules per target (cf. `wasm-pack --target web|nodejs|bundler`).
- `runtime.mjs` is embedded in the cabal-npm binary as a multiline string (see `Runtime.hs`) and written verbatim into every assembled package; eventually it should probably be generated per-target (see previous bullet).
- `package.json` could use the modern `"exports"` field for proper ESM resolution.
- The `.wasm` binary is shipped uncompressed. We should at least apply gzip or brotli compression (Wasm compresses very well); npm gzips tarballs in transit, but precompressed artifacts would also help web serving.

## Consumer runtime support

- Consumers of a generated package never need TypeScript tooling to consume it: the package ships plain `.mjs` for execution plus full `.d.ts`/`.d.mts` declarations for typing; no TypeScript *source* is distributed.
- The only Node-specific code in the entire generated package is one line: `import { readFile } from "node:fs/promises"` in `runtime.mjs`. `index.mjs` uses no environment APIs at all, `@bjorn3/browser_wasi_shim` is pure JS, and GHC's generated `ghc_wasm_jsffi.js` is deliberately runtime-agnostic (its only environment probing is choosing a `setImmediate` implementation, with explicit branches for Node/Bun, Deno, browsers, and Cloudflare Workers). So Bun (which implements `node:fs/promises` natively) and Deno (which supports `node:` builtins, and resolves the package's bare imports when consumed via an `npm:` specifier) are *likely* to work, but neither is tested — consider adding them to the dev shell and CI. Browsers can't use `runtime.mjs` at all (no filesystem) — see the per-target runtime bullet above; note that switching to `WebAssembly.instantiateStreaming(fetch(...))` would remove the last Node-ism for fetch-capable runtimes. We also haven't established a minimum supported Node version (the generated code uses ESM, `BigInt`, and async instantiation — so realistically Node ≥18, but unverified).
- Our own tests are `.mts` run directly by Node via type stripping (types are erased, not compiled — and *not checked*, hence the separate `npx tsc --noEmit` step). Type stripping is enabled by default since Node 22.18/23.6 (the dev shell's Node qualifies, so the README just says `node --test test.mts`); on Node 22.6–22.17 it needs `--experimental-strip-types`, and on older Node the tests would need `tsx`/`ts-node` or precompilation. Only constructs requiring codegen (`enum`, namespaces, etc.) are unsupported — we don't use any.

## TH ↔ pack communication

How the `.d.ts` fragments get from the library's TH splices to the pack tool. This whole mechanism deserves revisiting at some point.

- How it currently works: `cabal-npm` writes the absolute path of a per-run temporary directory to a marker file, `.wasm-bindgen-hs-ts-out-dir`, in the working directory (removed again via `bracket_` once the build finishes). During compilation, each `Wasm.Export` splice checks (via `runIO`) for that marker file relative to *its* working directory; if present, it writes its `.d.ts` fragment into the named directory, and otherwise writes nothing (so ordinary dev/HLS builds produce no stray output). After the build, pack reads the fragments back to assemble `index.d.ts`/`index.mjs`.
- Why a marker file rather than an environment variable: the TH code runs inside GHC's Wasm external interpreter, and `dyld.mjs` hardcodes the interpreter's WASI environment to just `PATH` and `PWD`, so host environment variables never reach `lookupEnv` in TH. The host *filesystem* is fully preopened, though, hence file-based communication (both for the marker and for the fragments themselves, which are written to an absolute path under `/tmp`). Forwarding the host environment could be proposed upstream in GHC.
- The marker file is intentionally not gitignored and there's no crash cleanup beyond `bracket_`: if pack is killed uncleanly (SIGKILL, power loss), a stale marker is left behind, silently re-enabling fragment-writing in ordinary dev builds against a dead temp path. Pack could detect and remove a pre-existing marker on startup, and the file should probably be gitignored.
- The marker file name is duplicated as `tsOutDirFile` in both `Wasm.Export` (the library) and `Pack` (the tool), since they're separate packages built for different targets; the two constants must be kept in sync by hand.
- The marker also assumes pack's working directory and the compilation working directory coincide (true when running from the project root with packages at the root). For target packages in subdirectories, the TH side should probably resolve the marker via `getPackageRoot` instead.

## Wasm FFI

- Pure functions don't need `Async` exports. Using `Async` for pure functions like `greetManyPure` or `replicateText` adds unnecessary overhead and forces callers to `await`.
- The `init()` / explicit initialization pattern is ugly but unavoidable: callers must `await init()` before using any exports, because Wasm module instantiation is inherently asynchronous on the current WebAssembly platform. WASI 0.3 components should eventually eliminate this boilerplate. See [wasm-bodge](https://github.com/alexjg/wasm-bodge) for an alternative approach in the meantime.
- Sync exports don't yet propagate uncaught Haskell exceptions to JavaScript (GHC limitation).

## Project organisation

- We'll probably rename the repo at some point, and split the JS/TypeScript stuff (`TS.AST`, `TS.Serialize`) in to its own package.
