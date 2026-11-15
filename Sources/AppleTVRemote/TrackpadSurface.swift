import SwiftUI
import AppKit
import AppleTVProtocol

/// How a one-finger slide picks its D-pad direction in trackpad mode.
enum TrackpadSlideMode: String, CaseIterable, Identifiable {
    /// The area of the trackpad the finger is in (top / bottom / left / right)
    /// decides the button, like pressing the rim of the Siri Remote clickpad.
    /// Slides starting in the centre fall back to the slide direction.
    case zone
    /// The direction the finger moves decides the button.
    case direction

    static let defaultsKey = "com.adhir.appletv-remote.trackpadSlideMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zone:      return "Trackpad area (top / bottom / left / right)"
        case .direction: return "Slide direction"
        }
    }

    static var current: TrackpadSlideMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TrackpadSlideMode.init) ?? .zone
    }
}

/// Pure gesture maths for trackpad mode. Positions are `NSTouch.normalizedPosition`
/// values: 0…1 on each axis, origin at the trackpad's bottom-left corner.
enum TrackpadGesture {
    /// Half-width of the central dead zone that belongs to no edge area.
    static let centreHalfSize: CGFloat = 0.18
    /// Finger travel before the first D-pad press of a slide.
    static let firstStep: CGFloat = 0.06
    /// Further travel for each repeat press while the finger keeps sliding.
    static let repeatStep: CGFloat = 0.14
    /// Ring rotation for a two-finger slide spanning the full trackpad height.
    static let ringDegreesPerUnit: Double = 360
    /// Rotation is batched until it reaches this much, to limit frame rate.
    static let ringMinStepDegrees: Double = 3

    /// Edge area containing `p`, or nil for the centre.
    static func zone(at p: CGPoint) -> RemoteCommand? {
        let dx = p.x - 0.5, dy = p.y - 0.5
        if abs(dx) < centreHalfSize, abs(dy) < centreHalfSize { return nil }
        return direction(dx: dx, dy: dy)
    }

    /// Dominant axis of a movement. +y is toward the top of the trackpad.
    static func direction(dx: CGFloat, dy: CGFloat) -> RemoteCommand {
        if abs(dy) >= abs(dx) { return dy > 0 ? .up : .down }
        return dx > 0 ? .right : .left
    }
}

/// Full-pane overlay that turns the MacBook trackpad into the Siri Remote
/// touch surface while it is on screen:
///
///   one-finger slide   — D-pad press (by trackpad area or slide direction)
///   two fingers up     — ring anticlockwise
///   two fingers down   — ring clockwise
///   click              — select
///   right-click        — leave trackpad mode
///
/// The pointer is parked over the view and detached from the trackpad so
/// slides don't drag it away; raw touches are only delivered to the view
/// under the pointer.
struct TrackpadSurface: NSViewRepresentable {
    var onDirection: (RemoteCommand) -> Void
    var onRing: (Double) -> Void
    var onRingEnd: () -> Void
    var onClick: () -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> TrackpadSurfaceView {
        let v = TrackpadSurfaceView()
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: TrackpadSurfaceView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: TrackpadSurfaceView, coordinator: ()) {
        nsView.releasePointer()
    }

    private func apply(to v: TrackpadSurfaceView) {
        v.onDirection = onDirection
        v.onRing = onRing
        v.onRingEnd = onRingEnd
        v.onClick = onClick
        v.onExit = onExit
    }
}

final class TrackpadSurfaceView: NSView {
    var onDirection: (RemoteCommand) -> Void = { _ in }
    var onRing: (Double) -> Void = { _ in }
    var onRingEnd: () -> Void = {}
    var onClick: () -> Void = {}
    var onExit: () -> Void = {}

    // One-finger slide.
    private var slideOrigin: CGPoint?
    private var slideZone: RemoteCommand?
    private var slideFired = false
    /// Set once a second finger lands; one-finger slides stay ignored until
    /// every finger has lifted, so ending a ring gesture can't fire a press.
    private var multiTouchSeen = false

