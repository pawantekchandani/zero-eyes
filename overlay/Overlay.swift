import Cocoa

// Floating controls for the shared Zero Eyes player. State is read straight
// from the same files the player uses, so the panel costs no processes while
// idle; button presses call ~/.local/bin/zero-eyes.

let playerPath = ("~/.local/bin/zero-eyes" as NSString).expandingTildeInPath
let stateDir = ("~/Library/Application Support/Zero Eyes" as NSString).expandingTildeInPath
func stateFile(_ name: String) -> String { (stateDir as NSString).appendingPathComponent(name) }

func pidAlive(_ path: String) -> Bool {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let pid = Int32(raw) else { return false }
    return kill(pid, 0) == 0
}

struct PlayerState {
    var state = "idle"
    var text = ""
    var origin = ""
    var index = 0
    var total = 0
    var queue = 0
    var rate = "+0%"
    var muted = false

    static func read() -> PlayerState {
        var result = PlayerState()
        let fm = FileManager.default

        result.queue = (try? fm.contentsOfDirectory(atPath: stateFile("queue")))?
            .filter { $0.hasSuffix(".json") }.count ?? 0

        if fm.fileExists(atPath: stateFile("paused")) {
            result.state = "paused"
        } else if pidAlive(stateFile("afplay.pid"))
                    || pidAlive(stateFile("worker.pid"))
                    || result.queue > 0 {
            result.state = "playing"
        }

        if let data = fm.contents(atPath: stateFile("now.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.text = object["text"] as? String ?? ""
            result.origin = object["origin"] as? String ?? ""
            result.index = object["index"] as? Int ?? 0
            result.total = object["total"] as? Int ?? 0
        }

        let config = ("~/.config/zero-eyes/config" as NSString).expandingTildeInPath
        if let contents = try? String(contentsOfFile: config, encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
                if String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces) == "RATE" {
                    result.rate = String(trimmed[trimmed.index(after: equals)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                if String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces) == "MUTED" {
                    let value = String(trimmed[trimmed.index(after: equals)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        .lowercased()
                    result.muted = ["true", "1", "yes"].contains(value)
                }
            }
        }
        return result
    }
}

func runPlayer(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: playerPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

final class OverlayPanel: NSPanel {
    // Keep keyboard focus where it is: buttons still receive mouse clicks.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var effectView: NSVisualEffectView!
    private var playButton: NSButton!
    private var muteButton: NSButton!
    private var collapseButton: NSButton!
    private var titleLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var rateLabel: NSTextField!
    private var timer: Timer?
    private var latest = PlayerState()
    private var moveObserver: NSObjectProtocol?
    private var expandedViews: [NSView] = []
    private var collapsed = UserDefaults.standard.bool(forKey: "overlayCollapsed")

    private let expandedSize = NSSize(width: 372, height: 88)
    private let collapsedSize = NSSize(width: 96, height: 40)
    private let playExpandedFrame = NSRect(x: 44, y: 52, width: 28, height: 26)
    private let collapseExpandedFrame = NSRect(x: 300, y: 52, width: 28, height: 26)
    // Top-right corner of the expanded bar; collapsing keeps it in place.
    private var expandedOrigin = NSPoint.zero
    private var layingOut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        refresh()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func makeButton(_ symbol: String, _ label: String, _ action: Selector,
                            frame: NSRect) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        button.frame = frame
        return button
    }

    private func buildPanel() {
        let width = expandedSize.width
        let height = expandedSize.height

        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1.5
        effect.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.65).cgColor
        panel.contentView = effect
        panel.setContentSize(NSSize(width: width, height: height))
        effect.frame = NSRect(x: 0, y: 0, width: width, height: height)
        effectView = effect

        // Fixed frames on purpose: Auto Layout inside a borderless NSPanel made
        // the window collapse to its minimum width the first time it was shown.
        let top: CGFloat = 52
        let previous = makeButton("backward.end.fill", "Previous audio",
                                  #selector(previousTapped), frame: NSRect(x: 12, y: top, width: 28, height: 26))
        playButton = makeButton("play.fill", "Play or pause",
                                #selector(playTapped), frame: playExpandedFrame)
        let stop = makeButton("stop.fill", "Stop",
                              #selector(stopTapped), frame: NSRect(x: 76, y: top, width: 28, height: 26))
        let next = makeButton("forward.end.fill", "Next audio",
                              #selector(nextTapped), frame: NSRect(x: 108, y: top, width: 28, height: 26))
        // Mute sits between the transport and the rate group: it silences output
        // while the queue keeps draining, so nothing piles up while not listening.
        muteButton = makeButton("speaker.slash.fill", "Mute Zero Eyes",
                                #selector(muteTapped), frame: NSRect(x: 148, y: top, width: 28, height: 26))
        let slower = makeButton("minus", "Slower speech",
                                #selector(slowerTapped), frame: NSRect(x: 188, y: top, width: 28, height: 26))
        let faster = makeButton("plus", "Faster speech",
                                #selector(fasterTapped), frame: NSRect(x: 268, y: top, width: 28, height: 26))
        collapseButton = makeButton("chevron.up", "Minimize",
                                    #selector(collapseTapped), frame: collapseExpandedFrame)
        collapseButton.contentTintColor = .secondaryLabelColor
        let close = makeButton("xmark", "Close overlay",
                               #selector(closeTapped), frame: NSRect(x: 332, y: top, width: 28, height: 26))
        close.contentTintColor = .secondaryLabelColor

        rateLabel = NSTextField(labelWithString: "+0%")
        rateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.alignment = .center
        rateLabel.toolTip = "Speech rate"
        rateLabel.frame = NSRect(x: 220, y: top + 4, width: 44, height: 18)

        titleLabel = NSTextField(labelWithString: "Ready")
        titleLabel.font = .systemFont(ofSize: 11.5)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.frame = NSRect(x: 14, y: 31, width: 344, height: 15)

        statusLabel = NSTextField(labelWithString: "Idle")
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.frame = NSRect(x: 14, y: 15, width: 344, height: 13)

        let views: [NSView] = [previous, playButton, stop, next, muteButton, slower, rateLabel, faster,
                               collapseButton, close, titleLabel, statusLabel]
        for view in views {
            effect.addSubview(view)
        }
        expandedViews = [previous, stop, next, muteButton, slower, rateLabel, faster, close,
                         titleLabel, statusLabel]

        if let saved = UserDefaults.standard.string(forKey: "overlayOrigin") {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                expandedOrigin = NSPoint(x: parts[0], y: parts[1])
            }
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            expandedOrigin = NSPoint(x: visible.maxX - width - 24,
                                     y: visible.maxY - height - 24)
        }

        clampOrigin()
        applyLayout()

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.layingOut, let panel = self.panel else { return }
            let frame = panel.frame
            if self.collapsed {
                self.expandedOrigin = NSPoint(x: frame.maxX - self.expandedSize.width,
                                              y: frame.maxY - self.expandedSize.height)
            } else {
                self.expandedOrigin = frame.origin
            }
            UserDefaults.standard.set(
                "\(self.expandedOrigin.x),\(self.expandedOrigin.y)", forKey: "overlayOrigin")
        }

        panel.orderFrontRegardless()
    }

    // A display can shrink or vanish between launches (mirroring, lid closed,
    // a projector). Keep the saved bar inside a visible screen instead of
    // restoring it off-screen where it cannot be reached.
    private func clampOrigin() {
        let bar = NSRect(origin: expandedOrigin, size: expandedSize)
        let screen = NSScreen.screens.first { $0.frame.intersects(bar) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        expandedOrigin.x = min(max(expandedOrigin.x, visible.minX),
                               max(visible.minX, visible.maxX - expandedSize.width))
        expandedOrigin.y = min(max(expandedOrigin.y, visible.minY),
                               max(visible.minY, visible.maxY - expandedSize.height))
    }

    // Draw either the full bar or the small pill. The top-right corner stays
    // put so the bar never walks across the screen when it shrinks.
    private func applyLayout() {
        layingOut = true
        defer { layingOut = false }

        let size = collapsed ? collapsedSize : expandedSize
        let origin: NSPoint
        if collapsed {
            origin = NSPoint(x: expandedOrigin.x + expandedSize.width - size.width,
                             y: expandedOrigin.y + expandedSize.height - size.height)
        } else {
            origin = expandedOrigin
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        effectView.frame = NSRect(origin: .zero, size: size)
        effectView.layer?.cornerRadius = collapsed ? min(18, size.height / 2) : 18

        for view in expandedViews {
            view.isHidden = collapsed
        }
        playButton.isHidden = false
        collapseButton.isHidden = false

        let symbol = collapsed ? "chevron.down" : "chevron.up"
        let label = collapsed ? "Expand" : "Minimize"
        collapseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        collapseButton.toolTip = label
        collapseButton.setAccessibilityLabel(label)

        if collapsed {
            playButton.frame = NSRect(x: 16, y: (size.height - 26) / 2, width: 28, height: 26)
            collapseButton.frame = NSRect(x: 52, y: (size.height - 26) / 2, width: 28, height: 26)
        } else {
            playButton.frame = playExpandedFrame
            collapseButton.frame = collapseExpandedFrame
        }
    }

    @objc private func collapseTapped() {
        collapsed.toggle()
        UserDefaults.standard.set(collapsed, forKey: "overlayCollapsed")
        applyLayout()
    }

    private func refresh() {
        let state = PlayerState.read()
        latest = state

        let playing = state.state == "playing"
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play")
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
        rateLabel.stringValue = state.rate

        let muteSymbol = state.muted ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let muteLabel = state.muted ? "Unmute Zero Eyes" : "Mute Zero Eyes"
        muteButton.image = NSImage(systemSymbolName: muteSymbol, accessibilityDescription: muteLabel)
        muteButton.contentTintColor = state.muted ? .systemOrange : .labelColor
        muteButton.toolTip = muteLabel
        muteButton.setAccessibilityLabel(muteLabel)

        if state.state == "idle" {
            titleLabel.stringValue = "Ready"
            statusLabel.stringValue = state.muted ? "Muted · idle" : "Idle"
        } else {
            let body = state.text.isEmpty ? "Loading…" : state.text
            // Lead with the app so it is clear which session is being read.
            titleLabel.stringValue = state.origin.isEmpty ? body : "\(state.origin) · \(body)"
            if state.state == "paused" {
                statusLabel.stringValue = "Paused"
            } else {
                var status = state.total > 0 ? "Answer \(state.index + 1) of \(state.total)" : "Playing"
                if state.queue > 0 { status += " · \(state.queue) queued" }
                if state.muted { status += " · muted, not speaking" }
                statusLabel.stringValue = status
            }
        }
    }

    private func act(_ arguments: [String]) {
        runPlayer(arguments)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.refresh() }
    }

    @objc private func playTapped() {
        act(latest.state == "idle" ? ["--replay"] : ["--pause"])
    }

    @objc private func stopTapped() {
        act(["--stop"])
    }

    @objc private func muteTapped() {
        act(["--mute"])
    }

    @objc private func nextTapped() {
        act(["--next"])
    }

    @objc private func previousTapped() {
        act(["--previous"])
    }

    @objc private func slowerTapped() {
        act(["--rate-down"])
    }

    @objc private func fasterTapped() {
        act(["--rate-up"])
    }

    @objc private func closeTapped() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
