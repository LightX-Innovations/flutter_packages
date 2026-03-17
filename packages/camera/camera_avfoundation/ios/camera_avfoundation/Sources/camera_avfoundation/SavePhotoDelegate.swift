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

  /// Core Image context shared with the camera. Used only for crop/transform rendering.
  private let ciContext: CIContext?

  /// Clockwise rotation in degrees to apply to the captured photo pixels via CoreImage.
  /// Must be 0, 90, 180, or 270. Applied before cropping.
  private let rotationDegrees: Double

  /// Whether to flip the captured photo horizontally after rotation.
  private let flipHorizontally: Bool

  var filePath: String {
    path
  }

  init(
    path: String,
    ioQueue: DispatchQueue,
    completionHandler: @escaping SavePhotoDelegateCompletionHandler,
    cropRect: PlatformRect? = nil,
    ciContext: CIContext? = nil,
    rotationDegrees: Double = 0,
    flipHorizontally: Bool = false
  ) {
    self.path = path
    self.ioQueue = ioQueue
    self.completionHandler = completionHandler
    self.cropRect = cropRect
    self.ciContext = ciContext
    self.rotationDegrees = rotationDegrees
    self.flipHorizontally = flipHorizontally
    super.init()
  }

  /// Converts (clockwise rotation, horizontal flip) to the EXIF orientation value
  /// suitable for `CIImage.oriented(forExifOrientation:)`.
  ///
  /// EXIF orientation encodes both rotation and flip in a single 1–8 value.  The
  /// mapping below is derived from the TIFF/EXIF spec:
  ///   1 = identity              2 = flip H
  ///   3 = 180° CW               4 = 180° CW + flip H
  ///   5 = 270° CW + flip H      6 = 90° CW
  ///   7 = 90° CW + flip H       8 = 270° CW
  static func exifOrientation(rotationDegrees: Double, flipHorizontally: Bool) -> Int32 {
    switch (Int(rotationDegrees.truncatingRemainder(dividingBy: 360)), flipHorizontally) {
    case (90, false):  return 6
    case (90, true):   return 7
    case (180, false): return 3
    case (180, true):  return 4
    case (270, false): return 8
    case (270, true):  return 5
    case (0, true):    return 2
    default:           return 1  // identity
    }
  }

  static func centeredSquareCropRect(fullWidth: Double, fullHeight: Double) -> CGRect {
    let side = min(fullWidth, fullHeight)
    return CGRect(
      x: (fullWidth - side) / 2.0,
      y: (fullHeight - side) / 2.0,
      width: side,
      height: side)
  }

  /// Applies an explicit rotation+flip transform to `rawData` using CoreImage,
  /// then crops to a centered square.
  ///
  /// Rotation and flip are applied independently of any EXIF tag present in the
  /// JPEG.  The raw sensor pixels (native landscape orientation from
  /// `AVCapturePhotoOutput`) are used directly; no EXIF-based auto-rotation is
  /// applied.  The caller is responsible for stripping residual EXIF orientation
  /// tags after crop (via `rewriteImageData` or `clearJpegExifOrientation`).
  static func cropPhotoData(
    _ rawData: Data,
    ciContext: CIContext,
    rotationDegrees: Double = 0,
    flipHorizontally: Bool = false
  ) -> (data: Data, fullExtent: CGRect, croppedExtent: CGRect)? {
    // Always use the raw sensor pixels — no EXIF-based auto-orientation.
    // We apply the explicit rotation+flip ourselves below so behaviour is
    // independent of whether videoRotationAngle affected the photo connection.
    guard var ci = CIImage(data: rawData) else {
      return nil
    }

    let exifOri = exifOrientation(rotationDegrees: rotationDegrees, flipHorizontally: flipHorizontally)
    if exifOri != 1 {
      ci = ci.oriented(forExifOrientation: exifOri)
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

  /// Strips orientation tags from `data` without decoding or re-encoding pixels.
  ///
  /// Builds a fresh `CGMutableImageMetadata` that includes all sub-dictionary
  /// metadata (EXIF, TIFF, GPS, IPTC, ExifAux) except the TIFF orientation tag,
  /// then uses `CGImageDestinationCopyImageSource` to write a new JPEG whose
  /// compressed image data is a byte-for-byte copy of the original. Returns
  /// `nil` when the source cannot be parsed or the lossless copy fails.
  private static func stripOrientationTagsLosslessly(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let imageType = CGImageSourceGetType(source),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }

    // Build replacement metadata from all recognised sub-dictionaries, omitting
    // the orientation tag from the TIFF dict. kCGImageDestinationMergeMetadata
    // is false so this completely replaces existing metadata — we must
    // explicitly re-add every entry we want to keep.
    let mutableMeta = CGImageMetadataCreateMutable()
    let subDictKeys: [CFString] = [
      kCGImagePropertyExifDictionary,
      kCGImagePropertyTIFFDictionary,
      kCGImagePropertyGPSDictionary,
      kCGImagePropertyIPTCDictionary,
      kCGImagePropertyExifAuxDictionary,
    ]
    let orientationKeyStrings: Set<String> = [
      kCGImagePropertyTIFFOrientation as String,
      "Orientation",
    ]
    for dictKey in subDictKeys {
      guard let subDict = properties[dictKey] as? [CFString: Any] else { continue }
      for (propKey, propValue) in subDict {
        if dictKey == kCGImagePropertyTIFFDictionary,
          orientationKeyStrings.contains(propKey as String)
        { continue }
        CGImageMetadataSetValueMatchingImageProperty(
          mutableMeta, dictKey, propKey, propValue as AnyObject)
      }
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, imageType, 1, nil) else {
      return nil
    }

    let options: [CFString: Any] = [
      kCGImageDestinationMetadata: mutableMeta,
      kCGImageDestinationMergeMetadata: false,
    ]
    var cfError: Unmanaged<CFError>?
    guard
      CGImageDestinationCopyImageSource(
        destination, source, options as CFDictionary, &cfError),
      cfError == nil
    else { return nil }

    return output as Data
  }

  static func clearJpegExifOrientation(_ data: Data) -> Data {
    guard isJpeg(data), hasExifOrientation(data) else {
      return data
    }

    return stripOrientationTagsLosslessly(data)
      ?? rewriteImageData(data, metadataSourceData: data)
      ?? data
  }

  /// Applies an explicit rotation+flip to `data`, strips EXIF orientation, and
  /// returns the result.  Always uses raw sensor pixels (no EXIF auto-rotation).
  static func normalizeWithExplicitTransform(
    _ data: Data,
    rotationDegrees: Double = 0,
    flipHorizontally: Bool = false,
    ciContext: CIContext? = nil
  ) -> Data? {
    let exifOri = exifOrientation(rotationDegrees: rotationDegrees, flipHorizontally: flipHorizontally)
    guard exifOri != 1 else {
      // Identity — just strip residual EXIF orientation tag if present.
      return clearJpegExifOrientation(data)
    }
    guard var ci = CIImage(data: data) else {
      return clearJpegExifOrientation(data)
    }
    ci = ci.oriented(forExifOrientation: exifOri)
    let context = ciContext ?? CIContext()
    guard let rotatedData = context.jpegRepresentation(
      of: ci,
      colorSpace: ci.colorSpace ?? CGColorSpaceCreateDeviceRGB())
    else {
      return clearJpegExifOrientation(data)
    }
    return rewriteImageData(rotatedData, metadataSourceData: data)
      ?? clearJpegExifOrientation(rotatedData)
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
      } else {
        // Preserve scalar values: DPI, color model, bit depth, pixel dimensions, etc.
        metadata[key] = value
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
          NSLog("[SavePhotoDelegate] crop requested")
          if let cropped = SavePhotoDelegate.cropPhotoData(
            rawData, ciContext: ctx,
            rotationDegrees: strongSelf.rotationDegrees,
            flipHorizontally: strongSelf.flipHorizontally) {
            NSLog(
              "[SavePhotoDelegate] crop+transform applied: %.0fx%.0f -> %.0fx%.0f (%d bytes) rot=%.0f flipH=%d",
              cropped.fullExtent.width,
              cropped.fullExtent.height,
              cropped.croppedExtent.width,
              cropped.croppedExtent.height,
              cropped.data.count,
              strongSelf.rotationDegrees,
              strongSelf.flipHorizontally ? 1 : 0)
            finalData = SavePhotoDelegate.rewriteImageData(cropped.data, metadataSourceData: rawData)
              ?? SavePhotoDelegate.clearJpegExifOrientation(cropped.data)
          } else {
            NSLog("[SavePhotoDelegate] jpegRepresentation failed - using uncropped")
            finalData = SavePhotoDelegate.clearJpegExifOrientation(rawData)
          }
        } else if let rawData = rawData {
          NSLog(
            "[SavePhotoDelegate] no crop: cropRect=%@, ciContext=%@, data=%@",
            strongSelf.cropRect != nil ? "set" : "nil",
            strongSelf.ciContext != nil ? "set" : "nil",
            "set")
          // No crop requested — apply rotation+flip then strip EXIF.
          finalData = SavePhotoDelegate.normalizeWithExplicitTransform(
            rawData,
            rotationDegrees: strongSelf.rotationDegrees,
            flipHorizontally: strongSelf.flipHorizontally,
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
