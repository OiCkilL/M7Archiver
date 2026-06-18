import SwiftUI
import AppKit
@preconcurrency import UserNotifications

/// Drives a Dock-icon overlay reflecting any in-flight archive operation
/// (create or extract) — window-backed or headless (Finder right-click).
///
/// The running ring/squircle is rendered by the vendored `DockProgress` library
/// (sindresorhus, MIT — see `Sources/M7ArchiverApp/DockProgress/`).  The
/// terminal badge (green check / red exclamation / yellow warning) is drawn
/// natively as an SF Symbol for the 2s dwell, since DockProgress has no
/// "completed" state.  When an operation finishes while the app is not
/// frontmost, a user notification is posted and the Dock icon bounces.
///
/// Callers register a progress source with `observe(_:)` while an operation
/// runs and report its terminal outcome with `report(_:title:body:)`.  This is
/// agnostic to whether the operation is bound to a window model or runs
/// headless, so it works for both in-app and Finder-right-click flows.
///
/// State machine:  idle  →  running  →  finished(outcome)  →  idle (after 2s)
@MainActor
final class DockProgressController {
    static let shared = DockProgressController()

    enum Outcome {
        case success
        case failure
        case cancelled
    }

    private enum State: Equatable {
        case idle
        case running
        case finished(Outcome)
    }

    private var timer: Timer?
    private var state: State = .idle
    /// Active progress sources, wrapped in ref types so identity comparison
    /// works for removal.  Last-registered wins on each tick.
    private var sources: [SourceBox] = []
    /// Current fraction (0...1) read from the live source, exposed to the
    /// DockProgress `.badge` style's `badgeValue` closure as an integer
    /// percent.  nil while indeterminate.
    private var currentFraction: Double?
    /// Tick used to animate indeterminate progress (no fraction reported).
    private var indeterminateTick: Double = 0
    /// True between a finished report and its dwell clear, suppressing
    /// re-entering running on a trailing progress tick.
    private var finishedPending = false
    private var dwellTask: Task<Void, Never>?

    private init() {}

    /// Start the observation loop.  Call once at app launch.
    func start() {
        guard timer == nil else { return }
        // `.pie` draws a pie-slice progress in the bottom-right corner of the
        // Dock tile; the terminal SF Symbol badge is drawn at the same
        // corner/size so completion reads as a seamless swap.  Swap to `.bar`
        // / `.circle` / `.badge` / `.squircle` to try other built-in styles.
        DockProgress.style = .pie(color: .accentColor)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Register a progress source for an in-flight operation.  The controller
    /// polls the most recently registered live source each tick.  The returned
    /// token removes the source on deinit; `report(_:title:body:)` also clears
    /// all sources.
    @discardableResult
    func observe(_ source: @escaping @MainActor () -> Double?) -> SourceToken {
        let box = SourceBox(source: source)
        sources.append(box)
        finishedPending = false
        return SourceToken { [weak self, weak box] in
            guard let box else { return }
            self?.sources.removeAll { $0 === box }
        }
    }

    /// Reference-wrapped progress source so sources can be identified for
    /// removal by identity (closures have no `==`).
    private final class SourceBox {
        let source: @MainActor () -> Double?
        init(source: @escaping @MainActor () -> Double?) { self.source = source }
    }

    /// Lightweight handle that removes its source on deinit.  Hold it for the
    /// duration of the operation; releasing it (or calling `report`) clears
    /// the source.
    final class SourceToken {
        private let cancel: () -> Void
        fileprivate init(cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }

    /// Report the terminal outcome of an operation, following the HIG rule that
    /// feedback strength matches significance:
    /// - **success**: silent while frontmost (people expect success); notify +
    ///   green check only when the app is in the background.
    /// - **failure**: a red badge always; a notification only when there is no
    ///   window to show an in-context alert (HIG: "use an alert — not a
    ///   notification — to display an error message"). Callers with a window
    ///   present their own `NSAlert`.
    /// - **cancelled**: silent (the user initiated it; no confirmation needed).
    /// `hasWindow` tells the controller whether the caller can surface an
    /// in-app alert, so it knows whether a failure notification is the only
    /// channel or a redundant one.
    func report(_ outcome: Outcome, title: String, body: String, hasWindow: Bool = true) {
        dwellTask?.cancel()
        finishedPending = true
        sources.removeAll()
        currentFraction = nil
        DockProgress.resetProgress()

        let isBackground = !NSApp.isActive

        switch outcome {
        case .cancelled:
            // Silent: just end the ring, no badge, no notification.
            state = .idle
            finishedPending = false
        case .success:
            state = .finished(outcome)
            if isBackground {
                DispatchQueue.main.async { [weak self] in self?.drawFinished(outcome) }
                notifyIfBackground(title: title, body: body, outcome: outcome)
                scheduleDwellClear()
            } else {
                // Frontmost: no badge, no notification.  Reset to idle.
                state = .idle
                finishedPending = false
            }
        case .failure:
            state = .finished(outcome)
            DispatchQueue.main.async { [weak self] in self?.drawFinished(outcome) }
            // Notify only when there's no window to show an in-context alert,
            // or when the app is backgrounded (the alert can't be seen).
            if !hasWindow || isBackground {
                notifyIfBackground(title: title, body: body, outcome: outcome)
            }
            scheduleDwellClear()
        }
    }

    private func scheduleDwellClear() {
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                guard let self else { return }
                self.finishedPending = false
                self.state = .idle
                self.clearDock()
            }
        }
    }

