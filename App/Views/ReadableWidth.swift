import SwiftUI
import UIKit

enum Layout {
    /// Extra leading room at the top of the screen for the window controls iPadOS draws
    /// inside a window's top-left corner.
    ///
    /// Turning multitasking on is what created this: the controls did not exist while the
    /// app was full-screen only, and iPadOS does not reserve safe area for them — the top
    /// bar sits inside the safe area already and was still overlapped. So the room has to
    /// be made here.
    ///
    /// Keyed on idiom rather than size class deliberately. A narrow iPad window reports a
    /// compact width exactly like a phone, but it still has window controls, so a
    /// size-class test would leave them overlapping in the case most likely to be used.
    ///
    /// The number is eyeballed against a screenshot rather than derived — Apple publishes
    /// no metric for it. Too large only wastes space; too small puts the controls back on
    /// top of the title, which is the failure worth catching.
    static var windowControlsInset: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 68 : 0
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
}
