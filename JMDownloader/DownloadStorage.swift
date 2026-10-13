import Foundation

enum DownloadStorage {
    static func needsDirectTransfer(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [URLError.cannotCreateFile, .cannotOpenFile, .cannotCloseFile,
                .cannotWriteToFile, .cannotRemoveFile, .cannotMoveFile].contains(URLError.Code(rawValue: error.code))
    }

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    // Use a data stream, bypassing URLSessionDownloadTask's system-managed temporary file.
    // Memory is bounded to one 64 KiB buffer, independent of the image's size.
    static func receive(_ request: URLRequest, configuration: URLSessionConfiguration, directory: URL) async throws -> URL {
        try prepare(directory)
        let partial = directory.appendingPathComponent(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw URLError(.cannotCreateFile)
        }
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: partial) } }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ImageHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var buffer = Data(); buffer.reserveCapacity(65_536)
        var count = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 65_536 {
                try Task.checkCancellation()
                try file.write(contentsOf: buffer)
                count += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        try file.write(contentsOf: buffer)
        count += buffer.count
        guard count > 0 else { throw JMError.message("图片服务器返回空文件，请重试。") }
        try file.synchronize()
        try file.close()
        keep = true
        return partial
    }

    static func commit(_ staged: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }
}
