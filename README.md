An experiment in improving the UX of writing GHC Wasm JSFFI exports, inspired by Rust's [wasm-bindgen](https://rustwasm.github.io/docs/wasm-bindgen/). Extremely pre-alpha. Performant conversion functions depend on a submodule which is highly unstable.

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

Ultimate goal is to make converting a Haskell library to a TypeScript NPM package as simple as possible.

## Lists

Lists of otherwise-supported types (including nested lists, and `StablePtr`s) are converted to and from JS arrays. `String` (i.e. `[Char]`) is special-cased, and converted whole to a JS string.

## Opaque Haskell values (`StablePtr`)

Haskell heap objects can be passed to JS opaquely by using `StablePtr` in exported signatures. `StablePtr t` arguments and results are passed through the FFI unconverted (they appear as plain numbers on the JS side):

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

On the JS side, the recommended pattern is to wrap the pointer in a class, and register it with a `FinalizationRegistry` so that the Haskell-side stable pointer is released when the JS wrapper is garbage-collected:

```js
const counterRegistry = new FinalizationRegistry(exports.free_Counter);
class Counter {
  #ptr;
  constructor(ptr) {
    this.#ptr = ptr;
    counterRegistry.register(this, ptr);
  }
  static async new(name) {
    return new Counter(await exports.newCounter(name));
  }
  increment() {
    return exports.incrementCounter(this.#ptr);
  }
}
```

The [`npm` branch](https://github.com/georgefst/wasm-bindgen-hs/tree/npm), which generates JS/TS glue code and NPM packages, will eventually integrate this finalization-registry logic into the generated bindings.
