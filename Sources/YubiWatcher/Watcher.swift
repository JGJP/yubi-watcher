import Foundation

/// Polls the process table for `ssh-keygen -Y sign -n git` using a FIDO (sk-*) key.
/// ssh-keygen blocks until the key is touched, so the process exiting means the touch landed (or it timed out).
@MainActor
final class Watcher {
    private var timer: Timer?
    private var known: [String: SignRequest] = [:]
    private var ignored: Set<String> = []
    var onChange: (([SignRequest]) -> Void)?
    var isSigning: Bool { !known.isEmpty }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    private func scan() {
        var live: Set<String> = []
        var changed = false

        for pid in ProcessNode.allPids() where ProcessNode.shortName(pid) == "ssh-keygen" {
            guard let node = ProcessNode(pid: pid) else { continue }
            let id = "\(pid)-\(node.startTime)"
            live.insert(id)
            guard known[id] == nil, !ignored.contains(id) else { continue }

            let request = SignRequest(id: id, chain: ProcessNode.ancestry(of: pid))
            if SignRequest.isSign(node), request.namespace == "git", Self.isSecurityKey(request.keyFile) {
                known[id] = request
                changed = true
                if let git = request.git { loadChanges(id, git) }
            } else {
                ignored.insert(id)
            }
        }

        let gone = Set(known.keys).subtracting(live)
        gone.forEach { known[$0] = nil }
        ignored.formIntersection(live)
        if changed || !gone.isEmpty {
            onChange?(known.values.sorted { $0.id < $1.id })
        }
    }

    private func loadChanges(_ id: String, _ git: ProcessNode) {
        Task.detached {
            let changes = CommitInspector.inspect(git)
            await MainActor.run {
                guard self.known[id] != nil else { return }
                self.known[id]?.changes = changes
                self.onChange?(self.known.values.sorted { $0.id < $1.id })
            }
        }
    }

    /// Unreadable key files (e.g. git's short-lived temp file for `key::` literals) and private keys without a
    /// `.pub` sibling can't be cheaply classified, so they're treated as security keys.
    private static func isSecurityKey(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates = expanded.hasSuffix(".pub") ? [expanded] : [expanded + ".pub", expanded]
        guard let contents = candidates.lazy.compactMap({ try? String(contentsOfFile: $0, encoding: .utf8) }).first,
              !contents.contains("PRIVATE KEY") else { return true }
        return contents.contains("sk-ssh-ed25519@openssh.com") || contents.contains("sk-ecdsa-sha2-nistp256@openssh.com")
    }
}
