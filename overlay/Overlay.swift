import AVFoundation
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
    var volume = 100
    var muted = false
    var part = 0
    var parts = 0

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

        // Which part (sentence group) of the answer is playing, for the slider.
        if result.state != "idle",
           let data = fm.contents(atPath: stateFile("part.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result.part = object["part"] as? Int ?? 0
            result.parts = object["parts"] as? Int ?? 0
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
                if String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces) == "APP_VOLUME" {
                    let raw = String(trimmed[trimmed.index(after: equals)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'%"))
                    if let parsed = Int(raw) {
                        result.volume = max(0, min(100, parsed))
                    }
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

// Run the player and hand back what it printed, off the main thread.
func runPlayerOutput(_ arguments: [String], completion: @escaping (Int32, Data) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: playerPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var data = Data()
        var status: Int32 = 1
        if (try? process.run()) != nil {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            status = process.terminationStatus
        }
        DispatchQueue.main.async { completion(status, data) }
    }
}

// Push-to-talk reply. The overlay records and pastes, so Microphone and
// Accessibility are asked for once, for this app. The player stops speech,
// checks Whisper and transcribes (zero-eyes --reply-begin / --reply-transcribe).
final class ReplyRecorder {
    enum Phase { case idle, starting, recording, transcribing }

    private(set) var phase = Phase.idle
    var onChange: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var silenceLimit: Double = 2
    private var heardVoice = false
    private var lastVoice = Date()
    private var startedAt = Date()
    private var askedForAccessibility = false

    private let wavPath = stateFile("reply.wav")
    private let voiceLevel: Float = -40      // dBFS; quieter counts as silence
    private let maxSeconds: Double = 120

    func toggle() {
        switch phase {
        case .idle: begin()
        case .recording: finish()
        case .starting, .transcribing: break
        }
    }

    private func setPhase(_ next: Phase) {
        phase = next
        onChange?()
    }

    private func say(_ text: String) {
        runPlayer([text])
    }

    private func begin() {
        setPhase(.starting)
        runPlayerOutput(["--reply-begin"]) { [weak self] status, data in
            guard let self else { return }
            guard status == 0 else { self.setPhase(.idle); return }
            let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            self.silenceLimit = settings?["silence"] as? Double ?? 2
            self.withMicrophone { granted in
                if granted {
                    self.startRecording()
                } else {
                    self.setPhase(.idle)
                    self.say("Microphone access is off for Zero Eyes Overlay. "
                             + "Turn it on in System Settings, Privacy and Security, Microphone.")
                }
            }
        }
    }

    private func withMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    private func startRecording() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,           // what Whisper expects
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(atPath: wavPath)
        guard let recorder = try? AVAudioRecorder(url: URL(fileURLWithPath: wavPath), settings: settings),
              recorder.record() else {
            setPhase(.idle)
            say("The microphone could not be started.")
            return
        }
        recorder.isMeteringEnabled = true
        self.recorder = recorder
        heardVoice = false
        startedAt = Date()
        lastVoice = startedAt
        NSSound(named: "Tink")?.play()
        setPhase(.recording)

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkLevel() }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    // Stop on its own after the user stops talking, or at the time limit.
    private func checkLevel() {
        guard let recorder else { return }
        recorder.updateMeters()
        let now = Date()
        if recorder.averagePower(forChannel: 0) > voiceLevel {
            heardVoice = true
            lastVoice = now
        }
        let quiet = silenceLimit > 0 && heardVoice && now.timeIntervalSince(lastVoice) >= silenceLimit
        if quiet || now.timeIntervalSince(startedAt) >= maxSeconds {
            finish()
        }
    }

    private func finish() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        NSSound(named: "Pop")?.play()

        // Whisper invents words ("you") for silence, so a recording with no
        // voice in it is not transcribed at all.
        guard heardVoice else {
            try? FileManager.default.removeItem(atPath: wavPath)
            setPhase(.idle)
            say("I did not catch that.")
            return
        }
        setPhase(.transcribing)
        runPlayerOutput(["--reply-transcribe", wavPath]) { [weak self] _, data in
            guard let self else { return }
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let text = result?["text"] as? String ?? ""
            if !text.isEmpty {
                self.deliver(text, submit: result?["submit"] as? Bool ?? false)
            }
            self.setPhase(.idle)
        }
    }

    // Paste into the frontmost app with Cmd+V and put the old clipboard back.
    // Without Accessibility the text stays on the clipboard for the user.
    private func deliver(_ text: String, submit: Bool) {
        let pasteboard = NSPasteboard.general
        guard CGPreflightPostEventAccess() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if !askedForAccessibility {
                askedForAccessibility = true
                CGRequestPostEventAccess()
            }
            say("Reply copied. Press Command V.")
            return
        }

        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        }
        press(0x09, .maskCommand)                                   // V
        if submit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { press(0x24, []) }  // Return
        }
        // Give the app time to read the clipboard; skip the restore if
        // something else has been copied since.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}

