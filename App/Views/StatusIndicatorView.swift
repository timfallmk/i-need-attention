import SwiftUI

/// Top status pill on the main screen. Uses color + emoji + text so it reads at a glance.
struct StatusIndicatorView: View {
    let outgoing: AlertRecord?
    let incoming: AlertRecord?
    let isOnCooldown: Bool
    /// When set (and in the future), the incoming alert is snoozed until this time.
    var snoozedUntil: Date? = nil
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(emoji)
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if case .outgoingAcked = snapshot, let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(tint.opacity(0.16))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 28)
        .animation(.easeInOut, value: title)
    }

    // Decide which state to surface — incoming-unacked beats outgoing-pending beats idle.
    private var snapshot: Snapshot {
        if let incoming, incoming.state != .acknowledged, incoming.acknowledgedAt == nil {
            if let until = snoozedUntil, until > Date() {
                return .incomingSnoozed(until)
            }
            return .incomingPending(incoming)
        }
        if let outgoing {
            switch outgoing.state {
            case .sent: return .outgoingSent
            case .seen: return .outgoingSeen
            case .acknowledged: return .outgoingAcked(outgoing.ackEmoji)
            }
        }
        return .idle
    }

    private var emoji: String {
        switch snapshot {
        case .idle: return "💗"
        // Critical Alerts UI commented out (Apple denied entitlement). The wire field
        // stays so re-enabling is just restoring this branch.
        // case .outgoingSent: return outgoing?.critical == true ? "🚨" : "📡"
        case .outgoingSent: return "📡"
        case .outgoingSeen: return "👀"
        case .outgoingAcked(let e): return e ?? "✅"
        // case .incomingPending(let a): return a.critical ? "🚨" : "🔔"
        case .incomingPending: return "🔔"
        case .incomingSnoozed: return "⏰"
        }
    }

    private var title: String {
        switch snapshot {
        case .idle: return "All quiet"
        case .outgoingSent: return "Sent"
        case .outgoingSeen: return "Seen"
        case .outgoingAcked: return "Acknowledged"
        case .incomingPending(let a):
            let body = a.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "\(a.senderName) needs you" : "\(a.senderName) \(body)"
        case .incomingSnoozed: return "Snoozed"
        }
    }

    private var subtitle: String? {
        switch snapshot {
        case .idle: return isOnCooldown ? "Cooling down" : nil
        case .outgoingSent: return "Waiting for them to look"
        case .outgoingSeen: return "They saw it"
        case .outgoingAcked: return "They got back to you"
        case .incomingPending(let a): return relativeTime(from: a.createdAt)
        case .incomingSnoozed(let until): return "until \(until.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var tint: Color {
        switch snapshot {
        case .idle: return .secondary
        case .outgoingSent: return .blue
        case .outgoingSeen: return .indigo
        case .outgoingAcked: return .green
        case .incomingPending: return .red
        case .incomingSnoozed: return .orange
        }
    }

    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private enum Snapshot {
        case idle
        case outgoingSent
        case outgoingSeen
        case outgoingAcked(String?)
        case incomingPending(AlertRecord)
        case incomingSnoozed(Date)
    }
}

#if DEBUG
#Preview("Status states") {
    VStack(spacing: 12) {
        StatusIndicatorView(outgoing: nil, incoming: nil, isOnCooldown: false)
        StatusIndicatorView(outgoing: .preview(state: .sent), incoming: nil, isOnCooldown: false)
        StatusIndicatorView(outgoing: .preview(state: .acknowledged, ackEmoji: "❤️"), incoming: nil, isOnCooldown: false, onClear: {})
        StatusIndicatorView(outgoing: nil, incoming: .preview(state: .seen, senderName: "Sam", message: "needs coffee"), isOnCooldown: false)
        StatusIndicatorView(
            outgoing: nil,
            incoming: .preview(state: .seen, senderName: "Sam", message: "needs coffee"),
            isOnCooldown: false,
            snoozedUntil: Date().addingTimeInterval(15 * 60)
        )
    }
    .padding(.vertical)
}
#endif