    // Two-finger ring.
    private var twoFingerY: CGFloat?
    private var ringPending: Double = 0
    private var ringActive = false

    private var pointerCaptured = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Pointer capture

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { releasePointer(); return }
        let nc = NotificationCenter.default
        // Never keep the pointer detached once the user is elsewhere.
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                        object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.exit() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.exit() }
        })
        // Wait a tick so SwiftUI has given the view its final frame.
        DispatchQueue.main.async { [weak self] in self?.capturePointer() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releasePointer() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func capturePointer() {
        guard !pointerCaptured, let window, window.isKeyWindow,
              let primary = NSScreen.screens.first else { return }
        let inWindow = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        // Cocoa screen space has a bottom-left origin; Quartz is top-left.
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primary.frame.height - onScreen.y))
        CGAssociateMouseAndMouseCursorPosition(0)
        pointerCaptured = true
    }

    func releasePointer() {
        removeObservers()
        finishRing()
        guard pointerCaptured else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        pointerCaptured = false
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func exit() {
        releasePointer()
        onExit()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { exit() }
    /// Swallowed so two-finger slides don't scroll the remote underneath.
    override func scrollWheel(with event: NSEvent) {}

    // MARK: Touches

    override func touchesBegan(with event: NSEvent) {
        resetTracking()
        process(event)
    }

    override func touchesMoved(with event: NSEvent) {
        process(event)
    }

    override func touchesEnded(with event: NSEvent) {
        resetTracking()
        process(event)
    }

    override func touchesCancelled(with event: NSEvent) {
        resetTracking()
        finishRing()
        multiTouchSeen = false
    }

    /// The finger set changed, so stored baselines no longer apply.
    private func resetTracking() {
        slideOrigin = nil
        twoFingerY = nil
    }

    private func process(_ event: NSEvent) {
        let touches = event.touches(matching: .touching, in: self)
        switch touches.count {
        case 1:
            finishRing()
            guard !multiTouchSeen, let p = touches.first?.normalizedPosition else { return }
            trackSlide(to: p)
        case 2:
            multiTouchSeen = true
            slideOrigin = nil
            let y = touches.reduce(CGFloat(0)) { $0 + $1.normalizedPosition.y } / 2
            trackRing(toY: y)
        default:
            finishRing()
            slideOrigin = nil
            if touches.isEmpty { multiTouchSeen = false }
        }
    }

    private func trackSlide(to p: CGPoint) {
        guard let origin = slideOrigin else {
            slideOrigin = p
            slideZone = TrackpadGesture.zone(at: p)
            slideFired = false
            return
        }
        let dx = p.x - origin.x, dy = p.y - origin.y
        let needed = slideFired ? TrackpadGesture.repeatStep : TrackpadGesture.firstStep
        guard hypot(dx, dy) >= needed else { return }
        let byMotion = TrackpadGesture.direction(dx: dx, dy: dy)
        let command: RemoteCommand
        switch TrackpadSlideMode.current {
        case .zone:      command = slideZone ?? byMotion
        case .direction: command = byMotion
        }
        onDirection(command)
        slideOrigin = p
        slideFired = true
    }

    private func trackRing(toY y: CGFloat) {
        defer { twoFingerY = y }
        guard let last = twoFingerY else { return }
        // Fingers up = anticlockwise = negative degrees.
        ringPending -= Double(y - last) * TrackpadGesture.ringDegreesPerUnit
        guard abs(ringPending) >= TrackpadGesture.ringMinStepDegrees else { return }
        ringActive = true
        onRing(ringPending)
        ringPending = 0
    }

    private func finishRing() {
        ringPending = 0
        twoFingerY = nil
        guard ringActive else { return }
        ringActive = false
        onRingEnd()
    }
}
