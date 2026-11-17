import Foundation

struct CommitChanges: Sendable {
    let files: [String]
    let summary: String
}

/// git signs after writing the commit's tree but before updating HEAD, so diffing the index git is committing
/// from against the would-be parent reproduces the commit's changes.
enum CommitInspector {
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    private static let optionsWithValue: Set = ["-c", "-C", "--git-dir", "--work-tree", "--namespace"]

    static func inspect(_ git: ProcessNode) -> CommitChanges? {
        var cwd = git.cwd
        var subcommand: String?
        var i = 1
        while i < git.args.count {
            let arg = git.args[i]
            if optionsWithValue.contains(arg) {
                if arg == "-C", i + 1 < git.args.count { cwd = (cwd as NSString).appendingPathComponent(git.args[i + 1]) }
                i += 2
            } else if arg.hasPrefix("-") {
                i += 1
            } else {
                subcommand = arg
                break
            }
        }
        guard subcommand != "tag" else { return nil }

        let gitPath = git.path.isEmpty ? "/usr/bin/git" : git.path
        func run(_ args: [String], index: String? = nil) -> String? {
            var environment = ["GIT_OPTIONAL_LOCKS": "0"]
            environment["GIT_INDEX_FILE"] = index
            return Shell.run(gitPath, args, cwd: cwd, environment: environment)
        }

        guard let gitDir = run(["rev-parse", "--absolute-git-dir"])?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let index = commitIndex(in: gitDir)
        let parent = subcommand == "commit" && git.args.contains("--amend") ? "HEAD~1" : "HEAD"
        let base = run(["rev-parse", "--verify", "-q", "\(parent)^{commit}"]) == nil ? emptyTree : parent

        guard let nameStatus = run(["diff", "--cached", "--name-status", "-M", base], index: index) else { return nil }
        let files = nameStatus.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t").map(String.init)
            return "\(parts[0].prefix(1))  " + parts.dropFirst().joined(separator: " → ")
        }
        let summary = run(["diff", "--cached", "--shortstat", base], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CommitChanges(files: files, summary: summary.isEmpty ? "No file changes" : summary)
    }

    /// Partial commits (`git commit <paths>`) build a `next-index-<pid>.lock`; `-a` stages into `index.lock`.
    private static func commitIndex(in gitDir: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: gitDir)) ?? []
        if let partial = names.first(where: { $0.hasPrefix("next-index-") && $0.hasSuffix(".lock") }) {
            return (gitDir as NSString).appendingPathComponent(partial)
        }
        return names.contains("index.lock") ? (gitDir as NSString).appendingPathComponent("index.lock") : nil
    }
}
