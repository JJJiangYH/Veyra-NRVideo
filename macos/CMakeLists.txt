# Copyright Veyra contributors
# SPDX-License-Identifier: GPL-3.0-only
if(CMAKE_OSX_DEPLOYMENT_TARGET AND CMAKE_OSX_DEPLOYMENT_TARGET VERSION_LESS 26.0)
  message(FATAL_ERROR "Veyra for macOS requires macOS 26 or later")
endif()

find_program(VEYRA_XCRUN xcrun REQUIRED)
include(GameStream.cmake)
include(PS5Stream.cmake)
include(XboxStream.cmake)
set(veyra_mac_sources
  App.swift
  Player.swift
  Video.swift
  Export.swift
  Metrics.swift
  Capture.swift
  CaptureRecording.swift
  CaptureReplay.swift
  MediaContainer.swift
  Subtitles.swift
  NetworkMedia.swift
  PicturePreset.swift
  LiveCaptions.swift
  PictureGraph.swift
  PictureGraphEditor.swift
  ColourGrade.swift
  StillImage.swift
)
list(TRANSFORM veyra_mac_sources PREPEND "${CMAKE_CURRENT_SOURCE_DIR}/")
set(veyra_bundle "${CMAKE_CURRENT_BINARY_DIR}/Veyra.app")
set(veyra_binary "${veyra_bundle}/Contents/MacOS/Veyra")

set(VEYRA_MACOS_FFMPEG "" CACHE FILEPATH "Optional FFmpeg executable to bundle for MKV")
set(veyra_config "${CMAKE_CURRENT_BINARY_DIR}/veyra-macos-config.txt")
file(GENERATE OUTPUT "${veyra_config}" CONTENT
  "ffmpeg=${VEYRA_MACOS_FFMPEG}\nmoonlight=${VEYRA_MACOS_MOONLIGHT_SOURCE}\nchiaki=${VEYRA_MACOS_CHIAKI_SOURCE}\nxbox=${VEYRA_MACOS_DATACHANNEL_SOURCE}\nlinks=${veyra_xbox_link_files};${veyra_ps5_link_files};${veyra_pc_link_files}\n")
set(veyra_ffmpeg_commands "")
if(VEYRA_MACOS_FFMPEG)
  if(NOT EXISTS "${VEYRA_MACOS_FFMPEG}")
    message(FATAL_ERROR "VEYRA_MACOS_FFMPEG must point to a built executable")
  endif()
  list(APPEND veyra_ffmpeg_commands
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${veyra_bundle}/Contents/Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy "${VEYRA_MACOS_FFMPEG}" "${veyra_bundle}/Contents/Resources/ffmpeg"
    COMMAND /usr/bin/codesign --force --sign - "${veyra_bundle}/Contents/Resources/ffmpeg")
else()
  list(APPEND veyra_ffmpeg_commands
    COMMAND "${CMAKE_COMMAND}" -E rm -f "${veyra_bundle}/Contents/Resources/ffmpeg")
endif()

add_custom_command(
  OUTPUT "${veyra_binary}" "${veyra_bundle}/Contents/Info.plist"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${veyra_bundle}/Contents/MacOS"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist" "${veyra_bundle}/Contents/Info.plist"
  COMMAND "${VEYRA_XCRUN}" clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2
    -c "${CMAKE_CURRENT_SOURCE_DIR}/Interpolation.m" -o "${CMAKE_CURRENT_BINARY_DIR}/Interpolation.o"
  COMMAND "${VEYRA_XCRUN}" clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2
    -c "${CMAKE_CURRENT_SOURCE_DIR}/OBSOutput.m" -o "${CMAKE_CURRENT_BINARY_DIR}/OBSOutput.o"
  COMMAND "${VEYRA_XCRUN}" clang++ -std=c++20 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2
    ${veyra_pc_compile_options} -c "${CMAKE_CURRENT_SOURCE_DIR}/GameStream.mm" -o "${CMAKE_CURRENT_BINARY_DIR}/GameStream.o"
  COMMAND "${VEYRA_XCRUN}" clang++ -std=c++20 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2
    ${veyra_ps5_compile_options} -c "${CMAKE_CURRENT_SOURCE_DIR}/PS5Stream.mm" -o "${CMAKE_CURRENT_BINARY_DIR}/PS5Stream.o"
  COMMAND "${VEYRA_XCRUN}" clang++ -std=c++20 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2
    ${veyra_xbox_compile_options} -c "${CMAKE_CURRENT_SOURCE_DIR}/XboxStream.mm" -o "${CMAKE_CURRENT_BINARY_DIR}/XboxStream.o"
  COMMAND "${VEYRA_XCRUN}" clang++ -std=c++20 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2
    ${veyra_xbox_compile_options} -c "${CMAKE_CURRENT_SOURCE_DIR}/XboxPlatform.mm" -o "${CMAKE_CURRENT_BINARY_DIR}/XboxPlatform.o"
  COMMAND "${VEYRA_XCRUN}" clang++ -std=c++20 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -O2
    -c "${CMAKE_CURRENT_SOURCE_DIR}/ProtocolLog.mm" -o "${CMAKE_CURRENT_BINARY_DIR}/ProtocolLog.o"
  COMMAND "${VEYRA_XCRUN}" swiftc -target arm64-apple-macos26.0 -swift-version 5 -O
    -framework AppKit -framework AVFoundation -framework CoreImage -framework Metal
    -lc++ -lz -framework CoreServices -framework SystemConfiguration -framework GameController -framework LocalAuthentication -framework Security -framework Speech -framework Translation -framework ScreenCaptureKit -framework MetalFX -framework VideoToolbox -framework UniformTypeIdentifiers
    -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/Interpolation.h"
    ${veyra_mac_sources} "${CMAKE_CURRENT_BINARY_DIR}/Interpolation.o"
      "${CMAKE_CURRENT_BINARY_DIR}/OBSOutput.o" "${CMAKE_CURRENT_BINARY_DIR}/GameStream.o"
      "${CMAKE_CURRENT_BINARY_DIR}/PS5Stream.o" "${CMAKE_CURRENT_BINARY_DIR}/XboxStream.o" "${CMAKE_CURRENT_BINARY_DIR}/XboxPlatform.o"
      "${CMAKE_CURRENT_BINARY_DIR}/ProtocolLog.o"
      ${veyra_xbox_link_files} ${veyra_ps5_link_files} ${veyra_pc_link_files} -o "${veyra_binary}"
  ${veyra_ffmpeg_commands}
  COMMAND /usr/bin/codesign --force --sign - "${veyra_bundle}"
  DEPENDS "${veyra_config}" ${veyra_mac_sources} ${VEYRA_MACOS_FFMPEG} Interpolation.h Interpolation.m OBSOutput.m
    GameStream.mm GameStream.h PS5Stream.mm PS5Stream.h RemoteAVC.h ${veyra_pc_dependencies} ${veyra_pc_link_files}
    ${veyra_ps5_dependencies} ${veyra_ps5_link_files} XboxStream.mm XboxPlatform.mm XboxStream.h
    ${veyra_xbox_dependencies} ${veyra_xbox_link_files} ProtocolLog.mm ../include/veyra/ProtocolLog.h
    ../include/veyra/obs/FrameBus.h Info.plist
  VERBATIM
)
add_custom_target(veyra_macos ALL DEPENDS "${veyra_binary}" "${veyra_bundle}/Contents/Info.plist")
