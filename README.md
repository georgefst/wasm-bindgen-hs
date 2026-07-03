An experiment in improving the UX of writing GHC Wasm JSFFI exports, inspired by Rust's [wasm-bindgen](https://rustwasm.github.io/docs/wasm-bindgen/), as well as `wasm-pack` and `wasm-bodge`. Extremely pre-alpha. Performant conversion functions depend on a submodule which is highly unstable.

Note that this is all only supports GHC's _WebAssembly_ backend, not the _JavaScript_ backend.

# `wasm-bindgen-hs`

Allows writing:
```hs
$(exportJS Async "getCurrentTimeText" [|| Text.show <$> getCurrentTime ||])
```

instead of:

```hs
foreign export javascript "getCurrentTimeText" js_export_getCurrentTimeText :: IO JSString
js_export_getCurrentTimeText :: IO JSString
js_export_getCurrentTimeText = textToJSString . Text.show <$> getCurrentTime
```

While also generating TypeScript declarations, e.g. for use by `cabal-npm`:
```ts
export function getCurrentTimeText(): Promise<string>;
```

# `cabal-npm`

Creates a TypeScript NPM package out of the generated bindings.

# Running the example

## Build and package

```sh
cabal npm example --out-dir example/npm
```

This builds the Wasm binary, runs GHC's `post-link.mjs`, and assembles the NPM package in `example/npm/` (which is entirely generated) with `index.mjs`, `index.d.ts`, `runtime.mjs`, and `package.json`.

`cabal npm` works via cabal's [external command system](https://cabal.readthedocs.io/en/latest/external-commands.html): the dev shell puts a `cabal-npm` wrapper (which just delegates to `cabal run exe:cabal-npm`) on `PATH`, so no `cabal install` is needed.

## Move to subdirectory

```sh
cd example
```

## Install NPM dependencies

```sh
npm install
```

## Run tests

```sh
node --test test.mts
```

## Serve the web demo

```sh
npx http-server example -o demo.html
```
