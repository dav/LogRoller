import Foundation
import Security
import Network
import LogRollerCore

struct TLSIdentityProvider {
    private static let p12Password = "logroller"

    func loadOrCreateIdentity() throws -> sec_identity_t {
        try ensureIdentityBundle()

        let p12Data = try Data(contentsOf: Self.p12FileURL)
        let options: [String: Any] = [kSecImportExportPassphrase as String: Self.p12Password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess else {
            throw IdentityError.unableToImportIdentity(status)
        }

        guard
            let importedItems = items as? [[String: Any]],
            let first = importedItems.first,
            let secIdentityValue = first[kSecImportItemIdentity as String]
        else {
            throw IdentityError.identityMissing
        }

        let secIdentity = secIdentityValue as! SecIdentity
        guard let identity = sec_identity_create(secIdentity) else {
            throw IdentityError.identityCreationFailed
        }
        return identity
    }

    private func ensureIdentityBundle() throws {
        try FileManager.default.createDirectory(at: Self.certsDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: Self.p12FileURL.path(percentEncoded: false)) {
            return
        }

        let mkcert = try resolveExecutable(
            name: "mkcert",
            fallbackPaths: ["/opt/homebrew/bin/mkcert", "/usr/local/bin/mkcert"]
        )
        let openssl = try resolveExecutable(name: "openssl", fallbackPaths: ["/usr/bin/openssl", "/opt/homebrew/bin/openssl"])

        let hosts = LogRollerNetwork.certificateHosts()
        var mkcertArguments = [
            "-cert-file", Self.certPEMFileURL.path(percentEncoded: false),
            "-key-file", Self.keyPEMFileURL.path(percentEncoded: false),
        ]
        mkcertArguments.append(contentsOf: hosts)
        try runProcess(executablePath: mkcert, arguments: mkcertArguments)

        let opensslArguments = [
            "pkcs12",
            "-export",
            "-inkey", Self.keyPEMFileURL.path(percentEncoded: false),
            "-in", Self.certPEMFileURL.path(percentEncoded: false),
            "-out", Self.p12FileURL.path(percentEncoded: false),
            "-passout", "pass:\(Self.p12Password)",
        ]
        try runProcess(executablePath: openssl, arguments: opensslArguments)
    }

    private func resolveExecutable(name: String, fallbackPaths: [String]) throws -> String {
        for path in fallbackPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let output = try runProcess(executablePath: "/usr/bin/which", arguments: [name], allowFailure: true)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }

        throw IdentityError.executableMissing(name)
    }

    @discardableResult
    private func runProcess(executablePath: String, arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        let errorString = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0, !allowFailure {
            throw IdentityError.processFailed(
                executablePath: executablePath,
                status: process.terminationStatus,
                output: outputString,
                error: errorString
            )
        }

        return outputString
    }

    private enum IdentityError: LocalizedError {
        case executableMissing(String)
        case processFailed(executablePath: String, status: Int32, output: String, error: String)
        case unableToImportIdentity(OSStatus)
        case identityMissing
        case identityCreationFailed

        var errorDescription: String? {
            switch self {
            case let .executableMissing(name):
                return "Required executable not found: \(name)"
            case let .processFailed(executablePath, status, output, error):
                return "\(executablePath) failed (\(status)). stdout: \(output) stderr: \(error)"
            case let .unableToImportIdentity(status):
                return "Unable to import TLS identity from PKCS12 (\(status))."
            case .identityMissing:
                return "TLS identity is missing from PKCS12 import result."
            case .identityCreationFailed:
                return "Unable to bridge TLS identity to Network.framework."
            }
        }
    }

    private static var certsDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "LogRoller", directoryHint: .isDirectory)
            .appending(path: "certs", directoryHint: .isDirectory)
    }

    private static var certPEMFileURL: URL {
        certsDirectory.appending(path: "logroller-server-cert.pem")
    }

    private static var keyPEMFileURL: URL {
        certsDirectory.appending(path: "logroller-server-key.pem")
    }

    private static var p12FileURL: URL {
        certsDirectory.appending(path: "logroller-server-identity.p12")
    }
}