    private func tick() {
        // Never disturb a finished badge during its 2s dwell.
        if case .finished = state { return }

        // Poll the most recently registered live source.
        let activeSource = sources.last
        let fraction = activeSource?.source()

        if activeSource != nil {
            finishedPending = false
            state = .running
            currentFraction = fraction
            if let value = fraction {
                // Determinate (7-Zip create / engines that report bytes).
                DockProgress.progress = max(0, min(1, value))
            } else {
                // Indeterminate (ZIP create, before first percentage): sweep
                // DockProgress.progress back and forth so the ring animates.
                indeterminateTick += 0.015
                let phase = (sin(indeterminateTick * .pi) + 1) / 2 // 0...1 smooth
                DockProgress.progress = phase
            }
        } else if !finishedPending, state == .running {
            state = .idle
            currentFraction = nil
            DockProgress.resetProgress()
        }
    }

    // MARK: - Terminal badge (native SF Symbol)

    private func drawFinished(_ outcome: Outcome) {
        let view = NSHostingView(rootView: AnyView(DockProgressBadge(outcome: outcome)))
        view.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        NSApp.dockTile.contentView = view
        NSApp.dockTile.display()
    }

    private func clearDock() {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    // MARK: - Notification + attention

    private func notifyIfBackground(title: String, body: String, outcome: Outcome) {
        // Bounce the Dock icon regardless of focus (the canonical "something
        // happened" attention cue).  The notification itself is only shown
        // when the app is not frontmost, to avoid nagging an active user.
        NSApp.requestUserAttention(.criticalRequest)

        guard !NSApp.isActive else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // Request authorization once, on the first background completion.
            // The first such operation's notification may not fire (the prompt
            // is async), but every subsequent one will — this is the intended
            // "ask at first relevant moment" pattern rather than nagging at
            // launch or re-prompting on every operation.
            guard settings.authorizationStatus == .authorized else {
                Task { @MainActor in self.requestAuthorizationIfNeeded() }
                return
            }
            guard settings.alertSetting == .enabled else { return }
            self.postNotification(title: title, body: body, outcome: outcome, in: center)
        }
    }

    private var authorizationRequested = false

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated private func postNotification(title: String, body: String, outcome: Outcome, in center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = outcome == .success ? .default : .defaultCritical
        let request = UNNotificationRequest(
            identifier: "M7Archiver.operation.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}

/// Terminal badge drawn natively (DockProgress has no "completed" state).
/// Positioned to exactly overlay the running `.badge` style's circle
/// (bottom-right, `radius = size/4.8`, inset 4pt) so completion reads as a
/// seamless swap from the progress ring to the result symbol.
private struct DockProgressBadge: View {
    let outcome: DockProgressController.Outcome

    private var symbolName: String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.circle.fill"
        case .cancelled: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch outcome {
        case .success: return .green
        case .failure: return .red
        case .cancelled: return .yellow
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Mirror DockProgress.CanvasBadgeStyle geometry so the symbol
            // lands exactly where the progress ring was.
            let radius = geo.size.width / 4.8
            let centerX = geo.size.width - radius - 4
            let centerY = geo.size.height - radius - 4
            let symbolSize = radius * 1.5
            ZStack {
                // Same backdrop as the running badge.
                Circle()
                    .fill(Color(red: 0.94, green: 0.96, blue: 1.0))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: centerX, y: centerY)
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: symbolSize, height: symbolSize)
                    .position(x: centerX, y: centerY)
            }
        }
        .frame(width: 128, height: 128)
    }
}
