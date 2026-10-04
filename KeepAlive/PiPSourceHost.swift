import SwiftUI
import UIKit

/// A persistent transparent UIKit source host over the TabView, rather than a lazy Form row
/// or an unmanaged subview inserted into SwiftUI's root hosting view.
struct PiPSourceHost: UIViewRepresentable {
    let service: PiPKeepAliveService

    func makeUIView(context: Context) -> PiPSourceHostView {
        let view = PiPSourceHostView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.service = service
        return view
    }

    func updateUIView(_ uiView: PiPSourceHostView, context: Context) {
        uiView.service = service
        if uiView.window != nil { service.attachSourceHost(uiView) }
    }

    static func dismantleUIView(_ uiView: PiPSourceHostView, coordinator: ()) {
        uiView.service?.detachSourceHost(uiView)
    }
}

final class PiPSourceHostView: UIView {
    weak var service: PiPKeepAliveService?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { service?.attachSourceHost(self) }
        else { service?.detachSourceHost(self) }
    }
}
