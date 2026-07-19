#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)

project_version() {
    /usr/bin/awk '
        $1 == "MARKETING_VERSION:" {
            print $2
            found = 1
            exit
        }
        END {
            if (!found) exit 1
        }
    ' "$PROJECT_ROOT/project.yml"
}

if [ "${1:-}" = "--project-version" ]; then
    project_version
    exit 0
fi

VERSION=${1:-$(project_version)}
BUILD_NUMBER=${2:-1}
SIGNING_MODE=${HOVERY_RELEASE_SIGNING:-adhoc}
NOTARIZE=${HOVERY_RELEASE_NOTARIZE:-0}

case "$VERSION" in
    *[!0-9.]* | .* | *. | *..*)
        printf '%s\n' "Version must contain three numeric components, for example 0.1.0." >&2
        exit 1
        ;;
esac
if [ "$(printf '%s' "$VERSION" | /usr/bin/awk -F. '{print NF}')" -ne 3 ]; then
    printf '%s\n' "Version must contain three numeric components, for example 0.1.0." >&2
    exit 1
fi
case "$BUILD_NUMBER" in
    '' | *[!0-9]*)
        printf '%s\n' "Build number must be a positive integer." >&2
        exit 1
        ;;
esac
if [ "$BUILD_NUMBER" -lt 1 ]; then
    printf '%s\n' "Build number must be a positive integer." >&2
    exit 1
fi
case "$SIGNING_MODE" in
    adhoc | developer-id | unsigned) ;;
    *)
        printf '%s\n' "HOVERY_RELEASE_SIGNING must be adhoc, developer-id, or unsigned." >&2
        exit 1
        ;;
esac
case "$NOTARIZE" in
    0 | 1) ;;
    *)
        printf '%s\n' "HOVERY_RELEASE_NOTARIZE must be 0 or 1." >&2
        exit 1
        ;;
esac
if [ "$NOTARIZE" -eq 1 ] && [ "$SIGNING_MODE" != "developer-id" ]; then
    printf '%s\n' "Notarization requires Developer ID signing." >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    printf '%s\n' "xcodegen is required." >&2
    exit 1
fi

ARTIFACT_ROOT="$PROJECT_ROOT/.build/release"
DERIVED_ROOT="$PROJECT_ROOT/.build/release-derived"
ARTIFACT_DIRECTORY="$ARTIFACT_ROOT/artifacts"
STAGING_DIRECTORY="$ARTIFACT_ROOT/staging"
DMG_SOURCE_DIRECTORY="$STAGING_DIRECTORY/dmg"
EXTENSION_SOURCE_DIRECTORY="$PROJECT_ROOT/Examples/AppleDictionary/Extension/AppleDictionary.hoveryextension"
APP_DERIVED_DATA="$DERIVED_ROOT/Hovery"
DICTIONARY_DERIVED_DATA="$DERIVED_ROOT/AppleDictionary"
APP_PROJECT="$PROJECT_ROOT/Hovery.xcodeproj"
DICTIONARY_PROJECT="$PROJECT_ROOT/Examples/AppleDictionary/AppleDictionaryExtension.xcodeproj"
APP_PRODUCT="$APP_DERIVED_DATA/Build/Products/Release/Hovery.app"
HELPER_PRODUCT="$DICTIONARY_DERIVED_DATA/Build/Products/Release/AppleDictionaryHelper"
STAGED_APP="$STAGING_DIRECTORY/Hovery.app"
STAGED_EXTENSION="$STAGING_DIRECTORY/AppleDictionary.hoveryextension"
DMG_PATH="$ARTIFACT_DIRECTORY/Hovery-$VERSION.dmg"
EXTENSION_ARCHIVE="$ARTIFACT_DIRECTORY/AppleDictionary-$VERSION.hoveryextension.zip"

