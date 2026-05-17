# common target definitions
# this file will also load platform specific macros

add_executable(lumen ${SUNSHINE_TARGET_FILES})
foreach(dep ${SUNSHINE_TARGET_DEPENDENCIES})
    add_dependencies(lumen ${dep})  # compile these before Lumen
endforeach()

target_include_directories(lumen SYSTEM BEFORE PRIVATE ${FFMPEG_INCLUDE_DIRS})

# platform specific target definitions
if(WIN32)
    include(${CMAKE_MODULE_PATH}/targets/windows.cmake)
elseif(APPLE)
    include(${CMAKE_MODULE_PATH}/targets/unix.cmake)
    include(${CMAKE_MODULE_PATH}/targets/macos.cmake)
endif()

# todo - is this necessary? ... for anything except linux?
if(NOT DEFINED CMAKE_CUDA_STANDARD)
    set(CMAKE_CUDA_STANDARD 17)
    set(CMAKE_CUDA_STANDARD_REQUIRED ON)
endif()

target_link_libraries(lumen ${SUNSHINE_EXTERNAL_LIBRARIES} ${EXTRA_LIBS})
target_compile_definitions(lumen PUBLIC ${SUNSHINE_DEFINITIONS})
set_target_properties(lumen PROPERTIES
        CXX_STANDARD 23
        OUTPUT_NAME "${CMAKE_PROJECT_NAME}")

if(NOT APPLE)
    set_target_properties(lumen PROPERTIES
            VERSION ${PROJECT_VERSION}
            SOVERSION ${PROJECT_VERSION_MAJOR})
endif()

if(APPLE AND SUNSHINE_PACKAGE_MACOS)
    set_source_files_properties("${PROJECT_SOURCE_DIR}/lumen.icns"
            PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
    target_sources(lumen PRIVATE "${PROJECT_SOURCE_DIR}/lumen.icns")

    set_target_properties(lumen PROPERTIES
            MACOSX_BUNDLE TRUE
            MACOSX_BUNDLE_INFO_PLIST "${APPLE_PLIST_FILE}"
            MACOSX_BUNDLE_ICON_FILE "lumen.icns"
            MACOSX_BUNDLE_BUNDLE_NAME "${CMAKE_PROJECT_NAME}"
            MACOSX_BUNDLE_GUI_IDENTIFIER "dev.skyline23.lumen")

    add_custom_command(TARGET lumen POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_BUNDLE_CONTENT_DIR:lumen>/Resources/assets"
            COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_BINARY_DIR}/assets" "$<TARGET_BUNDLE_CONTENT_DIR:lumen>/Resources/assets"
            VERBATIM)
endif()

# CLion complains about unknown flags after running cmake, and cannot add symbols to the index for cuda files
if(CUDA_INHERIT_COMPILE_OPTIONS)
    foreach(flag IN LISTS SUNSHINE_COMPILE_OPTIONS)
        list(APPEND SUNSHINE_COMPILE_OPTIONS_CUDA "$<$<COMPILE_LANGUAGE:CUDA>:--compiler-options=${flag}>")
    endforeach()
endif()

target_compile_options(lumen PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${SUNSHINE_COMPILE_OPTIONS}>;$<$<COMPILE_LANGUAGE:CUDA>:${SUNSHINE_COMPILE_OPTIONS_CUDA};-std=c++17>)  # cmake-lint: disable=C0301

set(NPM_SOURCE_ASSETS_DIR ${SUNSHINE_SOURCE_ASSETS_DIR})
set(NPM_ASSETS_DIR ${CMAKE_BINARY_DIR})

#WebUI build
find_program(NPM npm REQUIRED)

if (NPM_OFFLINE)
    set(NPM_INSTALL_FLAGS "--offline")
else()
    set(NPM_INSTALL_FLAGS "")
endif()

add_custom_target(web-ui ALL
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Installing NPM Dependencies and Building the Web UI"
        COMMAND "$<$<BOOL:${WIN32}>:cmd;/C>" "${NPM}" install ${NPM_INSTALL_FLAGS}
        COMMAND "${CMAKE_COMMAND}" -E env "LUMEN_SOURCE_ASSETS_DIR=${NPM_SOURCE_ASSETS_DIR}" "LUMEN_ASSETS_DIR=${NPM_ASSETS_DIR}" "$<$<BOOL:${WIN32}>:cmd;/C>" "${NPM}" run build  # cmake-lint: disable=C0301
        COMMAND_EXPAND_LISTS
        VERBATIM)

# tests
if(BUILD_TESTS)
    add_subdirectory(tests)
endif()

# custom compile flags, must be after adding tests

if (NOT BUILD_TESTS)
    set(TEST_DIR "")
else()
    set(TEST_DIR "${CMAKE_SOURCE_DIR}/tests")
endif()

# src/upnp
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/upnp.cpp"
        DIRECTORY "${CMAKE_SOURCE_DIR}" "${TEST_DIR}"
        PROPERTIES COMPILE_FLAGS -Wno-pedantic)

# third-party/nanors
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/rswrapper.c"
        DIRECTORY "${CMAKE_SOURCE_DIR}" "${TEST_DIR}"
        PROPERTIES COMPILE_FLAGS "-ftree-vectorize -funroll-loops")

# third-party/ViGEmClient
set(VIGEM_COMPILE_FLAGS "")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unknown-pragmas ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-misleading-indentation ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-class-memaccess ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unused-function ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unused-variable ")
set_source_files_properties("${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/src/ViGEmClient.cpp"
        DIRECTORY "${CMAKE_SOURCE_DIR}" "${TEST_DIR}"
        PROPERTIES
        COMPILE_DEFINITIONS "UNICODE=1;ERROR_INVALID_DEVICE_OBJECT_PARAMETER=650"
        COMPILE_FLAGS ${VIGEM_COMPILE_FLAGS})

# src/shadow_http
string(TOUPPER "x${CMAKE_BUILD_TYPE}" BUILD_TYPE)
if("${BUILD_TYPE}" STREQUAL "XDEBUG")
    if(WIN32)
        if (NOT BUILD_TESTS)
            set_source_files_properties("${CMAKE_SOURCE_DIR}/src/shadow_http.cpp"
                    DIRECTORY "${CMAKE_SOURCE_DIR}"
                    PROPERTIES COMPILE_FLAGS -O2)
        else()
            set_source_files_properties("${CMAKE_SOURCE_DIR}/src/shadow_http.cpp"
                    DIRECTORY "${CMAKE_SOURCE_DIR}" "${CMAKE_SOURCE_DIR}/tests"
                    PROPERTIES COMPILE_FLAGS -O2)
        endif()
    endif()
else()
    add_definitions(-DNDEBUG)
endif()
