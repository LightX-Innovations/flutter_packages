#include "camera.h"

#include <opencv2/opencv.hpp>

#include "camera_texture_image_event_handler.h"

Camera::Camera(Pylon::IPylonDevice* device, int64_t camera_id,
               FlPluginRegistrar* registrar,
               CameraLinuxPlatformResolutionPreset resolution_preset)
    : camera_id(camera_id),
      cameraLinuxCameraEventApi(camera_linux_camera_event_api_new(
          fl_plugin_registrar_get_messenger(registrar),
          std::to_string(camera_id).c_str())),
      exposure_mode(CameraLinuxPlatformExposureMode::
                        CAMERA_LINUX_PLATFORM_EXPOSURE_MODE_AUTO),
      focus_mode(CameraLinuxPlatformFocusMode::
                     CAMERA_LINUX_PLATFORM_FOCUS_MODE_LOCKED),
      width(3840),
      height(2160),
      imageFormatGroup(CameraLinuxPlatformImageFormatGroup::
                           CAMERA_LINUX_PLATFORM_IMAGE_FORMAT_GROUP_RGB8),
      resolution_preset(resolution_preset),
      registrar(registrar) {
  camera = std::make_unique<Pylon::CInstantCamera>(device);
  setResolutionPreset(resolution_preset);
  if (registrar) g_object_ref(registrar);
}

Camera::~Camera() {
  if (cameraTextureImageEventHandler && camera)
    camera->DeregisterImageEventHandler(cameraTextureImageEventHandler.get());
  if (camera) {
    if (camera->IsGrabbing()) camera->StopGrabbing();
    if (camera->IsOpen()) camera->Close();
  }
  if (cameraLinuxCameraEventApi) g_object_unref(cameraLinuxCameraEventApi);
  if (registrar) g_object_unref(registrar);
}

void Camera::initialize(CameraLinuxPlatformImageFormatGroup imageFormat) {
  imageFormatGroup = imageFormat;
  cameraTextureImageEventHandler =
      std::make_unique<CameraTextureImageEventHandler>(*this, registrar);
  camera->Open();
  GenApi::INodeMap& nodemap = camera->GetNodeMap();
  Pylon::CEnumParameter(nodemap, "DeviceLinkThroughputLimitMode")
      .TrySetValue("Off");
  Pylon::CBooleanParameter(nodemap, "AcquisitionFrameRateEnable")
      .TrySetValue(true);
  Pylon::CFloatParameter(nodemap, "AcquisitionFrameRate").TrySetValue(60.0);
  Pylon::CFloatParameter(nodemap, "ResultingFrameRate").TrySetValue(60.0);
  setImageFormatGroup(imageFormat);
  Pylon::CEnumParameter(nodemap, "TriggerMode").SetValue("Off");
  Pylon::CIntegerParameter(nodemap, "Width").TrySetValue(width);
  Pylon::CIntegerParameter(nodemap, "Height").TrySetValue(height);
  Pylon::CIntegerParameter(nodemap, "OffsetX").TrySetValue(0);
  Pylon::CIntegerParameter(nodemap, "OffsetY").TrySetValue(0);
  Pylon::CStringParameter(nodemap, "ExposureAuto").TrySetValue("Continuous");
  Pylon::CBooleanParameter(nodemap, "ReverseY").TrySetValue(true);
  Pylon::CBooleanParameter(nodemap, "AutoFunctionROIUseBrightness")
      .TrySetValue(true);
  Pylon::CBooleanParameter(nodemap, "AutoFunctionROIUseWhiteBalance")
      .TrySetValue(true);
  Pylon::CEnumParameter(nodemap, "BslDefectPixelCorrectionMode")
      .TrySetValue("On");

  camera->RegisterImageEventHandler(cameraTextureImageEventHandler.get(),
                                    Pylon::RegistrationMode_Append,
                                    Pylon::Cleanup_None);
  camera->StartGrabbing(Pylon::GrabStrategy_LatestImages,
                        Pylon::EGrabLoop::GrabLoop_ProvidedByInstantCamera);

  emitState();
}

