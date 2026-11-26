import AVFoundation
import Foundation

// Persistent per-answer audio player for Zero Eyes. Keeping one AVAudioEngine
// open across all parts avoids afplay's ~0.9s CoreAudio setup/teardown gap, and
// trimming leading/trailing silence baked into TTS clips (e.g. ~0.9s in Edge
// MP3s) lets Python enforce a true 0.2s gap between spoken parts.
// Protocol: one "<volume_0_to_1>\t<file_path>" line per part on stdin; prints
// "done" (or "err") on stdout when playback finishes.
// Signals: SIGUSR1 pauses, SIGUSR2 resumes, SIGKILL stops immediately.

setbuf(stdout, nil)

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)

let queue = DispatchQueue(label: "local.zeroeyes.audio")
var paused = false
var currentFormat: AVAudioFormat?

signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)

let pauseSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
pauseSource.setEventHandler {
    paused = true
    player.pause()
}
pauseSource.resume()

let resumeSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: queue)
resumeSource.setEventHandler {
    paused = false
    if engine.isRunning {
        player.play()
    }
}
resumeSource.resume()

// Trim leading/trailing silence down to small breath margins so the caller's
// inter-part sleep defines the real audible pause.
func trimmedBuffer(from file: AVAudioFile) -> AVAudioPCMBuffer? {
    let totalFrames = AVAudioFrameCount(file.length)
    let format = file.processingFormat
    guard totalFrames > 0, format.commonFormat == .pcmFormatFloat32,
          totalFrames <= AVAudioFrameCount(format.sampleRate * 120),
          let full = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
        return nil
    }
    do {
        try file.read(into: full)
    } catch {
        return nil
    }
    let count = Int(full.frameLength)
    guard count > 0, let channels = full.floatChannelData else { return nil }

    let chCount = Int(format.channelCount)
    let threshold: Float = 0.004  // ~ -48 dBFS
    var firstActive = count
    var lastActive = -1

    for i in 0..<count {
        var peak: Float = 0
        for ch in 0..<chCount {
            let v = abs(channels[ch][i])
            if v > peak { peak = v }
        }
        if peak > threshold {
            firstActive = i
            break
        }
    }
    if firstActive >= count {
        return nil
    }
    for i in stride(from: count - 1, through: firstActive, by: -1) {
        var peak: Float = 0
        for ch in 0..<chCount {
            let v = abs(channels[ch][i])
            if v > peak { peak = v }
        }
        if peak > threshold {
            lastActive = i
            break
        }
    }

    let leadPad = Int(format.sampleRate * 0.02)
    let tailPad = Int(format.sampleRate * 0.03)
    let start = max(0, firstActive - leadPad)
    let end = min(count, lastActive + 1 + tailPad)
    let sliceCount = AVAudioFrameCount(max(1, end - start))

    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sliceCount) else {
        return nil
    }
    out.frameLength = sliceCount
    if let outChannels = out.floatChannelData {
        for ch in 0..<chCount {
            outChannels[ch].update(from: channels[ch].advanced(by: start), count: Int(sliceCount))
        }
    }
    return out
}

while let line = readLine() {
    let parts = line.split(separator: "\t", maxSplits: 1)
    guard parts.count == 2, let volume = Float(parts[0]) else {
        print("err")
        continue
    }
    let url = URL(fileURLWithPath: String(parts[1]))
    guard let file = try? AVAudioFile(forReading: url) else {
        print("err")
        continue
    }

    var started = true
    queue.sync {
        if currentFormat != file.processingFormat {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            currentFormat = file.processingFormat
        }
        engine.mainMixerNode.outputVolume = max(0, min(1, volume))
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                started = false
            }
        }
    }
    guard started else {
        print("err")
        continue
    }

    let finished = DispatchSemaphore(value: 0)
    if let buffer = trimmedBuffer(from: file) {
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            finished.signal()
        }
    } else {
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            finished.signal()
        }
    }
    queue.sync {
        if !paused {
            player.play()
        }
    }
    finished.wait()
    print("done")
}
