import SwiftUI
import WidgetKit

/// fin-widgets — the WidgetKit extension that renders Fin's Live Activity
/// (docs/CARPLAY-IMESSAGE-DESIGN.md §3.4, Phase 2). Today it holds exactly one
/// thing: the attention tile. There are no home-screen widgets.
///
/// The extension's deployment target is iOS 18.0 (project.yml), one
/// generation above the app's 17.0, on purpose: `supplementalActivityFamilies`
/// and `ActivityFamily.small` are `@available(iOS 18.0, *)` in WidgetKit
/// (verified in the iOS 26.5 SDK), `WidgetConfigurationBuilder` has no
/// limited-availability builder, and `WidgetBundleBuilder` rejects an
/// `#available` / `#unavailable` pair — so the honest shape is one widget
/// with the family opted in unconditionally, and an iOS 17 device simply has
/// no tile (the app's controller checks the same floor before starting one).
/// iOS 26 is what places the `.small` family on the CarPlay Dashboard.
@main
struct FinWidgetBundle: WidgetBundle {
    var body: some Widget {
        FinLiveActivity()
    }
}
