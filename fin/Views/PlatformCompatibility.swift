import SwiftUI

extension View {
    /// No-op on macOS — there's no software keyboard there to autocapitalize,
    /// and the modifier doesn't exist on that platform at all.
    @ViewBuilder
    func autocapitalizationNeverIfAvailable() -> some View {
        #if os(iOS) || os(visionOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// No-op on macOS — there's no on-screen keyboard to hint a numeric layout for.
    @ViewBuilder
    func numberPadIfAvailable() -> some View {
        #if os(iOS) || os(visionOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
