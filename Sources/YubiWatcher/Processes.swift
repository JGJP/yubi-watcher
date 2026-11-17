import AppKit
import Darwin

struct ProcessNode: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String
    let args: [String]
    let cwd: String
    let startTime: UInt64

    /// argv[0] is friendlier than the kernel name (e.g. Claude Code's binary is named after its version).
    var displayName: String {
        guard let argv0 = args.first, !argv0.isEmpty else { return name }
        return (argv0 as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }

    init?(pid: pid_t) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        self.pid = pid
        ppid = pid_t(info.pbi_ppid)
        startTime = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
        name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        path = Self.path(pid)
        args = Self.arguments(pid)
        cwd = Self.cwd(pid)
    }

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    static func shortName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    static func ancestry(of pid: pid_t) -> [ProcessNode] {
        var chain: [ProcessNode] = []
        var current = pid
        while current > 1, chain.count < 64, let node = ProcessNode(pid: current) {
            chain.append(node)
            current = node.ppid
        }
        return chain
    }

    private static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    private static func cwd(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    // KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, then argc NUL-terminated args.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

struct SignRequest: Identifiable {
    let id: String
    let chain: [ProcessNode]
    var changes: CommitChanges?

    var signer: ProcessNode { chain[0] }

    var namespace: String { option("-n") ?? "?" }
    var keyFile: String { option("-f") ?? "?" }

    var git: ProcessNode? { chain.first { $0.name == "git" } }

    private static let plumbing: Set = ["git", "ssh-keygen", "sh", "bash", "zsh", "fish", "dash", "env", "login"]

    /// The first ancestor above git that isn't a shell or more git/ssh-keygen plumbing.
    var requester: ProcessNode {
        let gitIndex = chain.firstIndex { $0.name == "git" } ?? 0
        return chain.dropFirst(gitIndex + 1).first { !Self.plumbing.contains($0.displayName) } ?? git ?? signer
    }

    var owningApp: NSRunningApplication? {
        chain.lazy.compactMap(\.app).first { $0.activationPolicy == .regular }
    }

    private func option(_ flag: String) -> String? {
        guard let i = signer.args.firstIndex(of: flag), i + 1 < signer.args.count else { return nil }
        return signer.args[i + 1]
    }

    static func isSign(_ node: ProcessNode) -> Bool {
        guard let y = node.args.firstIndex(of: "-Y"), y + 1 < node.args.count else { return false }
        return node.args[y + 1] == "sign"
    }
}
