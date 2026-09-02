import Foundation

/// One attributable third-party component bundled into the app, plus the full
/// text of the license it ships under. This is the single source of truth for
/// the Settings → Open Source screen.
struct OpenSourceComponent: Identifiable {
    /// Human-readable name shown in the list.
    let name: String
    /// One line on what we use it for.
    let summary: String
    /// Short license label (e.g. "Unicode License v3").
    let licenseName: String
    /// Where the upstream lives; shown as a tappable link when present.
    let url: URL?
    /// Verbatim license text or attribution notice — whichever the license in
    /// question actually requires to travel with copies of the work.
    let licenseText: String

    var id: String { name }
}

enum OpenSourceLicenses {
    /// Everything that needs attribution. The app otherwise links only Apple
    /// system frameworks (SwiftUI, CloudKit, UserNotifications, …), which carry
    /// no attribution requirement and are intentionally not listed here.
    static let all: [OpenSourceComponent] = [unicodeEmojiData, notificationSound]

    /// The emoji catalog (`App/Helpers/EmojiCatalog.swift`) — the picker's emoji
    /// list, names, and search keywords — is generated from Unicode's
    /// `emoji-test.txt` by `Tools/generate_emoji_catalog.py`. That data is
    /// covered by the Unicode License v3, which requires this notice to appear
    /// with copies of the data.
    static let unicodeEmojiData = OpenSourceComponent(
        name: "Unicode Emoji Data",
        summary: "Emoji list, names, and search keywords used by the emoji picker.",
        licenseName: "Unicode License v3",
        url: URL(string: "https://www.unicode.org/license.txt"),
        licenseText: """
        UNICODE LICENSE V3

        COPYRIGHT AND PERMISSION NOTICE

        Copyright © 1991-2026 Unicode, Inc.

        NOTICE TO USER: Carefully read the following legal agreement. BY
        DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
        SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
        TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
        DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

        Permission is hereby granted, free of charge, to any person obtaining a
        copy of data files and any associated documentation (the "Data Files") or
        software and any associated documentation (the "Software") to deal in the
        Data Files or Software without restriction, including without limitation
        the rights to use, copy, modify, merge, publish, distribute, and/or sell
        copies of the Data Files or Software, and to permit persons to whom the
        Data Files or Software are furnished to do so, provided that either (a)
        this copyright and permission notice appear with all copies of the Data
        Files or Software, or (b) this copyright and permission notice appear in
        associated Documentation.

        THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
        KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
        MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
        THIRD PARTY RIGHTS.

        IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
        BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
        OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
        WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
        ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
        FILES OR SOFTWARE.

        Except as contained in this notice, the name of a copyright holder shall
        not be used in advertising or otherwise to promote the sale, use or other
        dealings in these Data Files or Software without prior written
        authorization of the copyright holder.
        """
    )

    /// The bundled alert tone (`App/Resources/needs-attention.caf`) is a format
    /// conversion of a CC BY 3.0 work, so the attribution has to reach end users —
    /// a notice in the repo alone doesn't discharge it for a shipped binary.
    ///
    /// Unlike the Unicode entry above, CC BY does not require its full legal code to
    /// travel with the work: §4(a) is satisfied by naming the author, the title, the
    /// associated URI, any modifications made, and a URI for the license itself.
    /// That is exactly what this notice carries.
    static let notificationSound = OpenSourceComponent(
        name: "Notification Sound",
        summary: "The alert tone played when your partner needs your attention.",
        licenseName: "CC BY 3.0 Unported",
        url: URL(string: "https://creativecommons.org/licenses/by/3.0/"),
        licenseText: """
        "Chord2_Rev.wav" by Aarni Koskela (akx)

        Source:
        https://github.com/akx/Notifications/blob/master/WAV/Chord2_Rev.wav

        Licensed under the Creative Commons Attribution 3.0 Unported
        (CC BY 3.0) license:
        https://creativecommons.org/licenses/by/3.0/

        Changes made: converted from WAV to IMA4 CAF using
        afconvert -d ima4 -f caff. No trimming or normalization was applied.

        This notice is provided under section 4(a) of that license, which
        requires credit to the original author, the title of the work, the
        associated URI, an indication of any modifications made, and a URI
        for the license itself.
        """
    )
}
