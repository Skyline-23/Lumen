# Common dependencies for the Rust-owned native host.

find_package(Threads REQUIRED)

# Rust-owned owner/device/auth authority shared by every supported native host.
include("${CMAKE_MODULE_PATH}/dependencies/lumen_engine.cmake")

# The Rust Windows audio adapter calls the stable libopus C ABI directly.
set(LUMEN_ORIGINAL_LIBRARY_SUFFIXES "${CMAKE_FIND_LIBRARY_SUFFIXES}")
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
find_library(LUMEN_OPUS_STATIC_LIBRARY opus REQUIRED)
set(CMAKE_FIND_LIBRARY_SUFFIXES "${LUMEN_ORIGINAL_LIBRARY_SUFFIXES}")
set(OPUS_LIBRARIES "${LUMEN_OPUS_STATIC_LIBRARY}")
