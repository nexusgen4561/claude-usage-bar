// ClaudeUsageBar — a macOS menu bar widget for Claude usage limits.
//
// Data source: GET https://api.anthropic.com/api/oauth/usage — the same endpoint
// that powers `/usage` in Claude Code and the claude.ai settings/usage page.
//
// Two things matter for not getting rate limited:
//   1. Send `User-Agent: claude-code/<version>`. Without it the endpoint drops you
//      into an aggressively limited bucket and returns persistent 429s.
//   2. Do not poll faster than ~180s. That is the observed safe floor.
// Both are enforced below. The UI still ticks every second, because reset
// countdowns are computed locally from `resets_at` and need no network.

import AppKit
import Foundation

// MARK: - Tunables

let pollInterval: TimeInterval = 180      // safe floor — see note above
let maxBackoff: TimeInterval = 1800       // cap when the endpoint 429s
let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let settingsPage = URL(string: "https://claude.ai/settings/usage")!
let keychainService = "Claude Code-credentials"
let launchAgentLabel = "com.local.claudeusagebar"

let rowWidth: CGFloat = 320
let rowHeight: CGFloat = 52

// MARK: - Color

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
            green: CGFloat((v >> 8) & 0xff) / 255.0,
            blue: CGFloat(v & 0xff) / 255.0,
            alpha: 1.0)
}

/// Reserved status palette — good / warning / serious / critical.
/// Color never carries the meaning alone: every row also shows the number,
/// and the menu rows pair the color with a symbol.
enum Pressure {
    case good, warning, serious, critical

    static func of(_ percent: Double) -> Pressure {
        if percent >= 95 { return .critical }
        if percent >= 80 { return .serious }
        if percent >= 60 { return .warning }
        return .good
    }

    var color: NSColor {
        switch self {
        case .good:     return hex(0x0ca30c)
        case .warning:  return hex(0xfab219)
        case .serious:  return hex(0xec835a)
        case .critical: return hex(0xd03b3b)
        }
    }

    var symbol: String {
        switch self {
        case .good:     return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.circle.fill"
        case .serious:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - Model

struct UsageWindow {
    var kind: String
    var title: String
    var percent: Double
    var resetsAt: Date?
    var isActive: Bool
}

struct Snapshot {
    var windows: [UsageWindow]
    var fetchedAt: Date
}

enum FetchProblem: Error {
    case noCredentials
    case unauthorized
    case rateLimited
    case http(Int)
    case transport(String)

    var summary: String {
        switch self {
        case .noCredentials: return "Not signed in"
        case .unauthorized:  return "Sign-in expired"
        case .rateLimited:   return "Rate limited"
        case .http(let c):   return "HTTP \(c)"
        case .transport:     return "Offline"
        }
    }

    var detail: String {
        switch self {
        case .noCredentials:
            return "No Claude Code credentials found. Run `claude` in a terminal and sign in."
        case .unauthorized:
            return "The access token was rejected. Run `claude` in a terminal to refresh it."
        case .rateLimited:
            return "The usage endpoint returned 429. Backing off — showing the last known values."
        case .http(let code):
            return "The usage endpoint returned HTTP \(code)."
        case .transport(let message):
            return message
        }
    }
}

// MARK: - Formatting

func parseTimestamp(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: raw) { return date }

    // Some responses carry more fractional digits than the formatter accepts.
    if let dot = raw.firstIndex(of: ".") {
        let tail = raw[dot...]
        if let offset = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return plain.date(from: String(raw[raw.startIndex..<dot]) + String(raw[offset...]))
        }
    }
    return nil
}

func formatPercent(_ percent: Double) -> String {
    if percent > 0 && percent < 1 { return "<1%" }
    return "\(Int(percent.rounded()))%"
}

func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds <= 0 { return "now" }
    let total = Int(seconds)
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours) hr \(minutes) min" }
    if minutes > 0 { return "\(minutes) min \(secs) s" }
    return "\(secs) s"
}

