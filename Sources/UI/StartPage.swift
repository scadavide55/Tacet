import AVFoundation
import SwiftUI

struct StartPage: View {
    var tab: Tab
    @Environment(BrowserState.self) var b
    @Bindable private var s = Settings.shared
    private var bookmarks = Bookmarks.shared
    private var blocker = ContentBlocker.shared

    private var light: Bool { s.startBackground == .plain }

    var body: some View {
        ZStack {
            StartBackgroundView(style: s.startBackground, isPrivate: b.isPrivate)
            VStack(spacing: 24) {
                Spacer(minLength: 40)
                if s.showClock {
                    TimelineView(.everyMinute) { ctx in
                        Text(ctx.date, format: .dateTime.hour().minute())
                            .font(.system(size: 78, weight: .thin, design: .rounded))
                            .monospacedDigit()
                    }
                }
                if b.isPrivate {
                    VStack(spacing: 6) {
                        Label("Private browsing", systemImage: "eyeglasses").font(.system(size: 20, weight: .semibold))
                        Text("Tacet forgets the history, cookies and site data of this window when you close it.")
                            .font(.system(size: 13)).opacity(0.75)
                    }
                } else if s.showGreeting {
                    Text(greeting).font(.system(size: 20, weight: .medium)).opacity(0.9)
                }
                SearchPill(engine: s.engine.name, light: light) { b.showPalette("") }
                if s.showFavorites && !bookmarks.items.isEmpty {
                    FavoritesGrid(items: Array(bookmarks.items.prefix(12)), light: light) { tab.load($0) }
                }
                Spacer(minLength: 40)
                HStack(spacing: 6) {
                    Image(systemName: s.adBlock ? "shield.lefthalf.filled" : "shield.slash")
                    Text(s.adBlock ? LocalizedStringKey("Tacet Shield is blocking ads and trackers · \(blocker.ruleCount.formatted()) rules") : "Tacet Shield is off")
                }
                .font(.system(size: 11.5))
                .opacity(0.65)
                .padding(.bottom, 18)
            }
            .foregroundStyle(light ? Color.primary : Color.white)
            .padding(.horizontal, 40)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let base = L(h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : h < 22 ? "Good evening" : "Good night")
        let name = s.userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? base : "\(base), \(name)"
    }
}

struct SearchPill: View {
    let engine: String
    let light: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                Text("Search with \(engine) or enter an address").font(.system(size: 15))
                Spacer()
                Text("⌘L").font(.system(size: 11, weight: .medium, design: .rounded)).opacity(0.6)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: 560, minHeight: 48)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(light ? AnyShapeStyle(Color.primary.opacity(hover ? 0.09 : 0.06)) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(light ? 0 : 0.18)))
            }
            .scaleEffect(hover ? 1.01 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct FavoritesGrid: View {
    let items: [Bookmark]
    let light: Bool
    let open: (URL) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 100), spacing: 14)], spacing: 14) {
            ForEach(items) { bm in
                FavoriteTile(bookmark: bm, light: light) { open(bm.url) }
            }
        }
        .frame(maxWidth: 600)
    }
}

struct FavoriteTile: View {
    let bookmark: Bookmark
    let light: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(light ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(.ultraThinMaterial))
                    if let icon = Favicons.shared.cached(bookmark.url.host) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        // The name, not the host: "it.yahoo.com" would show an I for Yahoo.
                        Text(String((bookmark.title.isEmpty ? InputResolver.displayHost(bookmark.url) : bookmark.title).prefix(1)).uppercased())
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                    }
                }
                .frame(width: 60, height: 60)
                .scaleEffect(hover ? 1.06 : 1)
                Text(bookmark.title).font(.system(size: 11)).lineLimit(1).opacity(0.85)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            Button("Remove Bookmark") { Bookmarks.shared.remove([bookmark.id]) }
        }
        .help(bookmark.url.absoluteString)
    }
}

struct StartBackgroundView: View {
    let style: StartBackground
    let isPrivate: Bool

    /// The chosen picture, read from disk once rather than for every new tab.
    private static var cachedImage: (path: String, date: Date?, image: NSImage)?

    private static func image(at path: String) -> NSImage? {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let c = cachedImage, c.path == path, c.date == date { return c.image }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cachedImage = (path, date, img)
        return img
    }
    @Bindable private var s = Settings.shared
    private var power = Power.shared

    /// Backgrounds hold still in Low Power Mode.
    private var animated: Bool { s.animateBackground && !power.lowPower }

