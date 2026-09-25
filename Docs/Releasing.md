# Releasing Hovery

The project version is the `MARKETING_VERSION` value in `project.yml`. The app's internal build number is supplied by CI as the GitHub Actions run number. AppKit's About panel deliberately displays only the marketing version; the build number remains available in the app bundle for diagnostics.

## Artifacts

Every release build produces:

- `Hovery-<version>.dmg`, presenting the universal Hovery app in a standard drag-to-Applications installer window. The Apache license and NOTICE remain bundled inside the app.
- `AppleDictionary-<version>.hoveryextension.zip`, containing the universal native helper and web extension resources.
- `AutoTranslator-<version>.hoveryextension.zip`, containing the Web-only Auto Translator extension.
- `SHA256SUMS` and `RELEASE-INFO.txt`.

`Scripts/package-release.sh` owns the complete transaction: it builds, signs, packages, optionally notarizes, mounts and verifies the DMG, extracts and verifies the extensions, checks both architectures and signing teams, and writes checksums. A partially successful sequence cannot be mistaken for a verified release. The Auto Translator archive contains no executable code and is not submitted for notarization.

## Developer ID secrets

A public, Gatekeeper-ready release requires Apple Developer Program membership, a **Developer ID Application** certificate, and an App Store Connect API key with notarization access. Add these repository or `release` environment secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `MACOS_SIGNING_IDENTITY` | Full identity, such as `Developer ID Application: Example (TEAMID)` |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `APP_STORE_CONNECT_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key |
| `APP_STORE_CONNECT_KEY_ID` | API key identifier |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect issuer identifier |

On macOS, files can be encoded without assuming GNU command-line options:

```sh
base64 -i DeveloperID.p12 | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

The workflow imports the certificate into an ephemeral keychain. It signs the app, dictionary helper, and DMG with the same identity; submits the DMG and extension archive through `notarytool`; staples the DMG; and validates the final artifacts before publishing.

If the Developer ID secrets are absent, a tag still creates an ad-hoc-signed GitHub prerelease so packaging can be exercised. It is visibly marked as not notarized and is never presented as the latest stable Gatekeeper-ready release.

## Local packaging check

An ad-hoc-signed package can be built and fully inspected without distribution credentials:

```sh
version=$(Scripts/package-release.sh --project-version)
HOVERY_RELEASE_SIGNING=adhoc Scripts/package-release.sh "$version" 1
```

Artifacts are written to `.build/release/artifacts`.

## Publish

Update `MARKETING_VERSION`, commit the change, and create a matching annotated tag:

```sh
git tag -a v0.1.0 -m "Hovery 0.1.0"
git push origin main
git push origin v0.1.0
```

Tags must use `vMAJOR.MINOR.PATCH` and must match the project version. The Release workflow refuses mismatched tags.
