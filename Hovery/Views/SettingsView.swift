import AppKit
import Combine
import SwiftUI

struct SettingsView: View {
    private enum Layout {
        static let windowWidth: CGFloat = 540
        static let windowHeight: CGFloat = 680
        static let fieldWidth: CGFloat = 90
        static let modifierFieldWidth: CGFloat = 180
        static let fieldSpacing: CGFloat = 6
        static let errorLineLimit = 3
        static let minimumFractionDigits = 0
        static let maximumFractionDigits = 3
    }

    private enum Unit {
        case points
        case pixels
        case seconds
        case multiplier
        case lineHeights

        var symbol: String {
            switch self {
            case .points: String(localized: "pt", comment: "Abbreviation for points, shown after a number field.")
            case .pixels: String(localized: "px", comment: "Abbreviation for pixels, shown after a number field.")
            case .seconds: String(localized: "s", comment: "Abbreviation for seconds, shown after a number field.")
            case .multiplier: "×"
            case .lineHeights:
                String(
                    localized: "× line",
                    comment: "Shown after a number field whose value is a multiple of the text's line height."
                )
            }
        }
    }

    @ObservedObject var settings: HoverySettings
    @State private var draft: HoveryConfiguration
    @State private var draftBase: HoveryConfiguration
    /// Not part of the TOML configuration: macOS keeps it with the app's preferences.
    @State private var interfaceLanguage = InterfaceLanguagePreference().language
    @FocusState private var isEditingNumber: Bool

