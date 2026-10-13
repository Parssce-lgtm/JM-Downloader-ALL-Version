import Foundation
import CryptoKit
import CommonCrypto

enum JMCrypto {
    // Public protocol constants from jmcomic 2.7.7; these are not user credentials.
    static let secret = "185Hcomic3PAPP7R"
    static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func decrypt(_ value: String, timestamp: String) throws -> Data {
        guard let input = Data(base64Encoded: value) else { throw JMError.message("API 返回无效编码。") }
        let key = Data(md5(timestamp + secret).utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var count = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { data in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, nil, data.baseAddress, input.count,
                            out.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw JMError.message("API 数据解密失败，可能需要更新协议。") }
        return output.prefix(count)
    }
    static func strips(chapterID: Int, filename: String, scrambleID: Int) -> Int {
        if chapterID < scrambleID { return 0 }
        if chapterID < 268850 { return 10 }
        let modulus = chapterID < 421926 ? 10 : 8
        let suffix = md5("\(chapterID)\(filename)").utf8.last!
        return (Int(suffix) % modulus) * 2 + 2
    }
    static func slices(height: Int, count: Int) -> [(source: Int, destination: Int, height: Int)] {
        guard count > 0 else { return [(0, 0, height)] }
        let step = height / count, remainder = height % count
        return (0..<count).map { i in
            (height - step * (i + 1) - remainder,
             step * i + (i == 0 ? 0 : remainder), step + (i == 0 ? remainder : 0))
        }
    }
}
