import SwiftUI
import WidgetKit

/// Watch face complication. Tap launches the watch app with `attention://press`,
/// which the app intercepts via .onOpenURL to fire WatchSession.sendPress() immediately.
struct AttentionComplication: Widget {
    let kind = "AttentionComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AttentionTimelineProvider()) { _ in
            AttentionComplicationView()
                .widgetURL(URL(string: "attention://press"))
                .containerBackground(for: .widget) {
                    // Watch face accessories handle their own masking — keep this
                    // transparent so the AccessoryWidgetBackground in our view shows.
                    Color.clear
                }
        }
        .configurationDisplayName("Attention")
        .description("One-tap shortcut to ping your partner.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

struct AttentionEntry: TimelineEntry {
    let date: Date
}

struct AttentionTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> AttentionEntry {
        AttentionEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (AttentionEntry) -> Void) {
        completion(AttentionEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AttentionEntry>) -> Void) {
        // Static — the complication doesn't need scheduled refreshes.
        completion(Timeline(entries: [AttentionEntry(date: .now)], policy: .never))
    }
}

struct AttentionComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:    circularBody
        case .accessoryCorner:      cornerBody
        case .accessoryInline:      inlineBody
        case .accessoryRectangular: rectangularBody
        default:                    circularBody
        }
    }

    private var circularBody: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .fill(redGradient)
            Image(systemName: "exclamationmark")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
        }
    }

    private var cornerBody: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.red)
            .widgetLabel("Attention")
    }

    private var inlineBody: some View {
        Label("Need Attention", systemImage: "hand.raised.fill")
    }

    private var rectangularBody: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(redGradient).frame(width: 30, height: 30)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Attention")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text("Tap to ping")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var redGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.36, blue: 0.36),
                Color(red: 0.78, green: 0.10, blue: 0.14)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview(as: .accessoryCircular) {
    AttentionComplication()
} timeline: {
    AttentionEntry(date: .now)
}
