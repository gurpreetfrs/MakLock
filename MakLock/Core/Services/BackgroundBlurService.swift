import AppKit

final class BackgroundBlurService {
    static let shared = BackgroundBlurService()

    private var targetPIDs: Set<pid_t> = []
    private var timer: Timer?
    private var panels: [BlurCoverPanel] = []
    private let maxPanels = 48
    private var lastLoggedTargets = -1
    private var lastLoggedRects = -1

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
        let t = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = 0.03
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        panels.forEach { $0.orderOut(nil) }
    }

    private struct Entry {
        let bounds: CGRect
        let occludes: Bool
        let isTarget: Bool
    }

    private func refresh() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownPanelNumbers = Set(panels.map { $0.windowNumber })
        let overlayLayer = Int(CGWindowLevelForKey(.screenSaverWindow))

        var entries: [Entry] = []
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if pid == ownPID && (ownPanelNumbers.contains(number) || layer >= overlayLayer) { continue }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let visible = alpha > 0.01
            entries.append(Entry(
                bounds: bounds,
                occludes: visible && layer >= 0,
                isTarget: visible && layer == 0 && bounds.width >= 50 && bounds.height >= 50 && targetPIDs.contains(pid)
            ))
        }

        var rects: [CGRect] = []
        for (i, entry) in entries.enumerated() where entry.isTarget {
            var pieces = [entry.bounds]
            for j in 0..<i where entries[j].occludes {
                pieces = pieces.flatMap { Self.subtract($0, entries[j].bounds) }
                if pieces.isEmpty { break }
            }
            rects.append(contentsOf: pieces)
        }
        rects = rects.filter { $0.width >= 2 && $0.height >= 2 }
        if rects.count > maxPanels {
            rects = entries.filter(\.isTarget).map(\.bounds)
        }
        let targetCount = entries.filter(\.isTarget).count
        if targetCount != lastLoggedTargets || rects.count != lastLoggedRects {
            NSLog("[MakLock Blur] windows=%d targetWindows=%d coverRects=%d", entries.count, targetCount, rects.count)
            lastLoggedTargets = targetCount
            lastLoggedRects = rects.count
        }

        while panels.count < min(rects.count, maxPanels) {
            panels.append(BlurCoverPanel())
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for (i, panel) in panels.enumerated() {
            if i < rects.count {
                let r = rects[i]
                let frame = NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
                panel.setFrame(frame, display: true)
                panel.showsIcon = r.width >= 120 && r.height >= 120
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

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
