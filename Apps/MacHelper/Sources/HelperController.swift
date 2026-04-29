import AppKit
import CodexMobileKit
import CoreImage.CIFilterBuiltins
import SwiftUI

enum HelperStatus: Equatable {
    case stopped
    case starting
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    var detail: String {
        switch self {
        case .stopped: "Start the helper to pair your iPhone or iPad."
        case .starting: "Launching Codex app-server and waiting for readiness."
        case .ready: "Scan the QR code from Codex Mobile."
        case let .failed(message): message
        }
    }

    var tint: Color {
        switch self {
        case .ready: .green
        case .starting: .blue
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

@MainActor
final class HelperController: ObservableObject {
    @Published var status: HelperStatus = .stopped
    @Published var workspacePath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var pairingPayload: PairingPayload?
    @Published var qrImage: NSImage?
    @Published var port: Int?
    @Published var codexBinaryPath: String?

    private var process: Process?
    private var readinessTask: Task<Void, Never>?

    deinit {
        process?.terminate()
        readinessTask?.cancel()
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            if process == nil {
                pairingPayload = nil
                qrImage = nil
            }
        }
    }

    func start() {
        stop()
        status = .starting
        do {
            guard let binary = AppServerCommandBuilder.resolveCodexBinary() else {
                throw HelperError.codexBinaryMissing
            }
            codexBinaryPath = binary
            let support = try AppServerCommandBuilder.defaultSupportDirectory()
            let token = try AppServerCommandBuilder.generateToken()
            let tokenURL = support.appendingPathComponent("codex-mobile-token")
            try token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)

            let selectedPort = AppServerCommandBuilder.randomEphemeralPort()
            let launch = AppServerCommandBuilder.makeLaunchConfiguration(
                executablePath: binary,
                port: selectedPort,
                tokenFile: tokenURL.path
            )
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launch.executablePath)
            proc.arguments = launch.arguments
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            process = proc
            port = selectedPort

            let payload = try PairingPayload(
                name: NetworkIdentity.localHostName(),
                host: NetworkIdentity.primaryLANAddress(),
                port: selectedPort,
                token: token,
                cwd: workspacePath
            )
            pairingPayload = payload
            qrImage = Self.makeQRCode(from: payload.deepLinkURL.absoluteString)
            pollReadiness(port: selectedPort)
        } catch {
            status = .failed(error.localizedDescription)
            stopProcessOnly()
        }
    }

    func stop() {
        readinessTask?.cancel()
        readinessTask = nil
        stopProcessOnly()
        status = .stopped
        pairingPayload = nil
        qrImage = nil
        port = nil
    }

    func copyPairingLink() {
        guard let url = pairingPayload?.deepLinkURL.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func stopProcessOnly() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func pollReadiness(port: Int) {
        readinessTask?.cancel()
        readinessTask = Task { @MainActor in
            let url = URL(string: "http://127.0.0.1:\(port)/readyz")!
            for _ in 0..<40 {
                if Task.isCancelled { return }
                do {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 1
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        status = .ready
                        return
                    }
                } catch {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            status = .failed("Codex app-server did not become ready on port \(port).")
        }
    }

    private static func makeQRCode(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

enum HelperError: LocalizedError {
    case codexBinaryMissing

    var errorDescription: String? {
        switch self {
        case .codexBinaryMissing:
            "Could not find Codex. Install Codex.app or make `codex` available on PATH."
        }
    }
}

extension HelperController {
    static func previewReady() -> HelperController {
        let controller = HelperController()
        controller.status = .ready
        controller.workspacePath = "/Users/mac/project"
        controller.port = 49320
        controller.codexBinaryPath = AppServerCommandBuilder.bundledCodexPath
        controller.pairingPayload = try? PairingPayload(
            name: "MacBook Pro",
            host: "192.168.1.22",
            port: 49320,
            token: "abcdefghijklmnopqrstuvwxyzabcdef0123456789",
            cwd: "/Users/mac/project"
        )
        if let url = controller.pairingPayload?.deepLinkURL.absoluteString {
            controller.qrImage = makeQRCode(from: url)
        }
        return controller
    }
}

