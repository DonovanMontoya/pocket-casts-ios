import UIKit

/// A small "Skipped ad" pill with Undo. It sits just above the timeline in the
/// full player, or just above the mini player, so it follows the player wherever
/// the layout puts it instead of spanning the window.
@MainActor
final class AdSkipNoticeView: UIView {
    private static weak var current: AdSkipNoticeView?
    private static let visibleDuration: TimeInterval = 4

    private let undo: () -> Void

    static func show(undo: @escaping () -> Void) {
        guard let miniPlayer = (UIApplication.shared.delegate as? AppDelegate)?.miniPlayer() else { return }
        let host: UIView?
        let anchor: UIView?
        if miniPlayer.playerOpenState == .open, let item = miniPlayer.fullScreenPlayer?.nowPlayingItem, item.isViewLoaded {
            host = item.view
            anchor = item.timeSliderHolderView
        } else {
            host = miniPlayer.view.superview
            anchor = miniPlayer.mainView
        }
        guard let host, let anchor, anchor.window != nil, !miniPlayer.view.isHidden else { return }

        current?.removeFromSuperview()
        let notice = AdSkipNoticeView(undo: undo)
        host.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: anchor.centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -8),
            notice.widthAnchor.constraint(lessThanOrEqualTo: anchor.widthAnchor)
        ])
        current = notice
        notice.present()
        UIAccessibility.post(notification: .announcement, argument: "Skipped ad")
    }

    private init(undo: @escaping () -> Void) {
        self.undo = undo
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        addSubview(background)

        let label = UILabel()
        label.text = "Skipped ad"
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label

        var config = UIButton.Configuration.plain()
        config.title = "Undo"
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 4)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
            return attributes
        }
        let undoButton = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.undo()
            self?.dismiss()
        })

        let stack = UIStackView(arrangedSubviews: [label, undoButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .center
        stack.spacing = 4
        background.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -6)
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.layer.cornerRadius = bounds.height / 2
    }

    private func present() {
        alpha = 0
        if !UIAccessibility.isReduceMotionEnabled { transform = CGAffineTransform(translationX: 0, y: 6) }
        UIView.animate(withDuration: 0.2) {
            self.alpha = 1
            self.transform = .identity
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration) { [weak self] in
            self?.dismiss()
        }
    }

    private func dismiss() {
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}
