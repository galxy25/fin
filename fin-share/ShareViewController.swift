import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// fin-share's principal class (NSExtensionPrincipalClass): hosts the SwiftUI
/// sheet and ends the request when it sends or cancels.
#if os(iOS)
final class ShareViewController: UIViewController {
    private lazy var model = ShareModel { [weak self] in self?.finish() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareSheetView(model: model) { [weak self] in self?.cancel() })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = Self.providers(extensionContext)
        Task { await model.load(providers) }
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    static func providers(_ context: NSExtensionContext?) -> [NSItemProvider] {
        (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }
}
#else
final class ShareViewController: NSViewController {
    private lazy var model = ShareModel { [weak self] in self?.finish() }

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let host = NSHostingView(rootView: ShareSheetView(model: model) { [weak self] in self?.cancel() })
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
        view = host
        preferredContentSize = host.frame.size
        let providers = Self.providers(extensionContext)
        Task { await model.load(providers) }
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    static func providers(_ context: NSExtensionContext?) -> [NSItemProvider] {
        (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }
}
#endif
