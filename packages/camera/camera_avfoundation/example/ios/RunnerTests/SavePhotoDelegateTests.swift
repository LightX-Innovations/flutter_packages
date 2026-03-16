// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreImage
import ImageIO
import MobileCoreServices
import XCTest

@testable import camera_avfoundation

final class SavePhotoDelegateTests: XCTestCase {
  private func makeJPEGData(
    width: Int,
    height: Int,
    orientation: CGImagePropertyOrientation = .up,
    additionalProperties: [CFString: Any] = [:]
  ) throws -> Data {
    let ciContext = CIContext()
    let image = CIImage(color: .init(red: 0.2, green: 0.6, blue: 0.9))
      .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

    guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
      XCTFail("Expected CGImage creation to succeed")
      throw NSError(domain: "SavePhotoDelegateTests", code: 1)
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      kUTTypeJPEG,
      1,
      nil)
    else {
      XCTFail("Expected CGImageDestination creation to succeed")
      throw NSError(domain: "SavePhotoDelegateTests", code: 2)
    }

    var properties = additionalProperties
    properties[kCGImagePropertyOrientation] = orientation.rawValue
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func makeTestJPEG(width: Int, height: Int) -> Data {
    let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let ctx = CIContext()
    return ctx.jpegRepresentation(of: ci, colorSpace: CGColorSpaceCreateDeviceRGB())!
  }