case "$ARTIFACT_ROOT" in
    "$PROJECT_ROOT"/.build/*) ;;
    *)
        printf '%s\n' "Refusing to replace an artifact directory outside .build." >&2
        exit 1
        ;;
esac
/bin/rm -rf "$ARTIFACT_ROOT" "$DERIVED_ROOT"
/bin/mkdir -p "$ARTIFACT_DIRECTORY" "$STAGING_DIRECTORY" "$DMG_SOURCE_DIRECTORY"

xcodegen generate --spec "$PROJECT_ROOT/project.yml"
xcodegen generate --spec "$PROJECT_ROOT/Examples/AppleDictionary/project.yml"

configure_signing() {
    case "$SIGNING_MODE" in
        developer-id)
            : "${HOVERY_CODE_SIGN_IDENTITY:?HOVERY_CODE_SIGN_IDENTITY is required for Developer ID releases}"
            : "${HOVERY_DEVELOPMENT_TEAM:?HOVERY_DEVELOPMENT_TEAM is required for Developer ID releases}"
            printf '%s\n' \
                "CODE_SIGNING_ALLOWED=YES" \
                "CODE_SIGN_STYLE=Manual" \
                "CODE_SIGN_IDENTITY=$HOVERY_CODE_SIGN_IDENTITY" \
                "DEVELOPMENT_TEAM=$HOVERY_DEVELOPMENT_TEAM" \
                "OTHER_CODE_SIGN_FLAGS=--timestamp"
            ;;
        adhoc)
            printf '%s\n' \
                "CODE_SIGNING_ALLOWED=YES" \
                "CODE_SIGN_STYLE=Manual" \
                "CODE_SIGN_IDENTITY=-" \
                "DEVELOPMENT_TEAM="
            ;;
        unsigned)
            printf '%s\n' "CODE_SIGNING_ALLOWED=NO"
            ;;
    esac
}

SIGNING_ARGUMENTS_FILE="$ARTIFACT_ROOT/signing-arguments"
configure_signing > "$SIGNING_ARGUMENTS_FILE"

set -- /usr/bin/xcodebuild \
    -project "$APP_PROJECT" \
    -scheme Hovery \
    -configuration Release \
    -destination platform=macOS \
    -derivedDataPath "$APP_DERIVED_DATA" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ONLY_ACTIVE_ARCH=NO
while IFS= read -r argument; do
    set -- "$@" "$argument"
done < "$SIGNING_ARGUMENTS_FILE"
"$@" build

set -- /usr/bin/xcodebuild \
    -project "$DICTIONARY_PROJECT" \
    -scheme AppleDictionaryHelper \
    -configuration Release \
    -destination platform=macOS \
    -derivedDataPath "$DICTIONARY_DERIVED_DATA" \
    ONLY_ACTIVE_ARCH=NO
while IFS= read -r argument; do
    set -- "$@" "$argument"
done < "$SIGNING_ARGUMENTS_FILE"
"$@" build

if [ ! -d "$APP_PRODUCT" ] || [ ! -x "$HELPER_PRODUCT" ]; then
    printf '%s\n' "Release build products are missing." >&2
    exit 1
fi

/usr/bin/ditto "$APP_PRODUCT" "$STAGED_APP"
/usr/bin/ditto "$EXTENSION_SOURCE_DIRECTORY" "$STAGED_EXTENSION"
/bin/mkdir -p "$STAGED_EXTENSION/native"
/bin/rm -f "$STAGED_EXTENSION/native/AppleDictionaryHelper"
/usr/bin/ditto "$HELPER_PRODUCT" "$STAGED_EXTENSION/native/AppleDictionaryHelper"
/bin/chmod 755 "$STAGED_EXTENSION/native/AppleDictionaryHelper"

if [ "$SIGNING_MODE" != "unsigned" ]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
    /usr/bin/codesign --verify --strict --verbose=2 "$STAGED_EXTENSION/native/AppleDictionaryHelper"
fi

(
    cd "$STAGING_DIRECTORY"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
        AppleDictionary.hoveryextension \
        "$EXTENSION_ARCHIVE"
)

/usr/bin/ditto "$STAGED_APP" "$DMG_SOURCE_DIRECTORY/Hovery.app"
/bin/ln -s /Applications "$DMG_SOURCE_DIRECTORY/Applications"
/usr/bin/ditto "$PROJECT_ROOT/LICENSE" "$DMG_SOURCE_DIRECTORY/LICENSE"
/usr/bin/ditto "$PROJECT_ROOT/NOTICE" "$DMG_SOURCE_DIRECTORY/NOTICE"
/usr/bin/hdiutil create \
    -volname "Hovery $VERSION" \
    -srcfolder "$DMG_SOURCE_DIRECTORY" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

if [ "$SIGNING_MODE" = "developer-id" ]; then
    /usr/bin/codesign --force --sign "$HOVERY_CODE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi
/usr/bin/hdiutil verify "$DMG_PATH"

NOTARIZED=no
if [ "$NOTARIZE" -eq 1 ]; then
    : "${HOVERY_NOTARY_KEY_PATH:?HOVERY_NOTARY_KEY_PATH is required for notarization}"
    : "${HOVERY_NOTARY_KEY_ID:?HOVERY_NOTARY_KEY_ID is required for notarization}"
    : "${HOVERY_NOTARY_ISSUER_ID:?HOVERY_NOTARY_ISSUER_ID is required for notarization}"

    /usr/bin/xcrun notarytool submit "$DMG_PATH" \
        --key "$HOVERY_NOTARY_KEY_PATH" \
        --key-id "$HOVERY_NOTARY_KEY_ID" \
        --issuer "$HOVERY_NOTARY_ISSUER_ID" \
        --wait
    /usr/bin/xcrun stapler staple "$DMG_PATH"
    /usr/bin/xcrun stapler validate "$DMG_PATH"

    # ZIP archives can be notarized but cannot carry a stapled ticket. The
    # helper's ticket remains available to Gatekeeper online.
    /usr/bin/xcrun notarytool submit "$EXTENSION_ARCHIVE" \
        --key "$HOVERY_NOTARY_KEY_PATH" \
        --key-id "$HOVERY_NOTARY_KEY_ID" \
        --issuer "$HOVERY_NOTARY_ISSUER_ID" \
        --wait
    NOTARIZED=yes
fi

case "$SIGNING_MODE:$NOTARIZED" in
    developer-id:yes) DISTRIBUTION="Developer ID signed and notarized" ;;
    developer-id:no) DISTRIBUTION="Developer ID signed, not notarized" ;;
    adhoc:*) DISTRIBUTION="Ad-hoc signed, not notarized (prerelease)" ;;
    unsigned:*) DISTRIBUTION="Unsigned, not notarized (development artifact)" ;;
esac
/usr/bin/printf '%s\n' \
    "Hovery $VERSION" \
    "Build $BUILD_NUMBER" \
    "Signing: $SIGNING_MODE" \
    "Notarized: $NOTARIZED" \
    "Distribution: $DISTRIBUTION" \
    > "$ARTIFACT_DIRECTORY/RELEASE-INFO.txt"

TEMPORARY_DIRECTORY=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hovery-release.XXXXXX")
MOUNT_DIRECTORY="$TEMPORARY_DIRECTORY/mount"
EXTRACT_DIRECTORY="$TEMPORARY_DIRECTORY/extensions"
DMG_ATTACHED=0

cleanup() {
    if [ "$DMG_ATTACHED" -eq 1 ]; then
        /usr/bin/hdiutil detach "$MOUNT_DIRECTORY" -quiet || true
    fi
    /bin/rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT HUP INT TERM

/bin/mkdir -p "$MOUNT_DIRECTORY" "$EXTRACT_DIRECTORY"
/usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIRECTORY" -quiet
DMG_ATTACHED=1

MOUNTED_APP="$MOUNT_DIRECTORY/Hovery.app"
if [ ! -d "$MOUNTED_APP" ] || [ ! -L "$MOUNT_DIRECTORY/Applications" ]; then
    printf '%s\n' "The DMG does not contain Hovery.app and its Applications link." >&2
    exit 1
fi
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")
if [ "$APP_VERSION" != "$VERSION" ]; then
    printf '%s\n' "App version $APP_VERSION does not match release version $VERSION." >&2
    exit 1
fi
APP_ARCHITECTURES=$(/usr/bin/lipo -archs "$MOUNTED_APP/Contents/MacOS/Hovery")
case " $APP_ARCHITECTURES " in
    *" arm64 "*) ;;
    *) printf '%s\n' "Hovery is missing arm64." >&2; exit 1 ;;
esac
case " $APP_ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) printf '%s\n' "Hovery is missing x86_64." >&2; exit 1 ;;
esac
if [ "$SIGNING_MODE" != "unsigned" ]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"
fi

/usr/bin/ditto -x -k "$EXTENSION_ARCHIVE" "$EXTRACT_DIRECTORY"
EXTRACTED_EXTENSION="$EXTRACT_DIRECTORY/AppleDictionary.hoveryextension"
EXTRACTED_HELPER="$EXTRACTED_EXTENSION/native/AppleDictionaryHelper"
if [ ! -f "$EXTRACTED_EXTENSION/manifest.toml" ] || [ ! -x "$EXTRACTED_HELPER" ]; then
    printf '%s\n' "The Apple Dictionary extension archive is incomplete." >&2
    exit 1
fi
HELPER_ARCHITECTURES=$(/usr/bin/lipo -archs "$EXTRACTED_HELPER")
case " $HELPER_ARCHITECTURES " in
    *" arm64 "*) ;;
    *) printf '%s\n' "AppleDictionaryHelper is missing arm64." >&2; exit 1 ;;
esac
case " $HELPER_ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) printf '%s\n' "AppleDictionaryHelper is missing x86_64." >&2; exit 1 ;;
esac
if [ "$SIGNING_MODE" != "unsigned" ]; then
    /usr/bin/codesign --verify --strict --verbose=2 "$EXTRACTED_HELPER"
    APP_TEAM=$(/usr/bin/codesign -dv --verbose=4 "$MOUNTED_APP" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
    HELPER_TEAM=$(/usr/bin/codesign -dv --verbose=4 "$EXTRACTED_HELPER" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
    if [ "$APP_TEAM" != "$HELPER_TEAM" ]; then
        printf '%s\n' "App and dictionary helper signatures use different teams." >&2
        exit 1
    fi
fi
if [ "$NOTARIZED" = yes ]; then
    /usr/bin/xcrun stapler validate "$DMG_PATH"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

(
    cd "$ARTIFACT_DIRECTORY"
    /usr/bin/shasum -a 256 \
        "Hovery-$VERSION.dmg" \
        "AppleDictionary-$VERSION.hoveryextension.zip" \
        RELEASE-INFO.txt \
        > SHA256SUMS
)

printf '%s\n' "Created release artifacts:"
printf '  %s\n' "$DMG_PATH" "$EXTENSION_ARCHIVE"
