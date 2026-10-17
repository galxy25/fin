import SwiftUI

struct ThemeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeBackgroundHex") private var backgroundHex = AppTheme.default.backgroundHex
    @AppStorage("themeForegroundHex") private var foregroundHex = AppTheme.default.foregroundHex
    @AppStorage("themeFontSize") private var fontSize = AppTheme.defaultFontSize

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
                ColorPicker("Background", selection: backgroundBinding, supportsOpacity: false)
                ColorPicker("Text", selection: foregroundBinding, supportsOpacity: false)
                Stepper(value: $fontSize, in: AppTheme.fontSizeRange, step: 1) {
                    LabeledContent("Font Size", value: "\(Int(fontSize)) pt")
                }
                Text("The quick brown fox $ ls -la")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Color(hex: foregroundHex))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(hex: backgroundHex))
                    .accessibilityIdentifier("themeFontPreview")
                Button("Reset to Classic Green on Black") {
                    backgroundHex = AppTheme.default.backgroundHex
                    foregroundHex = AppTheme.default.foregroundHex
                    fontSize = AppTheme.defaultFontSize
                }
            }
            .navigationTitle("Theme")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
