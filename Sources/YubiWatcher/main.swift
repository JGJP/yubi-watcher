import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let watcher = Watcher()
    private let overlay = Overlay()
    private var statusItem: NSStatusItem!
    private var testProcess: Process?
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: "YubiWatcher")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watcher.onChange = { [overlay] in overlay.show($0) }
        watcher.start()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if watcher.isSigning {
            menu.addItem(info("Waiting for touch…"))
        } else if let keys = YubiKeyInfo.connected() {
            if keys.isEmpty { menu.addItem(info("No YubiKey connected")) }
            for (i, key) in keys.enumerated() {
                let item = NSMenuItem(title: "Connected YubiKey \(i + 1)", action: #selector(showKey), keyEquivalent: "")
                item.representedObject = key
                menu.addItem(item)
            }
        } else {
            menu.addItem(info("Install libfido2 for YubiKey details"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Test (touch YubiKey)", action: testProcess == nil ? #selector(test) : nil,
                                keyEquivalent: ""))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func showKey(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? YubiKeyInfo else { return }
        alert(key.name, key.details.joined(separator: "\n"))
    }

    /// Runs a real `ssh-keygen -Y sign` (via git's configured program) so the watcher shows the overlay and the
    /// touch is genuinely required.
    @objc private func test() {
        guard testProcess == nil else { return }
        func config(_ key: String) -> String? {
            Shell.run("/usr/bin/git", ["config", "--global", "--get", key])?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let key = config("user.signingkey") else { return alert("No user.signingkey in global git config") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config("gpg.ssh.program") ?? "/usr/bin/ssh-keygen")
        process.arguments = ["-Y", "sign", "-n", "git", "-f", (key as NSString).expandingTildeInPath]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        var timedOut = false
        process.terminationHandler = { process in
            let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                self.testProcess = nil
                if timedOut {
                    self.alert("No touch happened")
                } else if process.terminationStatus != 0 {
                    self.alert("Signing failed", error)
                }
            }
        }
        do { try process.run() } catch { return alert("Couldn't run ssh-keygen", error.localizedDescription) }
        stdin.fileHandleForWriting.write(Data("YubiWatcher test\n".utf8))
        try? stdin.fileHandleForWriting.close()
        testProcess = process

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard process.isRunning else { return }
            timedOut = true
            // A wrapper script defers SIGTERM until its child exits, so kill the whole subtree.
            let root = process.processIdentifier
            for pid in ProcessNode.allPids() where ProcessNode.ancestry(of: pid).dropFirst().contains(where: { $0.pid == root }) {
                kill(pid, SIGTERM)
            }
            process.terminate()
        }
    }

    private func alert(_ message: String, _ info: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        NSApp.activate()
        alert.runModal()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
