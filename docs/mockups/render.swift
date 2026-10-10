// Renders a mockup HTML page to a 2x PNG with a transparent background.
//   swift docs/mockups/render.swift docs/mockups/after.html docs/hoot-after.png
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: render.swift <page.html> <out.png>") }
let page = URL(fileURLWithPath: args[1]).standardizedFileURL
let out = URL(fileURLWithPath: args[2])
let repoRoot = page.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let width: CGFloat = 1280 // .window is 1200px plus 40px padding each side

final class Renderer: NSObject, WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // Give images and fonts a moment, then size the view to the page and snapshot it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
        let height = CGFloat((result as? Double) ?? 800)
        webView.setFrameSize(NSSize(width: width, height: height))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          let config = WKSnapshotConfiguration()
          config.rect = CGRect(x: 0, y: 0, width: width, height: height)
          config.snapshotWidth = NSNumber(value: Double(width)) // points; Retina backing makes it 2x
          webView.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
              fatalError("snapshot failed: \(String(describing: error))")
            }
            try! png.write(to: out)
            print("\(out.path): \(rep.pixelsWide)x\(rep.pixelsHigh)")
            exit(0)
          }
        }
      }
    }
  }
}

let app = NSApplication.shared
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
webView.setValue(false, forKey: "drawsBackground") // keep the area around the window transparent
webView.appearance = NSAppearance(named: .darkAqua)
let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView
let renderer = Renderer()
webView.navigationDelegate = renderer
webView.loadFileURL(page, allowingReadAccessTo: repoRoot)
app.run()
