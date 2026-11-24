# Veyra OBS filter module.
#
# OBS owns capture, decode, encode and composition; this module adds only the
# per-frame GPU enhancement chain, which is why it works on Linux without any
# of the Windows-only backends (NGX/DLSS, Media Foundation, WGC, WASAPI).

if(APPLE)
  set(VEYRA_OBS_SOURCE_DIR "" CACHE PATH "Source of the corresponding OBS release")
  if(VEYRA_OBS_SOURCE_DIR)
    find_path(VEYRA_OBS_SIMDE_INCLUDE_DIR NAMES simde/x86/sse2.h REQUIRED)
    if(NOT EXISTS "${VEYRA_OBS_SOURCE_DIR}/libobs/obs-module.h")
      message(FATAL_ERROR "VEYRA_OBS_SOURCE_DIR must point to the OBS source root")
    endif()
    # OBS modules resolve the exported host symbols when loaded by OBS.
    set(OBS_INSTALL_PREFIX "")
    set(OBS_DATA_PATH "data")
    set(OBS_PLUGIN_PATH "obs-plugins")
    set(OBS_RELATIVE_PREFIX "../")
    set(OBS_RELEASE_CANDIDATE 0)
    set(OBS_BETA 0)
    configure_file("${VEYRA_OBS_SOURCE_DIR}/libobs/obsconfig.h.in" "${CMAKE_CURRENT_BINARY_DIR}/obsconfig.h" @ONLY)
  else()
    find_package(libobs REQUIRED)
  endif()
else()
  find_package(libobs REQUIRED)
endif()

add_library(veyra_obs_plugin MODULE
  veyra-filter.c
)
set_target_properties(veyra_obs_plugin PROPERTIES
  PREFIX ""
  OUTPUT_NAME "veyra-filter"
)
target_compile_features(veyra_obs_plugin PRIVATE c_std_11)
if(APPLE AND VEYRA_OBS_SOURCE_DIR)
  target_include_directories(veyra_obs_plugin PRIVATE "${VEYRA_OBS_SOURCE_DIR}/libobs"
    "${CMAKE_CURRENT_BINARY_DIR}" "${VEYRA_OBS_SIMDE_INCLUDE_DIR}")
  target_link_options(veyra_obs_plugin PRIVATE "LINKER:-undefined,dynamic_lookup")
else()
  target_link_libraries(veyra_obs_plugin PRIVATE OBS::libobs)
endif()


if(APPLE)
  target_sources(veyra_obs_plugin PRIVATE veyra-source-macos.c)
  set_target_properties(veyra_obs_plugin PROPERTIES BUNDLE TRUE BUNDLE_EXTENSION plugin
    MACOSX_BUNDLE_GUI_IDENTIFIER io.veyra.obs-filter)
  add_custom_command(TARGET veyra_obs_plugin POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_DIR:veyra_obs_plugin>/Contents/Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/veyra.effect"
      "$<TARGET_BUNDLE_DIR:veyra_obs_plugin>/Contents/Resources/veyra.effect"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/locale"
      "$<TARGET_BUNDLE_DIR:veyra_obs_plugin>/Contents/Resources/locale"
    COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_DIR:veyra_obs_plugin>"
    VERBATIM)
  install(DIRECTORY "$<TARGET_BUNDLE_DIR:veyra_obs_plugin>" DESTINATION obs-plugins USE_SOURCE_PERMISSIONS)
else()
  install(TARGETS veyra_obs_plugin LIBRARY DESTINATION lib/obs-plugins)
  install(FILES veyra.effect DESTINATION share/obs/obs-plugins/veyra-filter)
  install(DIRECTORY locale/ DESTINATION share/obs/obs-plugins/veyra-filter/locale)
endif()

include(CTest)
if(BUILD_TESTING)
  add_executable(veyra_cube_tests ../../tests/obs-filter/cube-tests.c)
  target_link_libraries(veyra_cube_tests PRIVATE m)
  add_test(NAME obs_cube_parser COMMAND veyra_cube_tests "${CMAKE_CURRENT_BINARY_DIR}/test.cube")
  set_tests_properties(obs_cube_parser PROPERTIES TIMEOUT 30)
endif()
