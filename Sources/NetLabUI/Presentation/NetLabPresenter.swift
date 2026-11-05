import Combine
import NetLabCore
import SwiftUI
import UIKit

@MainActor
public final class NetLabPresenter: NSObject {
    public static let shared = NetLabPresenter()

    public private(set) var store: NetLabStore?
    private var showsButton = true
    private var respondsToShake = true
    private var overlayWindow: NetLabOverlayWindow?
    private var panelWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var cancellables = Set<AnyCancellable>()
    private var sceneObserver: NSObjectProtocol?

    public func install(backend: NetLabBackend, showsButton: Bool, respondsToShake: Bool) {
        let store = NetLabStore(backend: backend)
        self.store = store
        self.showsButton = showsButton
        self.respondsToShake = respondsToShake
        cancellables.removeAll()

        store.$snapshot
            .map(\.armedCount)
            .removeDuplicates()
            .sink { [weak self] count in self?.overlayWindow?.setArmedCount(count) }
            .store(in: &cancellables)
        backend.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                if case let .overrideApplied(text) = event { self?.overlayWindow?.showBanner(text) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .netLabShake)
            .sink { [weak self] _ in
                guard let self, self.respondsToShake else { return }
                self.panelWindow == nil ? self.present() : self.dismiss()
            }
            .store(in: &cancellables)

        attachWhenSceneIsReady()
    }

    public func uninstall() {
        dismiss()
        overlayWindow?.isHidden = true
        overlayWindow = nil
        cancellables.removeAll()
        if let sceneObserver { NotificationCenter.default.removeObserver(sceneObserver) }
        sceneObserver = nil
        store = nil
    }

    public func present() {
        guard let store, panelWindow == nil, let scene = activeScene else { return }
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 2
        window.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.makeKeyAndVisible()
        panelWindow = window

        let host = UIHostingController(rootView: NetLabRootView(store: store, onClose: { [weak self] in self?.dismiss() }))
        host.modalPresentationStyle = .pageSheet
        host.presentationController?.delegate = self
        root.present(host, animated: true)
    }

    public func dismiss() {
        guard let window = panelWindow else { return }
        if let presented = window.rootViewController?.presentedViewController {
            presented.dismiss(animated: true) { [weak self] in self?.tearDownPanel() }
        } else {
            tearDownPanel()
        }
    }

    private func tearDownPanel() {
        panelWindow?.isHidden = true
        panelWindow = nil
        previousKeyWindow?.makeKey()
    }

    private var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func attachWhenSceneIsReady() {
        if let scene = activeScene {
            attach(to: scene)
            return
        }
        sceneObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.overlayWindow == nil, let scene = self.activeScene else { return }
                self.attach(to: scene)
            }
        }
    }

    private func attach(to scene: UIWindowScene) {
        guard showsButton, overlayWindow == nil else { return }
        let window = NetLabOverlayWindow(windowScene: scene)
        window.onTap = { [weak self] in self?.present() }
        window.setArmedCount(store?.snapshot.armedCount ?? 0)
        window.isHidden = false
        overlayWindow = window
    }
}

extension NetLabPresenter: UIAdaptivePresentationControllerDelegate {
    nonisolated public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Task { @MainActor in self.tearDownPanel() }
    }
}

extension Notification.Name {
    static let netLabShake = Notification.Name("NetLab.shake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .netLabShake, object: nil)
        }
    }
}
