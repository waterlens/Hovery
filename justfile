set shell := ["/bin/sh", "-eu", "-c"]
set script-interpreter := ["/bin/sh", "-eu"]

root := justfile_directory()
destination := "platform=macOS"
hovery_project := root / "Hovery.xcodeproj"
dictionary_directory := root / "Examples/AppleDictionary"
dictionary_project := dictionary_directory / "AppleDictionaryExtension.xcodeproj"
build_directory := root / ".build"
hovery_derived_data := build_directory / "Hovery"
dictionary_derived_data := build_directory / "AppleDictionary"
applications_directory := env_var_or_default("HOVERY_APPLICATIONS_DIR", "/Applications")
extensions_directory := env_var_or_default("HOVERY_EXTENSIONS_DIR", env_var("HOME") / "Library/Application Support/Hovery/Extensions")
hovery_install_path := applications_directory / "Hovery.app"
dictionary_extension := dictionary_directory / "Extension/AppleDictionary.hoveryextension"
streaming_echo_extension := root / "Examples/StreamingEcho/Extension/StreamingEcho.hoveryextension"
auto_translator_directory := root / "Examples/AutoTranslator"
auto_translator_extension := auto_translator_directory / "Extension/AutoTranslator.hoveryextension"
dictionary_install_path := extensions_directory / "AppleDictionary.hoveryextension"
streaming_echo_install_path := extensions_directory / "StreamingEcho.hoveryextension"
auto_translator_install_path := extensions_directory / "AutoTranslator.hoveryextension"
trash_directory := env_var("HOME") / ".Trash"
shutdown_poll_attempts := "20"
shutdown_poll_interval := "0.1"

# List available recipes.
default:
    @just --list

# Generate both Xcode projects from their project.yml files.
generate: generate-hovery generate-dictionary

# Generate only the Hovery Xcode project.
generate-hovery:
    xcodegen generate --spec "{{root}}/project.yml"

# Generate only the independent Apple Dictionary Xcode project.
generate-dictionary:
    xcodegen generate --spec "{{dictionary_directory}}/project.yml"

# Build the signed Hovery app using the configured development team.
build configuration="Debug": (build-hovery configuration)

# Build the signed Hovery app using the configured development team.
build-hovery configuration="Debug": generate-hovery
    xcodebuild -project "{{hovery_project}}" -scheme Hovery -configuration "{{configuration}}" -destination '{{destination}}' -derivedDataPath "{{hovery_derived_data}}" build

# Build Hovery without signing; useful for compilation checks and CI.
build-hovery-unsigned configuration="Debug": generate-hovery
    xcodebuild -project "{{hovery_project}}" -scheme Hovery -configuration "{{configuration}}" -destination '{{destination}}' -derivedDataPath "{{hovery_derived_data}}" CODE_SIGNING_ALLOWED=NO build

# Build and assemble the signed Apple Dictionary extension helper.
build-dictionary configuration="Debug": generate-dictionary
    xcodebuild -project "{{dictionary_project}}" -scheme AppleDictionaryExtension -configuration "{{configuration}}" -destination '{{destination}}' -derivedDataPath "{{dictionary_derived_data}}" build

# Build and assemble the Apple Dictionary helper without signing.
build-dictionary-unsigned configuration="Debug": generate-dictionary
    xcodebuild -project "{{dictionary_project}}" -scheme AppleDictionaryExtension -configuration "{{configuration}}" -destination '{{destination}}' -derivedDataPath "{{dictionary_derived_data}}" CODE_SIGNING_ALLOWED=NO build

# Run all unsigned test suites without triggering certificate access.
test: test-hovery test-dictionary test-translator

# Run the Hovery test suite without signing.
test-hovery configuration="Debug": generate-hovery
    xcodebuild -quiet -project "{{hovery_project}}" -scheme Hovery -configuration "{{configuration}}" -destination '{{destination}}' -derivedDataPath "{{hovery_derived_data}}" CODE_SIGNING_ALLOWED=NO test

# Run the Apple Dictionary helper's black-box tests without signing.
test-dictionary configuration="Debug": generate-dictionary
    xcodebuild -quiet -project "{{dictionary_project}}" -scheme AppleDictionaryHelper -configuration "{{configuration}}" -destination '{{destination}}' -derivedDataPath "{{dictionary_derived_data}}" CODE_SIGNING_ALLOWED=NO test

# Run the Auto Translator's JavaScript tests with Node.js.
test-translator:
    node --test "{{auto_translator_directory}}/Tests/translator.test.mjs"

# Build both signed products. The dictionary helper is assembled independently.
build-all configuration="Debug": (build-hovery configuration) (build-dictionary configuration)

# Build and install only Hovery.
install configuration="Release": (install-hovery configuration)

