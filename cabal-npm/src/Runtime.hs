{-# LANGUAGE MultilineStrings #-}

{- | The GHC Wasm JSFFI runtime, generated per package (the name of the Wasm
binary is baked in). Based on the JS from
https://github.com/haskell-wasm/ghc-wasm-miso-examples, adapted to work in any
environment (see TODO.md).
-}
module Runtime (runtimeMjs) where

import Data.Text (Text)
import Data.Text qualified as T

runtimeMjs :: Text -> Text
runtimeMjs wasmFileName =
    T.replace "WASM_FILE" wasmFileName
        """
        import { WASI, OpenFile, File, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
        import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

        // NB. the literal file name in a `new URL(..., import.meta.url)` call also
        // allows asset-aware bundlers (e.g. Vite, Webpack 5) to include the Wasm
        // binary automatically. Bundlers without such support (e.g. esbuild) need
        // the binary copied alongside the output bundle.
        const wasmUrl = new URL("WASM_FILE", import.meta.url);

        async function instantiate(imports) {
          if (wasmUrl.protocol === "file:") {
            // Running directly from the filesystem (Node, Bun, Deno), where fetch
            // can't load file: URLs. The specifier indirection keeps
            // browser-targeting bundlers from trying to resolve the Node builtin.
            const nodeFsModule = "node:fs/promises";
            const { readFile } = await import(/* @vite-ignore */ nodeFsModule);
            return WebAssembly.instantiate(await readFile(wasmUrl), imports);
          }
          const response = fetch(wasmUrl);
          try {
            return await WebAssembly.instantiateStreaming(response, imports);
          } catch {
            // e.g. the server doesn't set the Wasm MIME type
            return WebAssembly.instantiate(await (await response).arrayBuffer(), imports);
          }
        }

        let exports;
        export async function init() {
          if (exports) return exports;
          const args = [];
          const env = [];
          const fds = [
            new OpenFile(new File([])),
            ConsoleStdout.lineBuffered((msg) => console.log(msg)),
            ConsoleStdout.lineBuffered((msg) => console.warn(msg)),
          ];
          const wasi = new WASI(args, env, fds);
          const instance_exports = {};
          const { instance } = await instantiate({
            wasi_snapshot_preview1: wasi.wasiImport,
            ghc_wasm_jsffi: ghc_wasm_jsffi(instance_exports),
          });
          Object.assign(instance_exports, instance.exports);
          wasi.initialize(instance);
          exports = instance.exports;
          return exports;
        }
        """
