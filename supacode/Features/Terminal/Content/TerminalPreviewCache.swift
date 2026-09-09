import AppKit
import CoreImage
import IOSurface
import SwiftUI

/// CPU-owned previews never keep a render target resident after the copy finishes.
/// NSCache may discard them under pressure; a missing preview uses the same cover.
@MainActor
final class TerminalPreviewCache {
  static let shared = TerminalPreviewCache()
  private let images = NSCache<NSUUID, NSImage>()
  private var pending: Set<UUID> = []
  private static let copyQueue = DispatchQueue(label: "app.supabit.supacode.terminal-previews", qos: .utility)
  private nonisolated static let imageContext = CIContext(options: [.cacheIntermediates: false])

  private init() {
    images.totalCostLimit = 64 * 1024 * 1024
    images.countLimit = 32
  }

  func image(for id: UUID) -> NSImage? { images.object(forKey: id as NSUUID) }

  func capture(id: UUID, contents: Any?) {
    guard pending.count < 2, !pending.contains(id), let surface = contents as? IOSurface else { return }
    pending.insert(id)
    let pinned = PinnedSurface(surface)
    Self.copyQueue.async { [weak self] in
      let image = pinned.copyImage()
      Task { @MainActor in
        guard let self else { return }
        self.pending.remove(id)
        guard let image else { return }
        let preview = NSImage(cgImage: image, size: .zero)
        self.images.setObject(preview, forKey: id as NSUUID, cost: image.bytesPerRow * image.height)
      }
    }
  }

  /// The renderer respects IOSurface use counts. The pin protects pixels during
  /// the asynchronous copy, including a concurrent hibernation teardown.
  private nonisolated final class PinnedSurface: @unchecked Sendable {
    let surface: IOSurface

    init(_ surface: IOSurface) {
      self.surface = surface
      surface.incrementUseCount()
    }

    deinit { surface.decrementUseCount() }

    func copyImage() -> CGImage? {
      // IOSurface and IOSurfaceRef are toll-free bridged; Core Image's imported
      // initializer uses the CF spelling with the app's explicit-module build.
      let input = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurfaceRef.self))
      // Downsample before blurring: the preview is deliberately not live text.
      let scale = min(1, 1200 / max(input.extent.width, input.extent.height))
      let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let blurred = scaled.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
      return TerminalPreviewCache.imageContext.createCGImage(
        blurred, from: scaled.extent, format: .BGRA8,
        colorSpace: CGColorSpace(name: CGColorSpace.displayP3), deferred: false)
    }
  }
}

/// A known dormant terminal starts showing progress before synchronous surface
/// construction begins. Resident terminals never enter this branch.
struct TerminalLoadingView: View {
  let contentID: UUID

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      if let image = TerminalPreviewCache.shared.image(for: contentID) {
        Image(nsImage: image).resizable().scaledToFill().opacity(0.65)
      }
      Group {
        if MotionPreference.reduceMotion {
          Text("Restoring terminal…")
        } else {
          ProgressView("Restoring terminal…")
        }
      }
      .controlSize(.small)
      .padding()
      .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    .clipped()
    .accessibilityLabel("Restoring terminal")
  }
}

/// A sibling of the surface, so the covered renderer stays unoccluded and can
/// produce the frame that removes the cover. Input still reaches its own surface.
@MainActor
final class TerminalPresentationCover: NSView {
  private let imageLayer = CALayer()
  private let spinner = NSProgressIndicator()
  private let status = NSTextField(labelWithString: "Restoring terminal…")

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(imageLayer)
    imageLayer.opacity = 0.65
    imageLayer.contentsGravity = .resizeAspect
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.usesThreadedAnimation = true
    spinner.setAccessibilityLabel("Restoring terminal")
    addSubview(spinner)
    status.isHidden = true
    addSubview(status)
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(_ presentation: TerminalPresentation, contentID: UUID) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    isHidden = !presentation.isCovered
    if presentation.isCovered {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      imageLayer.contents = TerminalPreviewCache.shared.image(for: contentID)?.cgImage(
        forProposedRect: nil, context: nil, hints: nil)
    } else {
      imageLayer.contents = nil
    }
    if presentation.showsProgress && !MotionPreference.reduceMotion {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }
    status.isHidden = !presentation.showsProgress || !MotionPreference.reduceMotion
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = bounds
    spinner.sizeToFit()
    spinner.setFrameOrigin(
      NSPoint(x: (bounds.width - spinner.frame.width) / 2, y: (bounds.height - spinner.frame.height) / 2))
    status.sizeToFit()
    status.setFrameOrigin(
      NSPoint(x: (bounds.width - status.frame.width) / 2, y: (bounds.height - status.frame.height) / 2))
    CATransaction.commit()
  }
}
