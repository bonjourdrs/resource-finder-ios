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
/// Native SwiftUI hit testing avoids competing UIKit representable surfaces.
@MainActor struct PlayerTouchSurface: View {
    let locked: Bool
    let tap: () -> Void
    let doubleTap: () -> Void
    let hold: (Bool) -> Void
    let cancel: () -> Void
    let drag: (CGPoint, CGPoint, CGSize, Bool) -> Void
    @GestureState private var contact = false
    @GestureState private var moving = false
    @State private var accelerated = false
    var body: some View {
        GeometryReader { geometry in
            Color.clear.contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("player_gesture_area")
                .accessibilityLabel("视频画面，轻点显隐控制，双击播放暂停")
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { value in
                    switch value { case .first: if !locked { doubleTap() }; case .second: tap() }
                })
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 12)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($contact) { value, state, _ in
                        switch value { case .first(let pressing): state = pressing; case .second(let pressing, _): state = pressing }
                    }
                    .onChanged { value in
                        if case .second(true, _) = value, !locked, !accelerated { accelerated = true; hold(true) }
                    }
                    .onEnded { _ in endHold() }, including: locked ? .none : .all)
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .updating($moving) { _, state, _ in state = true }
                    .onChanged { value in if !locked && !accelerated { drag(value.startLocation, CGPoint(x: value.translation.width, y: value.translation.height), geometry.size, false) } }
                    .onEnded { value in if !locked && !accelerated { drag(value.startLocation, CGPoint(x: value.translation.width, y: value.translation.height), geometry.size, true) } }, including: locked ? .none : .all)
        }
        .onChange(of: contact) { _, value in if !value { endHold() } }
        .onChange(of: moving) { _, value in if !value { cancel() } }
        .onChange(of: locked) { _, _ in endHold(); cancel() }
    }
    private func endHold() { if accelerated { accelerated = false; hold(false) } }
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
