import Combine
import PocketCastsDataModel
import UIKit

/// The ads state of one episode in a list row, shown beside the download icon:
/// the number of ads found, progress while finding them, or a warning when it failed.
/// Hidden for episodes that haven't been checked.
@MainActor
final class AdSkipBadgeView: UIStackView {
    private let icon = AdSkipIconView()
    private let label = ThemeableLabel()
    private var episodeUuid: String?
    private var podcastUuid: String?
    private var isDownloaded = false
    private var subscription: AnyCancellable?

    /// What the row reads out to VoiceOver, or nil when there's nothing to say.
    private(set) var accessibilityText: String?

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 3
        isHidden = true

        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.style = .primaryText02
        label.font = UIFont.font(ofSize: 13, scalingWith: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        addArrangedSubview(icon)
        addArrangedSubview(label)

        // objectWillChange fires before the new value lands, so read it on the next pass.
        subscription = AdSkipCoordinator.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ episode: BaseEpisode?) {
        let episode = AdSkipSettings.isSupported ? episode as? Episode : nil
        episodeUuid = episode?.uuid
        podcastUuid = episode?.podcastUuid
        isDownloaded = episode?.adAudioPath != nil
        refresh()
    }

    private func refresh() {
        let coordinator = AdSkipCoordinator.shared
        guard let episodeUuid else { return hide() }

        switch coordinator.statuses[episodeUuid] {
        case .waiting:
            apply(text: nil, alpha: 0.5, accessibility: "Waiting to find ads")
        case .finding(let progress):
            // Transcribed and now being classified: no percent to show.
            let percent = progress < 1 ? "\(Int((progress * 100).rounded()))%" : nil
            apply(text: percent, isFinding: true, accessibility: percent.map { "Finding ads, \($0)" } ?? "Checking for ads")
        case .failed:
            apply(text: nil, tint: ThemeColor.support05(), accessibility: "Couldn't find ads")
        case .found, nil:
            guard isDownloaded, let ads = coordinator.skippableAds(for: episodeUuid) else { return hide() }
            let exempt = podcastUuid.map(coordinator.isExempt(podcastUuid:)) ?? false
            let found = ads.count == 1 ? "1 ad found" : "\(ads.count) ads found"
            apply(text: "\(ads.count)", alpha: exempt ? 0.5 : 1, accessibility: found)
        }
    }

    private func hide() {
        isHidden = true
        icon.setAnimating(false)
        accessibilityText = nil
    }

    private func apply(text: String?, tint: UIColor = ThemeColor.primaryIcon02(), alpha: CGFloat = 1, isFinding: Bool = false, accessibility: String) {
        icon.color = tint
        icon.setAnimating(isFinding)
        label.text = text
        label.isHidden = text == nil
        self.alpha = alpha
        accessibilityText = accessibility
        isHidden = false
    }
}

/// The skip-ads mark (two arrows and a bar) drawn as three separate parts, so
/// they can light up one after another while ads are being found.
@MainActor
final class AdSkipIconView: UIView {
    private static let animationKey = "finding"
    private let parts = (0..<3).map { _ in CAShapeLayer() }
    private var isAnimating = false

    var color: UIColor = .gray {
        didSet { updateColors() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for part in parts {
            part.lineJoin = .round
            layer.addSublayer(part)
        }
        parts.prefix(2).forEach { $0.fillColor = nil }
        updateColors()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: AdSkipIconView, _) in
            view.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let height = UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 10)
        return CGSize(width: (height * 1.5).rounded(), height: height.rounded())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        let line = max(1.5, height * 0.16)
        let arrowWidth = bounds.width * 0.4
        let barWidth = line * 1.2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, arrow) in parts.prefix(2).enumerated() {
            // Each part gets its own frame so it pops from its own center.
            arrow.frame = CGRect(x: CGFloat(index) * arrowWidth, y: 0, width: arrowWidth, height: height)
            let inset = line / 2
            let path = UIBezierPath()
            path.move(to: CGPoint(x: inset, y: inset))
            path.addLine(to: CGPoint(x: arrowWidth - inset, y: height / 2))
            path.addLine(to: CGPoint(x: inset, y: height - inset))
            path.close()
            arrow.path = path.cgPath
            arrow.lineWidth = line
        }
        parts[2].frame = CGRect(x: bounds.width - barWidth, y: 0, width: barWidth, height: height)
        parts[2].path = UIBezierPath(roundedRect: parts[2].bounds, cornerRadius: barWidth / 2).cgPath
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    /// Safe to call on every progress update: the cycle only restarts when it was
    /// stopped or iOS dropped it (as it does when the app goes to the background).
    func setAnimating(_ animating: Bool) {
        isAnimating = animating
        updateAnimation()
    }

    private func updateColors() {
        let cgColor = color.cgColor
        parts.prefix(2).forEach { $0.strokeColor = cgColor }
        parts[2].fillColor = cgColor
    }

    private func updateAnimation() {
        guard isAnimating, window != nil else {
            parts.forEach { $0.removeAnimation(forKey: Self.animationKey) }
            return
        }
        guard parts[0].animation(forKey: Self.animationKey) == nil else { return }

        // Parts start dim, light up one, two, three with a small pop, hold, then reset.
        let dim: Float = 0.25
        let now = CACurrentMediaTime()
        for (index, part) in parts.enumerated() {
            let on = 0.1 + Double(index) * 0.2
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [dim, dim, 1, 1, dim]
            opacity.keyTimes = [0, on, on + 0.06, 0.85, 1].map { NSNumber(value: $0) }
            var animations: [CAAnimation] = [opacity]
            if !UIAccessibility.isReduceMotionEnabled {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1, 1, 1.35, 1, 1]
                pop.keyTimes = [0, on, on + 0.07, on + 0.16, 1].map { NSNumber(value: $0) }
                animations.append(pop)
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = 1.5
            group.repeatCount = .infinity
            group.beginTime = now
            part.add(group, forKey: Self.animationKey)
        }
    }
}