func prettyTitle(kind: String, scope: String?) -> String {
    switch kind {
    case "session":        return "Current session"
    case "weekly_all":     return "Weekly · all models"
    case "weekly_opus":    return "Weekly · Opus"
    case "weekly_sonnet":  return "Weekly · Sonnet"
    case "weekly_cowork":  return "Weekly · Cowork"
    case "weekly_oauth_apps": return "Weekly · connected apps"
    default:
        let words = kind.replacingOccurrences(of: "_", with: " ")
        let titled = words.prefix(1).uppercased() + words.dropFirst()
        if let scope = scope, !scope.isEmpty { return "\(titled) · \(scope)" }
        return titled
    }
}

// MARK: - Credentials

/// Used when no local install is found. Any plausible version gets past the
/// endpoint's client check; reading the real one just keeps this honest as
/// Claude Code moves.
let fallbackClientVersion = "2.1.199"

func claudeClientVersion() -> String {
    var candidates = [
        "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/package.json",
        "/usr/local/lib/node_modules/@anthropic-ai/claude-code/package.json",
        ("~/.claude/local/node_modules/@anthropic-ai/claude-code/package.json" as NSString).expandingTildeInPath,
    ]
    candidates.append(contentsOf: editorExtensionManifests())

    for path in candidates {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { continue }
        return version
    }
    return fallbackClientVersion
}

