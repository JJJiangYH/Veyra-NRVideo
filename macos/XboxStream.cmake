# SPDX-License-Identifier: GPL-3.0-only
set(VEYRA_MACOS_DATACHANNEL_SOURCE "" CACHE PATH "The libdatachannel source and dependencies")
set(VEYRA_MACOS_XBOX_LIBRARIES "" CACHE STRING "Semicolon-separated native Xbox libraries, including Opus")
set(VEYRA_MACOS_XBOX_OPUS_INCLUDE "" CACHE PATH "Opus include directory containing opus_multistream.h")
set(veyra_xbox_compile_options "")
set(veyra_xbox_link_files "")
set(veyra_xbox_dependencies "")
if(VEYRA_MACOS_DATACHANNEL_SOURCE)
  set(veyra_root "${CMAKE_CURRENT_SOURCE_DIR}/..")
  set(veyra_rtc "${VEYRA_MACOS_DATACHANNEL_SOURCE}/include")
  set(veyra_json "${VEYRA_MACOS_DATACHANNEL_SOURCE}/deps/json/include")
  if(NOT EXISTS "${veyra_rtc}/rtc/rtc.hpp" OR NOT EXISTS "${veyra_json}/nlohmann/json.hpp" OR
     NOT EXISTS "${VEYRA_MACOS_XBOX_OPUS_INCLUDE}/opus_multistream.h" OR NOT VEYRA_MACOS_XBOX_LIBRARIES)
    message(FATAL_ERROR "Xbox requires libdatachannel, nlohmann-json, Opus, and native archives")
  endif()
  set(veyra_xbox_compile_options -DVEYRA_MACOS_XBOX=1 -I "${veyra_root}/include"
    -I "${veyra_json}" -I "${VEYRA_MACOS_XBOX_OPUS_INCLUDE}")
  add_library(veyra_macos_xbox_protocol STATIC
    "${veyra_root}/src/xbox/Account.cpp"
    "${veyra_root}/src/xbox/Https.cpp"
    "${veyra_root}/src/xbox/StreamApi.cpp"
    "${veyra_root}/src/xbox/WebRtcSession.cpp")
  target_compile_definitions(veyra_macos_xbox_protocol PRIVATE RTC_STATIC RTC_ENABLE_MEDIA=1 RTC_ENABLE_WEBSOCKET=1)
  target_include_directories(veyra_macos_xbox_protocol PRIVATE "${veyra_root}/include" "${veyra_rtc}" "${veyra_json}")
  target_compile_features(veyra_macos_xbox_protocol PRIVATE cxx_std_20)
  set(veyra_xbox_link_files "$<TARGET_FILE:veyra_macos_xbox_protocol>" ${VEYRA_MACOS_XBOX_LIBRARIES})
  set(veyra_xbox_dependencies veyra_macos_xbox_protocol)
endif()
