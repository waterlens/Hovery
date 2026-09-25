# Apple Dictionary extension

This is an independent Xcode project for the Apple Dictionary example. Hovery does not build or link this helper.

Generate and open the project:

```sh
cd Examples/AppleDictionary
xcodegen generate
open AppleDictionaryExtension.xcodeproj
```

Select the same development team used to sign Hovery, then build the `AppleDictionaryExtension` scheme. It first completes and signs `AppleDictionaryHelper`, then assembles the signed helper into `Extension/AppleDictionary.hoveryextension/native/AppleDictionaryHelper`.

The helper is a persistent JSON-lines process. Its standard output is reserved for protocol responses; diagnostic logging belongs on standard error.

A `lookup` result reports whether a definition was `found`. A definition includes the `term`, its `format` (`html` or `text`), the `content`, and the `dictionary` name; a miss includes only the `term`. The helper sends no text of its own, so the page can describe a miss in the user's language.

The page's text is in `Extension/AppleDictionary.hoveryextension/i18n.toml`, in English and Simplified Chinese. Hovery uses the language that matches your preferred languages.
