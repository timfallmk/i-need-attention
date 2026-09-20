import SwiftUI

/// Watch-side counterpart to the iPhone's StatusIndicatorView. Same decision matrix:
/// incoming-unacked > outgoing-pending > idle, with watch-sized typography.
struct WatchStatusPill: View {
    let snapshot: WatchSnapshot?
    let now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        .background(Capsule().fill(tint.opacity(reduceTransparency ? 0.44 : 0.22)))
        .overlay(Capsule().strokeBorder(tint.opacity(reduceTransparency ? 0.80 : 0.45), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut, value: title)
    }

    // MARK: - Snapshot derivation (mirrors iOS StatusIndicatorView)

    private enum State {
        case loading
        case unpaired
        case idle(coolingDown: Bool)
        case outgoingSent
        case outgoingSeen
        case outgoingAcked(String?)
        case incomingPending(senderName: String, message: String?)
        case incomingSnoozed(Date)
    }

    private var state: State {
        guard let snap = snapshot else { return .loading }
        guard snap.paired else { return .unpaired }
        if let incoming = snap.incoming, !incoming.acknowledged {
            if let until = incoming.snoozedUntil, until > now {
                return .incomingSnoozed(until)
            }
            return .incomingPending(senderName: incoming.senderName, message: incoming.message)
        }
        if let outgoing = snap.outgoing {
            switch outgoing.state {
            // Critical Alerts UI commented out (Apple denied entitlement). The wire
            // field stays so re-enabling is just restoring the critical: parameter.
            // case .sent: return .outgoingSent(critical: outgoing.critical)
            case .sent: return .outgoingSent
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
        // case .outgoingSent(let c): return c ? "🚨" : "📡"
        case .outgoingSent: return "📡"
        case .outgoingSeen: return "👀"
        case .outgoingAcked(let e): return e ?? "✅"
        // case .incomingPending(_, let c): return c ? "🚨" : "🔔"
        case .incomingPending: return "🔔"
        case .incomingSnoozed: return "⏰"
        }
    }

    private var title: LocalizedStringKey {
        switch state {
        case .loading: return "Connecting…"
        case .unpaired: return "Not paired"
        case .idle: return "All quiet"
        case .outgoingSent: return "Sent"
        case .outgoingSeen: return "Seen"
        case .outgoingAcked: return "Acknowledged"
        case .incomingPending(let name, let message):
            let displayName = name.isEmpty ? String(localized: "Partner") : name
            let body = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return body.isEmpty ? "\(displayName) needs you" : "\(displayName) \(body)"
        case .incomingSnoozed: return "Snoozed"
        }
    }

    private var subtitle: LocalizedStringKey? {
        switch state {
        case .loading: return nil
        case .unpaired: return "Pair on iPhone"
        case .idle(let cooling): return cooling ? "Cooling down" : nil
        case .outgoingSent: return "Waiting"
        case .outgoingSeen: return "They saw it"
        case .outgoingAcked: return "Got back to you"
        case .incomingPending: return nil
        case .incomingSnoozed(let until): return "until \(until.formatted(date: .omitted, time: .shortened))"
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
        case .incomingSnoozed: return .orange
        }
    }
}

#if DEBUG
#Preview {
    let incoming = WatchSnapshot.IncomingInfo(
        recordName: "x", senderName: "Sam", critical: false,
        createdAt: Date(), acknowledged: false, message: "needs coffee", snoozedUntil: nil
    )
    var snoozed = incoming
    snoozed.snoozedUntil = Date().addingTimeInterval(15 * 60)
    return VStack(spacing: 8) {
        WatchStatusPill(snapshot: WatchSnapshot(paired: true, outgoing: nil, incoming: incoming, cooldownEnds: nil), now: Date())
        WatchStatusPill(snapshot: WatchSnapshot(paired: true, outgoing: nil, incoming: snoozed, cooldownEnds: nil), now: Date())
    }
}
#endif
