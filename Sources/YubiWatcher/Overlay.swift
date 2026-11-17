import AppKit
import Observation
import SwiftUI

@Observable
final class OverlayModel {
    var requests: [SignRequest] = []
}

@MainActor
final class Overlay {
    private var panels: [NSPanel] = []
    private let model = OverlayModel()
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func show(_ requests: [SignRequest]) {
        let previous = Set(model.requests.map(\.id))
        if requests.contains(where: { !previous.contains($0.id) }) {
            NSSound(named: "Glass")?.play()
        }
        model.requests = requests
        if requests.isEmpty || panels.isEmpty { rebuild() }
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        guard !model.requests.isEmpty else { return }

        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: OverlayView(model: model))
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}

private struct OverlayView: View {
    let model: OverlayModel
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.yellow)
                    .scaleEffect(pulse ? 1.08 : 0.94)
                    .animation(.easeInOut(duration: 0.7).repeatForever(), value: pulse)
                    .onAppear { pulse = true }
                Text("Touch your YubiKey to sign")
                    .font(.system(size: 44, weight: .bold))
                ForEach(model.requests) { RequestCard(request: $0) }
            }
            .foregroundStyle(.white)
            .padding(48)
        }
    }
}

private struct RequestCard: View {
    let request: SignRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                if let icon = request.owningApp?.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 24, weight: .semibold))
                    if let app = request.owningApp?.localizedName {
                        Text("via \(app)").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            if let git = request.git {
                row("Command", git.args.joined(separator: " "))
                row("Repository", git.cwd)
            }
            if let changes = request.changes {
                row("Changes", changes.summary)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(changes.files.prefix(12), id: \.self) { row("", $0) }
                    if changes.files.count > 12 { row("", "… \(changes.files.count - 12) more") }
                }
            }
            row("Key", request.keyFile)
            row("Chain", request.chain.reversed().map { "\($0.displayName) (\($0.pid))" }.joined(separator: " › "))
        }
        .padding(24)
        .frame(maxWidth: 900, alignment: .leading)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private var title: String { "\(request.requester.displayName)  ·  pid \(request.requester.pid)" }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 90, alignment: .trailing)
            Text(value).font(.system(size: 14, design: .monospaced)).textSelection(.disabled).lineLimit(3)
        }
    }
}
