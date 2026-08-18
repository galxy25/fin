#if os(iOS) || os(visionOS)
import UIKit

final class KeyboardAccessoryRow: UIView {
    var onSendBytes: (([UInt8]) -> Void)?
    /// Toggles Ctrl-armed state and returns the new state, so the button can restyle itself.
    var onToggleCtrl: (() -> Bool)?

    private struct Key {
        let title: String
        let bytes: [UInt8]
    }

    private let ctrlButton = UIButton(type: .system)

    private let keys: [Key] = [
        Key(title: "Esc", bytes: [0x1B]),
        Key(title: "Tab", bytes: [0x09]),
        Key(title: "\u{2190}", bytes: [0x1B, 0x5B, 0x44]),
        Key(title: "\u{2193}", bytes: [0x1B, 0x5B, 0x42]),
        Key(title: "\u{2191}", bytes: [0x1B, 0x5B, 0x41]),
        Key(title: "\u{2192}", bytes: [0x1B, 0x5B, 0x43]),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor.black.withAlphaComponent(0.95)
        autoresizingMask = [.flexibleWidth]

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40),
        ])

        style(ctrlButton, title: "Ctrl")
        ctrlButton.addAction(UIAction { [weak self] _ in
            self?.toggleCtrl()
        }, for: .touchUpInside)
        stack.addArrangedSubview(ctrlButton)

        for key in keys {
            let button = UIButton(type: .system)
            style(button, title: key.title)
            button.addAction(UIAction { [weak self] _ in
                self?.onSendBytes?(key.bytes)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    private func style(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
    }

    private func toggleCtrl() {
        let active = onToggleCtrl?() ?? false
        ctrlButton.backgroundColor = active ? UIColor.white.withAlphaComponent(0.3) : .clear
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 40)
    }
}
#endif
