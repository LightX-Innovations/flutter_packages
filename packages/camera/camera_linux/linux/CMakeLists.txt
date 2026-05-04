# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

set(CMAKE_CXX_STANDARD 17)

# ---------------------------------------------------------------------------
# Pylon SDK – architecture-aware setup
#
#   aarch64 (Jetson): downloaded automatically from the LightX GitHub release.
#   x86_64  (dev PC): uses a locally installed pylon SDK.
#                     Default search path: /opt/pylon
#                     Override via:  cmake -DPYLON_INSTALL_DIR=/path/to/pylon ...
#
# To install pylon on x86_64 Arch/Garuda Linux:
#   1. Download pylon 8.x Linux x86_64 .tar.gz from https://www.baslerweb.com/en/downloads/
#   2. sudo mkdir -p /opt/pylon && sudo tar -xzf pylon-*.tar.gz -C /opt/pylon
#   The official Basler installer also defaults to /opt/pylon.
# ---------------------------------------------------------------------------

set(PYLON_VERSION "8.0.2.16314")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64")
    # --- aarch64 (Jetson): auto-download from GitHub release ---
    set(PYLON_ARCH "aarch64")
    set(PYLON_ARCHIVE_NAME "pylon-${PYLON_VERSION}_linux-${PYLON_ARCH}.tar.gz")
    set(PYLON_ARCHIVE_PATH ${CMAKE_BINARY_DIR}/downloads/${PYLON_ARCHIVE_NAME})
    set(PYLON_DOWNLOAD_URL "https://github.com/LightX-Innovations/flutter_packages/releases/download/camera_linux_v0.1/pylon-${PYLON_VERSION}_linux-${PYLON_ARCH}.tar.gz")
    set(PYLON_ROOT ${CMAKE_BINARY_DIR}/pylon-sdk)

    set(PYLON_MPEG_ARCHIVE_NAME "pylon-supplementary-package-for-mpeg-4-1.0.2.121_${PYLON_ARCH}.tar.gz")
    set(PYLON_MPEG_ARCHIVE_PATH ${CMAKE_BINARY_DIR}/downloads/${PYLON_MPEG_ARCHIVE_NAME})
    set(PYLON_MPEG_DOWNLOAD_URL "https://github.com/LightX-Innovations/flutter_packages/releases/download/camera_linux_v0.1/${PYLON_MPEG_ARCHIVE_NAME}")

    if(NOT EXISTS "${PYLON_ARCHIVE_PATH}")
        message(STATUS "Downloading Pylon SDK archive (${PYLON_ARCH})...")
        file(DOWNLOAD
            "${PYLON_DOWNLOAD_URL}"
            "${PYLON_ARCHIVE_PATH}"
            SHOW_PROGRESS
            STATUS DOWNLOAD_STATUS
        )
        list(GET DOWNLOAD_STATUS 0 DOWNLOAD_RESULT)
    endif()

    if(NOT EXISTS "${PYLON_MPEG_ARCHIVE_PATH}")
        message(STATUS "Downloading Pylon SDK MPEG archive (${PYLON_ARCH})...")
        file(DOWNLOAD
            "${PYLON_MPEG_DOWNLOAD_URL}"
            "${PYLON_MPEG_ARCHIVE_PATH}"
            SHOW_PROGRESS
            STATUS DOWNLOAD_STATUS
        )
        list(GET DOWNLOAD_STATUS 0 DOWNLOAD_RESULT)
    endif()

    if(NOT EXISTS "${PYLON_ROOT}")
        message(STATUS "Extracting Pylon SDK to ${PYLON_ROOT}...")
        file(MAKE_DIRECTORY "${PYLON_ROOT}")
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E tar -xzf "${PYLON_ARCHIVE_PATH}"
            WORKING_DIRECTORY "${PYLON_ROOT}"
        )
        message(STATUS "Extracting Pylon MPEG SDK to ${PYLON_ROOT}...")
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E tar -xzf "${PYLON_MPEG_ARCHIVE_PATH}"
            WORKING_DIRECTORY "${PYLON_ROOT}"
        )
    endif()

else()
    # --- x86_64 (dev PC): use locally installed pylon ---
    if(NOT DEFINED PYLON_INSTALL_DIR)
        set(PYLON_INSTALL_DIR "/opt/pylon")
    endif()

    if(NOT EXISTS "${PYLON_INSTALL_DIR}/include/pylon/PylonIncludes.h")
        message(FATAL_ERROR
            "Pylon SDK not found at '${PYLON_INSTALL_DIR}'.\n"
            "Install pylon for x86_64 from https://www.baslerweb.com/en/downloads/ "
            "(extract to /opt/pylon), then re-run cmake.\n"
            "Or pass -DPYLON_INSTALL_DIR=/your/path to cmake."
        )
    endif()

    set(PYLON_ROOT "${PYLON_INSTALL_DIR}")
    message(STATUS "Using locally installed Pylon SDK at ${PYLON_ROOT}")
endif()

include_directories(${PYLON_ROOT}/include)

link_directories(${PYLON_ROOT}/lib)

# Project-level configuration.
set(PROJECT_NAME "camera_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "camera_linux_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "camera_plugin.cpp"
  "camera_host_plugin.cpp"
 
  "camera_video_recorder_image_event_handler.cpp"
  "camera.cpp"
  "capture_pipeline.cpp"
  "fl_lightx_texture_gl.cpp"
 
  "messages.g.cc"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
cmake_policy(SET CMP0072 NEW)
set(OpenGL_GL_PREFERENCE GLVND)
find_package( OpenGL REQUIRED )
target_link_libraries(${PLUGIN_NAME} PRIVATE OpenGL::GL)
target_link_libraries(${PLUGIN_NAME}
    PRIVATE
    ${PYLON_ROOT}/lib/libpylonbase.so
    ${PYLON_ROOT}/lib/libpylonutility.so
)
find_package(PkgConfig REQUIRED)

# --- OpenCV Integration ---
# Exclude optional modules that pull in unavailable VTK/HDF5 system libs.
find_package(OpenCV REQUIRED COMPONENTS
    core imgproc highgui imgcodecs videoio calib3d features2d
    objdetect photo stitching video ml flann)
include_directories(${OpenCV_INCLUDE_DIRS})
# Filter out viz and hdf modules which require VTK and HDF5 (not needed here).
set(_opencv_filtered_libs "")
foreach(_lib ${OpenCV_LIBS})
    if(NOT _lib MATCHES "opencv_viz|opencv_hdf")
        list(APPEND _opencv_filtered_libs "${_lib}")
    endif()
endforeach()
target_link_libraries(${PLUGIN_NAME} PRIVATE ${_opencv_filtered_libs})

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(camera_linux_bundled_libraries
  "${PYLON_ROOT}/lib/libpylonbase.so"
  "${PYLON_ROOT}/lib/libpylonutility.so"
  PARENT_SCOPE
)
