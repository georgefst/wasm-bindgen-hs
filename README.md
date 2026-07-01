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
