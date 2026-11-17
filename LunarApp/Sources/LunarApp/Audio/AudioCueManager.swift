import AVFoundation
import Foundation

/// Subtle synthesized audio cues for study transitions and feedback.
public enum AudioCue: String, CaseIterable, Sendable {
    case flip
    case step
    case correct
    case wrong
    case chime
    case tick
}

/// Abstraction allowing ViewModels to trigger audio cues without requiring hardware output in tests.
public protocol AudioCuePlaying: Sendable {
    func play(_ cue: AudioCue, enabled: Bool)
}

/// Lightweight `AVAudioEngine` tone synthesizer matching `src/lib/audio.ts` cues.
public final class AudioCueManager: AudioCuePlaying, @unchecked Sendable {
    public static let shared = AudioCueManager()

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?

    private init() {}

    public func play(_ cue: AudioCue, enabled: Bool) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }

        guard ensureEngineStarted(),
              let player,
              let format,
              let buffer = synthesizeBuffer(for: cue, format: format) else {
            return
        }

        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    private func ensureEngineStarted() -> Bool {
        if let engine, engine.isRunning, player != nil, format != nil {
            return true
        }

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        let sampleRate = 44_100.0
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return false
        }

        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: monoFormat)

        do {
            try newEngine.start()
            self.engine = newEngine
            self.player = newPlayer
            self.format = monoFormat
            return true
        } catch {
            return false
        }
    }

    private func synthesizeBuffer(for cue: AudioCue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate

        switch cue {
        case .flip:
            return renderSweep(
                sampleRate: sampleRate,
                format: format,
                duration: 0.08,
                startFreq: 320,
                endFreq: 180,
                amplitude: 0.08,
                waveform: .sine
            )
        case .step:
            return renderSweep(
                sampleRate: sampleRate,
                format: format,
                duration: 0.12,
                startFreq: 440,
                endFreq: 660,
                amplitude: 0.09,
                waveform: .triangle
            )
        case .correct:
            return renderNotes(
                sampleRate: sampleRate,
                format: format,
                notes: [
                    (freq: 523.25, start: 0.0, duration: 0.10),
                    (freq: 659.25, start: 0.08, duration: 0.10),
                    (freq: 783.99, start: 0.16, duration: 0.12)
                ],
                totalDuration: 0.28,
                amplitude: 0.12
            )
        case .wrong:
            return renderSweep(
                sampleRate: sampleRate,
                format: format,
                duration: 0.25,
                startFreq: 220,
                endFreq: 110,
                amplitude: 0.11,
                waveform: .triangle
            )
        case .chime:
            return renderNotes(
                sampleRate: sampleRate,
                format: format,
                notes: [
                    (freq: 523.25, start: 0.0, duration: 0.36),
                    (freq: 659.25, start: 0.12, duration: 0.36),
                    (freq: 783.99, start: 0.24, duration: 0.36),
                    (freq: 1046.50, start: 0.36, duration: 0.40)
                ],
                totalDuration: 0.76,
                amplitude: 0.10
            )
        case .tick:
            return renderSweep(
                sampleRate: sampleRate,
                format: format,
                duration: 0.03,
                startFreq: 800,
                endFreq: 400,
                amplitude: 0.04,
                waveform: .sine
            )
        }
    }

    private enum Waveform {
        case sine
        case triangle
    }

    private func renderSweep(
        sampleRate: Double,
        format: AVAudioFormat,
        duration: Double,
        startFreq: Double,
        endFreq: Double,
        amplitude: Double,
        waveform: Waveform
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(max(1, Int(sampleRate * duration)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount

        var phase = 0.0
        let total = Int(frameCount)
        for i in 0..<total {
            let progress = Double(i) / Double(max(1, total - 1))
            let freq = startFreq * pow(endFreq / startFreq, progress)
            phase += 2.0 * .pi * freq / sampleRate

            let raw: Double
            switch waveform {
            case .sine:
                raw = sin(phase)
            case .triangle:
                let norm = (phase / (2.0 * .pi)).truncatingRemainder(dividingBy: 1.0)
                raw = 4.0 * abs(norm - 0.5) - 1.0
            }

            let attack = min(1.0, Double(i) / (sampleRate * 0.005))
            let decay = pow(0.01, progress)
            samples[i] = Float(raw * amplitude * attack * decay)
        }
        return buffer
    }

    private func renderNotes(
        sampleRate: Double,
        format: AVAudioFormat,
        notes: [(freq: Double, start: Double, duration: Double)],
        totalDuration: Double,
        amplitude: Double
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(max(1, Int(sampleRate * totalDuration)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount

        let total = Int(frameCount)
        for i in 0..<total {
            samples[i] = 0
        }

        for note in notes {
            let startIdx = Int(note.start * sampleRate)
            let noteFrames = Int(note.duration * sampleRate)
            for offset in 0..<noteFrames {
                let idx = startIdx + offset
                guard idx < total else { break }
                let progress = Double(offset) / Double(max(1, noteFrames - 1))
                let attack = min(1.0, Double(offset) / (sampleRate * 0.008))
                let decay = pow(0.015, progress)
                let val = sin(2.0 * .pi * note.freq * Double(offset) / sampleRate)
                samples[idx] += Float(val * amplitude * attack * decay)
            }
        }
        return buffer
    }
}
