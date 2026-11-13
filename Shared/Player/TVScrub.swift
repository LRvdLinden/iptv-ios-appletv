#if os(tvOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import QuartzCore

/// Build 170: de scrub-status van de tijdbalk op Apple TV in een eigen, klein object. Alleen `TVTimelineBarContent`
/// volgt hem; `PlayerScreen` bewaart hem in `@State` (zonder te volgen), zodat een swipe niet elke frame het hele
/// spelerscherm opnieuw tekent. De pure logica (curve, dode zone, uitrollen, ritme, afknijpen) staat in Build170.swift.
@MainActor
final class TVScrubModel: NSObject, ObservableObject {
    /// Voorbeeldpositie in seconden; nil = niet aan het spoelen.
    @Published private(set) var preview: Double?
    /// Positie (s) bij het begin van het spoelen: de rode balk en de verschiltekst blijven daaraan vast.
    @Published private(set) var origin: Double = 0
    /// Bevestigd of geannuleerd, wacht tot de speler de nieuwe tijd meldt: de kop blijft staan, geen tekst.
    @Published private(set) var committing = false

    weak var player: PlayerController?

    private(set) var panning = false
    private(set) var holding = false
    private var lastPanAt = Date.distantPast
    private var deadMoved = 0.0
    private var wasPlaying = false
    private var seeked = false
    // uitrollen
    private var coastVelocity = 0.0
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    // ingedrukt houden
    private var holdTimer: Timer?
    private var holdTick = 0
    private var holdForward = true
    // losse klikken (build 169)
    private var clickRepeat = 0
    private var lastClick: (at: Date, forward: Bool)?
    // afgeknepen seeks
    private var inFlight = false
    private var lastSeekAt: Double?
    private var lastTarget: Double?
    private var pumpScheduled = false
    // na bevestigen
    private var commitTarget = 0.0
    private var commitStart = Date()
    private var commitTimer: Timer?

    /// Aan het spoelen (niet aan het wachten na bevestigen).
    var isScrubbing: Bool { preview != nil && !committing }
    var coasting: Bool { link != nil }
    /// Vlak na een swipe geen losse klikstap (de swipe zelf geeft soms ook een pijltje).
    var recentlyPanned: Bool { Date().timeIntervalSince(lastPanAt) < 0.4 }
    /// Focus op de tijdbalk vasthouden (swipen, uitrollen, ingedrukt houden).
    var guardsFocus: Bool {
        Scrub170.guardsFocus(panning: panning || holding, coasting: coasting, sinceLastPan: Date().timeIntervalSince(lastPanAt))
    }

    private var duration: Double { player?.duration ?? 0 }
    private var av: AVEngine? { player?.engine as? AVEngine }
    /// Actuele tijd van de engine (niet de waarde van de laatste tik van de speler, die is tot 0,5 s oud).
    private var engineTime: Double {
        guard let p = player else { return 0 }
        let t = p.engine.time
        return t.isFinite && t > 0 ? t : p.duration * p.position
    }

    // MARK: begin en verschuiven

    private func beginIfNeeded() {
        guard let p = player, p.duration > 0 else { return }
        if committing { finishCommit() }
        guard preview == nil else { return }
        let t = Scrub169.clamp(engineTime, duration: p.duration)
        origin = t
        preview = t
        // pauzeren tijdens het spoelen (zoals Apple); bevestigen of annuleren speelt verder als het speelde
        wasPlaying = p.engine.isPlaying || p.engine.state == .buffering
        if wasPlaying { p.engine.pause() }
        seeked = false; inFlight = false; lastSeekAt = nil; lastTarget = t
    }

    private func move(by seconds: Double) {
        guard let p = preview, !committing, seconds.isFinite else { return }
        let n = Scrub169.clamp(p + seconds, duration: duration)
        if n != p {
            preview = n
            pump()
        } else if coasting {
            stopCoast()          // tegen het begin of eind
        }
    }

    // MARK: swipen

    /// Nieuwe aanraking op het touchoppervlak: uitrollen meteen stoppen.
    func touchDown() { stopCoast() }

    func panBegan() {
        stopCoast(); stopHold()
        panning = true; deadMoved = 0; lastPanAt = Date()
        clickRepeat = 0; lastClick = nil
        beginIfNeeded()
    }

