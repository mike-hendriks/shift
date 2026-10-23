import AppKit
import AVFoundation
import Combine
import ServiceManagement
import ShiftCore
import SwiftUI

/// First-run guide: what Shift does, a hands-on try with a demo photo, and where results go.
/// Shown once per onboarding version, including to people updating from a version without it.
@MainActor
final class OnboardingController {
    /// Raise when the onboarding changes enough that everyone should see it again.
    static let version = 1
    private static let seenKey = "onboardingVersion"

    private let settings: SettingsStore
    private var window: NSWindow?
    private var closeObserver: Any?
    let model: OnboardingModel

    init(settings: SettingsStore) {
        self.settings = settings
        model = OnboardingModel(settings: settings)
    }

    var needsOnboarding: Bool { UserDefaults.standard.integer(forKey: Self.seenKey) < Self.version }

    func show(step: OnboardingModel.Step = .welcome) {
        model.reset(to: step)
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model, finish: { [weak self] in self?.finish() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Shift"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 940, height: 620))
            window.center()
            window.isReleasedWhenClosed = false
            // Closing early counts as seen: it can always be reopened from the menu bar.
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                   queue: .main) { _ in
                MainActor.assumeIsolated { UserDefaults.standard.set(Self.version, forKey: Self.seenKey) }
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }

    private func finish() {
        if model.launchAtLogin, SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        UserDefaults.standard.set(Self.version, forKey: Self.seenKey)
        window?.close()
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, tryIt, tricks, location }

    @Published var step: Step = .welcome
    // Tutorial progress, driven by what really happens in the bar.
    @Published var demoFile: URL?
    @Published var dragged = false
    @Published var barShown = false
    @Published var result: ShiftResult?
    @Published var launchAtLogin = true

    let settings: SettingsStore
    private var observers: [Any] = []

    init(settings: SettingsStore) {
        self.settings = settings
        observers.append(NotificationCenter.default.addObserver(forName: .shiftBarDidShow, object: nil, queue: .main) { [weak self] note in
            let files = note.object as? [URL] ?? []
            MainActor.assumeIsolated {
                guard let self, let demo = self.demoFile, files.contains(where: { $0.lastPathComponent == demo.lastPathComponent }) else { return }
                self.dragged = true
                self.barShown = true
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .shiftDidProcess, object: nil, queue: .main) { [weak self] note in
            let results = note.object as? [ShiftResult] ?? []
            MainActor.assumeIsolated {
                guard let self, let demo = self.demoFile,
                      let hit = results.first(where: { $0.sources.contains { $0.lastPathComponent == demo.lastPathComponent } }) else { return }
                self.dragged = true
                self.barShown = true
                self.result = hit
            }
        })
    }

    var trigger: TriggerModifiers { settings.settings.triggerModifiers }

    func reset(to step: Step) {
        self.step = step
        dragged = false
        barShown = false
        result = nil
        launchAtLogin = SMAppService.mainApp.status == .enabled || UserDefaults.standard.integer(forKey: "onboardingVersion") == 0
        if demoFile == nil {
            Task { demoFile = await DemoPhoto.url() }
        }
    }

    func next() { if let next = Step(rawValue: step.rawValue + 1) { step = next } }
    func back() { if let previous = Step(rawValue: step.rawValue - 1) { step = previous } }
}

/// A large photo-like image for the tutorial, made on the Mac itself: a sunset with film grain, a few megabytes,
/// so the web preset has something worth shrinking.
enum DemoPhoto {
    static func url() async -> URL? {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shift/Tutorial", isDirectory: true)
        let url = folder.appendingPathComponent("sunset-demo.jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let image = render(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? url : nil
        }.value
    }

    private static func render() -> CGImage? {
        let width = 3200, height = 2000
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }

        // Sky: deep violet to warm orange near the horizon (CoreGraphics' origin is bottom left).
        let sky = CGGradient(colorsSpace: space, colors: [color(0.98, 0.62, 0.36), color(0.93, 0.38, 0.52), color(0.36, 0.20, 0.55),
                                                          color(0.12, 0.09, 0.30)] as CFArray, locations: [0, 0.3, 0.7, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h * 0.35), end: CGPoint(x: 0, y: h), options: [.drawsBeforeStartLocation])
        // Sun with a soft glow.
        let glow = CGGradient(colorsSpace: space, colors: [color(1, 0.86, 0.55), CGColor(red: 1, green: 0.6, blue: 0.4, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: w * 0.66, y: h * 0.5), startRadius: 0,
                               endCenter: CGPoint(x: w * 0.66, y: h * 0.5), endRadius: h * 0.45, options: [])
        ctx.setFillColor(color(1, 0.9, 0.66))
        ctx.fillEllipse(in: CGRect(x: w * 0.66 - 150, y: h * 0.5 - 150, width: 300, height: 300))
        // Three mountain ridges, from far and light to near and dark.
        let ridges: [(CGFloat, [CGFloat], CGColor)] = [
            (0.42, [0.0, 0.55, 0.12, 0.62, 0.3, 0.5, 0.48, 0.68, 0.66, 0.52, 0.82, 0.64, 1.0, 0.5], color(0.55, 0.3, 0.55)),
            (0.30, [0.0, 0.42, 0.2, 0.3, 0.36, 0.5, 0.55, 0.34, 0.74, 0.48, 0.9, 0.36, 1.0, 0.44], color(0.36, 0.2, 0.42)),
            (0.16, [0.0, 0.3, 0.15, 0.2, 0.32, 0.34, 0.5, 0.18, 0.7, 0.3, 0.86, 0.16, 1.0, 0.26], color(0.18, 0.11, 0.26)),
        ]
        for (_, points, fill) in ridges {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: 0))
            for i in stride(from: 0, to: points.count, by: 2) {
                ctx.addLine(to: CGPoint(x: points[i] * w, y: points[i + 1] * h))
            }
            ctx.addLine(to: CGPoint(x: w, y: 0))
            ctx.closePath()
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        // Film grain makes it compress like a real photo.
        if let data = ctx.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var seed: UInt32 = 0x9E3779B9
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Int(seed >> 27) - 16
                for c in 0..<3 { pixels[i + c] = UInt8(clamping: Int(pixels[i + c]) + noise) }
            }
        }
        return ctx.makeImage()
    }
}

