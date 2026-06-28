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
    /// Verbatim license / permission notice. Reproduced in full because most
    /// permissive licenses require the notice to travel with copies.
    let licenseText: String

    var id: String { name }
}

enum OpenSourceLicenses {
    /// Everything that needs attribution. The app otherwise links only Apple
    /// system frameworks (SwiftUI, CloudKit, UserNotifications, …), which carry
    /// no attribution requirement and are intentionally not listed here.
    static let all: [OpenSourceComponent] = [unicodeEmojiData]

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

        Copyright © 1991-2025 Unicode, Inc.

        NOTICE TO USER: Carefully read the following legal agreement. BY \
        DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR \
        SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF \
        THE TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT \
        DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

        Permission is hereby granted, free of charge, to any person obtaining a \
        copy of data files and any associated documentation (the "Data Files") \
        or software and any associated documentation (the "Software") to deal in \
        the Data Files or Software without restriction, including without \
        limitation the rights to use, copy, modify, merge, publish, distribute, \
        and/or sell copies of the Data Files or Software, and to permit persons \
        to whom the Data Files or Software are furnished to do so, provided that \
        either (a) this copyright and permission notice appear with all copies \
        of the Data Files or Software, or (b) this copyright and permission \
        notice appear in associated Documentation.

        THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF \
        ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE \
        WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
        NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN NO EVENT SHALL THE COPYRIGHT \
        HOLDER OR HOLDERS INCLUDED IN THIS NOTICE BE LIABLE FOR ANY CLAIM, OR \
        ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES, OR ANY DAMAGES WHATSOEVER \
        RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF \
        CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN \
        CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA FILES OR SOFTWARE.

        Except as contained in this notice, the name of a copyright holder shall \
        not be used in advertising or otherwise to promote the sale, use or \
        other dealings in these Data Files or Software without prior written \
        authorization of the copyright holder.
        """
    )
}
