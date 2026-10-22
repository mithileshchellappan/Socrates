#if os(macOS)
import AppKit
import StudyUI
import SwiftUI

/// One open pane: its header and its content's hosting controller. The window keeps one per open
/// pane (`PaneStage`), so the pane moves between columns, screen kinds and the maximize slot
/// without being built again; closing it empties its root, and the controller goes.
final class PaneItemController: NSViewController {
    let id: PaneID
    /// Header and content: in this controller's view, or in the maximize slot.
    let pane: PaneView
    /// The offer whose content is installed (nil: none has arrived yet).
    private(set) var installed: PaneOffer?

    private let model: PaneHostModel
    private let environment: PaneEnvironment
    private let content: NSHostingController<PaneRoot>
    private var accessory: NSHostingView<PaneRoot>?

    init(id: PaneID, model: PaneHostModel, environment: PaneEnvironment) {
        self.id = id
        self.model = model
        self.environment = environment
        let hosting = NSHostingController(rootView: PaneRoot(id: id, model: model, environment: environment, content: nil))
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        hosting.safeAreaRegions = []
        content = hosting
        pane = PaneView(content: hosting.view)
        super.init(nibName: nil, bundle: nil)
        addChild(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The pane goes in unless the maximize slot holds it (a pane opened maximized gets its column
    /// later): the column then shows the bare surface until `takeBack()`.
    override func loadView() {
        let view = PaneItemView(frame: NSRect(x: 0, y: 0, width: 336, height: 400))
        if pane.superview == nil {
            pane.frame = view.bounds
            view.addSubview(pane)
        }
        self.view = view
    }

    /// Installs the offer's content and accessory when the offer's identity changes (a new
    /// closure alone changes nothing). An offer that goes away leaves the content as it was until
    /// another arrives or the pane closes.
    func install(_ offer: PaneOffer?) {
        guard let offer, offer != installed else { return }
        installed = offer
        content.rootView = PaneRoot(id: id, model: model, environment: environment, content: offer.content())
        if let makeAccessory = offer.accessory {
            let root = PaneRoot(id: id, model: model, environment: environment, content: makeAccessory(), fills: false)
            if let accessory {
                accessory.rootView = root
            } else {
                let view = NSHostingView(rootView: root)
                view.sizingOptions = [.intrinsicContentSize]
                view.sceneBridgingOptions = []
                view.safeAreaRegions = []
                accessory = view
            }
        } else {
            accessory = nil
        }
    }

    /// The header for `spec`: its title (or the accessory in its place), ⤢ or ⤡.
    func showHeader(_ spec: PaneSpec, isMaximized: Bool, canRestore: Bool) {
        pane.header.show(title: spec.showsTitle ? spec.title : nil, accessory: accessory, isMaximized: isMaximized, canRestore: canRestore)
    }

    /// Closed: the content goes, so a closed pane holds none of the screen's state.
    func empty() {
        installed = nil
        accessory = nil
        content.rootView = PaneRoot(id: id, model: model, environment: environment, content: nil)
        pane.header.show(title: nil, accessory: nil, isMaximized: false, canRestore: false)
    }

    /// The pane back in its column (after the maximize slot), at the column's size, without
    /// leaving the window.
    func takeBack() {
        guard pane.superview !== view else { return }
        view.addSubview(pane)
        pane.frame = view.bounds
    }

    /// The window's first responder sits in this pane.
    func holdsFirstResponder(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: pane)
    }
}
#endif
