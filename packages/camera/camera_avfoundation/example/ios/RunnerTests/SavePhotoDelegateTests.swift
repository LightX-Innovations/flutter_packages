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
    orientation: CGImagePropertyOrientation = .up
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

    let properties = [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary
    CGImageDestinationAddImage(destination, cgImage, properties)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func makeTestJPEG(width: Int, height: Int) -> Data {
    let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let ctx = CIContext()
    return ctx.jpegRepresentation(of: ci, colorSpace: CGColorSpaceCreateDeviceRGB())!
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

  func testCenteredSquareCropRect_usesShortestEdgeAndCentersCrop() {
    let ciCropRect = SavePhotoDelegate.centeredSquareCropRect(fullWidth: 2268, fullHeight: 4032)

    XCTAssertEqual(ciCropRect.origin.x, 0, accuracy: CGFloat(0.001))
    XCTAssertEqual(ciCropRect.origin.y, 882, accuracy: CGFloat(0.001))
    XCTAssertEqual(ciCropRect.width, 2268, accuracy: CGFloat(0.001))
    XCTAssertEqual(ciCropRect.height, 2268, accuracy: CGFloat(0.001))
  }

  func testCropPhotoData_cropsToSquareAndProducesSquareOutput() throws {
    let rawData = try makeJPEGData(width: 60, height: 40, orientation: .right)

    let result = try XCTUnwrap(
      SavePhotoDelegate.cropPhotoData(
      rawData,
      ciContext: CIContext()))

    XCTAssertEqual(result.fullExtent.width, 60, accuracy: CGFloat(0.001))
    XCTAssertEqual(result.fullExtent.height, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(result.croppedExtent.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(result.croppedExtent.height, 40, accuracy: CGFloat(0.001))

    let outputSize = try XCTUnwrap(pixelSize(of: result.data))
    XCTAssertEqual(outputSize.width, 40, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 40, accuracy: CGFloat(0.001))
  }

  func testHandlePhotoCaptureResult_cropProducesSquareFromPortraitPhoto() throws {
    let completionExpectation = expectation(description: "Cropped portrait photo should be written")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = makeTestJPEG(width: 2268, height: 4032)
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
    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 2268, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 2268, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_cropProducesSquareFromLandscapePhoto() throws {
    let completionExpectation = expectation(description: "Cropped landscape photo should be written")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = makeTestJPEG(width: 4032, height: 3024)
    let cropRect = PlatformRect(x: 0.125, y: 0, width: 0.75, height: 1.0)
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
    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 3024, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 3024, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_squarePhotoRemainsSquare() throws {
    let completionExpectation = expectation(description: "Square photo should remain square")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = makeTestJPEG(width: 3024, height: 3024)
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
      ciContext: CIContext())

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 3024, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 3024, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_noCropWritesOriginalDataUnchanged() throws {
    let completionExpectation = expectation(description: "Uncropped photo should be written")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = makeTestJPEG(width: 640, height: 480)
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

  func testHandlePhotoCaptureResult_invalidImageFallsBackToOriginalData() throws {
    let completionExpectation = expectation(description: "Invalid image data should still be written")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = Data([0x00, 0x01, 0x02])
    let fileUrl = makeTempPhotoPath()

    let delegate = SavePhotoDelegate(
      path: fileUrl.path,
      ioQueue: ioQueue,
      completionHandler: { path, error in
        XCTAssertNil(error)
        XCTAssertEqual(path, fileUrl.path)
        completionExpectation.fulfill()
      },
      cropRect: PlatformRect(x: 0, y: 0, width: 1.0, height: 1.0),
      ciContext: CIContext())

    delegate.handlePhotoCaptureResult(error: nil) { rawData }

    waitForExpectations(timeout: 30, handler: nil)

    let writtenData = try Data(contentsOf: fileUrl)
    XCTAssertEqual(writtenData, rawData)
    try? FileManager.default.removeItem(at: fileUrl)
  }

  func testHandlePhotoCaptureResult_arbitraryCropRectValuesAreIgnored() throws {
    let completionExpectation = expectation(description: "Arbitrary crop rect should still yield centered square")
    let ioQueue = DispatchQueue(label: "test")
    let rawData = makeTestJPEG(width: 1920, height: 1080)
    let cropRect = PlatformRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)
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
    let outputSize = try XCTUnwrap(pixelSize(of: writtenData))
    XCTAssertEqual(outputSize.width, 1080, accuracy: CGFloat(0.001))
    XCTAssertEqual(outputSize.height, 1080, accuracy: CGFloat(0.001))
    try? FileManager.default.removeItem(at: fileUrl)
  }
}
