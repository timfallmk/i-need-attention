import SwiftUI
import UIKit

enum Layout {
    /// Extra leading room for the window controls iPadOS draws inside a window's
    /// top-left corner, applied only where they can actually reach the title.
    ///
    /// Turning multitasking on is what created this: the controls did not exist while the
    /// app was full-screen only, and iPadOS reserves no safe area for them — the top bar
    /// sits inside the safe area already and was overlapped anyway.
    ///
    /// Both halves of the condition earn their place. **Idiom**, because an iPhone has no
    /// window controls and must keep its existing 24pt. **Compact width**, because the
    /// hazard is not "is this an iPad" but "is the content column close enough to the
    /// window's leading edge for the controls to reach it". `readableWidth` centres that
    /// column, so a full-screen or wide window already leaves a margin far bigger than
    /// the controls — at the regular-width threshold the margin is over 120pt against
    /// controls under 80pt wide — and insetting there only pushes the title away from an
    /// edge nothing is sitting on. That is what it looked like, and it looked wrong.
    ///
    /// Still eyeballed rather than derived; Apple publishes no metric. Too large wastes
    /// space in the one case that needs it, too small puts the controls back on the
    /// title.
    static func windowControlsInset(_ widthClass: UserInterfaceSizeClass?) -> CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .pad, widthClass == .compact else {
            return 0
        }
        return 44
    }

    /// How wide content is allowed to grow before it stops filling the screen.
    ///
    /// Every custom layout in the app is built on `maxWidth: .infinity`, which is the
    /// right answer on a phone — fill whatever you are given — and the wrong one at
    /// 1024pt, where a status pill spans the room and the eye has to travel the width of
    /// an iPad to read six words. The fix is one cap above those call sites rather than
    /// an edit at each of them: the inner `.infinity` then fills the cap, not the screen.
    ///
    /// 520 sits above the widest iPhone — a Pro Max is ~440pt in portrait — so the cap
    /// never binds there and the phone layout is unchanged by construction rather than
    /// by inspection. iPhone stays portrait-locked (see `project.yml`), so there is no
    /// landscape case where a phone is wide enough for this to start applying.
    static let readableWidth: CGFloat = 520
}

extension View {
    /// Centres content and stops it growing past `Layout.readableWidth`.
    ///
    /// Apply to content, never to a backdrop. The outer `.infinity` re-centres the
    /// capped block, which is what makes the cap read as a column rather than as content
    /// pinned to the leading edge — but anything painting to the screen edge has to stay
    /// free to fill it, so it belongs inside a `ZStack`'s content layer and not around
    /// the `ZStack` itself.
    func readableWidth() -> some View {
        frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
    }

    /// Keeps a hand-rolled top bar clear of the iPadOS window controls. A no-op on
    /// iPhone and in any window wide enough that `readableWidth` already centres the
    /// content away from them.
    func windowControlsInset() -> some View {
        modifier(WindowControlsInset())
    }
}

private struct WindowControlsInset: ViewModifier {
    @Environment(\.horizontalSizeClass) private var widthClass

    func body(content: Content) -> some View {
        content.padding(.leading, Layout.windowControlsInset(widthClass))
    }
}
