import SwiftUI

struct ThemeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let scope: ThemeScope
    @AppStorage private var backgroundHex: String
    @AppStorage private var foregroundHex: String
    @AppStorage private var fontSize: Double
    @AppStorage private var syncEnabled: Bool

    init(scope: ThemeScope = .terminal) {
        self.scope = scope
        _backgroundHex = AppStorage(wrappedValue: scope.defaultBackgroundHex, scope.backgroundKey)
        _foregroundHex = AppStorage(wrappedValue: scope.defaultForegroundHex, scope.foregroundKey)
        _fontSize = AppStorage(wrappedValue: scope.defaultFontSize, scope.fontSizeKey)
        _syncEnabled = AppStorage(wrappedValue: false, scope.syncEnabledKey)
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { Color(hex: backgroundHex) },
            set: { backgroundHex = $0.toHexString() }
        )
    }

    private var foregroundBinding: Binding<Color> {
        Binding(
            get: { Color(hex: foregroundHex) },
            set: { foregroundHex = $0.toHexString() }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Colors") {
                    ColorPicker("Background", selection: backgroundBinding, supportsOpacity: false)
                    ColorPicker("Text", selection: foregroundBinding, supportsOpacity: false)
                    Button("Reset to Classic Green on Black") {
                        backgroundHex = AppTheme.default.backgroundHex
                        foregroundHex = AppTheme.default.foregroundHex
                    }
                }
                Section("Font Size") {
                    Stepper(value: $fontSize, in: AppTheme.fontSizeRange, step: 1) {
                        LabeledContent("Size", value: "\(Int(fontSize)) pt")
                    }
                    Text(scope == .terminal ? "The quick brown fox $ ls -la" : "The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: fontSize, design: scope == .terminal ? .monospaced : .default))
                        .foregroundStyle(Color(hex: foregroundHex))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(hex: backgroundHex))
                        .accessibilityIdentifier("themeFontPreview")
                    Button("Reset to Default Size") {
                        fontSize = scope.defaultFontSize
                    }
                    .disabled(fontSize == scope.defaultFontSize)
                }
                Section {
                    Toggle("Sync Across Devices", isOn: $syncEnabled)
                } footer: {
                    Text(syncEnabled
                        ? "This theme follows your iCloud account. Turning sync on adopts the theme your other devices share; changes here reach them."
                        : "This device uses its own theme. Turn on to share it through iCloud with your other devices that have sync on.")
                }
            }
            .navigationTitle(scope.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
