import SwiftUI

struct EmojiPickerView: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 4, alignment: .center),
        count: 8
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
                Button {
                    Haptics.select()
                    onPick(emoji)
                    dismiss()
                } label: {
                    Text(emoji)
                        .font(.system(size: 30))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
