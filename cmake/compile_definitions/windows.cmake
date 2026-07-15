# windows specific compile definitions

add_compile_definitions(LUMEN_PLATFORM="windows")

enable_language(RC)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -static")

# gcc complains about misleading indentation in some mingw includes
list(APPEND LUMEN_COMPILE_OPTIONS -Wno-misleading-indentation)

# vigem
include_directories(SYSTEM "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/include")

# lumen icon
if(NOT DEFINED PROJECT_ICON_PATH)
    set(PROJECT_ICON_PATH "${CMAKE_SOURCE_DIR}/lumen.ico")
endif()
configure_file("${PROJECT_ICON_PATH}" "${CMAKE_CURRENT_BINARY_DIR}/lumen.ico" COPYONLY)

# Create a separate object library for the RC file with minimal includes
add_library(lumen_rc_object OBJECT "${CMAKE_SOURCE_DIR}/src/platform/windows/windows.rc")

# Set minimal properties for RC compilation - only what's needed for the resource file
# Otherwise compilation can fail due to "line too long" errors
set_target_properties(lumen_rc_object PROPERTIES
    COMPILE_DEFINITIONS "PROJECT_NAME=${PROJECT_NAME};PROJECT_VENDOR=${LUMEN_PUBLISHER_NAME};PROJECT_VERSION=${PROJECT_VERSION};PROJECT_VERSION_MAJOR=${PROJECT_VERSION_MAJOR};PROJECT_VERSION_MINOR=${PROJECT_VERSION_MINOR};PROJECT_VERSION_PATCH=${PROJECT_VERSION_PATCH}"  # cmake-lint: disable=C0301
    INCLUDE_DIRECTORIES ""
)

set(PLATFORM_TARGET_FILES
        "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/src/ViGEmClient.cpp"
        "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/include/ViGEm/Client.h"
        "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/include/ViGEm/Common.h"
        "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/include/ViGEm/Util.h"
        "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/include/ViGEm/km/BusShared.h")

list(PREPEND PLATFORM_LIBRARIES
        avrt
        advapi32
        comctl32
        d3d11
        D3DCompiler
        d2d1
        dwrite
        dwmapi
        dxgi
        gdi32
        iphlpapi
        imm32
        ksuser
        libssp.a
        libstdc++.a
        libwinpthread.a
        msimg32
        ntdll
        ole32
        opengl32
        setupapi
        shell32
        shlwapi
        synchronization.lib
        userenv
        user32
        uxtheme
        windowscodecs
        winspool
        ws2_32
        wsock32
)
