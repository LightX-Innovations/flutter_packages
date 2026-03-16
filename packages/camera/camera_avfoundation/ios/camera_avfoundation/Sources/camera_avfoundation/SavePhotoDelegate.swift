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

  var filePath: String {
    path
  }

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

  static func clearJpegExifOrientation(_ data: Data) -> Data {
    guard isJpeg(data) else {
      return data
    }

    guard hasExifOrientation(data) else {
      return data
    }

    return stripExifApp1Segments(data) ?? data
  }

  private static func isJpeg(_ data: Data) -> Bool {
    return data.count > 2 && data[0] == 0xFF && data[1] == 0xD8
  }

  private static func hasExifOrientation(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return false
    }

    return properties[kCGImagePropertyOrientation] != nil
  }

  private static func stripExifApp1Segments(_ data: Data) -> Data? {
    guard isJpeg(data) else {
      return nil
    }

    var output = Data([0xFF, 0xD8])
    var offset = 2
    var strippedAny = false

    while offset < data.count {
      if data[offset] != 0xFF {
        output.append(data.subdata(in: offset..<data.count))
        return strippedAny ? output : data
      }

      let markerStart = offset
      while offset < data.count && data[offset] == 0xFF {
        offset += 1
      }
      if offset >= data.count {
        return strippedAny ? output : data
      }

      let marker = data[offset]
      offset += 1

      let hasNoLength =
        marker == 0xD8 ||
        marker == 0xD9 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)

      if hasNoLength {
        output.append(data.subdata(in: markerStart..<offset))
        if marker == 0xD9 {
          return strippedAny ? output : data
        }
        continue
      }

      if offset + 2 > data.count {
        return strippedAny ? output : data
      }

      let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
      let segmentEnd = offset + length
      if length < 2 || segmentEnd > data.count {
        return strippedAny ? output : data
      }

      if marker == 0xDA {
        output.append(data.subdata(in: markerStart..<segmentEnd))
        output.append(data.subdata(in: segmentEnd..<data.count))
        return strippedAny ? output : data
      }

      let isExifApp1 =
        marker == 0xE1 &&
        length >= 8 &&
        data[offset + 2] == 0x45 &&
        data[offset + 3] == 0x78 &&
        data[offset + 4] == 0x69 &&
        data[offset + 5] == 0x66 &&
        data[offset + 6] == 0x00 &&
        data[offset + 7] == 0x00

      if isExifApp1 {
        strippedAny = true
      } else {
        output.append(data.subdata(in: markerStart..<segmentEnd))
      }

      offset = segmentEnd
    }

    return strippedAny ? output : data
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
          if let cropped = SavePhotoDelegate.cropPhotoData(rawData, ciContext: ctx) {
            NSLog(
              "[SavePhotoDelegate] crop applied: %.0fx%.0f -> %.0fx%.0f (%d bytes)",
              cropped.fullExtent.width,
              cropped.fullExtent.height,
              cropped.croppedExtent.width,
              cropped.croppedExtent.height,
              cropped.data.count)
            finalData = SavePhotoDelegate.clearJpegExifOrientation(cropped.data)
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
          finalData = SavePhotoDelegate.clearJpegExifOrientation(rawData)
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
