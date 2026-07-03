{-# LANGUAGE MultilineStrings #-}

-- | The generic GHC Wasm JSFFI runtime, written verbatim into every assembled
-- package. Kept as close as possible to the JS from
-- https://github.com/haskell-wasm/ghc-wasm-miso-examples, adapted for Node
-- and wrapped in an initialisation function (see TODO.md).
module Runtime (runtimeMjs) where

import Data.Text (Text)

runtimeMjs :: Text
runtimeMjs =
    """
    import { WASI, OpenFile, File, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
    import { readFile } from "node:fs/promises";
    import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";
    let exports;
    export async function init(wasmFileName) {
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
      const wasmBytes = await readFile(new URL(wasmFileName, import.meta.url));
      const { instance } = await WebAssembly.instantiate(wasmBytes, {
        wasi_snapshot_preview1: wasi.wasiImport,
        ghc_wasm_jsffi: ghc_wasm_jsffi(instance_exports),
      });
      Object.assign(instance_exports, instance.exports);
      wasi.initialize(instance);
      exports = instance.exports;
      return exports;
    }
    """
