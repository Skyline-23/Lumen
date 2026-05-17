# unix specific compile definitions
# put anything here that applies to both linux and macos

list(APPEND LUMEN_EXTERNAL_LIBRARIES
        ${CURL_LIBRARIES})

if(APPLE AND LUMEN_PACKAGE_MACOS)
    return()
endif()

# add install prefix to assets path if not already there
if(NOT LUMEN_ASSETS_DIR MATCHES "^${CMAKE_INSTALL_PREFIX}")
    set(LUMEN_ASSETS_DIR "${CMAKE_INSTALL_PREFIX}/${LUMEN_ASSETS_DIR}")
endif()
