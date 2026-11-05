import UIKit

final class NetLabOverlayWindow: UIWindow {
    private static let buttonSize: CGFloat = 52
    private static let margin: CGFloat = 12

    var onTap: (() -> Void)?

    private let button = UIButton(type: .custom)
    private let badge = UILabel()
    private let banner = UILabel()
    private let bannerContainer = UIView()
    private var bannerHide: DispatchWorkItem?
    private var hasPlacedButton = false

    override var canBecomeKey: Bool { false }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        rootViewController = root
        configureButton(in: root.view)
        configureBanner(in: root.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let hit else { return nil }
        return hit === button || hit.isDescendant(of: button) ? hit : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !hasPlacedButton, bounds.width > 0 else { return }
        hasPlacedButton = true
        let area = bounds.inset(by: safeAreaInsets)
        button.frame = CGRect(
            x: area.maxX - Self.buttonSize - Self.margin,
            y: area.maxY - Self.buttonSize - 96,
            width: Self.buttonSize,
            height: Self.buttonSize
        )
    }

    func setArmedCount(_ count: Int) {
        var configuration = button.configuration ?? .filled()
        configuration.baseBackgroundColor = count > 0 ? .systemOrange : .secondarySystemBackground
        configuration.baseForegroundColor = count > 0 ? .white : .label
        button.configuration = configuration
        badge.text = "\(count)"
        badge.isHidden = count == 0
        button.accessibilityValue = count > 0 ? "\(count) overrides armed" : "No overrides armed"
    }

    func showBanner(_ text: String) {
        banner.text = "Override applied · \(text)"
        bannerHide?.cancel()
        UIView.animate(withDuration: 0.2) { self.bannerContainer.alpha = 1 }
        let hide = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.bannerContainer.alpha = 0 }
        }
        bannerHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
    }

    private func configureButton(in view: UIView) {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "network")
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .secondarySystemBackground
        configuration.baseForegroundColor = .label
        button.configuration = configuration
        button.accessibilityLabel = "NetLab"
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.25
        button.layer.shadowRadius = 5
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        view.addSubview(button)

        badge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = .systemRed
        badge.textAlignment = .center
        badge.layer.cornerRadius = 10
        badge.layer.masksToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -4),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 4),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    private func configureBanner(in view: UIView) {
        bannerContainer.backgroundColor = .label
        bannerContainer.layer.cornerRadius = 18
        bannerContainer.alpha = 0
        bannerContainer.isUserInteractionEnabled = false
        bannerContainer.translatesAutoresizingMaskIntoConstraints = false
        banner.font = .preferredFont(forTextStyle: .footnote)
        banner.adjustsFontForContentSizeCategory = true
        banner.textColor = .systemBackground
        banner.numberOfLines = 2
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerContainer.addSubview(banner)
        view.addSubview(bannerContainer)
        NSLayoutConstraint.activate([
            bannerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bannerContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bannerContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            banner.topAnchor.constraint(equalTo: bannerContainer.topAnchor, constant: 9),
            banner.bottomAnchor.constraint(equalTo: bannerContainer.bottomAnchor, constant: -9),
            banner.leadingAnchor.constraint(equalTo: bannerContainer.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: bannerContainer.trailingAnchor, constant: -16)
        ])
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        let area = bounds.inset(by: safeAreaInsets)
        let half = Self.buttonSize / 2
        button.center = CGPoint(
            x: min(max(button.center.x + translation.x, area.minX + half), area.maxX - half),
            y: min(max(button.center.y + translation.y, area.minY + half), area.maxY - half)
        )
    }
}
