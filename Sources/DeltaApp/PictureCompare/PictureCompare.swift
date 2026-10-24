import AppKit
import DiffCore
import SwiftUI

@MainActor final class PictureCompareModel: ObservableObject {
    typealias Side = TextCompareModel.Side

    @Published private(set) var urls: [Side: URL] = [:]
    @Published private(set) var images: [Side: CGImage] = [:]
    @Published var tolerance: Double = 0 { didSet { recompute() } }
    @Published private(set) var diff: ImageDiff?
    @Published var errorMessage: String?
    weak var window: NSWindow?
    private var token = 0

    func load(_ url: URL, side: Side) {
        guard let image = loadImage(url) else {
            errorMessage = "\(url.lastPathComponent) is not an image macOS can read."
            return
        }
        images[side] = image
        urls[side] = url
        recompute()
    }

    func swap() {
        (urls[.left], urls[.right]) = (urls[.right], urls[.left])
        (images[.left], images[.right]) = (images[.right], images[.left])
        recompute()
    }

    private func recompute() {
        guard let a = images[.left], let b = images[.right] else { return }
        token += 1
        let mine = token, tol = Int(tolerance)
        Task {
            let result = await Task.detached(priority: .userInitiated) { compareImages(a, b, tolerance: tol) }.value
            if mine == token { diff = result }
        }
    }
}

struct PictureCompareView: View {
    @ObservedObject var model: PictureCompareModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                PathBar(title: "Left", url: model.urls[.left]) { model.load($0, side: .left) }
                PathBar(title: "Right", url: model.urls[.right]) { model.load($0, side: .right) }
            }
            HStack(spacing: 10) {
                Text("Tolerance").foregroundStyle(.secondary)
                Slider(value: $model.tolerance, in: 0...64, step: 1).frame(width: 180)
                    .accessibilityValue("\(Int(model.tolerance))")
                    .help("Ignore colour differences up to this amount (0–255 per channel)")
                Text("\(Int(model.tolerance))").monospacedDigit().frame(width: 28, alignment: .leading)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            HStack(spacing: 1) {
                pane("Left", model.images[.left])
                pane("Right", model.images[.right])
                VStack(spacing: 4) {
                    Text("Differences").font(.caption).foregroundStyle(.secondary)
                    ZStack {
                        if let right = model.images[.right] {
                            Image(decorative: right, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit).opacity(0.3)
                        }
                        if let mask = model.diff?.mask {
                            Image(decorative: mask, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Difference overlay")
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(left: model.images[.left].map { "\($0.width) × \($0.height) px" } ?? "",
                      center: model.images.count == 2 ? summary : "Choose two images",
                      right: model.images[.right].map { "\($0.width) × \($0.height) px" } ?? "")
        }
        .frame(minWidth: 900, minHeight: 400)
        .toolbar {
            SessionToolbar()
            ToolbarItemGroup {
                Button { model.swap() } label: { Label("Swap", systemImage: "arrow.left.arrow.right") }.help("Swap left and right")
            }
        }
        .modifier(SessionChrome(window: model.window, error: $model.errorMessage, onStep: { _ in }))
    }

    private func pane(_ title: String, _ image: CGImage?) -> some View {
        VStack(spacing: 4) {
            Text(image.map { "\(title) · \($0.width) × \($0.height)" } ?? title).font(.caption).foregroundStyle(.secondary)
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                } else {
                    Text("Drop an image").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(title) image")
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var summary: String {
        guard let d = model.diff else { return "" }
        if d.differingPixels == 0 { return "Images match" }
        let pct = Double(d.differingPixels) / Double(max(d.width * d.height, 1)) * 100
        return "\(d.differingPixels) pixel\(d.differingPixels == 1 ? "" : "s") differ (\(pct.formatted(.number.precision(.fractionLength(2))))%)"
    }
}