    var body: some View {
        if isPrivate {
            AnimatedGradient(base: [0x1A1033, 0x2E1A57], blobs: [0x7B4DDB, 0x3B2A8C], animated: animated)
        } else {
            switch style {
            case .image:
                if let img = Self.image(at: s.startImagePath) {
                    GeometryReader { g in
                        Image(nsImage: img).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                            .overlay(Color.black.opacity(0.25))
                    }
                } else {
                    Self.fallback
                }
            case .video:
                if FileManager.default.fileExists(atPath: s.startVideoPath) {
                    VideoBackground(url: URL(fileURLWithPath: s.startVideoPath), paused: power.lowPower).overlay(Color.black.opacity(0.25))
                } else {
                    Self.fallback
                }
            case .plain:
                Color(nsColor: .textBackgroundColor)
            case .accent:
                LinearGradient(colors: [s.accent, s.accent.opacity(0.55), .black.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .flow:
                FlowGradient(animated: !power.lowPower)
            default:
                let p = Self.presets[style] ?? Self.presets[.aurora]!
                AnimatedGradient(base: p.0, blobs: p.1, animated: animated)
            }
        }
    }

    static let presets: [StartBackground: ([UInt32], [UInt32])] = [
        .aurora: ([0x0B1026, 0x1B2A6B], [0x2EC4B6, 0x8E44AD]),
        .dusk: ([0x2B1B3F, 0x7A2E58], [0xFF8A5B, 0xFFC371]),
        .ocean: ([0x03152B, 0x0B3D6E], [0x00B4D8, 0x48CAE4]),
        .forest: ([0x0B2016, 0x1E4D3A], [0x52B788, 0x95D5B2]),
        .ember: ([0x2A0E0E, 0x6B1E1E], [0xFF6B35, 0xFFB347]),
        .graphite: ([0x1C1C1E, 0x3A3A3C], [0x636366, 0x8E8E93]),
    ]

    private static var fallback: some View {
        AnimatedGradient(base: [0x0B1026, 0x1B2A6B], blobs: [0x2EC4B6, 0x8E44AD], animated: false)
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A preset gradient whose two glows can drift slowly around the page.
struct AnimatedGradient: View {
    let base: [UInt32]
    let blobs: [UInt32]
    let animated: Bool

    var body: some View { GradientLayers(style: .preset(base: base, blobs: blobs, animated: animated)) }
}

/// Colours that slowly shift around the hue wheel.
struct FlowGradient: View {
    var animated = true
    var body: some View { GradientLayers(style: .flow(animated: animated)) }
}

/// Draws the start page gradients with Core Animation. The motion runs in the window server,
/// so it costs the app nothing per frame and never competes with typing or scrolling.
struct GradientLayers: NSViewRepresentable {
    enum Style: Equatable {
        case preset(base: [UInt32], blobs: [UInt32], animated: Bool)
        case flow(animated: Bool)
    }
    let style: Style

    func makeNSView(context: Context) -> GradientLayerView { GradientLayerView(style: style) }
    func updateNSView(_ v: GradientLayerView, context: Context) { if v.style != style { v.style = style } }
}

final class GradientLayerView: NSView {
    var style: GradientLayers.Style { didSet { rebuild() } }
    private let base = CAGradientLayer()
    private let glows = [CAGradientLayer(), CAGradientLayer()]
    private var builtSize = CGSize.zero

    init(style: GradientLayers.Style) {
        self.style = style
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(base)
        for g in glows {
            g.type = .radial
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        ([base] + glows).forEach { $0.contentsScale = scale }
    }

    private func rebuild() {
        let size = bounds.size
        builtSize = size
        guard size.width > 0, size.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ([base] + glows).forEach { $0.removeAllAnimations() }
        base.frame = bounds
        let d = max(size.width, size.height)
        // SwiftUI unit points start at the top; layers start at the bottom.
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * size.width, y: (1 - y) * size.height) }

        switch style {
        case .preset(let baseHex, let blobs, let animated):
            base.colors = baseHex.map { Self.cg($0) }
            base.startPoint = CGPoint(x: 0.5, y: 1)
            base.endPoint = CGPoint(x: 0.5, y: 0)
            let radii = [d * 0.6, d * 0.65]
            let alphas = [0.55, 0.45]
            let paths: [(Double) -> (Double, Double)] = [
                { t in (0.2 + 0.18 * sin(t / 6), 0.15 + 0.15 * cos(t / 8)) },
                { t in (0.8 + 0.15 * cos(t / 7), 0.85 + 0.12 * sin(t / 5)) },
            ]
            let still = [(0.15, 0.1), (0.9, 0.95)]
            for (i, g) in glows.enumerated() {
                g.bounds = CGRect(x: 0, y: 0, width: radii[i] * 2, height: radii[i] * 2)
                g.colors = [Self.cg(blobs[i], alpha: alphas[i]), Self.cg(blobs[i], alpha: 0)]
                if animated {
                    let f = paths[i]
                    let now = f(Self.now)
                    g.position = point(now.0, now.1)
                    let periods = i == 0 ? (6.0, 8.0) : (7.0, 5.0)
                    g.add(Self.drift("position.x", period: 2 * .pi * periods.0) { t in point(f(t).0, 0).x }, forKey: "x")
                    g.add(Self.drift("position.y", period: 2 * .pi * periods.1) { t in point(0, f(t).1).y }, forKey: "y")
                } else {
                    g.position = point(still[i].0, still[i].1)
                }
            }

        case .flow(let animated):
            func hue(_ h: Double, _ s: Double, _ b: Double, _ a: Double = 1) -> CGColor {
                NSColor(colorSpace: .sRGB, hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: a).cgColor
            }
            func h(_ t: Double) -> Double { (t / 60).truncatingRemainder(dividingBy: 1) }
            func baseColors(_ t: Double) -> [CGColor] { [hue(h(t), 0.55, 0.28), hue(h(t) + 0.12, 0.6, 0.42)] }
            func ends(_ t: Double) -> (CGPoint, CGPoint) {
                let c = cos(t / 9)
                return (CGPoint(x: 0.5 + 0.5 * c, y: 1), CGPoint(x: 0.5 - 0.5 * c, y: 0))
            }
            let t0 = Self.now
            base.colors = baseColors(t0)
            (base.startPoint, base.endPoint) = ends(t0)
            if animated {
                base.add(Self.drift("colors", period: 60) { baseColors($0) }, forKey: "colors")
                base.add(Self.drift("startPoint", period: 2 * .pi * 9) { NSValue(point: ends($0).0) }, forKey: "start")
                base.add(Self.drift("endPoint", period: 2 * .pi * 9) { NSValue(point: ends($0).1) }, forKey: "end")
            }

            let glowSpecs: [(radius: Double, shift: Double, b: Double, a: Double, x: (Double) -> Double, y: (Double) -> Double, px: Double, py: Double)] = [
                (0.55, 0.3, 0.75, 0.5, { 0.3 + 0.25 * sin($0 / 7) }, { 0.3 + 0.2 * cos($0 / 11) }, 7, 11),
                (0.6, 0.55, 0.7, 0.45, { 0.75 + 0.2 * cos($0 / 8) }, { 0.75 + 0.2 * sin($0 / 10) }, 8, 10),
            ]
            for (g, spec) in zip(glows, glowSpecs) {
                let r = d * spec.radius
                g.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
                func colors(_ t: Double) -> [CGColor] {
                    [hue(h(t) + spec.shift, 0.7, spec.b, spec.a), hue(h(t) + spec.shift, 0.7, spec.b, 0)]
                }
                g.colors = colors(t0)
                g.position = point(spec.x(t0), spec.y(t0))
                guard animated else { continue }
                g.add(Self.drift("colors", period: 60) { colors($0) }, forKey: "colors")
                g.add(Self.drift("position.x", period: 2 * .pi * spec.px) { point(spec.x($0), 0).x }, forKey: "x")
                g.add(Self.drift("position.y", period: 2 * .pi * spec.py) { point(0, spec.y($0)).y }, forKey: "y")
            }
        }
        CATransaction.commit()
    }

    private static var now: Double { Date.timeIntervalSinceReferenceDate }

    /// A looping animation sampled from a periodic function of time, starting at the current phase.
    private static func drift(_ key: String, period: Double, _ f: (Double) -> Any) -> CAKeyframeAnimation {
        let samples = 72
        let a = CAKeyframeAnimation(keyPath: key)
        a.values = (0...samples).map { f(Double($0) / Double(samples) * period) }
        a.duration = period
        a.repeatCount = .infinity
        a.calculationMode = .linear
        a.isRemovedOnCompletion = false
        a.timeOffset = now.truncatingRemainder(dividingBy: period)
        // Slow drift doesn't need 120 Hz; this keeps ProMotion and Low Power Mode cheap.
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        return a
    }

    static func cg(_ hex: UInt32, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// A muted, looping video. It pauses on its first frame while `paused` (Low Power Mode).
struct VideoBackground: NSViewRepresentable {
    let url: URL
    var paused = false

    func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateNSView(_ v: PlayerView, context: Context) {
        v.play(url)
        v.paused = paused
    }
    static func dismantleNSView(_ v: PlayerView, coordinator: ()) { v.stop() }

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var current: URL?
        var paused = false {
            didSet { if paused != oldValue { syncPlayback() } }
        }

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            play(url)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func play(_ url: URL) {
            guard url != current else { return }
            current = url
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            syncPlayback()
        }

        func stop() {
            player.pause()
            looper = nil
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            occlusion = nil
        }

        private var occlusion: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            occlusion = nil
            guard let window else { player.pause(); return }
            // Decoding stops while the window is hidden, minimised or covered.
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                               object: window, queue: .main) { [weak self] _ in self?.syncPlayback() }
            syncPlayback()
        }

        private func syncPlayback() {
            guard looper != nil, let window else { player.pause(); return }
            window.occlusionState.contains(.visible) && !paused ? player.play() : player.pause()
        }
    }
}
