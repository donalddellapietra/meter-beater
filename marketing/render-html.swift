// Renders a local HTML file to a PNG at an exact pixel size using WebKit.
// usage: swift render-html.swift <in.html> <out.png> <width> <height>
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count == 5,
      let width = Int(arguments[3]),
      let height = Int(arguments[4]) else {
    FileHandle.standardError.write(Data("usage: render-html <in.html> <out.png> <width> <height>\n".utf8))
    exit(2)
}
let htmlURL = URL(fileURLWithPath: arguments[1])
let outURL = URL(fileURLWithPath: arguments[2])
let size = NSSize(width: width, height: height)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let outURL: URL
    let pixelSize: NSSize

    init(webView: WKWebView, outURL: URL, pixelSize: NSSize) {
        self.webView = webView
        self.outURL = outURL
        self.pixelSize = pixelSize
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let images and fonts settle before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.capture() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("navigation failed: \(error)\n".utf8))
        exit(1)
    }

    private func capture() {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: pixelSize)
        webView.takeSnapshot(with: configuration) { image, error in
            guard let image else {
                FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                exit(1)
            }
            guard let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(self.pixelSize.width),
                pixelsHigh: Int(self.pixelSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { exit(1) }
            representation.size = self.pixelSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(
                in: NSRect(origin: .zero, size: self.pixelSize),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
            guard let data = representation.representation(using: .png, properties: [:]) else { exit(1) }
            do {
                try data.write(to: self.outURL)
            } catch {
                FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
                exit(1)
            }
            exit(0)
        }
    }
}

let window = NSWindow(
    contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
let webView = WKWebView(frame: NSRect(origin: .zero, size: size))
let renderer = Renderer(webView: webView, outURL: outURL, pixelSize: size)
webView.navigationDelegate = renderer
window.contentView = webView
window.orderBack(nil)
webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    FileHandle.standardError.write(Data("timed out\n".utf8))
    exit(1)
}
app.run()
