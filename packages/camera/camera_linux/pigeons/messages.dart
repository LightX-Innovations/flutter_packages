// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  gobjectHeaderOut: 'linux/messages.g.h',
  gobjectSourceOut: 'linux/messages.g.cc',
  gobjectOptions: GObjectOptions(),
  copyrightHeader: 'pigeons/copyright.txt',
))

// Pigeon equivalent of CGSize.
class PlatformSize {
  PlatformSize({required this.width, required this.height});

  final double width;
  final double height;
}

// Pigeon version of DeviceOrientation.
enum PlatformDeviceOrientation {
  portraitUp,
  landscapeLeft,
  portraitDown,
  landscapeRight,
}

// Pigeon version of ExposureMode.
enum PlatformExposureMode {
  auto,
  locked,
}

// Pigeon version of FlashMode.
enum PlatformFlashMode {
  off,
  auto,
  always,
  torch,
}

// Pigeon version of FocusMode.
enum PlatformFocusMode {
  auto,
  locked,
}

/// Pigeon version of ImageFileFormat.
enum PlatformImageFileFormat {
  jpeg,
  heif,
}

// Pigeon version of the subset of ImageFormatGroup supported on iOS.
enum PlatformImageFormatGroup {
  rgb8,
  mono8,
}

enum PlatformResolutionPreset {
  low, // 352x288 on iOS, ~240p on Android and Web
  medium, // ~480p
  high, // ~720p
  veryHigh, // ~1080p
  ultraHigh, // ~2160p
  max, // The highest resolution available.
}

// Pigeon version of the data needed for a CameraInitializedEvent.
class PlatformCameraState {
  PlatformCameraState({
    required this.previewSize,
    required this.exposureMode,
    required this.focusMode,
    required this.exposurePointSupported,
    required this.focusPointSupported,
  });

  /// The size of the preview, in pixels.
  final PlatformSize previewSize;

  /// The default exposure mode
  final PlatformExposureMode exposureMode;

  /// The default focus mode
  final PlatformFocusMode focusMode;

  /// Whether setting exposure points is supported.
  final bool exposurePointSupported;

  /// Whether setting focus points is supported.
  final bool focusPointSupported;
}

// Pigeon equivalent of CGPoint.
class PlatformPoint {
  PlatformPoint({required this.x, required this.y});

  final double x;
  final double y;
}

@HostApi()
abstract class CameraApi {
  /// Returns the list of available cameras.
  @async
  List<String> getAvailableCamerasNames();

  /// Create a new camera with the given settings, and returns its ID.
  @async
  int create(String cameraName, PlatformResolutionPreset resolutionPreset);

  /// Initializes the camera with the given ID.
  @async
  void initialize(int cameraId, PlatformImageFormatGroup imageFormat);

  /// Begins streaming frames from the camera.
  @async
  void startImageStream();

  /// Stops streaming frames from the camera.
  @async
  void stopImageStream();

  /// Get the texture ID for the camera with the given ID.
  @async
  int? getTextureId(int cameraId);

  /// Called by the Dart side of the plugin when it has received the last image
  /// frame sent.
  ///
  /// This is used to throttle sending frames across the channel.
  @async
  void receivedImageStreamData();

  /// Indicates that the given camera is no longer being used on the Dart side,
  /// and any associated resources can be cleaned up.
  @async
  void dispose(int cameraId);

  /// Locks the camera capture to the current device orientation.
  @async
  void lockCaptureOrientation(PlatformDeviceOrientation orientation);

  /// Unlocks camera capture orientation, allowing it to automatically adapt to
  /// device orientation.
  @async
  void unlockCaptureOrientation();

  /// Takes a picture with the current settings, and returns the path to the
  /// resulting file.
  @async
  String takePicture();

  /// Does any preprocessing necessary before beginning to record video.
  @async
  void prepareForVideoRecording();

  /// Begins recording video, optionally enabling streaming to Dart at the same
  /// time.
  @async
  void startVideoRecording(bool enableStream);

  /// Stops recording video, and results the path to the resulting file.
  @async
  String stopVideoRecording();

  /// Pauses video recording.
  @async
  void pauseVideoRecording();

  /// Resumes a previously paused video recording.
  @async
  void resumeVideoRecording();

  /// Switches the camera to the given flash mode.
  @async
  void setFlashMode(PlatformFlashMode mode);

  /// Switches the camera to the given exposure mode.
  @async
  void setExposureMode(PlatformExposureMode mode);

  /// Anchors auto-exposure to the given point in (0,1) coordinate space.
  ///
  /// A null value resets to the default exposure point.
  @async
  void setExposurePoint(PlatformPoint? point);

  /// Sets the lens position manually to the given value.
  /// The value should be between 0 and 1.
  /// 0 means the lens is at the minimum position.
  /// 1 means the lens is at the maximum position.
  @async
  void setLensPosition(double position);

  /// Returns the minimum exposure offset supported by the camera.
  @async
  double getMinExposureOffset();

  /// Returns the maximum exposure offset supported by the camera.
  @async
  double getMaxExposureOffset();

  /// Sets the exposure offset manually to the given value.
  @async
  void setExposureOffset(double offset);

  /// Switches the camera to the given focus mode.
  @async
  void setFocusMode(PlatformFocusMode mode);

  /// Anchors auto-focus to the given point in (0,1) coordinate space.
  ///
  /// A null value resets to the default focus point.
  @async
  void setFocusPoint(PlatformPoint? point);

  /// Returns the minimum zoom level supported by the camera.
  @async
  double getMinZoomLevel();

  /// Returns the maximum zoom level supported by the camera.
  @async
  double getMaxZoomLevel();

  /// Sets the zoom factor.
  @async
  void setZoomLevel(double zoom);

  /// Pauses streaming of preview frames.
  @async
  void pausePreview();

  /// Resumes a previously paused preview stream.
  @async
  void resumePreview();

  /// Changes the camera used while recording video.
  ///
  /// This should only be called while video recording is active.
  @async
  void updateDescriptionWhileRecording(String cameraName);

  /// Sets the file format used for taking pictures.
  @async
  void setImageFileFormat(PlatformImageFileFormat format);

  //Sets the ImageFormatGroup.
  @async
  void setImageFormatGroup(
      int cameraId, PlatformImageFormatGroup imageFormatGroup);
}

/// Handler for native callbacks that are tied to a specific camera ID.
///
/// This is intended to be initialized with the camera ID as a suffix.
@FlutterApi()
abstract class CameraEventApi {
  /// Called when the camera is inialitized for use.
  void initialized(PlatformCameraState initialState);

  void textureId(int textureId);

  /// Called when an error occurs in the camera.
  ///
  /// This should be used for errors that occur outside of the context of
  /// handling a specific HostApi call, such as during streaming.
  void error(String message);
}
