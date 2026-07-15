cmake_minimum_required(VERSION 3.20)

project(lumen_tools)

include_directories(${CMAKE_SOURCE_DIR})

add_executable(lumen-service
        lumen_service.cpp
        "${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/src/ViGEmClient.cpp")
set_target_properties(lumen-service PROPERTIES
        CXX_STANDARD 23
        OUTPUT_NAME "LumenService")
target_link_libraries(lumen-service
        ${LUMEN_EXTERNAL_LIBRARIES}
        ${EXTRA_LIBS})
add_dependencies(lumen-service lumen_host_rust_build)
target_compile_options(lumen-service PRIVATE ${LUMEN_COMPILE_OPTIONS})
