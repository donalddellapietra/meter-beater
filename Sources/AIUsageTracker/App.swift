import SwiftUI
import UsageCore

@main
struct AIUsageTrackerApp: App {
    @State private var model = WoolModel()
#if DEBUG
    private let isCapturing = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_PATH"] != nil
    private let isCapturingSettings = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_SETTINGS"] == "1"
    private let isCapturingDateRange = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_DATE_RANGE"] == "1"
    private let isCapturingBreakdown = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_BREAKDOWN"] == "1"
    private let isCapturingLoading = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_LOADING"] == "1"
    private let isCapturingAchievement = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_ACHIEVEMENT"] == "1"
    private let isCapturingSpendEditor = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_SPEND"] == "1"
#endif

    init() {
        TempArtifactJanitor.sweepAsync()
    }

    var body: some Scene {
        MenuBarExtra {
            WoolPanel(model: model)
                .environment(\.locale, model.appLanguage.locale)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "scissors")
                Text(model.hasLoadedSummary ? WoolFormat.menuValue(model.summary) : "…")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: model.summary.apiUSD))
                    .animation(.smooth(duration: 0.6), value: WoolFormat.menuValue(model.summary))
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            CostSettingsView(model: model)
                .environment(\.locale, model.appLanguage.locale)
        }

#if DEBUG
        Window("Meter Beater", id: "panel-capture") {
            Group {
                if isCapturingAchievement {
                    AchievementCaptureView(model: model)
                } else if isCapturingSpendEditor {
                    SpendEditorCaptureView(model: model)
                } else if isCapturingBreakdown {
                    ProviderBreakdownCaptureView(model: model)
                } else if isCapturingDateRange {
                    DateRangeCaptureView(model: model)
                } else if isCapturingSettings {
                    CostSettingsView(model: model)
                } else {
                    WoolPanel(model: model, forceLoading: isCapturingLoading)
                }
            }
                .environment(\.locale, model.appLanguage.locale)
                .background(DebugPanelCapture())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(isCapturing ? .presented : .suppressed)
#endif
    }
}

#if DEBUG
private struct DebugPanelCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CaptureAnchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CaptureAnchor: NSView {
    private static var scheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !Self.scheduled,
              let window,
              let path = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_PATH"],
              !path.isEmpty else { return }
        Self.scheduled = true
        if ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_APPEARANCE"] == "dark" {
            let appearance = NSAppearance(named: .darkAqua)
            NSApplication.shared.appearance = appearance
            window.appearance = appearance
        }
        let delayMilliseconds = ProcessInfo.processInfo.environment["AI_USAGE_TRACKER_CAPTURE_DELAY_MS"]
            .flatMap(Int.init) ?? 2000
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) {
            guard let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif
