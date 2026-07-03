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

## Lists

Lists of otherwise-supported types (including nested lists, and `StablePtr`s) are converted to and from JS arrays. `String` (i.e. `[Char]`) is special-cased, and converted whole to a JS string.

## Opaque Haskell values (`StablePtr`)

Haskell heap objects can be passed to JS opaquely by using `StablePtr` in exported signatures. `StablePtr t` arguments and results are passed through the FFI unconverted (they appear as plain numbers at the raw FFI boundary):

```hs
data Counter = Counter Text (IORef Int)

newCounter :: Text -> IO (StablePtr Counter)
newCounter name = newStablePtr . Counter name =<< newIORef 0
$(exportDeclJS Async 'newCounter)

incrementCounter :: StablePtr Counter -> IO Int
incrementCounter ptr = do
    Counter _ ref <- deRefStablePtr ptr
    modifyIORef' ref (+ 1)
    readIORef ref
$(exportDeclJS Async 'incrementCounter)
```

For every type `T` which appears as `StablePtr T` in any export, a synchronous `free_T` export (wrapping `freeStablePtr`) is generated automatically, exactly once per module. Note that:

- The `StablePtr` payload must be a plain type constructor, so that the freeing export can be named after it.
- Using the same opaque type in exports across _multiple modules_ will currently generate clashing `free_T` exports, as will two types with the same base name in one module (the latter is detected and rejected at compile time).

In packages assembled by `cabal-npm`, each opaque type is wrapped in a generated JS class holding the pointer privately, registered with a `FinalizationRegistry` so that the Haskell-side stable pointer is released when the JS wrapper is garbage-collected. Exported functions accept and return instances of these classes, so consumers never see raw pointers.

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
