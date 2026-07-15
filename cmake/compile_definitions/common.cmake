# common compile definitions
# this file will also load platform specific definitions

list(APPEND LUMEN_COMPILE_OPTIONS -Wall -Wno-sign-compare)
# Wall - enable all warnings
# Werror - treat warnings as errors
# Wno-maybe-uninitialized/Wno-uninitialized - disable warnings for maybe uninitialized variables
# Wno-sign-compare - disable warnings for signed/unsigned comparisons
# Wno-restrict - disable warnings for memory overlap
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    # GCC specific compile options

    # GCC 12 and higher will complain about maybe-uninitialized
    if(CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 12)
        list(APPEND LUMEN_COMPILE_OPTIONS -Wno-maybe-uninitialized)

        # Disable the bogus warning that may prevent compilation (only for GCC 12).
        # See https://gcc.gnu.org/bugzilla/show_bug.cgi?id=105651.
        if(CMAKE_CXX_COMPILER_VERSION VERSION_LESS 13)
            list(APPEND LUMEN_COMPILE_OPTIONS -Wno-restrict)
        endif()
    endif()
endif()
if(BUILD_WERROR)
    list(APPEND LUMEN_COMPILE_OPTIONS -Werror)
endif()

# setup assets directory
if(NOT LUMEN_ASSETS_DIR)
    set(LUMEN_ASSETS_DIR "assets")
endif()

# platform specific compile definitions
if(WIN32)
    include(${CMAKE_MODULE_PATH}/compile_definitions/windows.cmake)
endif()

set(LUMEN_ENTRY_FILES
        "${CMAKE_SOURCE_DIR}/src/platform/windows/rust_host_main.cpp")

set(LUMEN_TARGET_FILES
        ${LUMEN_ENTRY_FILES}
        ${PLATFORM_TARGET_FILES})

if(NOT LUMEN_ASSETS_DIR_DEF)
    set(LUMEN_ASSETS_DIR_DEF "${LUMEN_ASSETS_DIR}")
endif()
list(APPEND LUMEN_DEFINITIONS LUMEN_ASSETS_DIR="${LUMEN_ASSETS_DIR_DEF}")

# Publisher metadata
list(APPEND LUMEN_DEFINITIONS LUMEN_PUBLISHER_NAME="${LUMEN_PUBLISHER_NAME}")
list(APPEND LUMEN_DEFINITIONS LUMEN_PUBLISHER_WEBSITE="${LUMEN_PUBLISHER_WEBSITE}")
list(APPEND LUMEN_DEFINITIONS LUMEN_PUBLISHER_ISSUE_URL="${LUMEN_PUBLISHER_ISSUE_URL}")

include_directories(BEFORE "${CMAKE_SOURCE_DIR}")

list(APPEND LUMEN_EXTERNAL_LIBRARIES
        ${CMAKE_THREAD_LIBS_INIT}
        ${OPUS_LIBRARIES}
        ${PLATFORM_LIBRARIES})
