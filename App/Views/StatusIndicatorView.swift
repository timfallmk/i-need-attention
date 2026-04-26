import SwiftUI

/// Top status pill on the main screen. Uses color + emoji + text so it reads at a glance.
struct StatusIndicatorView: View {
    let outgoing: AlertRecord?
    let incoming: AlertRecord?
    let isOnCooldown: Bool

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
        case .outgoingSent: return "📡"
        case .outgoingSeen: return "👀"
        case .outgoingAcked(let e): return e ?? "✅"
        case .incomingPending: return "🔔"
        }
    }

    private var title: String {
        switch snapshot {
        case .idle: return "All quiet"
        case .outgoingSent: return "Sent"
        case .outgoingSeen: return "Seen"
        case .outgoingAcked: return "Acknowledged"
        case .incomingPending(let a): return "\(a.senderName) needs you"
        }
    }

    private var subtitle: String? {
        switch snapshot {
        case .idle: return isOnCooldown ? "Cooling down" : nil
        case .outgoingSent: return "Waiting for them to look"
        case .outgoingSeen: return "They saw it"
        case .outgoingAcked: return "They got back to you"
        case .incomingPending(let a): return relativeTime(from: a.createdAt)
        }
    }

    private var tint: Color {
        switch snapshot {
        case .idle: return .secondary
        case .outgoingSent: return .blue
        case .outgoingSeen: return .indigo
        case .outgoingAcked: return .green
        case .incomingPending: return .red
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
    }
}
