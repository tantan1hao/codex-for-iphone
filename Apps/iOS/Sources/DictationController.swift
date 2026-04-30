import AVFAudio
import Combine
import Foundation
import Speech

enum DictationState: Equatable, Sendable {
    case idle
    case listening
    case denied
    case error(String)

    var errorMessage: String? {
        if case let .error(message) = self {
            return message
        }
        return nil
    }
}

@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var partialTranscript = ""
    @Published private(set) var finalTranscript = ""
    @Published private(set) var speechAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()

    var currentTranscript: String {
        partialTranscript.isEmpty ? finalTranscript : partialTranscript
    }

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionID = UUID()
    private var isInputTapInstalled = false
    private var isStoppingNormally = false

    @discardableResult
    func requestAuthorization() async -> Bool {
        speechAuthorizationStatus = await Self.requestSpeechAuthorization()

        guard speechAuthorizationStatus == .authorized else {
            state = .denied
            return false
        }

        guard await Self.requestMicrophoneAuthorization() else {
            state = .denied
            return false
        }

        if state == .denied {
            state = .idle
        }
        return true
    }

    func start(locale: Locale = .current) async {
        guard state != .listening else { return }

        cancel()
        partialTranscript = ""
        finalTranscript = ""

        guard await requestAuthorization() else { return }

        do {
            try startRecognition(locale: locale)
        } catch {
            fail(with: error.localizedDescription)
        }
    }

    func stop() {
        guard state == .listening || audioEngine.isRunning || recognitionRequest != nil else {
            state = .idle
            return
        }

        isStoppingNormally = true
        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if finalTranscript.isEmpty, !partialTranscript.isEmpty {
            finalTranscript = partialTranscript
        }
        partialTranscript = ""
        state = .idle
        deactivateAudioSession()
    }

    func cancel() {
        recognitionID = UUID()
        isStoppingNormally = false
        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        partialTranscript = ""
        state = .idle
        deactivateAudioSession()
    }

    private func startRecognition(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw DictationError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw DictationError.recognizerTemporarilyUnavailable
        }

        speechRecognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw DictationError.microphoneUnavailable
        }

        let currentRecognitionID = UUID()
        recognitionID = currentRecognitionID
        isStoppingNormally = false

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        isInputTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal == true
            let errorMessage = error.map(Self.userFacingMessage(for:))

            Task { @MainActor [weak self] in
                self?.handleRecognitionUpdate(
                    id: currentRecognitionID,
                    transcript: transcript,
                    isFinal: isFinal,
                    errorMessage: errorMessage
                )
            }
        }

        state = .listening
    }

    private func handleRecognitionUpdate(
        id: UUID,
        transcript: String,
        isFinal: Bool,
        errorMessage: String?
    ) {
        guard id == recognitionID else { return }

        if !transcript.isEmpty {
            if isFinal {
                finalTranscript = transcript
                partialTranscript = ""
            } else {
                partialTranscript = transcript
            }
        }

        if isFinal {
            finishRecognition()
            return
        }

        guard let errorMessage else { return }
        if isStoppingNormally {
            finishRecognition()
        } else {
            fail(with: errorMessage)
        }
    }

    private func finishRecognition() {
        stopAudioEngine()
        recognitionRequest = nil
        recognitionTask = nil
        isStoppingNormally = false
        state = .idle
        deactivateAudioSession()
    }

    private func fail(with message: String) {
        stopAudioEngine()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isStoppingNormally = false
        partialTranscript = ""
        state = .error(message)
        deactivateAudioSession()
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func requestMicrophoneAuthorization() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            true
        case .denied:
            false
        case .undetermined:
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            false
        }
    }

    nonisolated private static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "语音识别服务暂时不可用。"
        }
        return error.localizedDescription
    }
}

private enum DictationError: LocalizedError {
    case recognizerUnavailable
    case recognizerTemporarilyUnavailable
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            "当前语言不支持系统语音识别。"
        case .recognizerTemporarilyUnavailable:
            "语音识别当前不可用，模拟器或系统服务可能未提供识别器。"
        case .microphoneUnavailable:
            "无法读取麦克风输入。"
        }
    }
}
