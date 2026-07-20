# Hovery Web extensions

A Web extension is a directory ending in `.hoveryextension`. Put extension packages in the directory configured by `directory` in `extensions.toml`; the default is `Extensions` beside the configuration files.

## Manifest

```toml
[extension]
id = "org.example.extension"
name = "Example"
input = "sentence"
order = 0

[view]
document = "web/index.html"
module = "web/main.js"

[permissions]
network = ["https://api.example.com"]
capabilities = []
selectionOverlay = true
```

`input` accepts `word`, `sentence`, `paragraph`, or `block`. Every request also contains all available semantic selections.

## ESM lifecycle

The module must export `present(request)`. It may also export `mount(context)` and `unmount(context)`:

```js
export function mount({ root, extension, capabilities }) {
  // Called once after the document and ESM entry load.
}

export async function present({ id, input, selections, root, signal, capabilities, overlay }) {
  overlay.showInput()
  root.textContent = input.text
}

export function unmount({ root }) {
  root.replaceChildren()
}
```

Hovery aborts `signal` before invoking `present()` for a newer request. The page owns its DOM and may use standard browser APIs, ESM imports, Web Components, or a bundled Web framework. There is no callback or event-based lifecycle API.

Relative resources are isolated to the extension package. Network connections are disabled unless their origin is listed in the manifest. Browser CORS rules still apply.

## Selection overlay

An extension that declares `selectionOverlay = true` may show which source selection it is processing. `showInput()` always refers to the actual input selected for this request, including semantic-level fallback:

```js
overlay.showInput()
overlay.show(selections.sentence, {
  material: "hudWindow",
  materialOpacity: 0.16,
  fill: "rgba(255, 159, 10, 0.08)",
  stroke: "orange",
  lineWidth: 1.5,
  lineDash: [5, 3],
  lineCap: "round",
  shadow: { color: "rgb(0 0 0 / 25%)", radius: 5, y: -1 }
})
overlay.show([
  { selection: selections.word, style: { stroke: "#0a84ff", lineWidth: 2 } },
  { selection: selections.sentence, style: { stroke: "orange", lineDash: [5, 3] } }
])
overlay.clear()
```

`fill`, `stroke`, and `shadow.color` accept CSS colors. They are resolved to sRGB by the extension's Web environment before crossing the native boundary; there is no host color palette. `material` accepts `none` or an AppKit visual-effect material such as `hudWindow`, `popover`, `menu`, `sidebar`, `contentBackground`, or `underPageBackground`.

Selections carry request-scoped opaque IDs. Hovery maps those IDs back to its own geometry; extensions cannot submit arbitrary screen coordinates. Stale IDs are ignored. The overlay is cleared automatically when the request is aborted, the results panel closes, or the active provider changes. Only the active provider's overlay is visible.

The extension controls each selection's presentation. The host configuration only provides a global switch and fallback styling for extensions that omit style properties:

```toml
[extensionOverlay]
enabled = true
fillOpacity = 0.0
strokeOpacity = 0.55
lineWidth = 1.0
material = "hudWindow"
materialOpacity = 0.18
```

## Native capabilities

An extension can package its own persistent native helper. Hovery has no provider-specific native implementations; it only validates, launches, and communicates with the executable declared by the extension:

```toml
[permissions]
capabilities = ["org.example.dictionary"]

[native]
executable = "native/ExampleHelper"
protocol = "json-lines-v1"
```

Native extensions are disabled until the user explicitly trusts and enables them. Their executable must have a valid code signature from the same development team as Hovery. Build and copy the helper without modifying its signature after signing.

Calls from ESM use a Promise directly; there is no Hovery callback or event lifecycle:

```js
const result = await capabilities.invoke(
  "org.example.dictionary",
  "lookup",
  { text: input.text }
)
```

Hovery rejects capabilities that the package did not declare. A capability result must be structured-clone-compatible data such as strings, arrays, and plain objects. Cancelling the current presentation rejects its outstanding calls, but helpers should still make expensive operations bounded because process cancellation does not imply operation-level cancellation inside the helper.

### JSON-lines protocol

Hovery keeps the helper running while its extension is loaded. Each line on standard input is one UTF-8 JSON request:

```json
{"id":"request-id","capability":"org.example.dictionary","method":"lookup","arguments":{"text":"hello"}}
```

The helper writes exactly one response with the matching `id` to standard output:

```json
{"id":"request-id","result":{"format":"html","content":"..."}}
```

Failures use `{"id":"request-id","error":{"message":"..."}}`. Standard output is reserved for protocol messages; helpers should write diagnostics to standard error. Requests may be concurrent and responses may arrive in any order. Runtime limits are configured in `extensions.toml`:

```toml
nativeRequestTimeout = 5.0
nativeMaximumMessageBytes = 4194304
```

### Apple Dictionary example

Apple Dictionary is an independent example project under `Examples/AppleDictionary`; it is not a Hovery target or dependency. Build its `AppleDictionaryExtension` scheme using the same development team as Hovery. The project signs the helper before assembling it into `Examples/AppleDictionary/Extension/AppleDictionary.hoveryextension`.

The example prefers the system's rich panel document when that implementation is available, and falls back to the public plain-text DictionaryServices API. The rich API is not a public App Store API, so extensions must not assume that the HTML format exists on every macOS release.

Example packages are not installed automatically. Copy one into the folder shown by **Extensions… → Open Extensions Folder**, then choose **Reload**.

See `Examples/StreamingEcho/Extension/StreamingEcho.hoveryextension` for incremental page updates and `Examples/AppleDictionary` for the independently built native example.