/// `~/.vscode/extensions/anthropic.claude-code-<version>-<platform>/package.json`,
/// newest first. Covers developers who only ever installed the IDE extension.
func editorExtensionManifests() -> [String] {
    let roots = ["~/.vscode/extensions", "~/.vscode-insiders/extensions", "~/.cursor/extensions"]
        .map { ($0 as NSString).expandingTildeInPath }
    var manifests: [String] = []
    for root in roots {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        manifests += entries
            .filter { $0.hasPrefix("anthropic.claude-code-") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/package.json" }
    }
    return manifests
}

/// Reads the OAuth access token fresh on every poll, so a token that Claude Code
/// refreshes in the background is picked up without restarting this app.
func readAccessToken() -> String? {
    if let json = readKeychainJSON() ?? readCredentialsFileJSON(),
       let oauth = json["claudeAiOauth"] as? [String: Any],
       let token = oauth["accessToken"] as? String,
       !token.isEmpty {
        return token
    }
    return nil
}

func readKeychainJSON() -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func readCredentialsFileJSON() -> [String: Any]? {
    let path = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - Fetching

final class UsageFetcher {
    private let clientVersion = claudeClientVersion()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch(completion: @escaping (Result<Snapshot, FetchProblem>) -> Void) {
        guard let token = readAccessToken() else {
            DispatchQueue.main.async { completion(.failure(.noCredentials)) }
            return
        }

        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: request) { data, response, error in
            let outcome: Result<Snapshot, FetchProblem>
            if let error = error {
                outcome = .failure(.transport(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                switch http.statusCode {
                case 401, 403: outcome = .failure(.unauthorized)
                case 429:      outcome = .failure(.rateLimited)
                default:       outcome = .failure(.http(http.statusCode))
                }
            } else if let data = data, let snapshot = UsageFetcher.parse(data) {
                outcome = .success(snapshot)
            } else {
                outcome = .failure(.transport("Could not read the usage response."))
            }
            DispatchQueue.main.async { completion(outcome) }
        }.resume()
    }

    /// Prefers the generic `limits` array so new windows (Opus, Cowork, …) appear
    /// without a code change, and falls back to the older explicit fields.
    static func parse(_ data: Data) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var windows: [UsageWindow] = []

        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
                windows.append(UsageWindow(
                    kind: kind,
                    title: prettyTitle(kind: kind, scope: limit["scope"] as? String),
                    percent: percent,
                    resetsAt: (limit["resets_at"] as? String).flatMap(parseTimestamp),
                    isActive: (limit["is_active"] as? Bool) ?? false))
            }
        }

        if windows.isEmpty {
            let legacy: [(String, String)] = [
                ("five_hour", "session"),
                ("seven_day", "weekly_all"),
                ("seven_day_opus", "weekly_opus"),
                ("seven_day_sonnet", "weekly_sonnet"),
            ]
            for (field, kind) in legacy {
                guard let entry = root[field] as? [String: Any],
                      let percent = (entry["utilization"] as? NSNumber)?.doubleValue else { continue }
                windows.append(UsageWindow(
                    kind: kind,
                    title: prettyTitle(kind: kind, scope: nil),
                    percent: percent,
                    resetsAt: (entry["resets_at"] as? String).flatMap(parseTimestamp),
                    isActive: false))
            }
        }

        if let extra = root["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true,
           let percent = (extra["utilization"] as? NSNumber)?.doubleValue {
            windows.append(UsageWindow(
                kind: "extra_usage",
                title: "Extra usage credits",
                percent: percent,
                resetsAt: nil,
                isActive: false))
        }

        guard !windows.isEmpty else { return nil }
        return Snapshot(windows: windows, fetchedAt: Date())
    }
}

// MARK: - Views

/// A thin meter: recessive track, status-colored fill, 4px rounded ends,
/// anchored to the left baseline.
final class MeterView: NSView {
    var percent: Double = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = Pressure.good.color { didSet { needsDisplay = true } }

    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        let height: CGFloat = 6
        let radius: CGFloat = 3
        let track = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)

        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fraction = max(0, min(1, percent / 100))
        guard fraction > 0 else { return }
        let width = max(height, track.width * CGFloat(fraction))
        let fill = NSRect(x: track.minX, y: track.minY, width: width, height: height)
        fillColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

final class UsageRowView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let meter = MeterView()

    private var resetsAt: Date?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight))

        // Bottom-left origin: title row on top, meter beneath it, reset text last.
        icon.frame = NSRect(x: 14, y: 34, width: 12, height: 12)
        icon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.frame = NSRect(x: 32, y: 32, width: 170, height: 16)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        valueLabel.frame = NSRect(x: rowWidth - 76, y: 32, width: 62, height: 16)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = .labelColor

        meter.frame = NSRect(x: 32, y: 22, width: rowWidth - 46, height: 8)

        resetLabel.frame = NSRect(x: 32, y: 4, width: rowWidth - 46, height: 14)
        resetLabel.font = .systemFont(ofSize: 10.5)
        resetLabel.textColor = .secondaryLabelColor

        for view in [icon, titleLabel, valueLabel, meter, resetLabel] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ window: UsageWindow) {
        let pressure = Pressure.of(window.percent)
        titleLabel.stringValue = window.title
        valueLabel.stringValue = formatPercent(window.percent)
        meter.percent = window.percent
        meter.fillColor = pressure.color
        resetsAt = window.resetsAt

        let image = NSImage(systemSymbolName: pressure.symbol, accessibilityDescription: nil)
        icon.image = image
        icon.contentTintColor = pressure.color

        tick()
    }

    /// Recomputed locally every second — no network involved.
    func tick() {
        guard let resetsAt = resetsAt else {
            resetLabel.stringValue = "No reset window"
            return
        }
        let remaining = resetsAt.timeIntervalSinceNow
        if remaining <= 0 {
            resetLabel.stringValue = "Reset — refreshing shortly"
        } else {
            resetLabel.stringValue = "Resets in \(formatDuration(remaining))"
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let fetcher = UsageFetcher()

    private var snapshot: Snapshot?
    private var problem: FetchProblem?
    private var rowViews: [UsageRowView] = []

    private var nextPollAt = Date()
    private var currentInterval = pollInterval
    private var inFlight = false
    private var menuIsOpen = false
    private var statusFooter: NSMenuItem?
    private var launchItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.needle",
                                   accessibilityDescription: "Claude usage")
                ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Claude usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }

        menu.delegate = self
        statusItem.menu = menu
        renderTitle()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        poll()
    }

    // MARK: Polling

    private func tick() {
        if Date() >= nextPollAt { poll() }
        if menuIsOpen {
            rowViews.forEach { $0.tick() }
            updateFooter()
        }
        renderTitle()
    }

    private func poll() {
        guard !inFlight else { return }
        inFlight = true
        nextPollAt = Date().addingTimeInterval(currentInterval)

        fetcher.fetch { [weak self] result in
            guard let self = self else { return }
            self.inFlight = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.problem = nil
                self.currentInterval = pollInterval          // recovered — back to the floor
            case .failure(let problem):
                self.problem = problem
                if case .rateLimited = problem {
                    self.currentInterval = min(self.currentInterval * 2, maxBackoff)
                }
            }
            self.nextPollAt = Date().addingTimeInterval(self.currentInterval)
            self.renderTitle()
            if self.menuIsOpen { self.rebuildMenu() }
        }
    }

    private var isStale: Bool {
        guard let snapshot = snapshot else { return true }
        return Date().timeIntervalSince(snapshot.fetchedAt) > currentInterval * 2
    }

    // MARK: Menu bar title

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        guard let snapshot = snapshot else {
            let text = problem.map { "· \($0.summary)" } ?? "· …"
            button.attributedTitle = NSAttributedString(string: " \(text)", attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ])
            button.toolTip = problem?.detail ?? "Loading Claude usage…"
            return
        }

        let session = snapshot.windows.first { $0.kind == "session" }
        let weekly = snapshot.windows.first { $0.kind == "weekly_all" }
        let shown = [session, weekly].compactMap { $0 }
        let parts = shown.isEmpty ? Array(snapshot.windows.prefix(2)) : shown

        let title = NSMutableAttributedString(string: " ")
        for (index, window) in parts.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " · ", attributes: [
                    .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
            }
            let color = isStale ? NSColor.tertiaryLabelColor : Pressure.of(window.percent).color
            title.append(NSAttributedString(string: formatPercent(window.percent), attributes: [
                .font: font, .foregroundColor: color,
            ]))
        }
        button.attributedTitle = title

        let lines = parts.map { window -> String in
            let reset = window.resetsAt.map { " · resets in \(formatDuration($0.timeIntervalSinceNow))" } ?? ""
            return "\(window.title): \(formatPercent(window.percent))\(reset)"
        }
        button.toolTip = lines.joined(separator: "\n") + (isStale ? "\n(showing last known values)" : "")
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        rowViews.removeAll()

        let header = NSMenuItem(title: "Your usage limits", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let snapshot = snapshot {
            for window in snapshot.windows {
                let row = UsageRowView()
                row.apply(window)
                rowViews.append(row)

                let item = NSMenuItem()
                item.view = row
                menu.addItem(item)
            }
        }

        if let problem = problem {
            menu.addItem(.separator())
            let item = NSMenuItem(title: problem.summary, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = problem.detail
            menu.addItem(item)
            for line in wrap(problem.detail, width: 46) {
                let detail = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                detail.isEnabled = false
                detail.attributedTitle = NSAttributedString(string: line, attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                menu.addItem(detail)
            }
        }

        menu.addItem(.separator())

        let footer = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        footer.isEnabled = false
        menu.addItem(footer)
        statusFooter = footer
        updateFooter()

        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let open = NSMenuItem(title: "Open usage settings…", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let launch = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = launchAgentInstalled() ? .on : .off
        menu.addItem(launch)
        launchItem = launch

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func updateFooter() {
        guard let footer = statusFooter else { return }
        let age = snapshot.map { formatDuration(Date().timeIntervalSince($0.fetchedAt)) + " ago" } ?? "never"
        let next = formatDuration(nextPollAt.timeIntervalSinceNow)
        let backoff = currentInterval > pollInterval ? " · backing off" : ""
        let text = "Updated \(age) · next check in \(next)\(backoff)"
        footer.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty {
                line = String(word)
            } else if line.count + word.count + 1 <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    // MARK: Actions

    @objc private func refreshNow() {
        // Manual refreshes bypass the backoff clock but still go through the
        // in-flight guard, so a held-down shortcut cannot spam the endpoint.
        nextPollAt = Date()
        poll()
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(settingsPage)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Launch at login

    private var launchAgentPath: String {
        ("~/Library/LaunchAgents/\(launchAgentLabel).plist" as NSString).expandingTildeInPath
    }

    private func launchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func toggleLaunchAtLogin() {
        let path = launchAgentPath
        if launchAgentInstalled() {
            try? FileManager.default.removeItem(atPath: path)
            launchItem?.state = .off
            return
        }

        let executable = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: URL(fileURLWithPath: path))
            launchItem?.state = .on
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not enable launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
