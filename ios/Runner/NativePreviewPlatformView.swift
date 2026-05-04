import AVFoundation
import Flutter
import HaishinKit
import UIKit

/// Flutter platform view `swingcapture/native_preview` — classic camera preview layer or HaishinKit MTHKView for RTMP.
final class NativePreviewPlatformView: NSObject, FlutterPlatformView {
  private let container: PreviewContainerView

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    pipeline: NativeCapturePipeline
  ) {
    self.container = PreviewContainerView(frame: frame, pipeline: pipeline)
    super.init()
  }

  func view() -> UIView {
    container
  }

  deinit {
    container.detach()
  }
}

final class NativePreviewViewFactory: NSObject, FlutterPlatformViewFactory {
  private weak var pipeline: NativeCapturePipeline?

  init(pipeline: NativeCapturePipeline) {
    self.pipeline = pipeline
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    guard let pipeline else {
      return FallbackPlatformView(frame: frame)
    }
    return NativePreviewPlatformView(
      frame: frame,
      viewIdentifier: viewId,
      arguments: args,
      pipeline: pipeline
    )
  }
}

/// Empty placeholder if the pipeline was released before the view is created.
private final class FallbackPlatformView: NSObject, FlutterPlatformView {
  private let rootView = UIView()

  init(frame: CGRect) {
    super.init()
    rootView.frame = frame
    rootView.backgroundColor = .black
  }

  func view() -> UIView {
    rootView
  }
}

final class PreviewContainerView: UIView {
  private weak var pipeline: NativeCapturePipeline?
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var hkView: MTHKView?

  init(frame: CGRect, pipeline: NativeCapturePipeline) {
    self.pipeline = pipeline
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true
    pipeline.attachPreviewContainer(self)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    previewLayer?.frame = bounds
    hkView?.frame = bounds
  }

  func showClassicPreview(session: AVCaptureSession) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.hkView?.removeFromSuperview()
      self.hkView = nil
      if self.previewLayer == nil {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer
        self.layer.insertSublayer(layer, at: 0)
      } else {
        self.previewLayer?.session = session
      }
      self.previewLayer?.frame = self.bounds
    }
  }

  func showRtmpPreview(stream: RTMPStream) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.previewLayer?.removeFromSuperlayer()
      self.previewLayer = nil
      if self.hkView == nil {
        let v = MTHKView(frame: self.bounds)
        v.videoGravity = .resizeAspectFill
        self.hkView = v
        self.addSubview(v)
      }
      self.hkView?.attachStream(stream)
      self.hkView?.frame = self.bounds
    }
  }

  func clearPreview() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.previewLayer?.removeFromSuperlayer()
      self.previewLayer = nil
      self.hkView?.attachStream(nil)
      self.hkView?.removeFromSuperview()
      self.hkView = nil
    }
  }

  func detach() {
    pipeline?.detachPreviewContainer(self)
    clearPreview()
  }
}