final class OverlayPanel: NSPanel {
    // Keep keyboard focus where it is: buttons still receive mouse clicks.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Draws a colored active fill on the left side of the track even in a
// non-activating HUD panel (where AppKit otherwise dims slider fills to gray).
final class TintedSliderCell: NSSliderCell {
    var fillColor: NSColor = .systemBlue

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let barHeight: CGFloat = 3.5
        let bar = NSRect(
            x: rect.minX,
            y: rect.midY - barHeight / 2,
            width: rect.width,
            height: barHeight
        )
        let radius = barHeight / 2
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        let span = maxValue - minValue
        let ratio = span > 0 ? CGFloat((doubleValue - minValue) / span) : 0
        let clamped = min(max(ratio, 0), 1)
        if clamped > 0 {
            let filled = NSRect(x: bar.minX, y: bar.minY, width: bar.width * clamped, height: bar.height)
            fillColor.withAlphaComponent(isEnabled ? 0.9 : 0.35).setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }
    }
}

// A slider that knows when the user holds it, so the half-second refresh does
// not pull the knob back while it is being dragged.
final class SeekSlider: NSSlider {
    private(set) var dragging = false
    override func mouseDown(with event: NSEvent) {
        dragging = true
        super.mouseDown(with: event)  // returns when the mouse is released
        dragging = false
    }
}

// Continuous drag readout for app volume; commits once when released.
final class VolumeSlider: NSSlider {
    private(set) var dragging = false
    var onRelease: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        dragging = true
        super.mouseDown(with: event)
        dragging = false
        onRelease?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var effectView: NSVisualEffectView!
    private var playButton: NSButton!
    private var muteButton: NSButton!
    private var micButton: NSButton!
    private let reply = ReplyRecorder()
    private var replySignal: DispatchSourceSignal?
    private var collapseButton: NSButton!
    private var stopButton: NSButton!
    private var closeButton: NSButton!
    private var logoView: NSImageView!
    private var titleLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var rateLabel: NSTextField!
    private var seekSlider: SeekSlider!
    private var volumeIcon: NSImageView!
    private var volumeSlider: VolumeSlider!
    private var volumeLabel: NSTextField!
    private var timer: Timer?
    private var latest = PlayerState()
    private var moveObserver: NSObjectProtocol?
    private var expandedViews: [NSView] = []
    private var collapsed = UserDefaults.standard.bool(forKey: "overlayCollapsed")
    private var permanentlyMinimized = UserDefaults.standard.bool(forKey: "overlayPermanentlyMinimized")

    private let expandedSize = NSSize(width: 436, height: 128)
    private let collapsedSize = NSSize(width: 96, height: 40)
    private let playExpandedFrame = NSRect(x: 44, y: 92, width: 28, height: 26)
    private let collapseExpandedFrame = NSRect(x: 364, y: 92, width: 28, height: 26)
    // Top-right corner of the expanded bar; collapsing keeps it in place.
    private var expandedOrigin = NSPoint.zero
    private var layingOut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        refresh()

