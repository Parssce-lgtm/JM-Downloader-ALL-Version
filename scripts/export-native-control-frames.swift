// Temporary-build diagnostic: inspect native control interaction without
// installing gesture recognizers or custom drawing into the application.
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

let args = CommandLine.arguments
if args.count != 5 { fatalError("Expected video, start timestamp, test log, output directory") }
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let commandStart = Double(try String(contentsOfFile: args[2]).trimmingCharacters(in: .whitespacesAndNewlines))!
// simctl may wait before writing its first frame. Prefer the movie timestamp;
// the command timestamp is only an explicitly marked fallback.
let movieStart = asset.creationDate?.dateValue?.timeIntervalSince1970
let start = movieStart ?? commandStart
print("Video alignment: \(movieStart == nil ? "command fallback; verify manually" : "movie creation metadata") \(start)")
let log = try String(contentsOfFile: args[3])
let output = URL(fileURLWithPath: args[4], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let regex = try NSRegularExpression(pattern: "CONTROL_CAPTURE ([a-z0-9-]+) ([0-9]+\\.[0-9]+) ([0-9]+)")
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 660, height: 1600)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
var written = 0
for match in regex.matches(in: log, range: NSRange(log.startIndex..., in: log)) {
    func field(_ index: Int) -> String { String(log[Range(match.range(at: index), in: log)!]) }
    let name = field(1), timestamp = Double(field(2))!, duration = Int(field(3))!
    for index in 0..<(duration * 4 + 4) {
        let second = max(0, timestamp - start - 0.75 + Double(index) / 4)
        do {
            let full = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
            let image = full
            let url = output.appendingPathComponent(String(format: "%@-%03d.png", name, index))
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { written += 1 }
            }
        } catch { print("Frame unavailable at \(second): \(error)") }
    }
}
print("Exported \(written) native-control diagnostic frames")
