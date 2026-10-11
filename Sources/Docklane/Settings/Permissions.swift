import AppKit
import Observation
import DocklaneCore
import SwiftUI

/// The two permissions Docklane needs, and where to grant them.
@MainActor
enum Permissions {
    /// Why each permission is needed, shown next to it (welcome window and Settings).
    static let accessibilityPurpose: LocalizedStringKey =
        "Finds your windows, brings the one you choose to the front and arranges them. The ⌘Tab window switcher also needs it."
    static let screenRecordingPurpose: LocalizedStringKey =
        "Shows previews and titles of your windows. Docklane records no sound; previews are never saved or sent anywhere."

    static var accessibility: Bool { AccessibilityInspector.isTrusted }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var allGranted: Bool { accessibility && screenRecording }

    /// Asks for whatever is missing without opening System Settings. macOS shows its own
    /// prompts and adds Docklane to both lists in Privacy & Security, so the user only has to
    /// switch it on.
    static func promptForMissing() {
        if !accessibility {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !screenRecording {
            CGRequestScreenCaptureAccess()
        }
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary // kAXTrustedCheckOptionPrompt
        AXIsProcessTrustedWithOptions(options)
        openPrivacyPane("Privacy_Accessibility")
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Watches the permissions while Docklane runs: they can be turned off in System Settings or
/// reset by a macOS update. Accessibility changes arrive as a system notification; Screen
/// Recording is checked on wake and once a minute (a cheap local call).
@MainActor
@Observable
final class PermissionMonitor {
    static let shared = PermissionMonitor()

    private(set) var state = PermissionState(accessibility: Permissions.accessibility,
                                             screenRecording: Permissions.screenRecording)
    /// Screen Recording came back while Docklane was running; it takes effect after a restart.
    private(set) var restartSuggested = false
    @ObservationIgnored var onChange: ((PermissionState.Reaction) -> Void)?
    @ObservationIgnored private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust value updates a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.check() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check() {
        let new = PermissionState(accessibility: Permissions.accessibility, screenRecording: Permissions.screenRecording)
        guard new != state else { return }
        let reaction = PermissionState.reaction(from: state, to: new)
        state = new
        if reaction.suggestRestart { restartSuggested = true }
        onChange?(reaction)
    }
}

/// What is off and what that means, with a way to fix it; shown in the menu bar popover.
struct PermissionWarning: View {
    private var monitor: PermissionMonitor { .shared }

    var body: some View {
        let state = monitor.state
        if !state.allGranted || monitor.restartSuggested {
            VStack(alignment: .leading, spacing: 8) {
                if !state.allGranted {
                    Label("A permission Docklane needs is off", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if !state.accessibility {
                    row("Without Accessibility, Docklane can't switch to or arrange windows, and ⌘Tab goes back to the macOS switcher.",
                        action: Permissions.requestAccessibility)
                }
                if !state.screenRecording {
                    row("Without Screen Recording, previews and window titles stop updating and windows on other desktops can't be shown.",
                        action: Permissions.requestScreenRecording)
                }
                if state.screenRecording && monitor.restartSuggested {
                    HStack {
                        Text("Restart Docklane to finish turning on Screen Recording.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Restart Docklane", action: Relauncher.relaunch)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.orange.opacity(0.12)))
        }
    }

    private func row(_ text: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Settings", action: action)
        }
    }
}

/// First-run window. Without it Docklane would wait silently for its permissions.
@MainActor
final class PermissionsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.title = "Docklane"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PermissionsView())
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }
}

struct PermissionsView: View {
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording
    @State private var askedForScreenRecording = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Docklane").font(.title2.bold())
                    Text("Every open window, at a glance.").foregroundStyle(.secondary)
                }
            }
            Text("Docklane needs two permissions. Grant them in System Settings → Privacy & Security; Docklane starts on its own once both are on.")
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                title: "Accessibility",
                detail: Permissions.accessibilityPurpose,
                granted: accessibility,
                action: Permissions.requestAccessibility
            )
            PermissionRow(
                title: "Screen & System Audio Recording",
                detail: Permissions.screenRecordingPurpose,
                granted: screenRecording
            ) {
                askedForScreenRecording = true
                Permissions.requestScreenRecording()
            }

            if askedForScreenRecording && !screenRecording {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                    Text("Screen Recording takes effect after Docklane restarts.")
                        .font(.callout)
                    Spacer()
                    Button("Restart Docklane", action: Relauncher.relaunch)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 500)
        .onReceive(timer) { _ in
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
        }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Text("Granted").foregroundStyle(.green)
            } else {
                Button("Open Settings", action: action)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
    }
}
