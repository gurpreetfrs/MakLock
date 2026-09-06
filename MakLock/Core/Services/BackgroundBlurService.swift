import AppKit

final class BackgroundBlurService {
    static let shared = BackgroundBlurService()

    private var targetPIDs: Set<pid_t> = []
    private var timer: Timer?
    private var windowPanels: [Int: BlurCoverPanel] = [:]
    private var regionPanels: [BlurCoverPanel] = []
    private var useRelativeOrdering = true
    private var orderingVerified = false
    private let maxRegionPanels = 48

    private init() {}

    func setTargets(_ pids: Set<pid_t>) {
        let changed = pids != targetPIDs
        if changed {
            NSLog("[MakLock Blur] targets: %@", pids.map(String.init).joined(separator: ","))
        }
        targetPIDs = pids
        if pids.isEmpty {
            stop()
        } else {
            start()
            if changed { refresh() }
        }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = 0.05
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        windowPanels.values.forEach { $0.orderOut(nil) }
        regionPanels.forEach { $0.orderOut(nil) }
    }

    private struct Entry {
        let pid: pid_t
        let number: Int
        let layer: Int
        let bounds: CGRect
        let visible: Bool
        var isTarget: Bool
    }

    private var ownPanelNumbers: Set<Int> {
        Set(windowPanels.values.map { $0.windowNumber } + regionPanels.map { $0.windowNumber })
    }

    private func snapshot() -> [Entry]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let overlayLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var entries: [Entry] = []
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if pid == ownPID && layer >= overlayLayer { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let visible = alpha > 0.01
            entries.append(Entry(
                pid: pid, number: number, layer: layer, bounds: bounds, visible: visible,
                isTarget: visible && layer == 0 && bounds.width >= 50 && bounds.height >= 50 && targetPIDs.contains(pid)
            ))
        }
        return entries
    }

    private func refresh() {
        guard let entries = snapshot() else { return }
        if useRelativeOrdering {
            refreshRelative(entries)
        } else {
            refreshRegions(entries)
        }
    }

    private func appKitFrame(_ r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private func refreshRelative(_ entries: [Entry]) {
        let own = ownPanelNumbers
        let targets = entries.filter { $0.isTarget && !own.contains($0.number) }
        var seen = Set<Int>()

        for t in targets {
            let panel = windowPanels[t.number] ?? {
                let p = BlurCoverPanel(level: .normal)
                windowPanels[t.number] = p
                return p
            }()
            let frame = appKitFrame(t.bounds)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            panel.showsIcon = frame.width >= 120 && frame.height >= 120
            panel.order(.above, relativeTo: t.number)
            seen.insert(t.number)
        }
        for (number, panel) in windowPanels where !seen.contains(number) {
            panel.orderOut(nil)
            windowPanels[number] = nil
        }

        if !orderingVerified, !targets.isEmpty {
            verifyOrdering(targets: targets)
        }
    }

    private func verifyOrdering(targets: [Entry]) {
        guard let after = snapshot() else { return }
        let index: [Int: Int] = Dictionary(uniqueKeysWithValues: after.enumerated().map { ($1.number, $0) })
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontIndex = after.firstIndex { $0.pid == frontPID && $0.layer == 0 && $0.visible }

        var checked = false
        for t in targets {
            guard let panel = windowPanels[t.number],
                  let panelIndex = index[panel.windowNumber],
                  let targetIndex = index[t.number] else { continue }
            checked = true
            let abovePanelTarget = panelIndex < targetIndex
            let behindFrontApp = frontIndex.map { $0 < targetIndex ? panelIndex > $0 : true } ?? true
            if !(abovePanelTarget && behindFrontApp) {
                NSLog("[MakLock Blur] relative ordering not honoured (panel=%d target=%d front=%@); using region mode",
                      panelIndex, targetIndex, frontIndex.map(String.init) ?? "none")
                useRelativeOrdering = false
                windowPanels.values.forEach { $0.orderOut(nil) }
                windowPanels.removeAll()
                orderingVerified = true
                refreshRegions(after)
                return
            }
        }
        if checked {
            orderingVerified = true
            NSLog("[MakLock Blur] relative ordering verified")
        }
    }

    private func refreshRegions(_ entries: [Entry]) {
        let own = ownPanelNumbers
        var rects: [CGRect] = []
        for (i, entry) in entries.enumerated() where entry.isTarget && !own.contains(entry.number) {
            var pieces = [entry.bounds]
            for j in 0..<i where entries[j].visible && entries[j].layer >= 0 && !own.contains(entries[j].number) {
                pieces = pieces.flatMap { Self.subtract($0, entries[j].bounds) }
                if pieces.isEmpty { break }
            }
            rects.append(contentsOf: pieces)
        }
        rects = rects.filter { $0.width >= 2 && $0.height >= 2 }
        if rects.count > maxRegionPanels {
            rects = entries.filter { $0.isTarget && !own.contains($0.number) }.map(\.bounds)
        }

        while regionPanels.count < min(rects.count, maxRegionPanels) {
            regionPanels.append(BlurCoverPanel(level: .floating))
        }
        for (i, panel) in regionPanels.enumerated() {
            if i < rects.count {
                let frame = appKitFrame(rects[i])
                if panel.frame != frame { panel.setFrame(frame, display: true) }
                panel.showsIcon = frame.width >= 120 && frame.height >= 120
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    private static func subtract(_ r: CGRect, _ o: CGRect) -> [CGRect] {
        let i = r.intersection(o)
        guard !i.isNull, !i.isEmpty else { return [r] }
        var out: [CGRect] = []
        if i.minY > r.minY {
            out.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: i.minY - r.minY))
        }
        if i.maxY < r.maxY {
            out.append(CGRect(x: r.minX, y: i.maxY, width: r.width, height: r.maxY - i.maxY))
        }
        if i.minX > r.minX {
            out.append(CGRect(x: r.minX, y: i.minY, width: i.minX - r.minX, height: i.height))
        }
        if i.maxX < r.maxX {
            out.append(CGRect(x: i.maxX, y: i.minY, width: r.maxX - i.maxX, height: i.height))
        }
        return out
    }
}

final class BlurCoverPanel: NSPanel {
    private let iconView = NSImageView()

    var showsIcon: Bool = false {
        didSet { iconView.isHidden = !showsIcon }
    }

    init(level: NSWindow.Level) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = level
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        tint.autoresizingMask = [.width, .height]

        iconView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 36, weight: .medium))
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isHidden = true

        contentView = effect
        tint.frame = effect.bounds
        effect.addSubview(tint)
        effect.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