    func panChanged(_ fraction: Double, velocity: Double) {
        guard panning else { return }
        lastPanAt = Date()
        let eff = Scrub170.afterDeadZone(moved: deadMoved, delta: fraction)
        if fraction.isFinite { deadMoved += abs(fraction) }
        if eff != 0 { move(by: Scrub170.panSeconds(fraction: eff, velocity: velocity, duration: duration)) }
    }

    func panEnded(velocity: Double) {
        guard panning else { return }
        panning = false
        lastPanAt = Date()
        if deadMoved > Scrub170.deadZone { startCoast(Scrub170.coastVelocity(release: velocity, duration: duration)) }
    }

    // MARK: uitrollen

    private func startCoast(_ v: Double) {
        stopCoast()
        guard v != 0, preview != nil, !committing else { return }
        coastVelocity = v
        lastFrame = 0
        let l = CADisplayLink(target: self, selector: #selector(coastFrame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func coastFrame(_ l: CADisplayLink) {
        let dt = lastFrame == 0 ? l.duration : l.timestamp - lastFrame
        lastFrame = l.timestamp
        let step = Scrub170.coastStep(velocity: coastVelocity, dt: dt)
        coastVelocity = step.velocity
        lastPanAt = Date()
        if step.delta != 0 { move(by: step.delta) }
        if step.velocity == 0 { stopCoast() }
    }

    private func stopCoast() {
        link?.invalidate(); link = nil
        coastVelocity = 0
    }

    // MARK: klikken en ingedrukt houden

    /// Losse klik ←/→ op de tijdbalk: −/+ 10 s, snel herhalen versnelt (build 169). Tijdens ingedrukt houden of
    /// vlak na een swipe niets (geen dubbele stappen).
    func click(forward: Bool) {
        guard !holding, !panning, !recentlyPanned else { return }
        stopCoast()
        beginIfNeeded()
        let now = Date()
        if let last = lastClick {
            clickRepeat = Scrub169.nextRepeat(previous: clickRepeat, sameDirection: last.forward == forward,
                                              interval: now.timeIntervalSince(last.at))
        } else {
            clickRepeat = 0
        }
        lastClick = (now, forward)
        let step = Scrub169.clickStep(repeatCount: clickRepeat)
        move(by: forward ? step : -step)
    }

    /// ←/→ ingedrukt gehouden (na `Scrub170.holdDelay`): herhalen met een vast ritme en oplopende stappen.
    func holdBegan(forward: Bool) {
        stopCoast(); stopHold()
        beginIfNeeded()
        guard preview != nil else { return }
        holding = true; holdTick = 0; holdForward = forward
        holdStep()
        let t = Timer(timeInterval: Scrub170.holdInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdStep() }
        }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }

    private func holdStep() {
        guard holding else { return }
        let s = Scrub170.holdStep(tick: holdTick)
        holdTick += 1
        move(by: holdForward ? s : -s)
    }

    /// Loslaten stopt meteen.
    func holdEnded() {
        stopHold()
        clickRepeat = 0; lastClick = nil
    }

    private func stopHold() {
        holdTimer?.invalidate(); holdTimer = nil
        holding = false
    }

    // MARK: beeld volgt mee (alleen AVPlayer)

