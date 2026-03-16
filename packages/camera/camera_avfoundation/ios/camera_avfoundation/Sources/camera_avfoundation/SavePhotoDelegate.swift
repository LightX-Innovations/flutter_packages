// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreImage
import Flutter
import Foundation
import ImageIO

typealias SavePhotoDelegateCompletionHandler = (String?, Error?) -> Void

class SavePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let path: String
  private let ioQueue: DispatchQueue
  let completionHandler: SavePhotoDelegateCompletionHandler

  /// Optional crop rectangle in normalised 0..1 coordinate space.
  /// When non-nil the photo is cropped to a centered square before being written.
  private let cropRect: PlatformRect?

  /// Core Image context shared with the camera. Used only for crop rendering.
  private let ciContext: CIContext?

  /// When `true`, the capture connection has already physically rotated the
  /// pixel data (via `videoRotationAngle` on iOS 17+). Any EXIF orientation
  /// tag present in the JPEG is therefore stale and must be stripped without
  /// re-applying. When `false` (legacy path), the EXIF orientation is
  /// meaningful and must be baked into the pixels before stripping.
  private let pixelsArePhysicallyRotated: Bool

  var filePath: String {
    path
  }

  init(
    path: String,
    ioQueue: DispatchQueue,
    completionHandler: @escaping SavePhotoDelegateCompletionHandler,
    cropRect: PlatformRect? = nil,
    ciContext: CIContext? = nil,
    pixelsArePhysicallyRotated: Bool = false
  ) {
    self.path = path
    self.ioQueue = ioQueue
    self.completionHandler = completionHandler
    self.cropRect = cropRect
    self.ciContext = ciContext
    self.pixelsArePhysicallyRotated = pixelsArePhysicallyRotated
    super.init()
  }

  static func centeredSquareCropRect(fullWidth: Double, fullHeight: Double) -> CGRect {
    let side = min(fullWidth, fullHeight)
    return CGRect(
      x: (fullWidth - side) / 2.0,
      y: (fullHeight - side) / 2.0,
      width: side,
      height: side)
  }

  static func cropPhotoData(
    _ rawData: Data,
    ciContext: CIContext,
    pixelsArePhysicallyRotated: Bool = false
  ) -> (data: Data, fullExtent: CGRect, croppedExtent: CGRect)? {
    // When the capture connection has already physically rotated the pixels
    // (iOS 17+ with videoRotationAngle), any EXIF orientation tag is stale.
    // Applying orientedCIImage would double-rotate onto already-correct pixels.
    // Use CIImage(data:) directly so the crop is on the as-captured (correct)
    // pixels.  The stale EXIF is stripped by rewriteImageData afterwards.
    // On older OS paths EXIF has not been physically baked in, so we still
    // need orientedCIImage to rotate the raw sensor pixels via the EXIF hint.
    let ci: CIImage?
    if pixelsArePhysicallyRotated {
      ci = CIImage(data: rawData)
    } else {
      ci = orientedCIImage(from: rawData)
    }
    guard let ci = ci else {
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

  static func clearJpegExifOrientation(_ data: Data) -> Data {
    guard isJpeg(data) else {
      return data
    }

    guard hasExifOrientation(data) else {
      return data
    }

    return rewriteImageData(data, metadataSourceData: data) ?? data
  }

  static func normalizePhotoDataRemovingExifOrientation(
    _ data: Data,
    ciContext: CIContext? = nil
  ) -> Data? {
    guard isJpeg(data), hasExifOrientation(data) else {
      return clearJpegExifOrientation(data)
    }

    guard let ciImage = orientedCIImage(from: data) else {
      return clearJpegExifOrientation(data)
    }

    let context = ciContext ?? CIContext()
    guard let normalizedData = context.jpegRepresentation(
      of: ciImage,
      colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB())
    else {
      return clearJpegExifOrientation(data)
    }

    return rewriteImageData(normalizedData, metadataSourceData: data)
      ?? clearJpegExifOrientation(normalizedData)
  }

  private static func isJpeg(_ data: Data) -> Bool {
    return data.count > 2 && data[0] == 0xFF && data[1] == 0xD8
  }

  private static func hasExifOrientation(_ data: Data) -> Bool {
    return exifOrientationValue(data) != nil
  }

  private static func exifOrientationValue(_ data: Data) -> Int? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return nil
    }

    return properties[kCGImagePropertyOrientation] as? Int
  }

  private static func orientedCIImage(from data: Data) -> CIImage? {
    guard let image = CIImage(data: data) else {
      return nil
    }

    guard let orientation = exifOrientationValue(data), orientation != 1 else {
      return image
    }

    return image.oriented(forExifOrientation: Int32(orientation))
  }

  private static func metadataWithoutOrientation(from data: Data) -> [CFString: Any]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return nil
    }

    var metadata: [CFString: Any] = [:]
    for (key, value) in properties where key != kCGImagePropertyOrientation {
      if value is [CFString: Any] || value is [String: Any] {
        metadata[key] = removingOrientationEntries(from: value)
      }
    }

    return metadata.isEmpty ? nil : metadata
  }

  private static func removingOrientationEntries(from value: Any) -> Any {
    if let dictionary = value as? [CFString: Any] {
      var cleaned: [String: Any] = [:]
      for (key, nestedValue) in dictionary where (key as String) != "Orientation" {
        cleaned[key as String] = removingOrientationEntries(from: nestedValue)
      }
      return cleaned
    }

    if let dictionary = value as? [String: Any] {
      var cleaned: [String: Any] = [:]
      for (key, nestedValue) in dictionary where key != "Orientation" {
        cleaned[key] = removingOrientationEntries(from: nestedValue)
      }
      return cleaned
    }

    return value
  }

  private static func rewriteImageData(_ imageData: Data, metadataSourceData: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let imageType = CGImageSourceGetType(source)
    else {
      return nil
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, imageType, 1, nil) else {
      return nil
    }

    let metadata = metadataWithoutOrientation(from: metadataSourceData) as CFDictionary?
    CGImageDestinationAddImage(destination, image, metadata)

    guard CGImageDestinationFinalize(destination) else {
      return nil
    }

    return output as Data
  }

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

        if strongSelf.cropRect != nil,
          let ctx = strongSelf.ciContext,
          let rawData = rawData
        {
          let ci = CIImage(data: rawData)?.oriented(.up)
          let fullW = ci?.extent.width ?? 0
          let fullH = ci?.extent.height ?? 0
          NSLog(
            "[SavePhotoDelegate] crop requested - extent=%.0fx%.0f",
            fullW,
            fullH)
          if let cropped = SavePhotoDelegate.cropPhotoData(
            rawData, ciContext: ctx,
            pixelsArePhysicallyRotated: strongSelf.pixelsArePhysicallyRotated) {
            NSLog(
              "[SavePhotoDelegate] crop applied: %.0fx%.0f -> %.0fx%.0f (%d bytes)",
              cropped.fullExtent.width,
              cropped.fullExtent.height,
              cropped.croppedExtent.width,
              cropped.croppedExtent.height,
              cropped.data.count)
            finalData = SavePhotoDelegate.rewriteImageData(cropped.data, metadataSourceData: rawData)
              ?? SavePhotoDelegate.clearJpegExifOrientation(cropped.data)
          } else {
            NSLog("[SavePhotoDelegate] jpegRepresentation failed - using uncropped")
            finalData = strongSelf.pixelsArePhysicallyRotated
            ? SavePhotoDelegate.clearJpegExifOrientation(rawData)
            : SavePhotoDelegate.normalizePhotoDataRemovingExifOrientation(
              rawData,
              ciContext: ctx)
          }
        } else if let rawData = rawData {
          NSLog(
            "[SavePhotoDelegate] no crop: cropRect=%@, ciContext=%@, data=%@",
            strongSelf.cropRect != nil ? "set" : "nil",
            strongSelf.ciContext != nil ? "set" : "nil",
            "set")
          finalData = strongSelf.pixelsArePhysicallyRotated
            ? SavePhotoDelegate.clearJpegExifOrientation(rawData)
            : SavePhotoDelegate.normalizePhotoDataRemovingExifOrientation(
              rawData,
              ciContext: strongSelf.ciContext)
        } else {
          NSLog(
            "[SavePhotoDelegate] no crop: cropRect=%@, ciContext=%@, data=%@",
            strongSelf.cropRect != nil ? "set" : "nil",
            strongSelf.ciContext != nil ? "set" : "nil",
            "nil")
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
