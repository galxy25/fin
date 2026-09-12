import SwiftUI

/// The attention tile's SwiftUI, shared by the fin-widgets extension (which
/// renders it inside `ActivityConfiguration`) and the app (which render-tests
/// it without a widget host). Pure SwiftUI on purpose — no WidgetKit or
/// ActivityKit import — so it compiles on every platform the app does.
///
/// Every layout is glanceable and tap-free: a Live Activity on the CarPlay
/// Dashboard cannot launch a non-CarPlay app (design §3.4), so nothing here
/// is a button and nothing needs one.
enum FinActivityStyle {
    /// Status colour: amber for "needs you", the accent for "working", green
    /// for a reply, grey when idle.
    static func tint(_ status: FinActivityAttributes.ContentState.Status) -> Color {
        switch status {
        case .needsInput: return .orange
        case .working: return .accentColor
        case .answered: return .green
        case .idle: return .secondary
        }
    }
}

/// Lock Screen / banner presentation. Also the fallback for any family the
/// extension does not lay out explicitly.
struct FinActivityLockScreenView: View {
    let agentName: String
    let state: FinActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.glyph)
                .font(.title2)
                .foregroundStyle(FinActivityStyle.tint(state.status))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.headline)
                    .font(.headline)
                    .lineLimit(1)
                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agentName): \(state.headline)\(state.detail.map { ", \($0)" } ?? "")")
    }
}

/// The `.small` supplemental family — what CarPlay Dashboard (iOS 26+) and
/// the Apple Watch Smart Stack show. Glyph, one-line headline, status colour,
/// nothing else: the car screen is read at a glance from arm's length.
struct FinActivitySmallView: View {
    let state: FinActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.glyph)
                .font(.title3)
                .foregroundStyle(FinActivityStyle.tint(state.status))
            Text(state.headline)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Dynamic Island pieces: compact leading (glyph) / trailing (one word),
/// minimal (glyph), and the expanded centre (headline + detail).
struct FinActivityGlyph: View {
    let state: FinActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.glyph)
            .foregroundStyle(FinActivityStyle.tint(state.status))
    }
}

struct FinActivityCompactTrailing: View {
    let state: FinActivityAttributes.ContentState

    var body: some View {
        Text(shortLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(FinActivityStyle.tint(state.status))
    }

    var shortLabel: String {
        switch state.status {
        case .needsInput: return "Input"
        case .working: return "Working"
        case .answered: return "Replied"
        case .idle: return "Ready"
        }
    }
}

struct FinActivityExpandedCenter: View {
    let state: FinActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.headline)
                .font(.headline)
                .lineLimit(1)
            if let detail = state.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