// MARK: Views

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep(model: model)
                case .tryIt: TryItStep(model: model)
                case .tricks: TricksStep()
                case .location: LocationStep(model: model, settings: model.settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(model.step)

            footer
        }
        .frame(width: 940, height: 620)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.clear], startPoint: .top, endPoint: .center)
        )
        .animation(.snappy(duration: 0.3), value: model.step)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step == model.step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: step == model.step ? 22 : 8, height: 8)
                }
            }
            Spacer()
            if model.step == .tryIt && model.result == nil {
                Button("Skip") { model.next() }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 8)
            }
            if model.step != .welcome {
                Button("Back") { model.back() }.controlSize(.large)
            }
            if model.step == .location {
                Button("Start using Shift", action: finish)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button(model.step == .welcome ? "Show me" : "Next") { model.next() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
    }
}

private struct StepHeader: View {
    let eyebrow: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 28, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NumberedRow: View {
    let number: Int
    let title: String
    let detail: String
    var done: Bool? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done == true ? Color.green : Color.accentColor.opacity(done == false ? 0.14 : 1))
                if done == true {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(done == false ? Color.accentColor : Color.white)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.snappy, value: done)
    }
}

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            LoopingVideo(name: "how-it-works")
                .frame(width: 520, height: 292)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 22) {
                StepHeader(eyebrow: "Welcome", title: "Drag. Hold \(model.trigger.names). Done.",
                           subtitle: "Shift converts, compresses, crops and resizes files without opening an app.")
                VStack(alignment: .leading, spacing: 16) {
                    NumberedRow(number: 1, title: "Drag a file", detail: "From Finder, your desktop, anywhere.")
                    NumberedRow(number: 2, title: "Hold \(model.trigger.label)", detail: "A bar slides in at the top of your screen.")
                    NumberedRow(number: 3, title: "Drop it on an action", detail: "Web preset, To PDF, Crop and more.")
                    NumberedRow(number: 4, title: "Drag the result on", detail: "It waits on the shelf, top right, ready for any app.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TryItStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            demoCard
            VStack(alignment: .leading, spacing: 22) {
                StepHeader(eyebrow: "Try it", title: "Shrink this photo for the web",
                           subtitle: "A real file, made for this tutorial. Nothing leaves your Mac.")
                VStack(alignment: .leading, spacing: 16) {
                    NumberedRow(number: 1, title: "Drag the photo out of this window", detail: "Keep the mouse button down.",
                                done: model.dragged || model.barShown)
                    NumberedRow(number: 2, title: "Hold \(model.trigger.label)", detail: "The bar slides in at the top of your screen.",
                                done: model.barShown)
                    NumberedRow(number: 3, title: "Drop it on Web preset", detail: "The big blue tile.", done: model.result != nil)
                }
                if let result = model.result {
                    successCard(result)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.snappy, value: model.result?.id)
        }
    }

    private var demoCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
                if let demo = model.demoFile {
                    VStack(spacing: 10) {
                        FileThumbnail(url: demo, size: 220)
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                            .scaleEffect(pulse && !model.dragged ? 1.03 : 1)
                            .overlay(FileDragSource(urls: [demo], onDragChanged: { dragging in
                                if dragging { model.dragged = true }
                            }))
                        Text(demo.lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text(formatBytes(fileSize(demo))).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(width: 330, height: 330)
            Label(model.dragged ? "Now hold \(model.trigger.symbols)" : "Drag me", systemImage: model.dragged ? "keyboard" : "hand.draw")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private func successCard(_ result: ShiftResult) -> some View {
        let saved = result.sourceBytes > 0 ? Int((1 - Double(result.outputBytes) / Double(result.sourceBytes)) * 100) : 0
        return HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(formatBytes(result.sourceBytes)) → \(formatBytes(result.outputBytes)), \(saved)% smaller")
                    .font(.system(size: 15, weight: .bold))
                Text("It's on the shelf now, top right. Drag it into any app, or press Space there to preview it.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.green.opacity(0.12)))
    }
}

private struct TricksStep: View {
    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            LoopingVideo(name: "batch")
                .frame(width: 520, height: 292)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 22) {
                StepHeader(eyebrow: "Good to know", title: "A few more tricks")
                VStack(alignment: .leading, spacing: 15) {
                    tip("square.stack.3d.up", "Drop a whole batch", "Mixed files are sorted by type, each with its own actions.")
                    tip("keyboard", "Skip the mouse", "Press 1–9 to pick a tile. Return runs the first.")
                    tip("crop", "Crop a batch at once", "Drag the edges once, every image gets the same crop.")
                    tip("number", "Anything to Markdown", "Documents, PDFs, text in images, even speech in video.")
                    tip("slider.horizontal.3", "Make it yours", "Presets, the order of tiles and your trigger key live in Settings.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LocationStep: View {
    @ObservedObject var model: OnboardingModel
    /// Observed directly: the choice lives in settings, and the model alone does not redraw this view when it changes.
    @ObservedObject var settings: SettingsStore

    private enum Choice { case downloads, nextToOriginal, custom }

    private var choice: Choice {
        if settings.settings.saveNextToOriginal { return .nextToOriginal }
        return settings.settings.outputDirectory == nil ? .downloads : .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(eyebrow: "Last step", title: "Where should results go?",
                       subtitle: "You can change this any time in Settings.")
            HStack(spacing: 16) {
                option(.downloads, symbol: "arrow.down.circle", title: "Downloads/Shift",
                       detail: "One folder for everything Shift makes.") {
                    settings.settings.saveNextToOriginal = false
                    settings.settings.outputDirectory = nil
                }
                option(.nextToOriginal, symbol: "doc.on.doc", title: "Next to the original",
                       detail: "Results land beside the file you dropped.") {
                    settings.settings.saveNextToOriginal = true
                }
                option(.custom, symbol: "folder.badge.gearshape",
                       title: choice == .custom ? (settings.settings.outputURL.lastPathComponent) : "Choose a folder…",
                       detail: choice == .custom ? settings.settings.outputURL.path(percentEncoded: false) : "Pick any folder you like.") {
                    chooseFolder()
                }
            }
            .frame(height: 170)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Open Shift when you log in", isOn: $model.launchAtLogin)
                    .toggleStyle(.switch)
                Text("Shift lives in the menu bar (\(Image(systemName: "shift"))). Your trigger is \(model.trigger.label); change it in Settings.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func option(_ value: Choice, symbol: String, title: String, detail: String, select: @escaping () -> Void) -> some View {
        let selected = choice == value
        return Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(Color.accentColor)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18)).foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Spacer(minLength: 0)
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.settings.outputDirectory = url.path
            settings.settings.saveNextToOriginal = false
        }
    }
}

/// A silent clip that loops, filling its frame. Clips ship in the app's Resources/Onboarding folder; promo/clips.mjs
/// renders them from the release film.
struct LoopingVideo: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> LoopingVideoView { LoopingVideoView(url: Self.url(for: name)) }
    func updateNSView(_ view: LoopingVideoView, context: Context) {}

    static func url(for name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Onboarding")
            // Development builds run from the repository.
            ?? [URL(fileURLWithPath: "Resources/Onboarding/\(name).mp4")].first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

final class LoopingVideoView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        guard let url else { return }
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }
}
