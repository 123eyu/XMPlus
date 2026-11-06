# Adapted from PiliPlus, commit d9e9626f1a3f89cd9ca85e18f61aaba02634e12a.
# GPL-3.0; see windows/LICENSE.PiliPlus and NOTICE at the project root.
# Modified 2026-11-04 for XMLY Flutter.

# Project-level configuration.
cmake_minimum_required(VERSION 3.18)
project(XMPlus LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "XMPlus")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

add_compile_options(/utf-8)

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# Upstream 0fc1598ec155659ed7c2db3628693a24bd4e0d25 fixes Windows COM teardown.
# ponytail: keep one process-wide compositor reference; remove after a hosted plugin includes that fix.
get_target_property(WEBVIEW_SOURCE_DIR flutter_inappwebview_windows_plugin SOURCE_DIR)
set(WEBVIEW_MANAGER "${WEBVIEW_SOURCE_DIR}/in_app_webview/in_app_webview_manager.cpp")
file(SHA256 "${WEBVIEW_MANAGER}" WEBVIEW_MANAGER_SHA256)
if(NOT WEBVIEW_MANAGER_SHA256 STREQUAL "eefc7b984c208696b3a3a34f99b0ddc11779fb7470009ebbabcfd274421d77ab")
  message(FATAL_ERROR "Recheck the pinned Windows WebView compositor patch before changing its source.")
endif()
file(READ "${WEBVIEW_MANAGER}" WEBVIEW_MANAGER_SOURCE)
string(REPLACE "compositor_ = graphics_context_->CreateCompositor();"
  "compositor_ = graphics_context_->CreateCompositor();\n        if (compositor_) compositor_->AddRef();"
  WEBVIEW_MANAGER_PATCHED "${WEBVIEW_MANAGER_SOURCE}")
set(WEBVIEW_MANAGER_COPY "${CMAKE_CURRENT_BINARY_DIR}/xmplus_webview_manager.cpp")
file(CONFIGURE OUTPUT "${WEBVIEW_MANAGER_COPY}" CONTENT "${WEBVIEW_MANAGER_PATCHED}" @ONLY)
set_source_files_properties("${WEBVIEW_MANAGER}" TARGET_DIRECTORY flutter_inappwebview_windows_plugin
  PROPERTIES HEADER_FILE_ONLY TRUE)
target_sources(flutter_inappwebview_windows_plugin PRIVATE "${WEBVIEW_MANAGER_COPY}")
target_include_directories(flutter_inappwebview_windows_plugin PRIVATE "${WEBVIEW_SOURCE_DIR}/in_app_webview")

# Add a private per-view command: WebView2 rejects CDP download-behavior APIs.
set(WEBVIEW_CHANNEL "${WEBVIEW_SOURCE_DIR}/in_app_webview/webview_channel_delegate.cpp")
file(SHA256 "${WEBVIEW_CHANNEL}" WEBVIEW_CHANNEL_SHA256)
if(NOT WEBVIEW_CHANNEL_SHA256 STREQUAL "e3a491fea03e5be934c6aec29c6e176f581250f9814eb179f8e0421c37bdbf3e")
  message(FATAL_ERROR "Recheck the pinned Windows WebView download guard before changing its source.")
endif()
file(READ "${WEBVIEW_CHANNEL}" WEBVIEW_CHANNEL_SOURCE)
set(WEBVIEW_GUARD [=[
    if (string_equals(methodName, "xmplusDenyDownloads")) {
      const auto hr = XmplusDenyWebViewDownloads(webView->webView.get());
      if (FAILED(hr)) result->Error(std::to_string(hr), "Cannot install native download guard");
      else result->Success(flutter::EncodableValue(true));
      return;
    }
]=])
string(REPLACE "auto& methodName = method_call.method_name();"
  "auto& methodName = method_call.method_name();\n${WEBVIEW_GUARD}"
  WEBVIEW_CHANNEL_PATCHED "${WEBVIEW_CHANNEL_SOURCE}")
set(WEBVIEW_CHANNEL_COPY "${CMAKE_CURRENT_BINARY_DIR}/xmplus_webview_channel.cpp")
file(CONFIGURE OUTPUT "${WEBVIEW_CHANNEL_COPY}"
  CONTENT "#include \"webview_download_guard.h\"\n${WEBVIEW_CHANNEL_PATCHED}" @ONLY)
set_source_files_properties("${WEBVIEW_CHANNEL}" TARGET_DIRECTORY flutter_inappwebview_windows_plugin
  PROPERTIES HEADER_FILE_ONLY TRUE)
target_sources(flutter_inappwebview_windows_plugin PRIVATE "${WEBVIEW_CHANNEL_COPY}")
target_include_directories(flutter_inappwebview_windows_plugin PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/runner")


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
