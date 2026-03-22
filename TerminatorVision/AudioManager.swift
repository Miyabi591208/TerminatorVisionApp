import AVFoundation
import Foundation

@MainActor
final class AudioManager: ObservableObject {
    @Published private(set) var environmentSamples: [CGFloat] = Array(repeating: 0.03, count: 36)
    @Published private(set) var voiceSamples: [CGFloat] = Array(repeating: 0.03, count: 36)
    @Published private(set) var environmentLevel: CGFloat = 0
    @Published private(set) var voiceLevel: CGFloat = 0
    @Published private(set) var microphoneAuthorized = false

    private let audioEngine = AVAudioEngine()
    private var overlayPlayer: AVAudioPlayer?
    private var isTapInstalled = false
    private var previousSample: Float = 0
    private var lowPassState: Float = 0
    private var smoothedEnvironment: CGFloat = 0.03
    private var smoothedVoice: CGFloat = 0.03

    func startAudioSystems() {
        Task {
            do {
                try await prepareAudioSession()
                startInputMonitoring()
                startOverlayLoop()
            } catch {
                print("Failed to start audio systems: \(error)")
            }
        }
    }

    func stopAudioSystems() {
        overlayPlayer?.stop()
        overlayPlayer = nil

        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        audioEngine.stop()
    }

    private func prepareAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        try session.overrideOutputAudioPort(.speaker)

        let granted = await AVAudioApplication.requestRecordPermission()
        microphoneAuthorized = granted
    }

    private func startOverlayLoop() {
        guard overlayPlayer == nil else {
            if overlayPlayer?.isPlaying == false {
                overlayPlayer?.play()
            }
            return
        }

        guard let fileURL = resolvedOverlayURL() else {
            print("overlay1.mp3 not found in app bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.numberOfLoops = -1
            player.volume = 0.82
            player.prepareToPlay()
            player.play()
            overlayPlayer = player
        } catch {
            print("Failed to start overlay audio: \(error)")
        }
    }

    private func startInputMonitoring() {
        guard microphoneAuthorized else { return }
        guard !isTapInstalled else { return }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            let analysis = self.analyze(buffer: buffer)

            Task { @MainActor in
                self.environmentLevel = analysis.environment
                self.voiceLevel = analysis.voice

                self.environmentSamples.removeFirst()
                self.environmentSamples.append(max(0.03, analysis.environment))

                self.voiceSamples.removeFirst()
                self.voiceSamples.append(max(0.03, analysis.voice))
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isTapInstalled = true
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }

    private func analyze(buffer: AVAudioPCMBuffer) -> (environment: CGFloat, voice: CGFloat) {
        guard let channelData = buffer.floatChannelData else { return (0.03, 0.03) }

        let channel = channelData[0]
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return (0.03, 0.03) }

        var sumFull: Float = 0
        var previous = previousSample
        var lowPass = lowPassState
        var sumLow: Float = 0
        var sumHigh: Float = 0

        for index in 0..<frameLength {
            let sample = channel[index]
            sumFull += sample * sample

            lowPass = (0.92 * lowPass) + (0.08 * sample)
            let lowComponent = lowPass
            let highComponent = sample - lowComponent
            let differentiated = sample - previous

            sumLow += lowComponent * lowComponent
            sumHigh += (highComponent * highComponent) + (differentiated * differentiated * 0.35)
            previous = sample
        }

        previousSample = previous
        lowPassState = lowPass

        let fullRMS = sqrt(sumFull / Float(frameLength))
        let lowRMS = sqrt(sumLow / Float(frameLength))
        let highRMS = sqrt(sumHigh / Float(frameLength))

        let rawEnvironment = min(max(pow(CGFloat(lowRMS) * 12.0, 0.72), 0.03), 1.0)
        let voiceRatio = CGFloat(highRMS / max(lowRMS, 0.0001))
        let rawVoice = min(
            max(
                pow(CGFloat(highRMS) * 30.0, 0.70) + (voiceRatio * 0.22) + (CGFloat(fullRMS) * 2.2),
                0.03
            ),
            1.0
        )

        smoothedEnvironment = (smoothedEnvironment * 0.90) + (rawEnvironment * 0.10)
        smoothedVoice = (smoothedVoice * 0.68) + (rawVoice * 0.32)

        let environment = min(max(smoothedEnvironment * 0.78, 0.03), 1.0)
        let voice = min(max(smoothedVoice * 1.08, 0.03), 1.0)

        return (environment, voice)
    }

    private func resolvedOverlayURL() -> URL? {
        if let directURL = Bundle.main.url(forResource: "overlay1", withExtension: "mp3") {
            return directURL
        }

        if let nestedURL = Bundle.main.url(
            forResource: "overlay1",
            withExtension: "mp3",
            subdirectory: "Media/Sounds"
        ) {
            return nestedURL
        }

        return nil
    }
}