# Build, verify, and install Hovery into the applications directory.
[script]
install-hovery configuration="Release": (build-hovery configuration)
    source_app="{{hovery_derived_data}}/Build/Products/{{configuration}}/Hovery.app"
    destination_app="{{hovery_install_path}}"
    if /usr/bin/pgrep -x Hovery >/dev/null; then
        printf '%s\n' "Hovery is running. Quit it before installing." >&2
        exit 1
    fi
    /usr/bin/codesign --verify --strict "$source_app"
    team_identifier=$(/usr/bin/codesign -dv --verbose=4 "$source_app" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
    if [ -z "$team_identifier" ] || [ "$team_identifier" = "not set" ]; then
        printf '%s\n' "The Hovery build does not have a development-team signature." >&2
        exit 1
    fi
    /bin/mkdir -p "{{applications_directory}}"
    /usr/bin/ditto "$source_app" "$destination_app"
    printf '%s\n' "Installed Hovery ($team_identifier) at $destination_app"

# Build and install all example extensions.
install-extensions configuration="Release": (install-dictionary configuration) install-streaming-echo install-auto-translator

# Build, verify, and install the Apple Dictionary extension.
[script]
install-dictionary configuration="Release": (build-dictionary configuration)
    source_extension="{{dictionary_extension}}"
    source_helper="$source_extension/native/AppleDictionaryHelper"
    destination_extension="{{dictionary_install_path}}"
    installed_app="{{hovery_install_path}}"
    /usr/bin/codesign --verify --strict "$source_helper"
    helper_team=$(/usr/bin/codesign -dv --verbose=4 "$source_helper" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
    if [ -z "$helper_team" ] || [ "$helper_team" = "not set" ]; then
        printf '%s\n' "The Apple Dictionary helper does not have a development-team signature." >&2
        exit 1
    fi
    if [ -d "$installed_app" ]; then
        app_team=$(/usr/bin/codesign -dv --verbose=4 "$installed_app" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
        if [ "$helper_team" != "$app_team" ]; then
            printf '%s\n' "Signature mismatch: Hovery uses Team $app_team, but the helper uses Team $helper_team." >&2
            exit 1
        fi
    fi
    /bin/mkdir -p "{{extensions_directory}}"
    /usr/bin/ditto "$source_extension" "$destination_extension"
    printf '%s\n' "Installed Apple Dictionary ($helper_team) at $destination_extension"

# Install the Web-only Streaming Echo example extension.
[script]
install-streaming-echo:
    source_extension="{{streaming_echo_extension}}"
    destination_extension="{{streaming_echo_install_path}}"
    /bin/mkdir -p "{{extensions_directory}}"
    /usr/bin/ditto "$source_extension" "$destination_extension"
    printf '%s\n' "Installed Streaming Echo at $destination_extension"

# Install the Web-only Auto Translator example extension.
[script]
install-auto-translator:
    source_extension="{{auto_translator_extension}}"
    destination_extension="{{auto_translator_install_path}}"
    /bin/mkdir -p "{{extensions_directory}}"
    /usr/bin/ditto "$source_extension" "$destination_extension"
    printf '%s\n' "Installed Auto Translator at $destination_extension"

# Build and install Hovery together with all example extensions.
install-all configuration="Release": (install-hovery configuration) (install-extensions configuration)

# Stop all running Hovery processes, escalating to SIGKILL only after a timeout.
kill: kill-hovery

# Stop all running Hovery processes.
[script]
kill-hovery:
    if ! /usr/bin/pgrep -x Hovery >/dev/null; then
        printf '%s\n' "Hovery is not running."
        exit 0
    fi
    /usr/bin/pkill -TERM -x Hovery || true
    attempt=0
    while /usr/bin/pgrep -x Hovery >/dev/null && [ "$attempt" -lt "{{shutdown_poll_attempts}}" ]; do
        /bin/sleep "{{shutdown_poll_interval}}"
        attempt=$((attempt + 1))
    done
    if /usr/bin/pgrep -x Hovery >/dev/null; then
        /usr/bin/pkill -KILL -x Hovery || true
        printf '%s\n' "Hovery did not exit in time and was force stopped."
    else
        printf '%s\n' "Stopped Hovery."
    fi

# Move only the installed Hovery app to Trash.
uninstall: uninstall-hovery

# Stop Hovery and move the installed app to Trash.
uninstall-hovery: kill-hovery (_move-to-trash hovery_install_path)

# Move all installed example extensions to Trash.
uninstall-extensions: uninstall-dictionary uninstall-streaming-echo uninstall-auto-translator

# Move the installed Apple Dictionary extension to Trash.
uninstall-dictionary: (_move-to-trash dictionary_install_path)

# Move the installed Streaming Echo extension to Trash.
uninstall-streaming-echo: (_move-to-trash streaming_echo_install_path)

# Move the installed Auto Translator extension to Trash.
uninstall-auto-translator: (_move-to-trash auto_translator_install_path)

# Stop Hovery and move the app and installed example extensions to Trash.
uninstall-all: uninstall-hovery uninstall-extensions

[private]
[script]
_move-to-trash path:
    target="{{path}}"
    if [ ! -e "$target" ]; then
        printf '%s\n' "Not installed: $target"
        exit 0
    fi
    /bin/mkdir -p "{{trash_directory}}"
    name=$(/usr/bin/basename "$target")
    timestamp=$(/bin/date '+%Y%m%d-%H%M%S')
    destination="{{trash_directory}}/$timestamp-$$-$name"
    /bin/mv "$target" "$destination"
    printf '%s\n' "Moved to Trash: $destination"

# Ask Xcode to clean both projects without deleting source files.
clean: clean-hovery clean-dictionary

# Clean Hovery build products.
clean-hovery configuration="Debug": generate-hovery
    xcodebuild -project "{{hovery_project}}" -scheme Hovery -configuration "{{configuration}}" -derivedDataPath "{{hovery_derived_data}}" clean

# Clean Apple Dictionary build products.
clean-dictionary configuration="Debug": generate-dictionary
    xcodebuild -project "{{dictionary_project}}" -scheme AppleDictionaryHelper -configuration "{{configuration}}" -derivedDataPath "{{dictionary_derived_data}}" clean

# Open the Hovery project in Xcode.
open-hovery: generate-hovery
    open "{{hovery_project}}"

# Open the independent Apple Dictionary project in Xcode.
open-dictionary: generate-dictionary
    open "{{dictionary_project}}"
