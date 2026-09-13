import SwiftUI

enum Layout {
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
