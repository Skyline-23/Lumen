# Publisher Metadata
set(SUNSHINE_PUBLISHER_NAME "SudoMaker"
        CACHE STRING "The name of the publisher (or fork developer) of the application.")
set(SUNSHINE_PUBLISHER_WEBSITE "https://www.sudomaker.com"
        CACHE STRING "The URL of the publisher's website.")
set(SUNSHINE_PUBLISHER_ISSUE_URL "https://github.com/Skyline-23/Lumen/issues"
        CACHE STRING "The URL of the publisher's support site or issue tracker.
        If you provide a modified version of Sunshine, we kindly request that you use your own url.")

option(BUILD_TESTS "Build tests" OFF)
option(NPM_OFFLINE "Use offline npm packages. You must ensure packages are in your npm cache." OFF)

option(BUILD_WERROR "Enable -Werror flag." OFF)

# if this option is set, the build will exit after configuring special package configuration files
option(SUNSHINE_CONFIGURE_ONLY "Configure special files only, then exit." OFF)

option(SUNSHINE_ENABLE_TRAY "Enable system tray icon." ON)

if(APPLE)
    option(BOOST_USE_STATIC "Use static boost libraries." OFF)
else()
    option(BOOST_USE_STATIC "Use static boost libraries." ON)
endif()

option(CUDA_FAIL_ON_MISSING "Fail the build if CUDA is not found." ON)
option(CUDA_INHERIT_COMPILE_OPTIONS
        "When building CUDA code, inherit compile options from the the main project. You may want to disable this if
        your IDE throws errors about unknown flags after running cmake." ON)

if(APPLE)
    option(SUNSHINE_CONFIGURE_PORTFILE
            "Configure macOS Portfile. Recommended to use with SUNSHINE_CONFIGURE_ONLY" OFF)
    option(SUNSHINE_PACKAGE_MACOS
            "Should only be used when creating a macOS package/dmg." OFF)
endif()
