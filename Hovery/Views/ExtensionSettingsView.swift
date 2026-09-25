import SwiftUI

struct ExtensionSettingsView: View {
    private enum Layout {
        // Fits inside the Extensions window, which presents this view as a sheet.
        static let width: CGFloat = 500
        static let height: CGFloat = 480
        static let stackedFieldSpacing: CGFloat = 6
        static let textLineLimit = 3...8
    }

    let form: WebExtensionCoordinator.SettingsForm
    let save: ([String: WebExtensionSettingValue]) throws -> Void
    let dismiss: () -> Void
    @State private var values: [String: WebExtensionSettingValue]
    @State private var saveError: String?

    init(
        form: WebExtensionCoordinator.SettingsForm,
        save: @escaping ([String: WebExtensionSettingValue]) throws -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.form = form
        self.save = save
        self.dismiss = dismiss
        _values = State(initialValue: form.values)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(form.name) Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            Form {
                ForEach(form.descriptors) { setting in
                    field(for: setting)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Restore Defaults", action: restoreDefaults)
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hasInvalidURL)
            }
            .padding()
        }
        .frame(width: Layout.width, height: Layout.height)
        .alert(
            "Couldn’t Save Settings",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            ),
            presenting: saveError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private var hasInvalidURL: Bool {
        form.descriptors.contains { setting in
            setting.type == .url && urlIsInvalid(for: setting)
        }
    }

    @ViewBuilder
    private func field(for setting: WebExtensionSettingDescriptor) -> some View {
        switch setting.type {
        case .string, .url:
            TextField(text: text(setting), prompt: prompt(setting)) {
                label(for: setting)
            }
        case .secret:
            SecureField(text: text(setting), prompt: prompt(setting)) {
                label(for: setting)
            }
        case .text:
            // Multi-line text is easier to read and edit at full width below its label.
            VStack(alignment: .leading, spacing: Layout.stackedFieldSpacing) {
                Text(setting.title)
                if let subtitle = subtitle(for: setting) {
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                TextField(setting.title, text: text(setting), prompt: prompt(setting), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(Layout.textLineLimit)
                    .textFieldStyle(.roundedBorder)
            }
        case .boolean:
            Toggle(isOn: flag(setting)) {
                label(for: setting)
            }
        case .number:
            TextField(value: number(setting), format: .number, prompt: prompt(setting)) {
                label(for: setting)
            }
        case .choice:
            Picker(selection: text(setting)) {
                ForEach(setting.options) { option in
                    Text(option.title).tag(option.value)
                }
            } label: {
                label(for: setting)
            }
        }
    }

    @ViewBuilder
    private func label(for setting: WebExtensionSettingDescriptor) -> some View {
        Text(setting.title)
        if let subtitle = subtitle(for: setting) {
            subtitle
        }
    }

    /// A problem with the current value, in red, followed by the manifest's description, if any.
    private func subtitle(for setting: WebExtensionSettingDescriptor) -> Text? {
        let problem = problem(for: setting).map { Text($0).foregroundStyle(.red) }
        let detail = setting.detail.map { Text($0) }
        switch (problem, detail) {
        case (let problem?, let detail?):
            return Text(
                "\(problem) \(detail)",
                comment: "A problem with a setting's value, then the setting's description."
            )
        case (let problem?, nil):
            return problem
        case (nil, let detail?):
            return detail
        case (nil, nil):
            return nil
        }
    }

    private func prompt(_ setting: WebExtensionSettingDescriptor) -> Text? {
        setting.placeholder.map(Text.init)
    }

    private func value(for setting: WebExtensionSettingDescriptor) -> WebExtensionSettingValue {
        values[setting.key] ?? setting.defaultValue
    }

    private func urlIsInvalid(for setting: WebExtensionSettingDescriptor) -> Bool {
        let value = value(for: setting)
        let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty && setting.networkOrigin(for: value) == nil
    }

    private func problem(for setting: WebExtensionSettingDescriptor) -> String? {
        if setting.type == .url, urlIsInvalid(for: setting) {
            return String(localized: "Enter a full URL, such as https://api.example.com/v1.")
        }
        if setting.isRequired, !setting.isSatisfied(by: setting.normalized(value(for: setting))) {
            return String(localized: "Required.")
        }
        return nil
    }

    private func text(_ setting: WebExtensionSettingDescriptor) -> Binding<String> {
        Binding(
            get: { value(for: setting).stringValue ?? "" },
            set: { values[setting.key] = .string($0) }
        )
    }

    private func flag(_ setting: WebExtensionSettingDescriptor) -> Binding<Bool> {
        Binding(
            get: { value(for: setting).booleanValue ?? false },
            set: { values[setting.key] = .boolean($0) }
        )
    }

    private func number(_ setting: WebExtensionSettingDescriptor) -> Binding<Double> {
        Binding(
            get: { value(for: setting).numberValue ?? 0 },
            set: { values[setting.key] = .number($0) }
        )
    }

    private func restoreDefaults() {
        values = WebExtensionSettingDescriptor.restoringDefaults(for: form.descriptors, values: values)
    }

    private func commit() {
        do {
            try save(values)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
