import SwiftUI

struct NounPickerSheet: View {
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var customMode = false
    @State private var customText = ""
    @FocusState private var customFocused: Bool

    private let presets = NounPresets.all
    private static let maxCustomLength = 30

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("What do you need?")
                .font(.headline)
                .padding(.bottom, 4)

            Text("Tap to send. The default \"needs attention\" stays on a regular tap.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            if customMode {
                customForm
            } else {
                presetList
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var presetList: some View {
        VStack(spacing: 8) {
            ForEach(presets, id: \.self) { preset in
                Button {
                    Haptics.select()
                    onPick(NounPresets.nounForBody(preset))
                } label: {
                    pickerRow(label: preset, systemImage: "hand.raised.fill")
                }
                .buttonStyle(.plain)
            }

            Button {
                Haptics.select()
                customMode = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    customFocused = true
                }
            } label: {
                pickerRow(label: "Custom\u{2026}", systemImage: "pencil")
            }
            .buttonStyle(.plain)
        }
    }

    private var customForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("e.g., a chat", text: $customText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .focused($customFocused)
                .autocorrectionDisabled(false)
                .textInputAutocapitalization(.never)
                .onChange(of: customText) { _, new in
                    var sanitized = new.replacingOccurrences(of: "\n", with: "")
                    if sanitized.count > Self.maxCustomLength {
                        sanitized = String(sanitized.prefix(Self.maxCustomLength))
                    }
                    if sanitized != new {
                        customText = sanitized
                    }
                }
                .onSubmit { trySend() }

            HStack {
                Text("Preview: \u{201C}needs \(previewBody)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(customText.count)/\(Self.maxCustomLength)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    customMode = false
                    customText = ""
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button {
                    trySend()
                } label: {
                    Text("Send")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedCustom.isEmpty)
            }
        }
    }

    private func pickerRow(label: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(label)
                .font(.body)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var trimmedCustom: String {
        customText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewBody: String {
        trimmedCustom.isEmpty ? "\u{2026}" : trimmedCustom
    }

    private func trySend() {
        let value = trimmedCustom
        guard !value.isEmpty else { return }
        onPick(value)
    }
}
