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

  /// Optional crop rectangle in normalised (0,1) coordinate space.
  /// When non-nil the photo is cropped (GPU path) before it is written to disk.
  private let cropRect: PlatformRect?

  /// Core Image context shared with the camera (Metal-backed). Only used when `cropRect` is set.
  private let ciContext: CIContext?

  /// The path for captured photo file.
  /// Exposed for unit tests to verify the captured photo file path.
  var filePath: String {
    path
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

        // If a crop is requested, apply it in Core Image before writing.
        if let crop = strongSelf.cropRect,
          let ctx = strongSelf.ciContext,
          let rawData = rawData
        {
          let ci = CIImage(data: rawData)?.oriented(.up)
          let fullW = ci?.extent.width ?? 0
          let fullH = ci?.extent.height ?? 0
          NSLog(
            "[SavePhotoDelegate] crop: ci=%@, extent=%.0fx%.0f, rect=(%.3f,%.3f,%.3f,%.3f)",
            ci != nil ? "ok" : "nil", fullW, fullH,
            crop.x, crop.y, crop.width, crop.height)
          if let ci = ci, fullW > 0, fullH > 0 {
            let ciCrop = CGRect(
              x: crop.x * fullW,
              y: (1.0 - crop.y - crop.height) * fullH,
              width: crop.width * fullW,
              height: crop.height * fullH)
            let cropped = ci.cropped(to: ciCrop)
            if let croppedData = ctx.jpegRepresentation(
              of: cropped,
              colorSpace: cropped.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            {
              NSLog(
                "[SavePhotoDelegate] crop applied: %dx%d -> %dx%d (%d bytes)",
                Int(fullW), Int(fullH), Int(cropped.extent.width), Int(cropped.extent.height),
                croppedData.count)
              finalData = croppedData
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
