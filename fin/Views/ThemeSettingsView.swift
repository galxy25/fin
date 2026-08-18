import SwiftUI

struct ThemeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("themeBackgroundHex") private var backgroundHex = AppTheme.default.backgroundHex
    @AppStorage("themeForegroundHex") private var foregroundHex = AppTheme.default.foregroundHex

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
                Button("Reset to Classic Green on Black") {
                    backgroundHex = AppTheme.default.backgroundHex
                    foregroundHex = AppTheme.default.foregroundHex
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
