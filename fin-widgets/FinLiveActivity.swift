import ActivityKit
import SwiftUI
import WidgetKit

/// The attention tile's presentations: Lock Screen banner, Dynamic Island
/// (compact / minimal / expanded), and the `.small` supplemental family that
/// CarPlay Dashboard shows on iOS 26+ (and the Watch Smart Stack from 18).
///
/// The views themselves live in fin/LiveActivity/FinActivityViews.swift,
/// compiled into the app too so they can be render-tested without a widget
/// host. This file is only the WidgetKit wiring around them.
struct FinLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FinActivityAttributes.self) { context in
            FinActivityPresentation(agentName: context.attributes.agentName, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FinActivityGlyph(state: context.state)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    FinActivityExpandedCenter(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FinActivityCompactTrailing(state: context.state)
                        .padding(.trailing, 4)
                }
            } compactLeading: {
                FinActivityGlyph(state: context.state)
            } compactTrailing: {
                FinActivityCompactTrailing(state: context.state)
            } minimal: {
                FinActivityGlyph(state: context.state)
            }
        }
        // `supplementalActivityFamilies` / `ActivityFamily.small` are
        // `@available(iOS 18.0, *)` (WidgetKit, iOS 26.5 SDK) — the extension's
        // floor. iOS 26 is what starts placing this family on the CarPlay
        // Dashboard (CarPlay Developer Guide pp. 3, 9, 10; WWDC25 session 216).
        .supplementalActivityFamilies([.small])
    }
}

/// Picks the layout by family: `.small` (CarPlay Dashboard / Smart Stack)
/// gets the one-line tile, everything else the Lock Screen banner.
struct FinActivityPresentation: View {
    @Environment(\.activityFamily) private var family
    let agentName: String
    let state: FinActivityAttributes.ContentState

    var body: some View {
        switch family {
        case .small:
            FinActivitySmallView(state: state)
        default:
            FinActivityLockScreenView(agentName: agentName, state: state)
        }
    }
}