    private func pump() {
        guard let av, let target = preview, !committing, !inFlight else { return }
        let now = CACurrentMediaTime()
        if let last = lastTarget, abs(target - last) < Scrub170.seekMinDelta { return }
        let wait = Scrub170.seekWait(now: now, lastSeekAt: lastSeekAt)
        if wait > 0 {
            guard !pumpScheduled else { return }
            pumpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pumpScheduled = false
                    self?.pump()
                }
            }
            return
        }
        guard Scrub170.shouldSeek(now: now, lastSeekAt: lastSeekAt, inFlight: inFlight, lastTarget: lastTarget, target: target)
        else { return }
        inFlight = true; lastSeekAt = now; lastTarget = target; seeked = true
        av.scrubSeek(toSeconds: target, precise: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inFlight = false
                self.pump()
            }
        }
    }

    // MARK: bevestigen en annuleren

    /// Precies naar de voorbeeldpositie en verder spelen als het speelde. De kop blijft staan tot de speler de
    /// nieuwe tijd meldt (hoogstens 1,5 s), zodat de balk niet eerst terugspringt.
    func commit() {
        guard let p = player, let target = preview, !committing else { return }
        settle(at: target)
        if let av {
            av.cancelSeeks()
            av.scrubSeek(toSeconds: target, precise: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeIfNeeded() }
            }
        } else {
            p.seek(toSeconds: target)
            resumeIfNeeded()
        }
    }

    /// Terug naar de oorspronkelijke positie (alleen een seek als het beeld al meeliep) en verder spelen als het speelde.
    func cancel() {
        guard let p = player, preview != nil, !committing else { return }
        if seeked, let av {
            settle(at: origin)
            preview = origin
            av.cancelSeeks()
            av.scrubSeek(toSeconds: origin, precise: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeIfNeeded() }
            }
        } else {
            stopCoast(); stopHold()
            clickRepeat = 0; lastClick = nil
            preview = nil
            if wasPlaying { p.engine.play() }
            wasPlaying = false
        }
    }

    private func settle(at target: Double) {
        stopCoast(); stopHold()
        clickRepeat = 0; lastClick = nil
        committing = true
        commitTarget = target
        commitStart = Date()
        commitTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCommit() }
        }
        RunLoop.main.add(t, forMode: .common)
        commitTimer = t
    }

    private func resumeIfNeeded() {
        if wasPlaying { player?.engine.play() }
        wasPlaying = false
    }

    private func checkCommit() {
        guard committing else { commitTimer?.invalidate(); commitTimer = nil; return }
        // wat de speler meldt (de tik van PlayerController), want daar volgt de rode balk op
        let reported = player?.currentTime ?? commitTarget
        if Scrub170.releaseHold(elapsed: Date().timeIntervalSince(commitStart), target: commitTarget, reported: reported) {
            finishCommit()
        }
    }

    private func finishCommit() {
        commitTimer?.invalidate(); commitTimer = nil
        committing = false
        preview = nil
    }

    /// Scherm weg: alles stoppen.
    func reset() {
        stopCoast(); stopHold()
        commitTimer?.invalidate(); commitTimer = nil
        committing = false
        preview = nil
        wasPlaying = false
    }
}

/// Build 170: het getekende deel van de tijdbalk. Volgt alleen het scrub-object en de waarden die het spelerscherm
/// doorgeeft; tekent opnieuw bij elke beweging van de voorbeeldpositie, zonder de rest van het scherm.
struct TVTimelineBarContent: View {
    @ObservedObject var scrub: TVScrubModel
    /// Positie van de speler (0…1) en duur (s)
    let position: Double
    let duration: Double
    let focused: Bool

    var body: some View {
        let now = min(max(position.isFinite ? position : 0, 0), 1)
        let preview: Double? = scrub.preview.map { Scrub170.fraction($0, duration: duration) }
        // tijdens het spoelen blijft de rode balk op de beginpositie; na bevestigen op het doel (geen terugsprong)
        let fill: Double = scrub.preview == nil ? now
            : (scrub.committing ? (preview ?? now) : Scrub170.fraction(scrub.origin, duration: duration))
        let head = preview ?? now
        let h: CGFloat = focused ? 16 : 8
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(focused ? 0.4 : 0.3)).frame(height: h)
                Capsule().fill(Theme.red).frame(width: max(h, w * fill), height: h)
                if let p = preview {
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: 4, height: h + 12).offset(x: w * p - 2)
                }
                if focused {
                    Circle().fill(Color.white).frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .offset(x: w * head - 15)
                }
            }
            .frame(width: w, height: g.size.height)
            .overlay(alignment: .topLeading) {
                if let t = scrub.preview, !scrub.committing {
                    // alleen de tekst rondt af op hele seconden; de kop volgt elke frame
                    Text(Scrub169.label(preview: t, current: scrub.origin))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: Capsule())
                        .fixedSize()
                        .position(x: min(max(w * head, 120), max(w - 120, 120)), y: -32)
                }
            }
            .animation(.linear(duration: 0.08), value: head)
            .animation(.linear(duration: 0.08), value: fill)
        }
        .accessibilityValue(Scrub169.time(scrub.preview ?? now * duration))
    }
}

