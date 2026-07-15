cmake_minimum_required(VERSION 3.25)
project(LumenWindowsDriverBoundaryTests LANGUAGES CXX)

enable_testing()

add_executable(lumen_driver_abi_layout tests/abi_layout.cpp)
target_compile_features(lumen_driver_abi_layout PRIVATE cxx_std_20)
target_include_directories(lumen_driver_abi_layout PRIVATE include)
add_test(NAME lumen_driver_abi_layout COMMAND lumen_driver_abi_layout)

if(DEFINED LUMEN_DRIVER_CORE_LIBRARY)
  add_library(lumen_driver_core STATIC IMPORTED)
  set_target_properties(lumen_driver_core PROPERTIES
    IMPORTED_LOCATION "${LUMEN_DRIVER_CORE_LIBRARY}")

  add_executable(lumen_driver_core_harness tests/core_harness.cpp)
  target_compile_features(lumen_driver_core_harness PRIVATE cxx_std_20)
  target_include_directories(lumen_driver_core_harness PRIVATE include)
  target_link_libraries(lumen_driver_core_harness PRIVATE lumen_driver_core)
  if(WIN32)
    target_link_libraries(lumen_driver_core_harness PRIVATE
      advapi32 bcrypt ntdll userenv ws2_32)
  endif()
  add_test(NAME lumen_driver_core_harness COMMAND lumen_driver_core_harness)
endif()

if(WIN32)
  add_executable(lumen_driver_device_qa
    tests/windows_device_io.cpp
    tests/windows_device_probes.cpp
    tests/windows_device_stop_restart.cpp
    tests/windows_device_qa.cpp)
  target_compile_features(lumen_driver_device_qa PRIVATE cxx_std_20)
  target_include_directories(lumen_driver_device_qa PRIVATE include)
  target_link_libraries(lumen_driver_device_qa PRIVATE setupapi)
endif()
