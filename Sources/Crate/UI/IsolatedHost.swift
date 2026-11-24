import AppKit
import SwiftUI

/// Hosts fast-changing content in a SwiftUI graph of its own.
///
/// A window's content is one SwiftUI graph, and whenever anything in it
/// changes, AppKit asks the graph for the content's minimum size again, which
/// means measuring every view in the window. A playing deck redraws sixty
/// times a second, so the whole window (decks, table, agent bar) was being
/// measured sixty times a second and the main thread had no time left for
/// typing. Content inside this host updates without the window noticing.
///
/// The host does not report its content's size, so the content must say how
/// tall it wants to be (see `DecksView.onHeight`) and the caller sets the frame.
struct IsolatedHost<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []       // do not measure the content for the window's sake
        view.safeAreaRegions = []     // the outer layout has already dealt with the title bar
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content
    }
}
