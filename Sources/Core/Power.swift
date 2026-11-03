import Observation
import Foundation
import Network

/// Low Power Mode and memory pressure, so Tacet does less when the Mac asks it to.
@Observable
final class Power {
    static let shared = Power()
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var memory: DispatchSourceMemoryPressure?
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var online = true

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            let on = ProcessInfo.processInfo.isLowPowerModeEnabled
            if self?.lowPower != on { self?.lowPower = on }
            if on { WindowRegistry.shared.browsers.forEach { $0.hibernateIdle() } }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            Self.relieveMemory(critical: event.contains(.critical))
        }
        source.resume()
        memory = source
        // Pages that failed while the Mac was offline load again when the connection comes back, as in Safari.
        network.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let cameBack = up && !self.online
                self.online = up
                guard cameBack else { return }
                for b in WindowRegistry.shared.browsers { b.tabs.forEach { $0.retryIfOffline() } }
            }
        }
        network.start(queue: DispatchQueue(label: "lumen.network", qos: .utility))
    }

    /// When macOS runs short of memory: background tabs idle for a couple of minutes sleep,
    /// and when it's critical every background tab sleeps and cached icons are dropped.
    static func relieveMemory(critical: Bool) {
        for b in WindowRegistry.shared.browsers {
            b.hibernate(idleFor: critical ? 0 : 120)
            if critical { b.releaseSpare() }
        }
        if critical { Favicons.shared.trimMemory() }
    }
}