/// Build 169/170: swipen over het touchoppervlak van de Siri Remote (indirecte aanrakingen) en ←/→ ingedrukt houden.
/// De recognizers hangen aan het venster, zodat ze de aanrakingen en drukken krijgen wat er ook de focus heeft
/// (vanger of tijdbalk); `enabled` / `holdEnabled` bepalen of ze beginnen. Alleen horizontale swipes; verticaal blijft
/// voor de focus. Waarden in breedtes van het venster: `fraction` = stukje sinds de vorige melding,
/// `velocity` = breedtes per seconde.
struct TVScrubPanListener: UIViewRepresentable {
    var enabled: Bool
    var holdEnabled: Bool
    var onTouchDown: () -> Void
    var onBegan: () -> Void
    var onChanged: (_ fraction: Double, _ velocity: Double) -> Void
    var onEnded: (_ velocity: Double) -> Void
    var onHoldBegan: (_ forward: Bool) -> Void
    var onHoldEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        context.coordinator.parent = self
        return v
    }

    func updateUIView(_ v: HostView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ v: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class HostView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    /// Meldt alleen dat een aanraking begint en doet verder niet mee (faalt meteen).
    final class TouchDownRecognizer: UIGestureRecognizer {
        var onDown: (() -> Void)?
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onDown?()
            state = .failed
        }
    }

    /// Lang drukken op ←/→, en onthoudt welke.
    final class ArrowHoldRecognizer: UILongPressGestureRecognizer {
        private(set) var forward = true
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            if let p = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow }) {
                forward = p.type == .rightArrow
            }
            super.pressesBegan(presses, with: event)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TVScrubPanListener?
        private var recognizers: [UIGestureRecognizer] = []
        private var pan: UIPanGestureRecognizer?
        private var hold: ArrowHoldRecognizer?
        private var last: CGFloat = 0

        func attach(to window: UIWindow?) {
            detach()
            guard let window else { return }
            let indirect = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]

            let p = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            p.allowedTouchTypes = indirect
            p.cancelsTouchesInView = false
            p.delaysTouchesBegan = false
            p.delaysTouchesEnded = false
            p.delegate = self
            pan = p

            let d = TouchDownRecognizer(target: nil, action: nil)
            d.allowedTouchTypes = indirect
            d.cancelsTouchesInView = false
            d.delaysTouchesBegan = false
            d.delaysTouchesEnded = false
            d.delegate = self
            d.onDown = { [weak self] in self?.parent?.onTouchDown() }

            let h = ArrowHoldRecognizer(target: self, action: #selector(handleHold(_:)))
            h.allowedTouchTypes = []
            h.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue),
                                   NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
            h.minimumPressDuration = Scrub170.holdDelay
            h.cancelsTouchesInView = false
            h.delegate = self
            hold = h

            for r in [p, d, h] as [UIGestureRecognizer] { window.addGestureRecognizer(r) }
            recognizers = [p, d, h]
        }

        func detach() {
            for r in recognizers { r.view?.removeGestureRecognizer(r) }
            recognizers = []; pan = nil; hold = nil
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g === hold { return parent?.holdEnabled == true }
            if g === pan {
                guard parent?.enabled == true, let v = g.view, let p = g as? UIPanGestureRecognizer else { return false }
                let vel = p.velocity(in: v)
                return abs(vel.x) > abs(vel.y)
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handle(_ p: UIPanGestureRecognizer) {
            guard let v = p.view else { return }
            let w = max(v.bounds.width, 1)
            switch p.state {
            case .began:
                last = 0
                parent?.onBegan()
                fallthrough
            case .changed:
                let t = p.translation(in: v).x
                let dx = Double((t - last) / w)
                last = t
                parent?.onChanged(dx, Double(p.velocity(in: v).x / w))
            case .ended:
                last = 0
                parent?.onEnded(Double(p.velocity(in: v).x / w))
            case .cancelled, .failed:
                last = 0
                parent?.onEnded(0)
            default:
                break
            }
        }

        @objc func handleHold(_ h: ArrowHoldRecognizer) {
            switch h.state {
            case .began: parent?.onHoldBegan(h.forward)
            case .ended, .cancelled, .failed: parent?.onHoldEnded()
            default: break
            }
        }
    }
}
#endif
