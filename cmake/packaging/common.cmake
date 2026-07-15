# common packaging

# common cpack options
set(CPACK_PACKAGE_NAME ${CMAKE_PROJECT_NAME})
set(CPACK_PACKAGE_VENDOR "SudoMaker")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${PROJECT_VERSION_PATCH})
set(CPACK_PACKAGE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/cpack_artifacts)
set(CPACK_PACKAGE_CONTACT "https://www.sudomaker.com")
set(CPACK_PACKAGE_DESCRIPTION ${CMAKE_PROJECT_DESCRIPTION})
set(CPACK_PACKAGE_HOMEPAGE_URL ${CMAKE_PROJECT_HOMEPAGE_URL})
set(CPACK_RESOURCE_FILE_LICENSE ${PROJECT_SOURCE_DIR}/LICENSE)
set(CPACK_PACKAGE_ICON ${PROJECT_SOURCE_DIR}/lumen.png)
set(CPACK_PACKAGE_FILE_NAME "${CMAKE_PROJECT_NAME}")
set(CPACK_STRIP_FILES YES)

set(LUMEN_PACKAGE_ASSETS_DIR "${LUMEN_ASSETS_DIR}")

# install common assets
install(DIRECTORY "${LUMEN_SOURCE_ASSETS_DIR}/common/assets/"
        DESTINATION "${LUMEN_PACKAGE_ASSETS_DIR}")
install(FILES "${CMAKE_SOURCE_DIR}/icon.svg"
        DESTINATION "${LUMEN_PACKAGE_ASSETS_DIR}/icons")
install(FILES
        "${CMAKE_SOURCE_DIR}/LICENSE"
        "${CMAKE_SOURCE_DIR}/NOTICE"
        DESTINATION "."
        COMPONENT application)
install(FILES
        "${CMAKE_SOURCE_DIR}/third-party/licenses/Opus-BSD-3-Clause.txt"
        "${CMAKE_SOURCE_DIR}/third-party/licenses/Rust-Crates.html"
        "${CMAKE_SOURCE_DIR}/third-party/licenses/Slint-Royalty-Free-2.0.txt"
        DESTINATION "licenses"
        COMPONENT application)
install(FILES
        "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/LICENSE"
        DESTINATION "licenses"
        RENAME "ViGEmClient-MIT.txt"
        COMPONENT application)
# copy assets to build directory, for running without install
file(GLOB_RECURSE ALL_ASSETS
        RELATIVE "${LUMEN_SOURCE_ASSETS_DIR}/common/assets/" "${LUMEN_SOURCE_ASSETS_DIR}/common/assets/*")
foreach(asset ${ALL_ASSETS})
    file(COPY "${LUMEN_SOURCE_ASSETS_DIR}/common/assets/${asset}"
            DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/assets")
endforeach()
file(COPY "${CMAKE_SOURCE_DIR}/icon.svg"
        DESTINATION "${CMAKE_CURRENT_BINARY_DIR}/assets/icons")

# platform specific packaging
if(WIN32)
    include(${CMAKE_MODULE_PATH}/packaging/windows.cmake)
endif()

include(CPack)
