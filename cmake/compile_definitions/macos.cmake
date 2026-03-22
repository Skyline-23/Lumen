# macos specific compile definitions

add_compile_definitions(SUNSHINE_PLATFORM="macos")

if(SUNSHINE_PACKAGE_MACOS)
    set(SUNSHINE_ASSETS_DIR "../Resources/assets")
endif()

set(MACOS_LINK_DIRECTORIES
        /opt/homebrew/lib
        /opt/local/lib
        /usr/local/lib)

foreach(dir ${MACOS_LINK_DIRECTORIES})
    if(EXISTS ${dir})
        link_directories(${dir})
    endif()
endforeach()

if(NOT BOOST_USE_STATIC AND NOT FETCH_CONTENT_BOOST_USED)
    ADD_DEFINITIONS(-DBOOST_LOG_DYN_LINK)
endif()

list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
        ${APP_KIT_LIBRARY}
        ${APP_SERVICES_LIBRARY}
        ${AV_FOUNDATION_LIBRARY}
        ${CORE_MEDIA_LIBRARY}
        ${CORE_VIDEO_LIBRARY}
        ${FOUNDATION_LIBRARY}
        ${METAL_LIBRARY}
        ${VIDEO_TOOLBOX_LIBRARY})

if(SCREEN_CAPTURE_KIT_LIBRARY)
    list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
            ${SCREEN_CAPTURE_KIT_LIBRARY})
endif()

set(APPLE_PLIST_FILE "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/Info.plist")

set(PLATFORM_TARGET_FILES
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloCore/Sources/ApolloCore.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/audio_stub.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/display_stub.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/input.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/misc.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/nv12_zero_device.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/publish.cpp"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/virtual_display.mm"
        "${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Sources/vt_metal_context.mm"
        "${CMAKE_SOURCE_DIR}/third-party/TPCircularBuffer/TPCircularBuffer.c"
        ${APPLE_PLIST_FILE})

include_directories("${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloMacSupport/Headers")
include_directories("${CMAKE_SOURCE_DIR}/src/platform/macos/Projects/ApolloCore/Headers")

if(SUNSHINE_ENABLE_TRAY)
    list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
            ${COCOA})
    list(APPEND PLATFORM_TARGET_FILES
            "${CMAKE_SOURCE_DIR}/third-party/tray/src/tray_darwin.m")
endif()
