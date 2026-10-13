import Foundation
import UIKit
import CryptoKit

actor CoverCache {
    static let shared = CoverCache()
    private let directory: URL
    private var memory = NSCache<NSString, NSData>()
    private var requests: [String: Task<Data, Error>] = [:]
    private var generation = UUID()
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("JMDownloaderCovers")) {
        self.directory = directory
        memory.totalCostLimit = 32 * 1024 * 1024
    }
    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".cover")
    }
    func cached(_ key: String) -> Data? {
        if let data = memory.object(forKey: key as NSString) { return data as Data }
        guard let data = try? Data(contentsOf: file(key)), UIImage(data: data) != nil else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }
    func insert(_ data: Data, key: String) throws {
        guard UIImage(data: data) != nil else { throw JMError.message("封面格式无效。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(key), options: .atomic)
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        var sizes = files.compactMap { url -> (URL, Int, Date)? in
            guard let value = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, value.fileSize ?? 0, value.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = sizes.reduce(0) { $0 + $1.1 }
        while total > 200 * 1024 * 1024, !sizes.isEmpty {
            let item = sizes.removeFirst(); try? FileManager.default.removeItem(at: item.0); total -= item.1
        }
    }
    func load(comic: Comic, preferences: Preferences) async throws -> Data {
        let key = DownloadCatalog.key(comic)
        if let cached = cached(key) { return cached }
        if let request = requests[key] { return try await request.value }
        let stamp = generation
        let task = Task<Data, Error> {
            let url: URL
            if comic.source == .picacg {
                guard let cover = comic.coverURL else { throw URLError(.badURL) }; url = cover
            } else {
                let host = try Validation.hosts(preferences.effectiveImageDomain)[0]
                let id = try Validation.numericID(comic.id)
                url = URL(string: "https://\(host)/media/albums/\(id)_3x4.jpg")!
            }
            let config = URLSessionConfiguration.ephemeral
            try NetworkConfiguration.apply(preferences, to: config)
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let urls = comic.source == .picacg ? MediaRequest.picaURLs(url) : [url]
            for (index, candidate) in urls.enumerated() {
                let request = MediaRequest.make(url: candidate, platform: comic.source, preferences: preferences)
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    let error = ImageHTTPError(status: status)
                    if index + 1 < urls.count && MediaRequest.canRetry(error) { continue }
                    throw error
                }
                guard UIImage(data: data) != nil else { throw URLError(.cannotDecodeContentData) }
                return data
            }
            throw URLError(.cannotDecodeContentData)
        }
        requests[key] = task
        defer { if stamp == generation { requests[key] = nil } }
        let data = try await task.value
        if stamp == generation { try insert(data, key: key) }
        return data
    }
    func clear() throws {
        generation = UUID()
        requests.values.forEach { $0.cancel() }; requests.removeAll(); memory.removeAllObjects()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
