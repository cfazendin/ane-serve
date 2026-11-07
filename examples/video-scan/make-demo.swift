// Run: swift examples/video-scan/make-demo.swift /private/tmp/ane-serve-demo
// Creates original graphics and system-generated narration; no downloaded media.
import Foundation
import CoreGraphics
import CoreText
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/ane-serve-demo", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, in context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
    ]
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes)), context)
}

let titles = ["RIVER TRAIL", "LAKE TRAIL", "VISITOR CENTER"]
let subtitles = ["Follow the red route", "Follow the blue route", "Both trails meet here"]
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.55, 0.1, 0.16), (0.06, 0.24, 0.58), (0.06, 0.38, 0.22)]
for index in 0..<3 {
    let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 2560,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let color = colors[index]
    context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    text(titles[index], x: 32, y: 288, size: 40, in: context)
    text(subtitles[index], x: 32, y: 244, size: 24, in: context)
    context.setFillColor(CGColor(red: 0.84, green: 0.93, blue: 0.99, alpha: 1))
    if index == 0 {
        context.setStrokeColor(CGColor(red: 0.3, green: 0.78, blue: 1, alpha: 1))
        context.setLineWidth(52)
        context.move(to: CGPoint(x: 32, y: 70))
        context.addCurve(to: CGPoint(x: 608, y: 150), control1: CGPoint(x: 220, y: 230), control2: CGPoint(x: 400, y: -30))
        context.strokePath()
    } else if index == 1 {
        context.fillEllipse(in: CGRect(x: 180, y: 34, width: 280, height: 160))
    } else {
        context.fill(CGRect(x: 240, y: 36, width: 160, height: 120))
        context.move(to: CGPoint(x: 210, y: 156))
        context.addLine(to: CGPoint(x: 320, y: 220))
        context.addLine(to: CGPoint(x: 430, y: 156))
        context.closePath()
        context.fillPath()
        context.setFillColor(CGColor(red: 0.06, green: 0.38, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 300, y: 36, width: 40, height: 70))
    }
    let url = output.appendingPathComponent("scene\(index + 1).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write demo image") }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "Demo", code: Int(process.terminationStatus)) }
}
let narration = "Welcome to the trail guide. River Trail is marked in red. Lake Trail is marked in blue. Both trails meet at the visitor center."
try run("/usr/bin/say", ["-r", "175", "-o", output.appendingPathComponent("narration.aiff").path, narration])
let frames = "file 'scene1.png'\nduration 4\nfile 'scene2.png'\nduration 4\nfile 'scene3.png'\nduration 4\nfile 'scene3.png'\n"
try frames.write(to: output.appendingPathComponent("frames.ffconcat"), atomically: true, encoding: .utf8)
let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
guard let ffmpeg = candidates.first(where: FileManager.default.isExecutableFile) else { fatalError("Install ffmpeg first") }
try run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", output.appendingPathComponent("frames.ffconcat").path,
                 "-i", output.appendingPathComponent("narration.aiff").path, "-map", "0:v", "-map", "1:a", "-vf", "fps=24", "-af", "apad", "-t", "12",
                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart", output.appendingPathComponent("trail-guide.mp4").path])
print("Demo video: \(output.appendingPathComponent("trail-guide.mp4").path)")
