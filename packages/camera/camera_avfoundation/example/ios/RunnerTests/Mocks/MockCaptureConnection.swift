// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

@testable import camera_avfoundation

/// A mock implementation of `CaptureConnection` that allows injecting a custom implementation.
final class MockCaptureConnection: NSObject, CaptureConnection {
  var setVideoOrientationStub: ((AVCaptureVideoOrientation) -> Void)?
  var setVideoRotationAngleStub: ((CGFloat) -> Void)?

  var connection: AVCaptureConnection {
    preconditionFailure("Attempted to access unimplemented property: connection")
  }
  var isVideoMirrored = false
  var videoOrientation: AVCaptureVideoOrientation {
    get { AVCaptureVideoOrientation.portrait }
    set {
      setVideoOrientationStub?(newValue)
    }
  }
  var inputPorts: [AVCaptureInput.Port] = []
  var isVideoMirroringSupported = false
  var isVideoOrientationSupported = false
  var preferredVideoStabilizationMode = AVCaptureVideoStabilizationMode.off

  @available(iOS 17.0, *)
  var videoRotationAngle: CGFloat {
    get { 0 }
    set {
      setVideoRotationAngleStub?(newValue)
    }
  }

  @available(iOS 17.0, *)
  func isVideoRotationAngleSupported(_ angle: CGFloat) -> Bool {
    true
  }
}