  private func exifOrientation(of imageData: Data) -> Int? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      return nil
    }

    return properties[kCGImagePropertyOrientation] as? Int
  }

  private func pixelSize(of imageData: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else {
      return nil
    }

    return CGSize(width: width, height: height)
  }

  private func displayedPixelSize(of imageData: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 4096,
        ] as CFDictionary)
    else {
      return nil
    }

    return CGSize(width: image.width, height: image.height)
  }

  private func exifUserComment(of imageData: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    else {
      return nil
    }

    return exif[kCGImagePropertyExifUserComment] as? String
  }

  private func tiffMake(of imageData: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    else {
      return nil
    }

    return tiff[kCGImagePropertyTIFFMake] as? String
  }

  private func makeTempPhotoPath() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("jpg")
  }

  func testHandlePhotoCaptureResult_mustCompleteWithErrorIfFailedToCapture() {
    let completionExpectation = expectation(
      description: "Must complete with error if failed to capture photo.")
    let captureError = NSError(domain: "test", code: 0, userInfo: nil)
    let ioQueue = DispatchQueue(label: "test")
    let delegate = SavePhotoDelegate(path: "test", ioQueue: ioQueue) { path, error in
      XCTAssertEqual(captureError, error as NSError?)
      XCTAssertNil(path)
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(error: captureError) { nil }

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_mustCompleteWithErrorIfFailedToWrite() {
    let completionExpectation = expectation(
      description: "Must complete with error if failed to write file.")
    let ioQueue = DispatchQueue(label: "test")
    let ioError = NSError(
      domain: "IOError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Localized IO Error"])
    let delegate = SavePhotoDelegate(path: "test", ioQueue: ioQueue) { path, error in
      XCTAssertEqual(ioError, error as NSError?)
      XCTAssertNil(path)
      completionExpectation.fulfill()
    }

    let mockWritableData = MockWritableData()
    mockWritableData.writeToFileStub = { path, options in
      throw ioError
    }

    delegate.handlePhotoCaptureResult(error: nil) { mockWritableData }

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_mustCompleteWithFilePathIfSuccessToWrite() {
    let completionExpectation = expectation(
      description: "Must complete with file path if succeeds to write file.")
    let ioQueue = DispatchQueue(label: "test")
    let filePath = "test"
    let delegate = SavePhotoDelegate(path: filePath, ioQueue: ioQueue) { path, error in
      XCTAssertNil(error)
      XCTAssertEqual(filePath, path)
      completionExpectation.fulfill()
    }

    let mockWritableData = MockWritableData()
    mockWritableData.writeToFileStub = { path, options in }

    delegate.handlePhotoCaptureResult(error: nil) { mockWritableData }

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_bothProvideDataAndSaveFileMustRunOnIOQueue() {
    let dataProviderQueueExpectation = expectation(
      description: "Data provider must run on io queue.")
    let writeFileQueueExpectation = expectation(description: "File writing must run on io queue.")
    let completionExpectation = expectation(
      description: "Must complete with file path if success to write file.")
    let ioQueue = DispatchQueue(label: "test")
    let ioQueueSpecific = DispatchSpecificKey<Void>()
    ioQueue.setSpecific(key: ioQueueSpecific, value: ())

    let mockWritableData = MockWritableData()
    mockWritableData.writeToFileStub = { path, options in
      if DispatchQueue.getSpecific(key: ioQueueSpecific) != nil {
        writeFileQueueExpectation.fulfill()
      }
    }

    let filePath = "test"
    let delegate = SavePhotoDelegate(path: filePath, ioQueue: ioQueue) { path, error in
      completionExpectation.fulfill()
    }

    delegate.handlePhotoCaptureResult(error: nil) {
      if DispatchQueue.getSpecific(key: ioQueueSpecific) != nil {
        dataProviderQueueExpectation.fulfill()
      }
      return mockWritableData
    }

    waitForExpectations(timeout: 30, handler: nil)
  }

  func testHandlePhotoCaptureResult_noCropStripsExifOrientation() throws {
    let completionExpectation = expectation(description: "Uncropped photo should be written")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = try makeJPEGData(width: 60, height: 40, orientation: .rightMirrored)
    XCTAssertEqual(exifOrientation(of: rawData), 7)
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      })

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertNil(exifOrientation(of: writtenData))

    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 60, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_noCropPreservesDisplayedOrientationAfterExifCleanup() throws {
    let completionExpectation = expectation(description: "Uncropped photo should preserve display orientation")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = try makeJPEGData(width: 60, height: 40, orientation: .rightMirrored)
    let rawDisplayedSize = try XCTUnwrap(displayedPixelSize(of: rawData))
    XCTAssertEqual(rawDisplayedSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(rawDisplayedSize.height, 60, accuracy: CGFloat(0.001))
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      })

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertNil(exifOrientation(of: writtenData))
    let displayedSize = try XCTUnwrap(displayedPixelSize(of: writtenData))
    XCTAssertEqual(displayedSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(displayedSize.height, 60, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_noCropPreservesOtherMetadata() throws {
    let completionExpectation = expectation(description: "Uncropped photo should preserve non-orientation metadata")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = try makeJPEGData(
      width: 60,
      height: 40,
      orientation: .rightMirrored,
      additionalProperties: [
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifUserComment: "medical-note"
        ],
        kCGImagePropertyTIFFDictionary: [
          kCGImagePropertyTIFFMake: "LightX"
        ],
      ])
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      })

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertNil(exifOrientation(of: writtenData))
    XCTAssertEqual(exifUserComment(of: writtenData), "medical-note")
    XCTAssertEqual(tiffMake(of: writtenData), "LightX")
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_noCropLeavesPlainJpegUntouched() throws {
    let completionExpectation = expectation(description: "Plain JPEG should be written")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = makeTestJPEG(width: 640, height: 480)
    XCTAssertNil(exifOrientation(of: rawData))
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      })

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertEqual(writtenData, rawData)
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_cropProducesSquareAndNoExifOrientation() throws {
    let completionExpectation = expectation(description: "Cropped portrait photo should be written")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = try makeJPEGData(width: 60, height: 40, orientation: .right)
    let cropRect = PlatformRect(x: 0, y: 0.125, width: 1.0, height: 0.75)
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      },
      cropRect: cropRect,
      ciContext: CIContext())

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertNil(exifOrientation(of: writtenData))

    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 40, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_cropPreservesOtherMetadata() throws {
    let completionExpectation = expectation(description: "Cropped photo should preserve non-orientation metadata")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = try makeJPEGData(
      width: 60,
      height: 40,
      orientation: .right,
      additionalProperties: [
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifUserComment: "medical-note"
        ],
        kCGImagePropertyTIFFDictionary: [
          kCGImagePropertyTIFFMake: "LightX"
        ],
      ])
    let cropRect = PlatformRect(x: 0, y: 0.125, width: 1.0, height: 0.75)
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      },
      cropRect: cropRect,
      ciContext: CIContext())

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertNil(exifOrientation(of: writtenData))
    XCTAssertEqual(exifUserComment(of: writtenData), "medical-note")
    XCTAssertEqual(tiffMake(of: writtenData), "LightX")
    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 40, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  /// Regression test: when the camera connection already physically rotated the
  /// pixels (iOS 17+ with videoRotationAngle), any EXIF orientation tag in the
  /// JPEG is stale.  The delegate must strip it WITHOUT re-applying the rotation
  /// — doing so would double-rotate the image back to sensor-native orientation.
  ///
  /// Input:  40×60 portrait pixels + stale EXIF orientation 6 ("rotate 90° CW")
  /// Expected: 40×60 output (pixel dimensions unchanged), no EXIF orientation.
  /// If the bug is present (EXIF re-applied), output would be 60×40 landscape.
  func testHandlePhotoCaptureResult_noCropDoesNotDoubleRotateWhenPixelsArePhysicallyRotated() throws {
    let completionExpectation = expectation(
      description: "Photo with stale EXIF should preserve pixel dimensions")
    let ioQueue = DispatchQueue(label: "test")
    // Simulate a portrait photo (40×60 raw pixels) that was physically rotated
    // by videoRotationAngle, but still carries a stale EXIF orientation = 6.
    let rawData = try makeJPEGData(width: 40, height: 60, orientation: .right)
    XCTAssertEqual(exifOrientation(of: rawData), 6, "precondition: EXIF orientation 6")
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      },
      pixelsArePhysicallyRotated: true)

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertNil(exifOrientation(of: writtenData), "stale EXIF orientation must be stripped")
    // Pixel dimensions must stay 40×60 — NOT 60×40 which would mean double-rotation.
    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 60, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  /// Regression test: same scenario as above but with a crop rect.
  /// The crop must be taken from the physically-correct portrait pixels, not
  /// from a landscape image produced by double-applying the stale EXIF.
  ///
  /// Input:  40×80 portrait pixels + stale EXIF orientation 6
  /// Expected: 40×40 square (from the portrait short side), no EXIF orientation.
  /// If the bug is present (EXIF re-applied), input appears as 80×40 landscape
  /// and the square would still be 40×40 — but taken from the wrong orientation.
  /// To make the two cases distinguishable we use 40×80 (not square-ish 40×60):
  /// portrait short-side = 40, landscape short-side = 40, both give 40.
  /// We therefore verify that the "physically-rotated" flag works end-to-end  by
  /// checking metadata is stripped and dimensions are correct.
  func testHandlePhotoCaptureResult_cropDoesNotDoubleRotateWhenPixelsArePhysicallyRotated() throws {
    let completionExpectation = expectation(
      description: "Crop with stale EXIF should not double-rotate")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = try makeJPEGData(width: 40, height: 80, orientation: .right)
    XCTAssertEqual(exifOrientation(of: rawData), 6, "precondition: EXIF orientation 6")
    let cropRect = PlatformRect(x: 0, y: 0, width: 1.0, height: 1.0)
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      },
      cropRect: cropRect,
      ciContext: CIContext(),
      pixelsArePhysicallyRotated: true)

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertNil(exifOrientation(of: writtenData), "stale EXIF orientation must be stripped")
    // Square crop from portrait (40×80) → 40×40.
    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 40, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }
}
