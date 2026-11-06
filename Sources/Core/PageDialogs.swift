import AppKit

/// Whether to offer to stop a page's dialogs: from the second one it shows within a short time, as Safari does.
struct DialogPolicy {
    static let span: TimeInterval = 30
    private(set) var shown: [Date] = []

    /// Notes a dialog shown at `date`, and says whether it should offer "Don't show more dialogs from this page".
    mutating func record(_ date: Date = Date()) -> Bool {
        shown = shown.filter { date.timeIntervalSince($0) < Self.span }
        shown.append(date)
        return shown.count >= 2
    }

    mutating func reset() { shown = [] }
}

/// A page's JavaScript dialogs (alert, confirm, prompt), shown one at a time as a sheet on the page's own window and
/// never as an alert that stops the whole app, so a page that calls alert() in a loop can't lock Tacet. A dialog
/// from a tab in the background waits until the tab is in front. From the second dialog in a short time, a checkbox
/// stops the page showing more until it navigates. WebKit always gets its answer, even when the page goes away.
/// Used on the main thread only, like the web views it serves.
final class PageDialogs {
    enum Kind { case alert, confirm, prompt(defaultText: String) }

    private struct Pending {
        let kind: Kind
        let title: String
        let message: String
        /// `ok` is true for OK; `text` is the prompt's answer.
        let done: (_ ok: Bool, _ text: String?) -> Void
    }

    /// The window to show on, or nil while the page isn't in front.
    var host: () -> NSWindow? = { nil }
    /// Called with true when a dialog is waiting for its tab to come to the front, and false when it no longer is.
    var onWaiting: (Bool) -> Void = { _ in }

    private var queue: [Pending] = []
    private var current: NSAlert?
    private var policy = DialogPolicy()
    private(set) var silenced = false
    private var sheetObserver: NSObjectProtocol?

    var isWaiting: Bool { current == nil && !queue.isEmpty }

    func alert(title: String, message: String, done: @escaping () -> Void) {
        enqueue(Pending(kind: .alert, title: title, message: message) { _, _ in done() })
    }

    func confirm(title: String, message: String, done: @escaping (Bool) -> Void) {
        enqueue(Pending(kind: .confirm, title: title, message: message) { ok, _ in done(ok) })
    }

    func prompt(title: String, message: String, defaultText: String, done: @escaping (String?) -> Void) {
        enqueue(Pending(kind: .prompt(defaultText: defaultText), title: title, message: message) { ok, text in done(ok ? text : nil) })
    }

    private func enqueue(_ p: Pending) {
        // Stopped by the user: alerts are dismissed, confirms answered Cancel and prompts left empty, at once.
        if silenced { p.done(false, nil); return }
        queue.append(p)
        showNext()
    }

    /// Shows the next waiting dialog if the page is in front and its window has no other sheet open.
    func showNext() {
        guard current == nil, let next = queue.first else { return }
        guard let window = host() else { onWaiting(true); return }
        if window.attachedSheet != nil {
            // Another sheet (a save panel, a sign-in): the dialog waits for it to close.
            guard sheetObserver == nil else { return }
            sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let o = self.sheetObserver { NotificationCenter.default.removeObserver(o) }
                    self.sheetObserver = nil
                    self.showNext()
                }
            }
            return
        }
        queue.removeFirst()
        onWaiting(false)
        let a = NSAlert()
        a.messageText = next.title.isEmpty ? L("This page says") : next.title
        a.informativeText = next.message
        a.addButton(withTitle: L("OK"))
        var field: NSTextField?
        switch next.kind {
        case .alert: break
        case .confirm: a.addButton(withTitle: L("Cancel"))
        case .prompt(let text):
            a.addButton(withTitle: L("Cancel"))
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            f.stringValue = text
            a.accessoryView = f
            a.window.initialFirstResponder = f
            field = f
        }
        if policy.record() {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = L("Don't show more dialogs from this page")
        }
        current = a
        a.beginSheetModal(for: window) { [weak self] response in
            let ok = response == .alertFirstButtonReturn
            next.done(ok, field?.stringValue)
            guard let self else { return }
            if self.current === a { self.current = nil }
            if a.showsSuppressionButton, a.suppressionButton?.state == .on {
                self.silenced = true
                let waiting = self.queue
                self.queue = []
                for p in waiting { p.done(false, nil) }
            }
            self.showNext()
        }
    }

    /// The page navigated or closed: dialogs open or waiting are answered as cancelled, and a page that was stopped
    /// may show dialogs again.
    func reset() {
        let waiting = queue
        queue = []
        if let a = current {
            current = nil
            // Ending the sheet runs its handler, which answers WebKit.
            a.window.sheetParent?.endSheet(a.window, returnCode: .alertSecondButtonReturn)
        }
        for p in waiting { p.done(false, nil) }
        if let o = sheetObserver { NotificationCenter.default.removeObserver(o) }
        sheetObserver = nil
        policy.reset()
        silenced = false
        onWaiting(false)
    }
}
