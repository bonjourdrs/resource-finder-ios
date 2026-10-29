import AVKit
import SwiftUI

@MainActor enum PlayerOrientation {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
    static func set(_ mask: UIInterfaceOrientationMask, rotate: Bool = true) {
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        while let child = controller?.presentedViewController { child.setNeedsUpdateOfSupportedInterfaceOrientations(); controller = child }
        if rotate { scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) }
    }
}
@MainActor struct PlayerGestures: UIViewRepresentable {
    let locked: Bool
    let tap: () -> Void
    let doubleTap: () -> Void
    let hold: (Bool) -> Void
    let drag: (CGPoint, CGPoint, CGSize, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear; view.isAccessibilityElement = true
        view.accessibilityIdentifier = "player_gesture_area"; view.accessibilityLabel = "视频画面，轻点显示或隐藏控制，双击播放暂停"
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.single))
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.double)); double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress)); hold.minimumPressDuration = 0.5; hold.allowableMovement = 12
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan)); pan.maximumNumberOfTouches = 1
        pan.require(toFail: hold)
        [single, double, hold, pan].forEach { view.addGestureRecognizer($0) }
        context.coordinator.doubleRecognizer = double; context.coordinator.holdRecognizer = hold; context.coordinator.panRecognizer = pan
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.doubleRecognizer?.isEnabled = !locked; context.coordinator.holdRecognizer?.isEnabled = !locked; context.coordinator.panRecognizer?.isEnabled = !locked
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.parent.hold(false) }
    @MainActor final class Coordinator: NSObject {
        var parent: PlayerGestures
        weak var doubleRecognizer: UITapGestureRecognizer?
        weak var holdRecognizer: UILongPressGestureRecognizer?
        weak var panRecognizer: UIPanGestureRecognizer?
        private var origin = CGPoint.zero
        init(_ parent: PlayerGestures) { self.parent = parent }
        @objc func single() { parent.tap() }
        @objc func double() { guard !parent.locked else { return }; parent.doubleTap() }
        @objc func longPress(_ g: UILongPressGestureRecognizer) { if g.state == .began { parent.hold(!parent.locked) }; if [.ended, .cancelled, .failed].contains(g.state) { parent.hold(false) } }
        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard !parent.locked, let view = g.view else { return }
            if g.state == .began { origin = g.location(in: view); parent.hold(false) }
            if [.began, .changed, .ended, .cancelled, .failed].contains(g.state) {
                parent.drag(origin, g.translation(in: view), view.bounds.size, [.ended, .cancelled, .failed].contains(g.state))
            }
        }
    }
}

@MainActor struct PlayerChrome: View {
    @ObservedObject var model: PlaybackModel
    let landscape: Bool
    let title: String
    let hasNext: Bool
    let close: () -> Void
    let fullscreen: () -> Void
    let lock: () -> Void
    let cast: () -> Void
    let speed: () -> Void
    let episodes: () -> Void
    let more: () -> Void
    let next: () -> Void
    let interact: (Bool) -> Void
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if landscape { icon("chevron.left", "退出全屏", "player_exit_fullscreen", close); Text(title).font(.subheadline).lineLimit(1) }
                Spacer()
                icon("tv", "投屏", "player_cast", cast)
                icon("ellipsis", "更多播放设置", "player_more", more)
            }.padding(.horizontal, 10).frame(height: 44).background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
            HStack {
                icon("lock.open", "锁定画面", "player_lock", lock)
                Spacer()
                icon(model.playing ? "pause.fill" : "play.fill", model.playing ? "暂停" : "播放", "player_play_pause", model.toggle).font(.title)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }.padding(.horizontal, 10).frame(maxHeight: .infinity)
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text(TVXML.time(scrubbing ? scrub : model.position)).monospacedDigit().font(.caption)
                    Slider(value: Binding(get: { scrubbing ? scrub : min(model.position, max(1, model.duration)) }, set: { scrub = $0 }), in: 0...max(1, model.duration), onEditingChanged: { editing in
                        if editing { scrub = model.position }; scrubbing = editing; interact(editing)
                        if !editing { model.seek(scrub) }
                    }).tint(.white).disabled(!model.ready || model.duration <= 0).accessibilityIdentifier("player_seek")
                    Text(TVXML.time(model.duration)).monospacedDigit().font(.caption)
                    icon("arrow.up.left.and.arrow.down.right", landscape ? "退出全屏" : "全屏", "player_fullscreen", fullscreen)
                }
                if landscape {
                    HStack {
                        icon(model.playing ? "pause.fill" : "play.fill", model.playing ? "暂停" : "播放", "landscape_play_pause", model.toggle)
                        Button("下一集", action: next).disabled(!hasNext)
                        Spacer()
                        Button("\(model.speed.formatted())×", action: speed).accessibilityIdentifier("player_speed")
                        Button("选集", action: episodes).accessibilityIdentifier("player_episodes")
                    }.font(.subheadline).frame(height: 36)
                }
            }.padding(.horizontal, 12).padding(.bottom, 6).background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }.foregroundStyle(.white).buttonStyle(.plain).accessibilityIdentifier("player_controls")
    }
    private func icon(_ system: String, _ label: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel(label).accessibilityIdentifier(id)
    }
}
