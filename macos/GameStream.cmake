# SPDX-License-Identifier: GPL-3.0-only
set(VEYRA_MACOS_MOONLIGHT_SOURCE "" CACHE PATH "Moonlight common C source with pinned submodules")
set(veyra_pc_compile_options "")
set(veyra_pc_link_files "")
set(veyra_pc_dependencies "")
if(VEYRA_MACOS_MOONLIGHT_SOURCE)
  set(OPENSSL_USE_STATIC_LIBS ON)
  find_package(OpenSSL REQUIRED)
  find_package(Opus CONFIG REQUIRED)
  set(BUILD_SHARED_LIBS OFF)
  add_subdirectory("${VEYRA_MACOS_MOONLIGHT_SOURCE}" "${CMAKE_CURRENT_BINARY_DIR}/moonlight" EXCLUDE_FROM_ALL)
  target_compile_options(moonlight-common-c PRIVATE -Wno-error)
  set(veyra_pc_compile_options -DVEYRA_MACOS_MOONLIGHT=1
    -I "${CMAKE_CURRENT_SOURCE_DIR}/../include"
    -I "${VEYRA_MACOS_MOONLIGHT_SOURCE}/src"
    -I "${OPENSSL_INCLUDE_DIR}")
  get_target_property(veyra_opus_includes Opus::opus INTERFACE_INCLUDE_DIRECTORIES)
  foreach(include_dir IN LISTS veyra_opus_includes)
    list(APPEND veyra_pc_compile_options -I "${include_dir}")
  endforeach()
  set(veyra_pc_protocol
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/moonlight/Xml.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/moonlight/Crypto.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/moonlight/Http.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/moonlight/Client.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/moonlight/Pairing.cpp"
  )
  add_library(veyra_macos_moonlight_protocol STATIC ${veyra_pc_protocol})
  target_include_directories(veyra_macos_moonlight_protocol PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../include")
  target_compile_features(veyra_macos_moonlight_protocol PRIVATE cxx_std_20)
  target_link_libraries(veyra_macos_moonlight_protocol PRIVATE OpenSSL::SSL OpenSSL::Crypto)
  set(veyra_pc_link_files
    "$<TARGET_FILE:veyra_macos_moonlight_protocol>"
    "$<TARGET_FILE:moonlight-common-c>" "$<TARGET_FILE:enet>"
    "$<TARGET_FILE:Opus::opus>" "$<TARGET_FILE:OpenSSL::SSL>" "$<TARGET_FILE:OpenSSL::Crypto>")
  set(veyra_pc_dependencies veyra_macos_moonlight_protocol moonlight-common-c enet)
endif()
