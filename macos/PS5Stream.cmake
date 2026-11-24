# SPDX-License-Identifier: GPL-3.0-only
set(VEYRA_MACOS_CHIAKI_SOURCE "" CACHE PATH "Chiaki sources staged with the Veyra patches")
set(VEYRA_MACOS_CHIAKI_BUILD "" CACHE PATH "Chiaki native build containing generated headers")
set(VEYRA_MACOS_CHIAKI_LIBRARIES "" CACHE STRING "Semicolon-separated static libraries for Chiaki, in link order")
set(veyra_ps5_compile_options "")
set(veyra_ps5_link_files "")
set(veyra_ps5_dependencies "")
if(VEYRA_MACOS_CHIAKI_SOURCE)
  if(NOT EXISTS "${VEYRA_MACOS_CHIAKI_SOURCE}/lib/include/chiaki/session.h" OR
     NOT EXISTS "${VEYRA_MACOS_CHIAKI_BUILD}/lib/include/chiaki/config.h" OR
     NOT VEYRA_MACOS_CHIAKI_LIBRARIES)
    message(FATAL_ERROR "PS5 requires the staged Chiaki source, generated headers, and native libraries")
  endif()
  set(veyra_root "${CMAKE_CURRENT_SOURCE_DIR}/..")
  set(veyra_ps5_compile_options -DVEYRA_MACOS_PS5=1 -I "${veyra_root}/include")
  add_library(veyra_macos_ps5_protocol STATIC
    "${veyra_root}/src/remoteplay/Validation.cpp"
    "${veyra_root}/src/remoteplay/AnnexB.cpp"
    "${veyra_root}/src/remoteplay/Timeline.cpp"
    "${veyra_root}/src/remoteplay/VideoIngress.cpp"
    "${veyra_root}/src/remoteplay/SessionInbox.cpp"
    "${veyra_root}/src/remoteplay/ChiakiBackend.cpp"
    "${veyra_root}/src/remoteplay/ChiakiRegistration.cpp")
  target_include_directories(veyra_macos_ps5_protocol PRIVATE "${veyra_root}/include"
    "${VEYRA_MACOS_CHIAKI_SOURCE}/lib/include" "${VEYRA_MACOS_CHIAKI_BUILD}/lib/include")
  target_compile_features(veyra_macos_ps5_protocol PRIVATE cxx_std_20)
  set(veyra_ps5_link_files "$<TARGET_FILE:veyra_macos_ps5_protocol>" ${VEYRA_MACOS_CHIAKI_LIBRARIES})
  set(veyra_ps5_dependencies veyra_macos_ps5_protocol)
endif()
