cmake_minimum_required(VERSION 3.20)
# `set_source_files_properties` requires 3.18
# `cmake_path(CONVERT ... TO_NATIVE_PATH_LIST ...)` requires 3.20
# todo - set this conditionally

project(Lumen VERSION 0.0.0
        DESCRIPTION "Self-hosted desktop streaming host"
        HOMEPAGE_URL "https://github.com/Skyline-23/Lumen")

if(NOT WIN32)
    message(FATAL_ERROR "The legacy C++ host is Windows-only. Build the Rust and Swift host on macOS through Tuist.")
endif()

set(PROJECT_LICENSE "MIT")

set(PROJECT_FQDN "dev.skyline23.lumen")

set(PROJECT_BRIEF_DESCRIPTION "Desktop streaming host")  # must be <= 35 characters

set(PROJECT_LONG_DESCRIPTION "Offering low latency desktop streaming with support for AMD, Intel, \
and Nvidia GPUs for hardware encoding. Software encoding is also available. Native host applications manage \
configuration, enrolled clients, and streaming behavior on each supported platform.")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    message(STATUS "Setting build type to 'Release' as none was specified.")
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Choose the type of build." FORCE)
endif()

# set the module path, used for includes
set(CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

# export compile_commands.json
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# set version info for this build
include(${CMAKE_MODULE_PATH}/prep/build_version.cmake)

# cmake build flags
include(${CMAKE_MODULE_PATH}/prep/options.cmake)

# initial prep
include(${CMAKE_MODULE_PATH}/prep/init.cmake)

# Exit early if END_BUILD is ON, i.e. when only generating package manifests
if(${END_BUILD})
    return()
endif()

# project constants
include(${CMAKE_MODULE_PATH}/prep/constants.cmake)

# load dependencies
include(${CMAKE_MODULE_PATH}/dependencies/common.cmake)

# setup compile definitions
include(${CMAKE_MODULE_PATH}/compile_definitions/common.cmake)

# target definitions
include(${CMAKE_MODULE_PATH}/targets/common.cmake)

# packaging
include(${CMAKE_MODULE_PATH}/packaging/common.cmake)
