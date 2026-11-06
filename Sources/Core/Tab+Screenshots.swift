import SwiftUI
import WebKit

/// Screenshots of what's on screen, of the whole page, or of one element picked on it. Each is copied to the clipboard
/// and saved as a PNG where you choose.
extension Tab {
    /// The tallest part of a page a screenshot covers, in points: endless pages stop somewhere.
    static let longestScreenshot: CGFloat = 40_000
    /// How much of the page WebKit draws at a time for a tall screenshot.
    static let screenshotBand: CGFloat = 4_000
    /// The most pixels in one screenshot; a bigger one is drawn at a lower resolution instead of taking gigabytes.
    static let screenshotPixels: CGFloat = 100_000_000

    /// What's visible on the page.
    func screenshot() {
        guard let wv = webView, wv.window != nil else { return }
        wv.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { NSSound.beep(); return }
            self.deliverScreenshot(cg, size: image.size)
        }
    }

    /// The whole page, top to bottom. On the Mac a web view's snapshot only paints what's on screen, so the page is
    /// drawn by WebKit as a PDF instead, which lays out all of it without scrolling, and turned into pixels.
    func screenshotFullPage() {
        guard let wv = webView, wv.window != nil, url != nil else { return }
        let js = "const e = document.documentElement; return [e.clientWidth || innerWidth, Math.max(e.scrollHeight, document.body ? document.body.scrollHeight : 0)]"
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { [weak self, weak wv] result in
            guard let self, let wv, let size = (try? result.get()) as? [NSNumber], size.count == 2 else { NSSound.beep(); return }
            let width = max(1, CGFloat(size[0].doubleValue))
            let height = min(max(1, CGFloat(size[1].doubleValue)), Self.longestScreenshot)
            self.capture(CGRect(x: 0, y: 0, width: width, height: height), in: wv)
        }
    }

    /// Lets the user click the element to take a screenshot of, highlighted as in Customize This Site; ↑ picks the
    /// block around it, Esc gives up.
    func startPickingScreenshot() {
        guard let wv = webView, url != nil, !pickingElements, !pickingScreenshot else { return }
        pickingScreenshot = true
        let tip = L("Click what to take a screenshot of · ↑ for a bigger block · Esc to cancel")
        let data = (try? JSONSerialization.data(withJSONObject: [tip])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        wv.evaluateJavaScript(Scripts.picker.replacingOccurrences(of: "__TIP__", with: data + "[0]").replacingOccurrences(of: "__SHOT__", with: "true"),
                              in: nil, in: .defaultClient)
        wv.window?.makeFirstResponder(wv)
    }

    /// The element picked, by its place on the page (in page coordinates, which don't change with scrolling).
    func screenshotElement(_ rect: CGRect) {
        guard let wv = webView, rect.width >= 1, rect.height >= 1 else { NSSound.beep(); return }
        var r = rect.integral
        r.size.height = min(r.height, Self.longestScreenshot)
        // The picker's highlight is gone from the page by the next frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.capture(r, in: wv) }
    }

    /// Draws part of the page into one picture, `screenshotBand` points at a time: WebKit makes a PDF of each band on
    /// the main thread, and each is turned into pixels in the background while the next is made.
    private func capture(_ rect: CGRect, in wv: WKWebView) {
        let backing = wv.window?.backingScaleFactor ?? 2
        let scale = min(backing, (Self.screenshotPixels / (rect.width * rect.height)).squareRoot())
        let pixelWidth = Int((rect.width * scale).rounded(.up)), pixelHeight = Int((rect.height * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { NSSound.beep(); return }
        let drawing = DispatchQueue(label: "lumen.screenshot", qos: .userInitiated)
        drawing.async {
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        var bands = stride(from: rect.minY, to: rect.maxY, by: Self.screenshotBand).map {
            CGRect(x: rect.minX, y: $0, width: rect.width, height: min(Self.screenshotBand, rect.maxY - $0))
        }
        var failed = false
        func next() {
            guard !bands.isEmpty else {
                drawing.async {
                    let image = failed ? nil : ctx.makeImage()
                    DispatchQueue.main.async {
                        guard let image else { NSSound.beep(); return }
                        self.deliverScreenshot(image, size: rect.size)
                    }
                }
                return
            }
            let band = bands.removeFirst()
            let config = WKPDFConfiguration()
            config.rect = band
            wv.createPDF(configuration: config) { result in
                guard case .success(let data) = result else { failed = true; bands = []; next(); return }
                drawing.async {
                    guard let provider = CGDataProvider(data: data as CFData), let page = CGPDFDocument(provider)?.page(at: 1) else { return }
                    let box = page.getBoxRect(.mediaBox)
                    guard box.width > 0, box.height > 0 else { return }
                    // PDF and bitmap y grow upwards: the first band goes at the top of the picture.
                    let top = (band.minY - rect.minY) * scale
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: CGFloat(pixelHeight) - top - band.height * scale)
                    ctx.scaleBy(x: band.width * scale / box.width, y: band.height * scale / box.height)
                    ctx.translateBy(x: -box.minX, y: -box.minY)
                    ctx.drawPDFPage(page)
                    ctx.restoreGState()
                }
                next()
            }
        }
        next()
    }

    /// Copies the picture to the clipboard and offers to save it as a PNG, in Downloads by default.
    private func deliverScreenshot(_ cg: CGImage, size: CGSize) {
        guard let window = webView?.window else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        guard let png = rep.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(Self.fileName(title)) \(stamp).png"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url) } catch { Dialogs.saveFailed(error, window: window) }
        }
    }
}
