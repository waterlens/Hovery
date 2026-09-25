<p align="center">
  <img src="Docs/Brand/HoveryIconSource.png" width="128" height="128" alt="Hovery icon">
</p>

# Hovery

Hovery recognizes the visible text beneath the pointer on macOS with Vision OCR. It can identify a word, sentence, paragraph, or text block without selecting or clicking the source text, then present results from isolated HTML/ESM extensions.

## Requirements

- macOS 26 or later
- Screen & System Audio Recording permission
- Accessibility permission

## Install

Download the current DMG from [GitHub Releases](https://github.com/waterlens/Hovery/releases), open it, and drag Hovery into Applications.

At first launch, grant both permissions shown by Hovery. Recognition is enabled by default while Command is held. Timing, activation keys, OCR behavior, and debugging options are configurable from Settings.

## Extensions

Release assets include two extensions:

- **Apple Dictionary** (`AppleDictionary-<version>.hoveryextension.zip`) looks up the word under the pointer in the system dictionaries. After installing it, trust and enable its native helper.
- **Auto Translator** (`AutoTranslator-<version>.hoveryextension.zip`) translates the text under the pointer with an OpenAI-compatible service of your choice. After installing it, click its gear button and enter the service's Base URL, API key, and model. See [its README](Examples/AutoTranslator/README.md) for common services.

To install one, extract it, open **Extensions…**, and copy the `.hoveryextension` directory into the extensions folder.

Extensions are ordinary isolated web pages with ESM entry points, and can declare settings that Hovery lets you edit. See [WebExtensions.md](Docs/WebExtensions.md) and the examples under [`Examples`](Examples).

## Build

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [just](https://github.com/casey/just), then run:

```sh
just test
just build-all Release
```

Generated projects and all build products live outside version control. Common development, installation, and cleanup commands are listed by `just`.

## License

Copyright © 2026 waterlens.

Licensed under the [Apache License 2.0](LICENSE).