    init(settings: HoverySettings) {
        self.settings = settings
        _draft = State(initialValue: settings.configuration)
        _draftBase = State(initialValue: settings.configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsActionBar

            Divider()

            Form {
                if let loadError = settings.loadError {
                    Section("Configuration Error") {
                        Text(loadError)
                            .foregroundStyle(.red)
                            .lineLimit(Layout.errorLineLimit)
                    }
                }

                Section("General") {
                    Picker("Language", selection: $interfaceLanguage) {
                        Text("System Language").tag(InterfaceLanguage.system)
                        // Each language is named in itself, so people can find their own.
                        Text(verbatim: "English").tag(InterfaceLanguage.english)
                        Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
                    }
                    .onChange(of: interfaceLanguage) { _, language in
                        InterfaceLanguagePreference().setLanguage(language)
                    }
                    if languageNeedsRestart {
                        LabeledContent {
                            Button("Restart Now", action: HoveryRelauncher.relaunch)
                        } label: {
                            Text("Restart Hovery to use the new language.")
                        }
                    }
                }

                Section("Debugging") {
                    Toggle("Debug Overlay", isOn: binding(\.overlay.debugEnabled))
                }

                Section("Activation") {
                    LabeledContent("Required modifiers") {
                        ModifierRecorderField(
                            modifiers: binding(\.interaction.requiredModifiers)
                        )
                        .frame(width: Layout.modifierFieldWidth)
                    }
                    Text("Click the field and press a modifier combination. Press Delete to clear it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("While results are shown, hold these keys and press 1–9 to switch between extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Capture Region") {
                    doubleField(String(localized: "Last-resort fallback width"), \.capture.width, unit: .points)
                    doubleField(String(localized: "Last-resort fallback height"), \.capture.height, unit: .points)
                    doubleField(String(localized: "Maximum pixel width"), \.capture.maximumPixelWidth, unit: .pixels)
                    doubleField(String(localized: "Maximum pixel height"), \.capture.maximumPixelHeight, unit: .pixels)
                    doubleField(
                        String(localized: "Screen metadata cache"),
                        \.capture.contentCacheLifetime,
                        unit: .seconds
                    )
                }

                Section("Hover Timing") {
                    doubleField(String(localized: "Movement tolerance"), \.interaction.movementThreshold, unit: .points)
                    doubleField(String(localized: "Scan delay"), \.interaction.scanDelay, unit: .seconds)
                    doubleField(String(localized: "Refresh interval"), \.interaction.refreshInterval, unit: .seconds)
                    doubleField(String(localized: "Polling interval"), \.interaction.pollingInterval, unit: .seconds)
                    doubleField(
                        String(localized: "Result movement multiplier"),
                        \.interaction.resultMovementToleranceMultiplier,
                        unit: .multiplier
                    )
                }

                Section("Vision OCR") {
                    doubleField(String(localized: "Minimum text height"), \.recognition.minimumTextHeightFraction)
                    intField(String(localized: "Maximum candidates"), \.recognition.maximumCandidateCount)
                    doubleField(String(localized: "Fallback confidence"), \.recognition.fallbackConfidence)
                    Toggle(
                        "Detect language automatically",
                        isOn: binding(\.recognition.automaticallyDetectLanguage)
                    )
                    Toggle(
                        "Use language correction",
                        isOn: binding(\.recognition.useLanguageCorrection)
                    )
                }

                Section("Pointer Hit Testing") {
                    doubleField(
                        String(localized: "Horizontal padding scale"),
                        \.regionSelection.magneticHorizontalScale,
                        unit: .lineHeights
                    )
                    doubleField(
                        String(localized: "Vertical padding scale"),
                        \.regionSelection.magneticVerticalScale,
                        unit: .lineHeights
                    )
                    doubleField(
                        String(localized: "Minimum padding"),
                        \.regionSelection.minimumMagneticPadding,
                        unit: .points
                    )
                    doubleField(
                        String(localized: "Maximum horizontal padding"),
                        \.regionSelection.maximumHorizontalPadding,
                        unit: .points
                    )
                    doubleField(
                        String(localized: "Maximum vertical padding"),
                        \.regionSelection.maximumVerticalPadding,
                        unit: .points
                    )
                    doubleField(String(localized: "Direct-hit score"), \.regionSelection.directHitScore)
                    doubleField(String(localized: "Nearby-hit score"), \.regionSelection.nearbyHitScore)
                    doubleField(String(localized: "Confidence weight"), \.regionSelection.confidenceWeight)
                    doubleField(String(localized: "Distance penalty"), \.regionSelection.distancePenalty)
                    doubleField(String(localized: "Vertical-center penalty"), \.regionSelection.verticalCenterPenalty)
                }

                Section("Block Grouping") {
                    doubleField(
                        String(localized: "Fallback line height"),
                        \.regionSelection.fallbackLineHeight,
                        unit: .points
                    )
                    doubleField(
                        String(localized: "Minimum line height"),
                        \.regionSelection.minimumLineHeight,
                        unit: .points
                    )
                    doubleField(
                        String(localized: "Maximum vertical gap"),
                        \.regionSelection.blockMaximumVerticalGap,
                        unit: .lineHeights
                    )
                    doubleField(
                        String(localized: "Edge alignment tolerance"),
                        \.regionSelection.blockAlignmentTolerance,
                        unit: .lineHeights
                    )
                    doubleField(
                        String(localized: "Minimum horizontal overlap"),
                        \.regionSelection.blockMinimumHorizontalOverlap
                    )
                    doubleField(String(localized: "Same-column overlap"), \.regionSelection.sameColumnMinimumOverlap)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: Layout.windowWidth, height: Layout.windowHeight)
        .onReceive(settings.$configuration.dropFirst()) { configuration in
            guard draft == draftBase else { return }
            draft = configuration
            draftBase = configuration
        }
    }

    /// macOS applies the interface language when Hovery launches.
    private var languageNeedsRestart: Bool {
        InterfaceLanguagePreference.localization(for: interfaceLanguage) != Bundle.main.preferredLocalizations.first
    }

    private var settingsActionBar: some View {
        HStack {
            Button("Open TOML File") {
                NSWorkspace.shared.open(settings.configurationURL)
            }
            Button("Reload") {
                settings.reload()
                draft = settings.configuration
                draftBase = settings.configuration
            }
            Spacer()
            Button("Restore Defaults") {
                settings.reset()
                draft = settings.configuration
                draftBase = settings.configuration
            }
            Button("Apply") {
                settings.replace(with: draft)
                draft = settings.configuration
                draftBase = settings.configuration
            }
            .disabled(
                draft == draftBase || settings.configuration != draftBase
            )
        }
        .padding()
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<HoveryConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                draft[keyPath: keyPath] = newValue
            }
        )
    }

    private func doubleField(
        _ title: String,
        _ keyPath: WritableKeyPath<HoveryConfiguration, Double>,
        unit: Unit? = nil
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: Layout.fieldSpacing) {
                TextField(
                    title,
                    value: binding(keyPath),
                    format: .number.precision(
                        .fractionLength(Layout.minimumFractionDigits...Layout.maximumFractionDigits)
                    )
                )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: Layout.fieldWidth)
                    .focused($isEditingNumber)
                if let unit {
                    Text(unit.symbol)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private func intField(
        _ title: String,
        _ keyPath: WritableKeyPath<HoveryConfiguration, Int>
    ) -> some View {
        LabeledContent(title) {
            TextField(title, value: binding(keyPath), format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: Layout.fieldWidth)
                .focused($isEditingNumber)
        }
    }
}

private struct ModifierRecorderField: NSViewRepresentable {
    @Binding var modifiers: [RecognitionModifier]

    func makeCoordinator() -> Coordinator {
        Coordinator(modifiers: $modifiers)
    }

    func makeNSView(context: Context) -> ModifierRecorderControl {
        let control = ModifierRecorderControl()
        control.onChange = context.coordinator.update
        control.setModifiers(modifiers)
        return control
    }

    func updateNSView(_ control: ModifierRecorderControl, context: Context) {
        context.coordinator.modifiers = $modifiers
        control.onChange = context.coordinator.update
        control.setModifiers(modifiers)
    }

    final class Coordinator {
        var modifiers: Binding<[RecognitionModifier]>

        init(modifiers: Binding<[RecognitionModifier]>) {
            self.modifiers = modifiers
        }

        func update(_ newValue: [RecognitionModifier]) {
            modifiers.wrappedValue = newValue
        }
    }
}

private final class ModifierRecorderControl: NSTextField {
    private enum KeyCode {
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let forwardDelete: UInt16 = 117
    }

    var onChange: (([RecognitionModifier]) -> Void)?
    private var modifiers: [RecognitionModifier] = []

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        alignment = .center
        focusRingType = .exterior
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setModifiers(_ modifiers: [RecognitionModifier]) {
        let ordered = RecognitionModifier.allCases.filter(Set(modifiers).contains)
        guard self.modifiers != ordered else { return }
        self.modifiers = ordered
        updateLabel()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func flagsChanged(with event: NSEvent) {
        let recorded = Self.modifiers(from: event.modifierFlags)
        guard !recorded.isEmpty else { return }
        modifiers = recorded
        updateLabel()
        onChange?(recorded)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.delete, KeyCode.forwardDelete:
            modifiers = []
            updateLabel()
            onChange?([])
        case KeyCode.escape:
            window?.makeFirstResponder(nil)
        default:
            NSSound.beep()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        needsDisplay = true
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    private func updateLabel() {
        stringValue = modifiers.isEmpty
            ? String(localized: "None", comment: "Shown when no modifier keys are required.")
            : modifiers.map(\.symbol).joined()
        toolTip = modifiers.isEmpty
            ? String(localized: "No modifier keys are required")
            : modifiers.map(\.displayName).joined(separator: " + ")
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> [RecognitionModifier] {
        RecognitionModifier.allCases.filter { modifier in
            switch modifier {
            case .command: flags.contains(.command)
            case .option: flags.contains(.option)
            case .control: flags.contains(.control)
            case .shift: flags.contains(.shift)
            case .globe: flags.contains(.function)
            }
        }
    }
}
