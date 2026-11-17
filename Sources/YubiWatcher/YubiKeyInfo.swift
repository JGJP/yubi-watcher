import Foundation

struct YubiKeyInfo {
    let name: String
    let details: [String]

    private static let tool = ["/opt/homebrew/bin/fido2-token", "/usr/local/bin/fido2-token"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// nil when libfido2's `fido2-token` isn't installed.
    static func connected() -> [YubiKeyInfo]? {
        guard let tool else { return nil }
        // Lines look like: ioreg://4295014300: vendor=0x1050, product=0x0406 (Yubico YubiKey FIDO+CCID)
        let devices = (Shell.run(tool, ["-L"]) ?? "").split(separator: "\n").filter { $0.contains("vendor=0x1050") }
        return devices.map { line in
            let path = String(line.prefix { $0 != " " }.dropLast())
            let name = line.firstIndex(of: "(").map { String(line[line.index(after: $0)...].dropLast()) } ?? "YubiKey"
            return YubiKeyInfo(name: name, details: details(Shell.run(tool, ["-I", path]) ?? ""))
        }
    }

    private static func details(_ output: String) -> [String] {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var lines: [String] = []
        if let fw = fields["fwversion"].flatMap({ Int($0.dropFirst(2), radix: 16) }) {
            lines.append("Firmware \(fw >> 16).\((fw >> 8) & 0xff).\(fw & 0xff)")
        }
        if let options = fields["options"]?.components(separatedBy: ", ") {
            lines.append(options.contains("clientPin") ? "FIDO2 PIN set" : "No FIDO2 PIN set")
        }
        if let retries = fields["pin retries"] { lines.append("PIN retries left: \(retries)") }
        if let remaining = fields["remaining rk(s)"] { lines.append("Resident key slots left: \(remaining)") }
        if let versions = fields["version strings"] { lines.append(versions) }
        return lines
    }
}
