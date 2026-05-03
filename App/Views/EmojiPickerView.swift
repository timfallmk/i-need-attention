import SwiftUI

struct EmojiPickerView: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var toneSelection: ToneSelection?

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 4, alignment: .center),
        count: 7
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    categoryList
                } else {
                    searchResults
                }
            }
            .navigationTitle("Pick an emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
        }
        .sheet(item: $toneSelection) { selection in
            ToneStripSheet(base: selection.base) { toned in
                toneSelection = nil
                onPick(toned)
                dismiss()
            }
            .presentationDetents([.height(180)])
            .presentationDragIndicator(.visible)
        }
    }

    private var categoryList: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
            ForEach(EmojiCatalog.categories, id: \.name) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    grid(for: category.emojis)
                        .padding(.horizontal, 12)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var searchResults: some View {
        let matches = EmojiCatalog.search(query)
        return Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .padding(.top, 40)
            } else {
                grid(for: matches)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
        }
    }

    private func grid(for emojis: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in
                cell(for: emoji)
            }
        }
    }

    private func cell(for emoji: String) -> some View {
        let supportsTones = EmojiCatalog.fitzpatrickBase.contains(emoji)
        return Text(emoji)
            .font(.system(size: 30))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.select()
                onPick(emoji)
                dismiss()
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                guard supportsTones else { return }
                Haptics.tick()
                toneSelection = ToneSelection(base: emoji)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(emoji))
            .modifier(ToneAccessibilityAction(emoji: emoji, enabled: supportsTones, onPick: { toneSelection = ToneSelection(base: $0) }))
    }
}