void Camera::setImageFormatGroup(
    CameraLinuxPlatformImageFormatGroup imageFormatGroup) {
  CAMERA_CONFIG_LOCK({
    GenApi::INodeMap& nodemap = camera->GetNodeMap();
    switch (imageFormatGroup) {
      case CameraLinuxPlatformImageFormatGroup::
          CAMERA_LINUX_PLATFORM_IMAGE_FORMAT_GROUP_MONO8:
        Pylon::CEnumParameter(nodemap, "PixelFormat").SetValue("Mono8");
        break;
      case CameraLinuxPlatformImageFormatGroup::
          CAMERA_LINUX_PLATFORM_IMAGE_FORMAT_GROUP_RGB8:
      default:
        Pylon::CEnumParameter(nodemap, "PixelFormat").SetValue("RGB8");
        break;
    }
  });
}

int64_t Camera::getTextureId() {
  if (!cameraTextureImageEventHandler) return -1;
  return cameraTextureImageEventHandler->get_texture_id();
}

void Camera::takePicture(std::string filePath) {
  CAMERA_CONFIG_LOCK(
      Pylon::CGrabResultPtr grabResult;

      if (camera->IsGrabbing()) { camera->StopGrabbing(); }

      if (!camera->GrabOne(Pylon::INFINITE, grabResult,
                           Pylon::TimeoutHandling_Return)) {
        std::cerr << "Failed to grab image within timeout." << std::endl;
        return;
      }

      if (!grabResult.IsValid() || !grabResult->GrabSucceeded()) {
        std::cerr << "Failed to grab image." << std::endl;
        return;
      };
      Pylon::CPylonImage image; image.AttachGrabResultBuffer(grabResult);
      bool isMono = image.GetPixelType() == Pylon::PixelType_Mono8 ||
                    image.GetPixelType() == Pylon::PixelType_Mono12 ||
                    image.GetPixelType() == Pylon::PixelType_Mono16;

      cv::Mat mat(grabResult->GetHeight(), grabResult->GetWidth(),
                  isMono ? CV_8UC1 : CV_8UC3, (uint8_t*)image.GetBuffer());
      cv::Mat bgr;
      cv::cvtColor(mat, bgr, isMono ? cv::COLOR_GRAY2BGR : cv::COLOR_RGB2BGR);
      cv::imwrite(filePath, bgr);

  );
}

void camera_linux_camera_event_api_initialized_callback(GObject* object,
                                                        GAsyncResult* result,
                                                        gpointer user_data) {}

void Camera::emitState() {
  if (!cameraLinuxCameraEventApi) return;
  CameraLinuxPlatformSize* size = camera_linux_platform_size_new(width, height);
  CameraLinuxPlatformCameraState* cameraState =
      camera_linux_platform_camera_state_new(size, exposure_mode, focus_mode,
                                             false, false);
  camera_linux_camera_event_api_initialized(
      cameraLinuxCameraEventApi, cameraState, nullptr,
      camera_linux_camera_event_api_initialized_callback, nullptr);
  g_object_unref(cameraState);
  g_object_unref(size);
}

void Camera::emitTextureId(int64_t textureId) const {
  if (!cameraLinuxCameraEventApi) return;

  camera_linux_camera_event_api_texture_id(
      cameraLinuxCameraEventApi, textureId, nullptr,
      camera_linux_camera_event_api_initialized_callback, nullptr);
}

