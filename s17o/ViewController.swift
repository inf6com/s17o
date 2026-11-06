import Cocoa
import SwiftUI

@MainActor
final class ViewController: NSViewController {
    private var model: AppModel?
    private var hostingView: NSHostingView<MonitoringView>?

    func configure(with model: AppModel) {
        self.model = model
        installRootViewIfReady()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installRootViewIfReady()
    }

    private func installRootViewIfReady() {
        guard isViewLoaded, let model else {
            return
        }

        let rootView = MonitoringView(model: model)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        self.hostingView?.removeFromSuperview()
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        self.hostingView = hostingView
    }
}
