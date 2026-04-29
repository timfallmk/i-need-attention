import SwiftUI

/// Watch-side counterpart to the iPhone's StatusIndicatorView. Same decision matrix:
/// incoming-unacked > outgoing-pending > idle, with watch-sized typography.
struct WatchStatusPill: View {
    let snapshot: WatchSnapshot?
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(emoji)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.22)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
        .animation(.easeInOut, value: title)
    }

    // MARK: - Snapshot derivation (mirrors iOS StatusIndicatorView)

    private enum State {
        case loading
        case unpaired
        case idle(coolingDown: Bool)
        case outgoingSent(critical: Bool)
        case outgoingSeen
        case outgoingAcked(String?)
        case incomingPending(senderName: String, critical: Bool)
    }

    private var state: State {
        guard let snap = snapshot else { return .loading }
        guard snap.paired else { return .unpaired }
        if let incoming = snap.incoming, !incoming.acknowledged {
            return .incomingPending(senderName: incoming.senderName, critical: incoming.critical)
        }
        if let outgoing = snap.outgoing {
            switch outgoing.state {
            case .sent: return .outgoingSent(critical: outgoing.critical)
            case .seen: return .outgoingSeen
            case .acknowledged: return .outgoingAcked(outgoing.ackEmoji)
            }
        }
        let cooling = (snap.cooldownEnds ?? .distantPast) > now
        return .idle(coolingDown: cooling)
    }

    private var emoji: String {
        switch state {
        case .loading: return "💗"
        case .unpaired: return "🔗"
        case .idle: return "💗"
        case .outgoingSent(let c): return c ? "🚨" : "📡"
        case .outgoingSeen: return "👀"
        case .outgoingAcked(let e): return e ?? "✅"
        case .incomingPending(_, let c): return c ? "🚨" : "🔔"
        }
    }

    private var title: String {
        switch state {
        case .loading: return "Connecting…"
        case .unpaired: return "Not paired"
        case .idle: return "All quiet"
        case .outgoingSent: return "Sent"
        case .outgoingSeen: return "Seen"
        case .outgoingAcked: return "Acknowledged"
        case .incomingPending(let name, _): return "\(name) needs you"
        }
    }

    private var subtitle: String? {
        switch state {
        case .loading: return nil
        case .unpaired: return "Pair on iPhone"
        case .idle(let cooling): return cooling ? "Cooling down" : nil
        case .outgoingSent: return "Waiting"
        case .outgoingSeen: return "They saw it"
        case .outgoingAcked: return "Got back to you"
        case .incomingPending: return nil
        }
    }

    private var tint: Color {
        switch state {
        case .loading: return .secondary
        case .unpaired: return .secondary
        case .idle: return .secondary
        case .outgoingSent: return .blue
        case .outgoingSeen: return .indigo
        case .outgoingAcked: return .green
        case .incomingPending: return .red
        }
    }
}
