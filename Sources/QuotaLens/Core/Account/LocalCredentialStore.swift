import CryptoKit
import Darwin
import Foundation

/// Local-only authenticated encryption. The key is protected by filesystem permissions,
/// not a password or Keychain; possession of both key and ciphertext permits decryption.
struct LocalCredentialStore: Sendable {
    let root: URL
    static var applicationStore: Self {
        .init(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaLens/EncryptedCredentials", isDirectory: true))
    }

    private func file(_ id: String) throws -> URL {
        guard !id.isEmpty, id.count <= 160,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw QueryAccountError.storage
        }
        return root.appendingPathComponent(id + ".qcred")
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: root.path),
           attributes[.type] as? FileAttributeType != .typeDirectory { throw QueryAccountError.storage }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw QueryAccountError.storage }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw QueryAccountError.storage }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private func readRegular(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw QueryAccountError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 4_000_000 else { throw QueryAccountError.storage }
        return try handle.readToEnd() ?? Data()
    }

    private func key(create: Bool) throws -> SymmetricKey {
        let url = root.appendingPathComponent("master.key")
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try readRegular(url)
            guard bytes.count == 32 else { throw QueryAccountError.storage }
            let key = SymmetricKey(data: bytes)
            if create, let existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "qcred" }) {
                let stored = try readRegular(existing)
                guard stored.prefix(4) == Data("QLC1".utf8) else { throw QueryAccountError.storage }
                _ = try AES.GCM.open(AES.GCM.SealedBox(combined: stored.dropFirst(4)), using: key,
                    authenticating: Data(existing.deletingPathExtension().lastPathComponent.utf8))
            }
            return key
        }
        guard create,
              try !FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .contains(where: { $0.pathExtension == "qcred" }) else { throw QueryAccountError.storage }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw QueryAccountError.storage }
        defer { Darwin.close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
        guard fsync(fd) == 0 else { throw QueryAccountError.storage }
        return key
    }

    func save<T: Encodable>(_ value: T, id: String) throws {
        let destination = try file(id)
        try withLock {
            let bytes = try JSONEncoder().encode(value)
            let sealed = try AES.GCM.seal(bytes, using: key(create: true), authenticating: Data(id.utf8))
            guard let combined = sealed.combined else { throw QueryAccountError.storage }
            var data = Data("QLC1".utf8)
            data.append(combined)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    func load<T: Decodable>(_ type: T.Type, id: String) throws -> T {
        let source = try file(id)
        return try withLock {
            guard FileManager.default.fileExists(atPath: source.path) else { throw QueryAccountError.credentialMissing }
            let bytes = try readRegular(source)
            guard bytes.prefix(4) == Data("QLC1".utf8) else { throw QueryAccountError.storage }
            let box = try AES.GCM.SealedBox(combined: bytes.dropFirst(4))
            let plaintext = try AES.GCM.open(box, using: key(create: false), authenticating: Data(id.utf8))
            return try JSONDecoder().decode(T.self, from: plaintext)
        }
    }

    func remove(id: String) throws {
        let target = try file(id)
        try withLock {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try readRegular(target)
                try FileManager.default.removeItem(at: target)
            }
        }
    }
}
