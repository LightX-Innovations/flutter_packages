// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreImage
import Flutter
import Foundation

/// The completion handler block for save photo operations.
/// Can be called from either main queue or IO queue.
/// If success, `path` will be present and `error` will be nil. Otherwise, `path` will be nil and
/// `error` will be present.
/// path - the path for successfully saved photo file.
/// error - photo capture error or IO error.
typealias SavePhotoDelegateCompletionHandler = (String?, Error?) -> Void

/// Delegate object that handles photo capture results.
class SavePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  /// The file path for the captured photo.
  private let path: String

  /// The queue on which captured photos are written to disk.
  private let ioQueue: DispatchQueue

  /// The completion handler block for capture and save photo operations.
  let completionHandler: SavePhotoDelegateCompletionHandler

  /// Optional crop signal from Dart.
  /// When non-nil the photo is cropped to a centered square before it is written to disk.
  private let cropRect: PlatformRect?

  /// Core Image context shared with the camera (Metal-backed). Only used when `cropRect` is set.
  private let ciContext: CIContext?

  /// The path for captured photo file.
  /// Exposed for unit tests to verify the captured photo file path.
  var filePath: String {
    path
  }

  static func centeredSquareCropRect(fullWidth: Double, fullHeight: Double)
    -> CGRect
  {
    let side = min(fullWidth, fullHeight)
    return CGRect(
      x: (fullWidth - side) / 2.0,
      y: (fullHeight - side) / 2.0,
      width: side,
      height: side)
  }

  static func cropPhotoData(
    _ rawData: Data,
    ciContext: CIContext
  ) -> (data: Data, fullExtent: CGRect, croppedExtent: CGRect)? {
    guard let ci = CIImage(data: rawData)?.oriented(.up) else {
      return nil
    }

    let fullExtent = ci.extent
    guard fullExtent.width > 0, fullExtent.height > 0 else {
      return nil
    }

    let ciCrop = centeredSquareCropRect(
      fullWidth: fullExtent.width,
      fullHeight: fullExtent.height)
    let cropped = ci.cropped(to: ciCrop)

    guard let croppedData = ciContext.jpegRepresentation(
      of: cropped,
      colorSpace: cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB())
    else {
      return nil
    }

    return (croppedData, fullExtent, cropped.extent)
  }

  /// Initialize a photo capture delegate.
  /// path - the path for captured photo file.
  /// ioQueue - the queue on which captured photos are written to disk.
  /// completionHandler - The completion handler block for save photo operations. Can
  /// be called from either main queue or IO queue.
  /// cropRect - optional crop in normalised (0,1) coordinates; applied before writing.
  /// ciContext - Core Image context to use for crop rendering; must be non-nil when cropRect is set.
  init(
    path: String,
    ioQueue: DispatchQueue,
    completionHandler: @escaping SavePhotoDelegateCompletionHandler,
    cropRect: PlatformRect? = nil,
    ciContext: CIContext? = nil
  ) {
    self.path = path
    self.ioQueue = ioQueue
    self.completionHandler = completionHandler
    self.cropRect = cropRect
    self.ciContext = ciContext
    super.init()
  }

  /// Handler to write captured photo data into a file.
  /// - Parameters:
  ///   - error: The capture error
  ///   - photoDataProvider: A closure that provides photo data
  func handlePhotoCaptureResult(
    error: Error?,
    photoDataProvider: @escaping () -> WritableData?
  ) {
    if let error = error {
      completionHandler(nil, error)
      return
    }

    ioQueue.async { [weak self] in
      guard let strongSelf = self else { return }

      do {
        let data = photoDataProvider()
        let rawData = data as? Data
        var finalData: WritableData? = data

        // If a crop is requested, apply a centered square crop in Core Image before writing.
        if strongSelf.cropRect != nil,
          let ctx = strongSelf.ciContext,
          let rawData = rawData
        {
          let ci = CIImage(data: rawData)?.oriented(.up)
          let fullW = ci?.extent.width ?? 0
          let fullH = ci?.extent.height ?? 0
          NSLog(
            "[SavePhotoDelegate] crop requested — extent=%.0fx%.0f",
            fullW,
            fullH)
          if ci != nil, fullW > 0, fullH > 0 {
            if let cropped = SavePhotoDelegate.cropPhotoData(
              rawData,
              ciContext: ctx)
            {
              NSLog(
                "[SavePhotoDelegate] crop applied: %.0fx%.0f -> %.0fx%.0f (%d bytes)",
                cropped.fullExtent.width, cropped.fullExtent.height,
                cropped.croppedExtent.width, cropped.croppedExtent.height,
                cropped.data.count)
              finalData = cropped.data
            } else {
              NSLog("[SavePhotoDelegate] jpegRepresentation failed — using uncropped")
            }
          } else {
            NSLog("[SavePhotoDelegate] CIImage nil or zero extent — using uncropped")
          }
        } else {
          NSLog(
            "[SavePhotoDelegate] no crop: cropRect=%@, ciContext=%@, data=%@",
            strongSelf.cropRect != nil ? "set" : "nil",
            strongSelf.ciContext != nil ? "set" : "nil",
            rawData != nil ? "set" : "nil")
        }

        try finalData?.writeToPath(strongSelf.path, options: .atomic)
        strongSelf.completionHandler(strongSelf.path, nil)
      } catch {
        strongSelf.completionHandler(nil, error)
      }
    }
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    handlePhotoCaptureResult(error: error) {
      photo.fileDataRepresentation()
    }
  }
}