Camera& Camera::setResolutionPreset(
    CameraLinuxPlatformResolutionPreset preset) {
  switch (preset) {
    case CameraLinuxPlatformResolutionPreset::
        CAMERA_LINUX_PLATFORM_RESOLUTION_PRESET_LOW:
      width = 352;
      height = 288;
      break;
    case CameraLinuxPlatformResolutionPreset::
        CAMERA_LINUX_PLATFORM_RESOLUTION_PRESET_MEDIUM:
      width = 640;
      height = 480;
      break;
    case CameraLinuxPlatformResolutionPreset::
        CAMERA_LINUX_PLATFORM_RESOLUTION_PRESET_HIGH:
      width = 1280;
      height = 720;
      break;
    case CameraLinuxPlatformResolutionPreset::
        CAMERA_LINUX_PLATFORM_RESOLUTION_PRESET_VERY_HIGH:
      width = 1920;
      height = 1080;
      break;
    case CameraLinuxPlatformResolutionPreset::
        CAMERA_LINUX_PLATFORM_RESOLUTION_PRESET_ULTRA_HIGH:
    case CameraLinuxPlatformResolutionPreset::
        CAMERA_LINUX_PLATFORM_RESOLUTION_PRESET_MAX:
      width = 3840;
      height = 2160;
      break;
    default:
      width = 1920;
      height = 1080;
      break;
  }
  resolution_preset = preset;
  return *this;
}

void Camera::setExposureMode(CameraLinuxPlatformExposureMode mode) {
  CAMERA_CONFIG_LOCK({
    GenApi::INodeMap& nodemap = camera->GetNodeMap();
    switch (mode) {
      case CameraLinuxPlatformExposureMode::
          CAMERA_LINUX_PLATFORM_EXPOSURE_MODE_AUTO:
        Pylon::CEnumParameter(nodemap, "ExposureAuto")
            .TrySetValue("Continuous");
        break;
      case CameraLinuxPlatformExposureMode::
          CAMERA_LINUX_PLATFORM_EXPOSURE_MODE_LOCKED:
        Pylon::CEnumParameter(nodemap, "ExposureAuto").TrySetValue("Off");
        break;
      default:
        Pylon::CEnumParameter(nodemap, "ExposureAuto")
            .TrySetValue("Continuous");
        break;
    }
    exposure_mode = mode;
    emitState();
  });
}

void Camera::setFocusMode(CameraLinuxPlatformFocusMode mode) {
  CAMERA_CONFIG_LOCK({
    GenApi::INodeMap& nodemap = camera->GetNodeMap();
    switch (mode) {
      case CameraLinuxPlatformFocusMode::CAMERA_LINUX_PLATFORM_FOCUS_MODE_AUTO:
        Pylon::CEnumParameter(nodemap, "FocusAuto")
            .TrySetValue("FocusAuto_Continuous");
        break;
      case CameraLinuxPlatformFocusMode::
          CAMERA_LINUX_PLATFORM_FOCUS_MODE_LOCKED:
        Pylon::CEnumParameter(nodemap, "FocusAuto")
            .TrySetValue("FocusAuto_Off");
        break;
      default:
        Pylon::CEnumParameter(nodemap, "FocusAuto")
            .TrySetValue("FocusAuto_Continuous");
        break;
    }
    focus_mode = mode;
    emitState();
  });
}

void Camera::startVideoRecording(std::string filePath) {
  if (!camera || !Pylon::CVideoWriter::IsSupported() ||
      cameraVideoRecorderImageEventHandler) {
    std::cerr << "Video recording is not supported or camera is not "
                 "initialized. or already recording."
              << std::endl;
    return;
  }
  CAMERA_CONFIG_LOCK({
    cameraVideoRecorderImageEventHandler =
        std::make_unique<CameraVideoRecorderImageEventHandler>(filePath);
    camera->RegisterImageEventHandler(
        cameraVideoRecorderImageEventHandler.get(),
        Pylon::RegistrationMode_Append, Pylon::Cleanup_None);
  });
}

void Camera::stopVideoRecording(std::string& filePath) {
  if (!camera || !cameraVideoRecorderImageEventHandler) {
    return;
  }
  CAMERA_CONFIG_LOCK({
    filePath = cameraVideoRecorderImageEventHandler->m_videoFilePath;
    camera->DeregisterImageEventHandler(
        cameraVideoRecorderImageEventHandler.get());
    cameraVideoRecorderImageEventHandler.reset();
  });
}