import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Saves a deep research report as Markdown or as a paginated PDF, with its sources listed once at the end.
enum ResearchExport {
    typealias Source = (url: URL, title: String)

    // MARK: Content

    /// The heading the report opens with, or else the question it answers.
    static func title(report: String, question: String?) -> String {
        // Only a heading the report opens with: a section heading such as "What changed" further down isn't a title.
        if case .heading(_, let text) = MarkdownBlocks.parse(report).first {
            let plain = plainText(text)
            if !plain.isEmpty { return plain }
        }
        let asked = AssistantHistory.title(question ?? "")
        return asked.isEmpty ? L("Research report") : asked
    }

    /// Each page once, in the order the research drew on them; the same address with another `#fragment` or a
    /// trailing slash counts as the same page.
    static func uniqueSources(_ sources: [Source]) -> [Source] {
        var seen = Set<String>()
        return sources.filter { seen.insert(key($0.url)).inserted }
    }

    private static func key(_ url: URL) -> String {
        var s = url.absoluteString
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    private static func name(_ source: Source) -> String {
        let t = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (source.url.host ?? source.url.absoluteString) : t
    }

    /// The report as a Markdown document: a title when the report has none of its own, the date, the report, then
    /// a Sources section with each page once.
    static func markdown(report: String, question: String?, sources: [Source], date: Date = Date()) -> String {
        let body = report.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        if !startsWithHeading(body) { out += "# " + title(report: body, question: question) + "\n\n" }
        out += "_" + date.formatted(date: .long, time: .omitted) + "_\n\n"
        out += body + "\n"
        let list = uniqueSources(sources)
        if !list.isEmpty {
            out += "\n---\n\n## " + L("Sources") + "\n\n"
            for s in list {
                let label = name(s).replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                out += "- [" + label + "](" + s.url.absoluteString + ")\n"
            }
        }
        return out
    }

    private static func startsWithHeading(_ text: String) -> Bool {
        if case .heading = MarkdownBlocks.parse(text).first { return true }
        return false
    }

    /// The report as a printable HTML page, built from the same Markdown blocks the chat shows. Sources are listed
    /// with their address written out, since a printed link can't be clicked.
    static func html(report: String, question: String?, sources: [Source], date: Date = Date()) -> String {
        let body = report.trimmingCharacters(in: .whitespacesAndNewlines)
        let docTitle = title(report: body, question: question)
        var out = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" + escape(docTitle) + "</title><style>"
            + css + "</style></head><body>\n"
        if !startsWithHeading(body) { out += "<h1>" + escape(docTitle) + "</h1>\n" }
        out += "<p class=\"date\">" + escape(date.formatted(date: .long, time: .omitted)) + "</p>\n"
        out += blocksHTML(MarkdownBlocks.parse(body))
        let list = uniqueSources(sources)
        if !list.isEmpty {
            out += "<section class=\"sources\"><h2>" + escape(L("Sources")) + "</h2>\n<ol>\n"
            for s in list {
                let href = escape(s.url.absoluteString)
                out += "<li><a href=\"" + href + "\">" + escape(name(s)) + "</a><br><span class=\"url\">" + href + "</span></li>\n"
            }
            out += "</ol></section>\n"
        }
        return out + "</body></html>\n"
    }

    private static let css = """
    body { font: 11pt/1.5 -apple-system, "Helvetica Neue", sans-serif; color: #1d1d1f; margin: 0; \
    -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    h1, h2, h3, h4, h5, h6 { font-family: ui-serif, "New York", Georgia, serif; font-weight: 600; line-height: 1.25; \
    margin: 1.2em 0 0.4em; break-after: avoid; }
    h1 { font-size: 22pt; margin-top: 0; } h2 { font-size: 16pt; } h3 { font-size: 13.5pt; } h4, h5, h6 { font-size: 11.5pt; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 0.7em; }
    p.date { color: #6e6e73; font-size: 9.5pt; margin-bottom: 1.4em; }
    ul, ol { padding-left: 1.4em; } li { margin: 0.15em 0; break-inside: avoid; }
    a { color: #0b57a4; text-decoration: none; }
    code { font: 9.5pt ui-monospace, Menlo, monospace; background: #f2f2f4; padding: 0 0.2em; border-radius: 3px; }
    pre { background: #f5f5f7; padding: 0.6em 0.8em; border-radius: 4px; white-space: pre-wrap; break-inside: avoid; }
    pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid #d2d2d7; padding-left: 0.8em; color: #424245; }
    hr { border: none; border-top: 1px solid #d2d2d7; margin: 1.2em 0; }
    table { border-collapse: collapse; font-size: 10pt; } th, td { border: 1px solid #d2d2d7; padding: 0.25em 0.5em; text-align: left; }
    th { background: #f5f5f7; } tr { break-inside: avoid; }
    .sources { margin-top: 1.6em; border-top: 1px solid #d2d2d7; } .sources li { margin-bottom: 0.4em; }
    .url { color: #6e6e73; font-size: 8.5pt; word-break: break-all; }
    """

    static func blocksHTML(_ blocks: [MarkdownBlock]) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let h = "h\(min(max(level, 1), 6))"
                out += "<\(h)>" + inline(text) + "</\(h)>\n"
            case .paragraph(let text):
                out += "<p>" + inline(text).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>\n"
            case .list(let items):
                out += listHTML(items)
            case .code(_, let text):
                out += "<pre><code>" + escape(text) + "</code></pre>\n"
            case .quote(let text):
                out += "<blockquote>" + inline(text).replacingOccurrences(of: "\n", with: "<br>\n") + "</blockquote>\n"
            case .rule:
                out += "<hr>\n"
            case .table(let header, let rows):
                out += "<table><thead><tr>" + header.map { "<th>" + inline($0) + "</th>" }.joined() + "</tr></thead><tbody>\n"
                for row in rows { out += "<tr>" + row.map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>\n" }
                out += "</tbody></table>\n"
            }
        }
        return out
    }

    /// Items into nested `<ul>`/`<ol>`, one list per indent level; numbered items keep their own numbers.
    private static func listHTML(_ items: [MarkdownBlock.Item]) -> String {
        var out = ""
        var open: [(level: Int, tag: String)] = []
        for item in items {
            let ordered = item.marker != "•"
            let tag = ordered ? "ol" : "ul"
            // Close deeper lists, and a list of the other kind at this level.
            while let last = open.last, last.level > item.level || (last.level == item.level && last.tag != tag) {
                out += "</li></\(last.tag)>"
                open.removeLast()
            }
            if let last = open.last, last.level == item.level {
                out += "</li>\n"
            } else {
                out += "<\(tag)>\n"
                open.append((item.level, tag))
            }
            let number = ordered ? Int(item.marker.dropLast()) : nil
            out += (number.map { "<li value=\"\($0)\">" } ?? "<li>") + inline(item.text).replacingOccurrences(of: "\n", with: "<br>")
        }
        while let last = open.popLast() { out += "</li></\(last.tag)>" }
        return out + "\n"
    }

    // MARK: Inline Markdown

    /// Inline Markdown as HTML: code, links, bold and italics, with everything else escaped. Code and links are set
    /// aside first so an underscore in an address or in code never turns into italics.
    static func inline(_ text: String) -> String {
        var kept: [String] = []
        func keep(_ html: String) -> String { kept.append(html); return "\u{1}\(kept.count - 1)\u{2}" }

        // Code spans.
        var s = replace(text, #"`([^`\n]+)`"#) { keep("<code>" + escape($0[1]) + "</code>") }
        // Links with a label, whose address may hold one level of parentheses, as Wikipedia's do.
        s = replace(s, #"\[((?:[^\[\]\\]|\\.)+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)"#) { m in
            let label = emphasis(escape(m[1].replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]")))
            guard let url = URL(string: m[2]), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return keep(label) }
            return keep("<a href=\"" + escape(m[2]) + "\">" + label + "</a>")
        }
        // Bare addresses in angle brackets.
        s = replace(s, #"<(https?://[^\s<>]+)>"#) { keep("<a href=\"" + escape($0[1]) + "\">" + escape($0[1]) + "</a>") }

        s = emphasis(escape(s))
        return replace(s, "\u{1}(\\d+)\u{2}") { kept[Int($0[1]) ?? 0] }
    }

    /// Bold and italics in text that's already escaped.
    private static func emphasis(_ s: String) -> String {
        var s = replace(s, #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { "<strong>" + $0[1] + "</strong>" }
        s = replace(s, #"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)"#) { "<strong>" + $0[1] + "</strong>" }
        s = replace(s, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#) { "<em>" + $0[1] + "</em>" }
        s = replace(s, #"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)"#) { "<em>" + $0[1] + "</em>" }
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ with: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            out += with(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The text of a heading without its Markdown marks, for a title or a file name.
    private static func plainText(_ s: String) -> String {
        var t = replace(s, #"\[([^\]]+)\]\([^)]*\)"#) { $0[1] }
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_")))
    }

    // MARK: PDF

    /// Letter where the US system of measurement is used, A4 everywhere else.
    static var paperSize: NSSize {
        Locale.current.measurementSystem == .us ? NSSize(width: 612, height: 792) : NSSize(width: 595.28, height: 841.89)
    }

    /// Prints the HTML into a paginated PDF in a hidden web view with JavaScript off. Nothing is loaded from the
    /// network: the page has no images or scripts, and links are only drawn.
    @MainActor static func pdf(html: String, paper: NSSize = paperSize, done: @escaping (Data?) -> Void) {
        let printer = PDFPrinter(paper: paper) { data in done(data) }
        printers.insert(printer)
        printer.start(html)
    }

    /// Printers kept alive until their PDF is written.
    @MainActor fileprivate static var printers = Set<PDFPrinter>()

    // MARK: Saving

    @MainActor static func saveMarkdown(_ message: AssistantChat.Message, question: String?) {
        let text = markdown(report: message.text, question: question, sources: message.sources, date: message.finished ?? Date())
        guard let url = ask(for: "md", type: UTType(filenameExtension: "md") ?? .plainText, message: message, question: question) else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { Dialogs.saveFailed(error, window: NSApp.keyWindow) }
    }

    @MainActor static func savePDF(_ message: AssistantChat.Message, question: String?) {
        let page = html(report: message.text, question: question, sources: message.sources, date: message.finished ?? Date())
        guard let url = ask(for: "pdf", type: .pdf, message: message, question: question) else { return }
        let window = NSApp.keyWindow
        pdf(html: page) { data in
            guard let data else { NSSound.beep(); return }
            do { try data.write(to: url) } catch { Dialogs.saveFailed(error, window: window) }
        }
    }

    @MainActor private static func ask(for ext: String, type: UTType, message: AssistantChat.Message, question: String?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = AssistantExport.fileName(title(report: message.text, question: question)) + "." + ext
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A hidden web view that lays the report out on pages and saves them as a PDF.
@MainActor private final class PDFPrinter: NSObject, WKNavigationDelegate {
    private let paper: NSSize
    private let done: (Data?) -> Void
    private let webView: WKWebView
    /// Printing needs the web view in a window; this one is never shown.
    private let window: NSWindow
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-report-\(UUID().uuidString).pdf")
    private var finished = false

    init(paper: NSSize, done: @escaping (Data?) -> Void) {
        self.paper = paper
        self.done = done
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let frame = NSRect(x: 0, y: 0, width: paper.width, height: paper.height)
        webView = WKWebView(frame: frame, configuration: config)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func start(_ html: String) {
        webView.loadHTMLString(html, baseURL: nil)
        // A page that never finishes loading still ends, with nothing saved.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the report itself; nothing else is ever loaded.
        decisionHandler(action.request.url?.scheme == "about" || action.request.url == nil ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: file])
        info.jobDisposition = .save
        info.paperSize = paper
        let margin: CGFloat = 54
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(x: 0, y: 0, width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        op.runModal(for: window, delegate: self, didRun: #selector(printed(_:success:contextInfo:)), contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    /// AppKit calls this on the print operation's own thread, so the rest happens back on the main one.
    @objc nonisolated private func printed(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { finish(success ? try? Data(contentsOf: file) : nil) }
        }
    }

    private func finish(_ data: Data?) {
        guard !finished else { return }
        finished = true
        try? FileManager.default.removeItem(at: file)
        window.contentView = nil
        ResearchExport.printers.remove(self)
        done(data)
    }
}

extension AssistantChat {
    /// What the user asked just before this reply, for the title of an exported report.
    func question(before id: UUID) -> String? {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return messages[..<i].last { $0.role == .user }?.text
    }
}

/// "Export Report" in a research reply's action row: Markdown or PDF.
struct ResearchExportMenu: View {
    let message: AssistantChat.Message
    var question: String?

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .help("Export Report")
        .accessibilityLabel("Export Report")
    }

    /// The two choices, also used in the reply's context menu.
    @ViewBuilder var items: some View {
        Button("Markdown…") { ResearchExport.saveMarkdown(message, question: question) }
        Button("PDF…") { ResearchExport.savePDF(message, question: question) }
    }
}
