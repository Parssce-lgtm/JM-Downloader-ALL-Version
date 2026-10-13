import Foundation

enum NetworkFailure {
    static func describe(_ error: URLError) -> String {
        let reason: String
        switch error.code {
        case .cannotCreateFile, .cannotOpenFile, .cannotCloseFile, .cannotWriteToFile,
             .cannotRemoveFile, .cannotMoveFile:
            reason = "iOS 无法创建或写入下载文件。这是文件存储错误，请检查设备剩余空间后重试，无需修改 API 域名。"
        case .notConnectedToInternet:
            reason = "设备当前离线，或应用未获网络权限。请在 iOS 设置中允许 JM downloader 使用无线局域网与蜂窝网络。"
        case .cannotFindHost, .dnsLookupFailed:
            reason = "DNS 无法解析服务器。请切换网络，或检测系统 VPN / DNS 是否正常。"
        case .cannotConnectToHost:
            reason = "无法连接服务器。请确认当前网络可访问该站点；代理是可选项。"
        case .timedOut:
            reason = "连接超时。请稍后重试，或切换 Wi-Fi / 蜂窝网络。"
        case .networkConnectionLost:
            reason = "网络连接中断，请恢复网络后继续下载。"
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            reason = "TLS 安全连接失败。请检查系统时间及 VPN / 代理的证书设置。"
        case .appTransportSecurityRequiresSecureConnection:
            reason = "服务器连接不符合 iOS 安全要求，请恢复默认 HTTPS 线路。"
        case .dataNotAllowed:
            reason = "系统不允许应用使用当前数据网络，请在 iOS 设置中打开网络权限。"
        case .cancelled:
            reason = "请求已取消，可重新操作。"
        default:
            reason = "网络请求未完成，请检测当前网络连接。"
        }
        let info = (error as NSError).userInfo
        let url = info[NSURLErrorFailingURLErrorKey] as? URL
            ?? (info[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        return reason + "（\(url?.host.map { $0 + " · " } ?? "")错误 \(error.code.rawValue)）"
    }
}

enum NetworkDiagnostics {
    static func check(_ preferences: Preferences, platform: ComicPlatform) async throws -> String {
        let hosts = try Validation.hosts(platform == .jmcomic ? preferences.effectiveJMDomains : preferences.effectivePicaDomain)
        let config = URLSessionConfiguration.ephemeral
        try NetworkConfiguration.apply(preferences, to: config)
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var failures: [String] = []
        for host in hosts {
            try Task.checkCancellation()
            do {
                // No credentials are sent. Any HTTP response proves DNS/TLS/transport connectivity,
                // not that login or comic retrieval is authorized.
                var request = URLRequest(url: URL(string: "https://\(host)/")!)
                request.httpMethod = "HEAD"
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw JMError.message("服务器响应无效。") }
                if http.statusCode >= 500 { throw JMError.message("服务器暂时不可用（HTTP \(http.statusCode)）。") }
                return "已连接 \(host)（HTTP \(http.statusCode)）。API 地址已配置；此检测仅验证网络连通，登录与下载需另行验证。"
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch let error as URLError { failures.append("\(host)：\(NetworkFailure.describe(error))") }
            catch { failures.append("\(host)：\(error.localizedDescription)") }
        }
        throw JMError.message(failures.joined(separator: "\n"))
    }
}
