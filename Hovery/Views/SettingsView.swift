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

    @ObservedObject var settings: HoverySettings
    @State private var draft: HoveryConfiguration
    @FocusState private var isEditingNumber: Bool

    init(settings: HoverySettings) {
        self.settings = settings
        _draft = State(initialValue: settings.configuration)
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
                    Text("Hovery does not reserve these keys; the frontmost app continues to receive them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Capture Region") {
                    doubleField("Last-resort fallback width", \.capture.width, unit: "pt")
                    doubleField("Last-resort fallback height", \.capture.height, unit: "pt")
                    doubleField("Maximum pixel width", \.capture.maximumPixelWidth, unit: "px")
                    doubleField("Maximum pixel height", \.capture.maximumPixelHeight, unit: "px")
                    doubleField("Screen metadata cache", \.capture.contentCacheLifetime, unit: "s")
                }

                Section("Hover Timing") {
                    doubleField("Movement tolerance", \.interaction.movementThreshold, unit: "pt")
                    doubleField("Scan delay", \.interaction.scanDelay, unit: "s")
                    doubleField("Refresh interval", \.interaction.refreshInterval, unit: "s")
                    doubleField("Polling interval", \.interaction.pollingInterval, unit: "s")
                    doubleField(
                        "Result movement multiplier",
                        \.interaction.resultMovementToleranceMultiplier,
                        unit: "×"
                    )
                }

                Section("Vision OCR") {
                    doubleField("Minimum text height", \.recognition.minimumTextHeightFraction)
                    intField("Maximum candidates", \.recognition.maximumCandidateCount)
                    doubleField("Fallback confidence", \.recognition.fallbackConfidence)
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
                    doubleField("Horizontal padding scale", \.regionSelection.magneticHorizontalScale, unit: "× line")
                    doubleField("Vertical padding scale", \.regionSelection.magneticVerticalScale, unit: "× line")
                    doubleField("Minimum padding", \.regionSelection.minimumMagneticPadding, unit: "pt")
                    doubleField("Maximum horizontal padding", \.regionSelection.maximumHorizontalPadding, unit: "pt")
                    doubleField("Maximum vertical padding", \.regionSelection.maximumVerticalPadding, unit: "pt")
                    doubleField("Direct-hit score", \.regionSelection.directHitScore)
                    doubleField("Nearby-hit score", \.regionSelection.nearbyHitScore)
                    doubleField("Confidence weight", \.regionSelection.confidenceWeight)
                    doubleField("Distance penalty", \.regionSelection.distancePenalty)
                    doubleField("Vertical-center penalty", \.regionSelection.verticalCenterPenalty)
                }

                Section("Block Grouping") {
                    doubleField("Fallback line height", \.regionSelection.fallbackLineHeight, unit: "pt")
                    doubleField("Minimum line height", \.regionSelection.minimumLineHeight, unit: "pt")
                    doubleField("Maximum vertical gap", \.regionSelection.blockMaximumVerticalGap, unit: "× line")
                    doubleField("Edge alignment tolerance", \.regionSelection.blockAlignmentTolerance, unit: "× line")
                    doubleField("Minimum horizontal overlap", \.regionSelection.blockMinimumHorizontalOverlap)
                    doubleField("Same-column overlap", \.regionSelection.sameColumnMinimumOverlap)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: Layout.windowWidth, height: Layout.windowHeight)
        .onReceive(settings.$configuration.dropFirst()) { configuration in
            if !isEditingNumber {
                draft = configuration
            }
        }
    }

    private var settingsActionBar: some View {
        HStack {
            Button("Open TOML File") {
                NSWorkspace.shared.open(settings.configurationURL)
            }
            Button("Open Extensions Folder") {
                try? FileManager.default.createDirectory(
                    at: settings.extensionsDirectoryURL,
                    withIntermediateDirectories: true
                )
                NSWorkspace.shared.open(settings.extensionsDirectoryURL)
            }
            Button("Reload") {
                settings.reload()
                draft = settings.configuration
            }
            Spacer()
            Button("Restore Defaults") {
                settings.reset()
                draft = settings.configuration
            }
            Button("Apply") {
                settings.replace(with: draft)
                draft = settings.configuration
            }
            .disabled(draft == settings.configuration)
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
        unit: String? = nil
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
                    Text(unit)
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
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        stringValue = modifiers.isEmpty ? "None" : modifiers.map(\.symbol).joined()
        toolTip = modifiers.isEmpty
            ? "No modifier keys are required"
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
