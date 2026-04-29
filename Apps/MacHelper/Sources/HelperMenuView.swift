import CodexMobileKit
import SwiftUI

struct HelperMenuView: View {
    @EnvironmentObject private var controller: HelperController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            workspace
            if let image = controller.qrImage, let payload = controller.pairingPayload {
                qrBlock(image: image, payload: payload)
            } else {
                placeholder
            }
            controls
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.status.tint)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.status.title)
                    .font(.headline)
                Text(controller.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspace")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(controller.workspacePath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                Spacer()
                Button {
                    controller.chooseWorkspace()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose workspace")
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func qrBlock(image: NSImage, payload: PairingPayload) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
            Text("\(payload.host):\(payload.port)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                controller.copyPairingLink()
            } label: {
                Label("Copy Pairing Link", systemImage: "doc.on.doc")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("Start the helper to generate a pairing code.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack {
            Button {
                controller.start()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}

struct HelperSettingsView: View {
    @EnvironmentObject private var controller: HelperController

    var body: some View {
        Form {
            LabeledContent("Codex binary") {
                Text(controller.codexBinaryPath ?? "Not resolved")
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Workspace") {
                Text(controller.workspacePath)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Port") {
                Text(controller.port.map(String.init) ?? "None")
            }
        }
        .padding()
    }
}

#Preview("Ready") {
    HelperMenuView()
        .environmentObject(HelperController.previewReady())
}

#Preview("Stopped") {
    HelperMenuView()
        .environmentObject(HelperController())
}
