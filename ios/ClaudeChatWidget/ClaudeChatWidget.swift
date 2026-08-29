import SwiftUI
import WidgetKit
import ActivityKit

private let appGroup = "group.com.susuclaude.app"

struct ClaudeChatEntry: TimelineEntry {
    let date: Date
    let title: String
    let body: String
}

struct ClaudeChatProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeChatEntry {
        ClaudeChatEntry(date: Date(), title: "Claude Chat", body: "随时记录，继续思考")
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeChatEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeChatEntry>) -> Void) {
        let entry = currentEntry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> ClaudeChatEntry {
        let defaults = UserDefaults(suiteName: appGroup)
        return ClaudeChatEntry(
            date: Date(),
            title: defaults?.string(forKey: "widgetTitle") ?? "Claude Chat",
            body: defaults?.string(forKey: "widgetBody") ?? "随时记录，继续思考"
        )
    }
}

struct ClaudeChatWidgetView: View {
    let entry: ClaudeChatProvider.Entry

    @ViewBuilder
    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content
                .containerBackground(Color(red: 0.98, green: 0.95, blue: 0.90), for: .widget)
        } else {
            content
                .background(Color(red: 0.98, green: 0.95, blue: 0.90))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(Color(red: 0.76, green: 0.35, blue: 0.21))
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(entry.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

struct ClaudeChatWidget: Widget {
    let kind = "ClaudeChatWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeChatProvider()) { entry in
            ClaudeChatWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Chat")
        .description("显示你在 Claude Chat 中设置的快捷信息。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(iOSApplicationExtension 16.1, *)
struct ClaudeChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let status: String
        let preview: String
        let working: Bool
    }

    let title: String
    let scopeId: String
}

@available(iOSApplicationExtension 16.1, *)
struct ClaudeChatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeChatActivityAttributes.self) { context in
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(red: 0.79, green: 0.44, blue: 0.28).opacity(0.16))
                    Image(systemName: context.state.working ? "ellipsis.message.fill" : "checkmark")
                        .foregroundStyle(Color(red: 0.79, green: 0.44, blue: 0.28))
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(context.state.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !context.state.preview.isEmpty {
                        Text(context.state.preview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if context.state.working {
                    ProgressView().tint(Color(red: 0.79, green: 0.44, blue: 0.28))
                }
            }
            .padding(.horizontal, 15)
            .activityBackgroundTint(Color(red: 0.98, green: 0.97, blue: 0.95))
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "ellipsis.message.fill")
                        .foregroundStyle(Color(red: 0.91, green: 0.49, blue: 0.30))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.preview.isEmpty {
                        Text(context.state.preview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: "ellipsis.message.fill")
                    .foregroundStyle(Color(red: 0.91, green: 0.49, blue: 0.30))
            } compactTrailing: {
                Image(systemName: context.state.working ? "waveform" : "checkmark")
                    .foregroundStyle(context.state.working ? Color.orange : Color.green)
            } minimal: {
                Image(systemName: context.state.working ? "ellipsis" : "checkmark")
                    .foregroundStyle(context.state.working ? Color.orange : Color.green)
            }
            .keylineTint(Color(red: 0.91, green: 0.49, blue: 0.30))
        }
    }
}

@main
struct ClaudeChatWidgets: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        ClaudeChatWidget()
        if #available(iOSApplicationExtension 16.1, *) {
            ClaudeChatLiveActivity()
        }
    }
}
