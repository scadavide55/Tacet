import SwiftUI

/// The Develop menu, in the menu bar and in the page's ⋯ menu, while Developer Mode is on.
struct DevelopMenuItems: View {
    let b: BrowserState?
    /// Only the menu bar's copy has keyboard shortcuts, so each shortcut is registered once.
    var shortcuts = false

    private var tab: Tab? { b?.current }
    private var hasPage: Bool { tab?.url != nil }

    var body: some View {
        Button("Show Web Inspector") { DevTools.showInspector(tab) }
            .shortcut("i", [.command, .option], shortcuts).disabled(!hasPage)
        Button("Show JavaScript Console") { DevTools.showConsole(tab) }
            .shortcut("c", [.command, .option], shortcuts).disabled(!hasPage)
        Button("Show Page Resources") { DevTools.showResources(tab) }.disabled(!hasPage)
        Button("Inspect Element…") { DevTools.pickElement(tab) }
            .shortcut("c", [.command, .option, .shift], shortcuts).disabled(!hasPage)
        Button("View Page Source") { DevTools.viewSource(tab) }
            .shortcut("u", [.command, .option], shortcuts).disabled(!hasPage)
        Button("Page Info") { DevTools.pageInfo(tab) }.disabled(!hasPage)
        Divider()
        Menu("Responsive Design Mode") {
            Toggle("Off", isOn: Binding(get: { tab?.device == nil }, set: { if $0 { DevTools.setDevice(nil, on: tab) } }))
            Divider()
            ForEach(DevDevice.all) { d in
                Toggle("\(d.name) — \(Int(d.width)) × \(Int(d.height))",
                       isOn: Binding(get: { tab?.device == d }, set: { if $0 { DevTools.setDevice(d, on: tab) } }))
            }
            Divider()
            Button("Custom Size…") { DevTools.askCustomDevice(tab) }
        }
        .disabled(tab == nil)
        Menu("User Agent") {
            Toggle("Default", isOn: Binding(get: { tab?.devUserAgent == nil }, set: { if $0 { DevTools.setUserAgent(nil, on: tab) } }))
            Divider()
            ForEach(DevUserAgent.allCases) { ua in
                Toggle(ua.name, isOn: Binding(get: { tab?.devUserAgent == ua.value }, set: { if $0 { DevTools.setUserAgent(ua, on: tab) } }))
            }
        }
        .disabled(tab == nil)
        let browsers = DevTools.browsers(for: tab?.url)
        if !browsers.isEmpty {
            Menu("Open Page With") {
                ForEach(browsers, id: \.self) { app in
                    Button(DevTools.appName(app)) { DevTools.open(tab?.url, with: app) }
                }
            }
        }
        Divider()
        Toggle("Disable JavaScript", isOn: Binding(get: { tab?.javaScriptOff ?? false }, set: { _ in DevTools.toggleJavaScript(tab) }))
            .disabled(!hasPage)
        Button("Disable Styles") { DevTools.toggleStyles(tab) }.disabled(!hasPage)
        Button("Show Element Outlines") { DevTools.toggleOutlines(tab) }.disabled(!hasPage)
        Button("Edit Page Text") { DevTools.toggleEditing(tab) }.disabled(!hasPage)
        Divider()
        Button("Empty Caches") { DevTools.emptyCaches(tab) }
            .shortcut("e", [.command, .option], shortcuts)
        Button("Clear Data for This Site…") { DevTools.clearSiteData(tab) }.disabled(tab?.host == nil)
    }
}

private extension View {
    @ViewBuilder
    func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers, _ on: Bool) -> some View {
        if on { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}

/// The page at a phone or tablet size, centred, with its size and a button to turn it sideways. Without a device
/// it adds nothing; it keeps the same structure either way so the web view stays in one container.
struct DeviceFrame<Content: View>: View {
    var tab: Tab
    @ViewBuilder let content: Content

    var body: some View {
        let device = tab.device
        let w = device.map { tab.deviceLandscape ? $0.height : $0.width }
        let h = device.map { tab.deviceLandscape ? $0.width : $0.height }
        VStack(spacing: 0) {
            if let device, let w, let h {
                HStack(spacing: 10) {
                    Text(device.name).font(.system(size: 12, weight: .semibold))
                    Text("\(Int(w)) × \(Int(h))").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Button { tab.deviceLandscape.toggle() } label: { Image(systemName: "rotate.right") }
                        .buttonStyle(.borderless).help("Rotate").accessibilityLabel("Rotate")
                    Button { DevTools.setDevice(nil, on: tab) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Exit Responsive Design Mode").accessibilityLabel("Exit Responsive Design Mode")
                }
                .padding(.vertical, 8)
            }
            GeometryReader { geo in
                content
                    .frame(width: w.map { min($0, geo.size.width) } ?? geo.size.width,
                           height: h.map { min($0, geo.size.height) } ?? geo.size.height)
                    // The shadow is drawn by a shape behind the page, never by the page's own view, so scrolling stays smooth.
                    .background {
                        if device != nil {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding([.horizontal, .bottom], device == nil ? 0 : 12)
        }
        .background(device == nil ? Color.clear : Color(nsColor: .underPageBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: tab.deviceLandscape)
    }
}
