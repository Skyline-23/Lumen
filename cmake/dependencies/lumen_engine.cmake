# Build the Rust host archive. The staticlib includes the source-neutral engine,
# so Windows links one Rust authority instead of composing duplicate archives.
find_program(LUMEN_CARGO_EXECUTABLE cargo REQUIRED)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "Lumen's Rust engine requires a 64-bit Windows host build.")
endif()
set(LUMEN_RUST_TARGET "x86_64-pc-windows-gnu")

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(LUMEN_RUST_PROFILE "debug")
    set(LUMEN_RUST_PROFILE_ARGUMENTS)
else()
    set(LUMEN_RUST_PROFILE "release")
    set(LUMEN_RUST_PROFILE_ARGUMENTS --release)
endif()

set(LUMEN_RUST_TARGET_DIR "${CMAKE_BINARY_DIR}/rust-target")
set(LUMEN_RUST_HOST_ARCHIVE
        "${LUMEN_RUST_TARGET_DIR}/${LUMEN_RUST_TARGET}/${LUMEN_RUST_PROFILE}/liblumen_host.a")
file(GLOB_RECURSE LUMEN_RUST_HOST_SOURCES CONFIGURE_DEPENDS
        "${CMAKE_SOURCE_DIR}/engine/lumen-engine/src/*.rs"
        "${CMAKE_SOURCE_DIR}/engine/lumen-host/src/*.rs"
        "${CMAKE_SOURCE_DIR}/engine/lumen-host/ui/*.slint")
list(APPEND LUMEN_RUST_HOST_SOURCES
        "${CMAKE_SOURCE_DIR}/engine/lumen-host/build.rs")

add_custom_command(
        OUTPUT "${LUMEN_RUST_HOST_ARCHIVE}"
        COMMAND "${CMAKE_COMMAND}" -E env
                "CARGO_TARGET_DIR=${LUMEN_RUST_TARGET_DIR}"
                "${LUMEN_CARGO_EXECUTABLE}" build --locked --package lumen-host --lib
                --target "${LUMEN_RUST_TARGET}" ${LUMEN_RUST_PROFILE_ARGUMENTS}
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        DEPENDS
                "${CMAKE_SOURCE_DIR}/Cargo.toml"
                "${CMAKE_SOURCE_DIR}/Cargo.lock"
                "${CMAKE_SOURCE_DIR}/engine/lumen-engine/Cargo.toml"
                "${CMAKE_SOURCE_DIR}/engine/lumen-host/Cargo.toml"
                ${LUMEN_RUST_HOST_SOURCES}
        COMMENT "Building the Lumen Rust host for ${LUMEN_RUST_TARGET}"
        VERBATIM)

add_custom_target(lumen_host_rust_build DEPENDS "${LUMEN_RUST_HOST_ARCHIVE}")
add_library(lumen_host_rust STATIC IMPORTED GLOBAL)
set_target_properties(lumen_host_rust PROPERTIES
        IMPORTED_LOCATION "${LUMEN_RUST_HOST_ARCHIVE}")
add_dependencies(lumen_host_rust lumen_host_rust_build)

list(APPEND LUMEN_TARGET_DEPENDENCIES lumen_host_rust_build)
list(APPEND LUMEN_EXTERNAL_LIBRARIES lumen_host_rust)
include_directories(BEFORE "${CMAKE_SOURCE_DIR}/engine/lumen-engine/include")
include_directories(BEFORE "${CMAKE_SOURCE_DIR}/engine/lumen-host/include")

# getrandom's Windows backend uses BCryptGenRandom.
list(APPEND EXTRA_LIBS bcrypt)