        // `zero-eyes --reply` (the Zero Eyes Reply service) sends SIGUSR1 to
        // the pid written here: one signal toggles recording.
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.reply.toggle() }
        source.resume()
        replySignal = source
        reply.onChange = { [weak self] in self?.refresh() }
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? String(getpid()).write(toFile: stateFile("overlay.pid"), atomically: true, encoding: .utf8)

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

    private func styleButton(_ button: NSButton, accent: NSColor, active: Bool = false,
                             tint: NSColor? = nil, fillAlpha: CGFloat? = nil) {
        button.contentTintColor = tint ?? (active ? accent : accent.withAlphaComponent(0.9))
        button.layer?.borderColor = accent.withAlphaComponent(active ? 0.85 : 0.45).cgColor
        let bg = fillAlpha ?? (active ? 0.18 : 0.07)
        button.layer?.backgroundColor = accent.withAlphaComponent(bg).cgColor
    }

    private func buildPanel() {
        let width = expandedSize.width
        let height = expandedSize.height

        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.borderless, .nonactivatingPanel, .miniaturizable],
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
        let top: CGFloat = 92
        let previous = makeButton("backward.end.fill", "Previous audio",
                                  #selector(previousTapped), frame: NSRect(x: 12, y: top, width: 28, height: 26))
        styleButton(previous, accent: .systemBlue)
        playButton = makeButton("play.fill", "Play or pause",
                                #selector(playTapped), frame: playExpandedFrame)
        styleButton(playButton, accent: .systemGreen)
        stopButton = makeButton("stop.fill", "Stop",
                                #selector(stopTapped), frame: NSRect(x: 76, y: top, width: 28, height: 26))
        styleButton(stopButton, accent: .systemRed, tint: .systemRed.withAlphaComponent(0.7))
        let next = makeButton("forward.end.fill", "Next audio",
                              #selector(nextTapped), frame: NSRect(x: 108, y: top, width: 28, height: 26))
        styleButton(next, accent: .systemBlue)
        // Mute sits between the transport and the rate group: it silences output
        // while the queue keeps draining, so nothing piles up while not listening.
        muteButton = makeButton("speaker.slash.fill", "Mute Zero Eyes",
                                #selector(muteTapped), frame: NSRect(x: 148, y: top, width: 28, height: 26))
        styleButton(muteButton, accent: .systemGray, tint: .secondaryLabelColor)
        let slower = makeButton("minus", "Slower speech",
                                #selector(slowerTapped), frame: NSRect(x: 188, y: top, width: 28, height: 26))
        styleButton(slower, accent: .systemCyan)
        let faster = makeButton("plus", "Faster speech",
                                #selector(fasterTapped), frame: NSRect(x: 268, y: top, width: 28, height: 26))
        styleButton(faster, accent: .systemCyan)
        collapseButton = makeButton("chevron.up", "Minimize",
                                    #selector(collapseTapped), frame: collapseExpandedFrame)
        styleButton(collapseButton, accent: .systemGray, tint: .secondaryLabelColor)
        micButton = makeButton("mic.fill", "Reply by voice",
                               #selector(micTapped), frame: NSRect(x: 300, y: top, width: 28, height: 26))
        styleButton(micButton, accent: .systemPurple)
        let dock = makeButton("dock.arrow.down.rectangle", "Send to Dock",
                              #selector(dockTapped), frame: NSRect(x: 332, y: top, width: 28, height: 26))
        styleButton(dock, accent: .systemGray, tint: .secondaryLabelColor)
        closeButton = makeButton("xmark", closeToolTip(),
                                 #selector(closeTapped), frame: NSRect(x: 396, y: top, width: 28, height: 26))
        styleCloseButton()

        rateLabel = NSTextField(labelWithString: "+0%")
        rateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.alignment = .center
        rateLabel.toolTip = "Speech rate"
        rateLabel.frame = NSRect(x: 220, y: top + 4, width: 44, height: 18)

        // The mark sits where the text line starts, so the bar carries the
        // app's identity even though the app itself has no Dock icon.
        let mark = Bundle.main.path(forResource: "MarkTemplate", ofType: "png")
            .flatMap { NSImage(contentsOfFile: $0) } ?? NSApp.applicationIconImage
        mark?.isTemplate = true
        logoView = NSImageView(frame: NSRect(x: 14, y: 69, width: 15, height: 15))
        logoView.image = mark
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.setAccessibilityLabel("Zero Eyes")

        titleLabel = NSTextField(labelWithString: "Ready")
        titleLabel.font = .systemFont(ofSize: 11.5)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.frame = NSRect(x: 35, y: 71, width: 387, height: 15)

        statusLabel = NSTextField(labelWithString: "Idle")
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.frame = NSRect(x: 14, y: 55, width: 408, height: 13)

        // One step per part (one or two sentences). Dragging jumps playback
        // to that part when the mouse is released.
        seekSlider = SeekSlider()
        let seekCell = TintedSliderCell()
        seekCell.fillColor = .systemBlue
        seekSlider.cell = seekCell
        seekSlider.minValue = 0
        seekSlider.maxValue = 1
        seekSlider.doubleValue = 0
        seekSlider.target = self
        seekSlider.action = #selector(seekMoved)
        seekSlider.frame = NSRect(x: 14, y: 32, width: 408, height: 18)
        seekSlider.controlSize = .small
        seekSlider.isContinuous = false
        seekSlider.allowsTickMarkValuesOnly = true
        seekSlider.isEnabled = false
        seekSlider.toolTip = "Drag to jump forward or back by sentence"
        seekSlider.setAccessibilityLabel("Position in answer")

        // Per-app playback volume (0-100%), applied only to Zero Eyes audio.
        volumeIcon = NSImageView(frame: NSRect(x: 14, y: 10, width: 15, height: 14))
        volumeIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "App volume")
        volumeIcon.contentTintColor = .secondaryLabelColor
        volumeIcon.imageScaling = .scaleProportionallyDown
        volumeIcon.toolTip = "Zero Eyes app volume (does not change Mac volume)"

        volumeSlider = VolumeSlider()
        let volumeCell = TintedSliderCell()
        volumeCell.fillColor = .systemTeal
        volumeSlider.cell = volumeCell
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = 100
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeMoved)
        volumeSlider.frame = NSRect(x: 35, y: 8, width: 347, height: 18)
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.toolTip = "Zero Eyes app volume (does not change Mac volume)"
        volumeSlider.setAccessibilityLabel("Zero Eyes app volume")
        volumeSlider.onRelease = { [weak self] in self?.commitVolume() }

        volumeLabel = NSTextField(labelWithString: "100%")
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.alignment = .right
        volumeLabel.toolTip = "Zero Eyes app volume"
        volumeLabel.frame = NSRect(x: 386, y: 10, width: 36, height: 14)

        let views: [NSView] = [previous, playButton, stopButton, next, muteButton, slower, rateLabel, faster,
                               micButton, collapseButton, dock, closeButton, logoView, titleLabel,
                               statusLabel, seekSlider, volumeIcon, volumeSlider, volumeLabel]
        for view in views {
            effect.addSubview(view)
        }
        expandedViews = [previous, stopButton, next, muteButton, slower, rateLabel, faster, micButton, dock,
                         closeButton, logoView, titleLabel, statusLabel, seekSlider,
                         volumeIcon, volumeSlider, volumeLabel]

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

        if permanentlyMinimized {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
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
        guard panel.isVisible || reply.phase != .idle else { return }
        render(PlayerState.read())
    }

    private func updateVolumeIcon(_ volume: Int, muted: Bool) {
        let symbol: String
        if muted || volume == 0 {
            symbol = "speaker.slash.fill"
        } else if volume < 50 {
            symbol = "speaker.wave.1.fill"
        } else {
            symbol = "speaker.wave.2.fill"
        }
        let accent: NSColor
        if muted {
            accent = .systemOrange
        } else if volume == 0 {
            accent = .tertiaryLabelColor
        } else {
            accent = .systemTeal
        }
        volumeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "App volume")
        volumeIcon.contentTintColor = accent
        if let cell = volumeSlider.cell as? TintedSliderCell {
            cell.fillColor = muted ? .systemOrange : (volume == 0 ? .systemGray : .systemTeal)
            volumeSlider.needsDisplay = true
        }
        volumeLabel.textColor = muted ? .systemOrange : (volume == 0 ? .tertiaryLabelColor : .systemTeal)
    }

    private func render(_ state: PlayerState) {
        latest = state

        let playing = state.state == "playing"
        let paused = state.state == "paused"
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play")
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
        if playing {
            styleButton(playButton, accent: .systemGreen, active: true)
        } else if paused {
            styleButton(playButton, accent: .systemYellow, active: true)
        } else {
            styleButton(playButton, accent: .systemGreen, active: false)
        }
        styleButton(stopButton, accent: .systemRed, active: playing || paused,
                    tint: (playing || paused) ? .systemRed : .systemRed.withAlphaComponent(0.65))
        rateLabel.stringValue = state.rate
        rateLabel.textColor = state.rate == "+0%" ? .secondaryLabelColor : .systemCyan

        let muteSymbol = state.muted ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let muteLabel = state.muted ? "Unmute Zero Eyes" : "Mute Zero Eyes"
        muteButton.image = NSImage(systemSymbolName: muteSymbol, accessibilityDescription: muteLabel)
        if state.muted {
            styleButton(muteButton, accent: .systemOrange, active: true)
        } else {
            styleButton(muteButton, accent: .systemGray, active: false, tint: .secondaryLabelColor)
        }
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
                if state.parts > 1 { status += " · part \(state.part + 1) of \(state.parts)" }
                if state.muted { status += " · muted, not speaking" }
                statusLabel.stringValue = status
            }
        }

        if !seekSlider.dragging {
            let usable = state.parts > 1
            seekSlider.isEnabled = usable
            seekSlider.maxValue = Double(max(1, state.parts - 1))
            seekSlider.numberOfTickMarks = usable ? state.parts : 0
            seekSlider.integerValue = usable ? state.part : 0
        }

        if !volumeSlider.dragging {
            volumeSlider.integerValue = state.volume
            volumeLabel.stringValue = "\(state.volume)%"
            updateVolumeIcon(state.volume, muted: state.muted)
        }

        let replying = reply.phase != .idle
        switch reply.phase {
        case .recording:
            styleButton(micButton, accent: .systemRed, active: true)
        case .transcribing:
            styleButton(micButton, accent: .systemPurple, active: true)
        default:
            styleButton(micButton, accent: .systemPurple, active: false)
        }
        let micLabel = reply.phase == .recording ? "Stop and send reply" : "Reply by voice"
        micButton.toolTip = micLabel
        micButton.setAccessibilityLabel(micLabel)
        switch reply.phase {
        case .recording: statusLabel.stringValue = "Listening… press again to send"
        case .transcribing: statusLabel.stringValue = "Transcribing…"
        default: break
        }
        if replying && state.state == "idle" { titleLabel.stringValue = "Reply" }
    }

    // Show the expected result at once; the next file read confirms it.
    private func act(_ arguments: [String], expect: ((inout PlayerState) -> Void)? = nil) {
        runPlayer(arguments)
        if let expect = expect {
            var state = latest
            expect(&state)
            render(state)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }

    private func expectLoading(_ state: inout PlayerState) {
        state.state = "playing"
        state.text = ""
    }

    @objc private func playTapped() {
        switch latest.state {
        case "idle": act(["--replay"], expect: expectLoading)
        case "paused": act(["--pause"]) { $0.state = "playing" }
        default: act(["--pause"]) { $0.state = "paused" }
        }
    }

    @objc private func stopTapped() {
        act(["--stop"]) { $0.state = "idle"; $0.queue = 0 }
    }

    @objc private func muteTapped() {
        act(["--mute"])
    }

    @objc private func micTapped() {
        reply.toggle()
    }

    @objc private func nextTapped() {
        act(["--next"], expect: expectLoading)
    }

    @objc private func previousTapped() {
        act(["--previous"], expect: expectLoading)
    }

    @objc private func seekMoved() {
        let target = seekSlider.integerValue
        guard latest.parts > 1, target != latest.part else { return }
        act(["--seek", String(target)]) { $0.part = target }
    }

    @objc private func slowerTapped() {
        act(["--rate-down"])
    }

    @objc private func fasterTapped() {
        act(["--rate-up"])
    }

    @objc private func volumeMoved() {
        let val = max(0, min(100, volumeSlider.integerValue))
        volumeLabel.stringValue = "\(val)%"
        updateVolumeIcon(val, muted: latest.muted)
        if !volumeSlider.dragging {
            commitVolume()
        }
    }

    private func commitVolume() {
        let target = max(0, min(100, volumeSlider.integerValue))
        guard target != latest.volume else { return }
        act(["--volume", String(target)]) { $0.volume = target }
    }

    private func closeToolTip() -> String {
        permanentlyMinimized
            ? "Close or minimize options (running permanently minimized)"
            : "Close or minimize options"
    }

    private func styleCloseButton() {
        if permanentlyMinimized {
            styleButton(closeButton, accent: .systemIndigo, active: true)
        } else {
            styleButton(closeButton, accent: .systemRed, active: false,
                        tint: .systemRed.withAlphaComponent(0.8))
        }
    }

    // Minimize into the Dock; clicking the Dock icon brings the bar back.
    @objc private func dockTapped() {
        panel.miniaturize(nil)
        if !panel.isMiniaturized { panel.orderOut(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        render(PlayerState.read())
        panel.orderFrontRegardless()
        return true
    }

    @objc private func togglePermanentlyMinimized() {
        permanentlyMinimized.toggle()
        UserDefaults.standard.set(permanentlyMinimized, forKey: "overlayPermanentlyMinimized")
        closeButton.toolTip = closeToolTip()
        styleCloseButton()
        if permanentlyMinimized {
            dockTapped()
        }
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    @objc private func closeTapped() {
        let menu = NSMenu()
        let permItem = NSMenuItem(
            title: "Run permanently minimized",
            action: #selector(togglePermanentlyMinimized),
            keyEquivalent: ""
        )
        permItem.target = self
        permItem.state = permanentlyMinimized ? .on : .off
        menu.addItem(permItem)

        let dockItem = NSMenuItem(
            title: "Minimize to Dock now",
            action: #selector(dockTapped),
            keyEquivalent: ""
        )
        dockItem.target = self
        menu.addItem(dockItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Close overlay",
            action: #selector(quitTapped),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        let y = closeButton.isFlipped ? closeButton.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: closeButton)
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(atPath: stateFile("overlay.pid"))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
