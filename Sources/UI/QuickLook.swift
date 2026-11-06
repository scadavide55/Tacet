import AppKit
import Quartz

/// Quick Look for a file Tacet shows, as the space bar does in Finder.
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var file: URL?

    /// Shows the file, or closes the preview when it's already showing that file.
    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible, file == url {
            panel.orderOut(nil)
            return
        }
        show(url)
    }

    /// Shows the file, replacing what the preview showed; nothing happens when the preview is closed.
    func follow(_ url: URL?) {
        guard let url, QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true else { return }
        show(url)
    }

    private func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        file = url
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { file == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { file as NSURL? }
}
