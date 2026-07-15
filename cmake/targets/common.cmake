# common target definitions
# this file will also load platform specific macros

add_executable(lumen ${LUMEN_TARGET_FILES})
foreach(dep ${LUMEN_TARGET_DEPENDENCIES})
    add_dependencies(lumen ${dep})  # compile these before Lumen
endforeach()

# platform specific target definitions
if(WIN32)
    include(${CMAKE_MODULE_PATH}/targets/windows.cmake)
endif()

target_link_libraries(lumen ${LUMEN_EXTERNAL_LIBRARIES} ${EXTRA_LIBS})
target_compile_definitions(lumen PUBLIC ${LUMEN_DEFINITIONS})
set_target_properties(lumen PROPERTIES
        CXX_STANDARD 23
        OUTPUT_NAME "${CMAKE_PROJECT_NAME}")

set_target_properties(lumen PROPERTIES
        VERSION ${PROJECT_VERSION}
        SOVERSION ${PROJECT_VERSION_MAJOR})

target_compile_options(lumen PRIVATE ${LUMEN_COMPILE_OPTIONS})

if(WIN32)
    add_subdirectory(tools)
endif()

# third-party/ViGEmClient
set(VIGEM_COMPILE_FLAGS "")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unknown-pragmas ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-misleading-indentation ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-class-memaccess ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unused-function ")
string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unused-variable ")
set_source_files_properties("${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/src/ViGEmClient.cpp"
        DIRECTORY "${CMAKE_SOURCE_DIR}"
        PROPERTIES
        COMPILE_DEFINITIONS "UNICODE=1;ERROR_INVALID_DEVICE_OBJECT_PARAMETER=650"
        COMPILE_FLAGS ${VIGEM_COMPILE_FLAGS})

if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_definitions(-DNDEBUG)
endif()
