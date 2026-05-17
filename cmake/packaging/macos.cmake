# macos specific packaging

set(APPLE_CODESIGN_IDENTITY "" CACHE STRING "Signing identity to use for macOS app bundles. Empty means ad-hoc signing.")

# todo - bundle doesn't produce a valid .app use cpack -G DragNDrop
set(CPACK_BUNDLE_NAME "${CMAKE_PROJECT_NAME}")
set(CPACK_BUNDLE_PLIST "${APPLE_PLIST_FILE}")
set(CPACK_BUNDLE_ICON "${PROJECT_SOURCE_DIR}/lumen.icns")
# set(CPACK_BUNDLE_STARTUP_COMMAND "${INSTALL_RUNTIME_DIR}/sunshine")

if(SUNSHINE_PACKAGE_MACOS)  # todo
    set(MAC_PREFIX "${CMAKE_PROJECT_NAME}.app/Contents")
    set(INSTALL_RUNTIME_DIR "${MAC_PREFIX}/MacOS")

    install(TARGETS lumen
            BUNDLE DESTINATION . COMPONENT Runtime
            RUNTIME DESTINATION ${INSTALL_RUNTIME_DIR} COMPONENT Runtime)
else()
    install(FILES "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/misc/uninstall_pkg.sh"
            DESTINATION "${SUNSHINE_PACKAGE_ASSETS_DIR}")
endif()

install(DIRECTORY "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/"
        DESTINATION "${SUNSHINE_PACKAGE_ASSETS_DIR}"
        PATTERN "Info.plist" EXCLUDE)
# copy assets to build directory, for running without install
file(COPY "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/"
        DESTINATION "${CMAKE_BINARY_DIR}/assets")

if(SUNSHINE_PACKAGE_MACOS)
    install(CODE "
        include(BundleUtilities)
        set(BU_CHMOD_BUNDLE_ITEMS ON)
        set(_bundle_path \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${CMAKE_PROJECT_NAME}.app\")
        if(NOT IS_ABSOLUTE \"\${_bundle_path}\")
            get_filename_component(_bundle_path \"\${_bundle_path}\" ABSOLUTE BASE_DIR \"${CMAKE_BINARY_DIR}\")
        endif()
        set(_bundle_macos_dir \"\${_bundle_path}/Contents/MacOS\")
        file(GLOB _versioned_executables \"\${_bundle_macos_dir}/${CMAKE_PROJECT_NAME}-*\")
        foreach(_versioned_executable IN LISTS _versioned_executables)
            if(EXISTS \"\${_versioned_executable}\")
                file(REMOVE \"\${_bundle_macos_dir}/${CMAKE_PROJECT_NAME}\")
                execute_process(COMMAND \"${CMAKE_COMMAND}\" -E copy \"\${_versioned_executable}\" \"\${_bundle_macos_dir}/${CMAKE_PROJECT_NAME}\")
                file(REMOVE \"\${_versioned_executable}\")
            endif()
        endforeach()
        if(EXISTS \"\${_bundle_macos_dir}/${CMAKE_PROJECT_NAME}.app\")
            file(REMOVE_RECURSE \"\${_bundle_macos_dir}/${CMAKE_PROJECT_NAME}.app\")
        endif()
        fixup_bundle(\"\${_bundle_path}\" \"\" \"\")
        set(_codesign_identity \"${APPLE_CODESIGN_IDENTITY}\")
        if(_codesign_identity STREQUAL \"\")
            set(_codesign_identity \"-\")
        endif()
        execute_process(
            COMMAND /usr/bin/codesign --force --deep --sign \"\${_codesign_identity}\" \"\${_bundle_path}\"
            RESULT_VARIABLE _codesign_result
        )
        if(NOT _codesign_result EQUAL 0)
            message(FATAL_ERROR \"codesign failed for \${_bundle_path}\")
        endif()
    " COMPONENT Runtime)
endif()
