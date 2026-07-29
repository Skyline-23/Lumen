# windows specific target definitions
set_target_properties(lumen PROPERTIES
        LINK_SEARCH_START_STATIC 1)
list(APPEND LUMEN_EXTERNAL_LIBRARIES
        $<TARGET_OBJECTS:lumen_rc_object>
        Windowsapp.lib
        Wtsapi32.lib)

find_program(LUMEN_DOTNET_EXECUTABLE dotnet REQUIRED)
set(LUMEN_WINDOWS_UI_PROJECT
        "${CMAKE_SOURCE_DIR}/src/platform/windows/Lumen.App/Lumen.App.csproj")
set(LUMEN_WINDOWS_UI_PUBLISH_DIR
        "${CMAKE_BINARY_DIR}/windows-ui")

if(LUMEN_WINDOWS_DEVELOPER_BUILD)
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        set(LUMEN_WINDOWS_UI_CONFIGURATION "Debug")
    else()
        set(LUMEN_WINDOWS_UI_CONFIGURATION "Release")
    endif()
    # This target deliberately builds from the NuGet restore output instead of
    # publishing a self-contained application. The development entrypoint
    # restores once, then CMake and MSBuild both keep their normal incremental
    # state in the selected build directory and the project obj/bin directories.
    add_custom_target(lumen-windows-ui
            COMMAND "${LUMEN_DOTNET_EXECUTABLE}" build
                    "${LUMEN_WINDOWS_UI_PROJECT}"
                    --configuration "${LUMEN_WINDOWS_UI_CONFIGURATION}"
                    --runtime win-x64
                    --no-restore
                    --property:SelfContained=false
                    --property:WindowsAppSDKSelfContained=false
            COMMENT "Building the framework-dependent WinUI management app for development"
            VERBATIM)
else()
    add_custom_target(lumen-windows-ui ALL
            COMMAND "${CMAKE_COMMAND}" -E rm -rf "${LUMEN_WINDOWS_UI_PUBLISH_DIR}"
            COMMAND "${LUMEN_DOTNET_EXECUTABLE}" publish
                    "${LUMEN_WINDOWS_UI_PROJECT}"
                    --configuration Release
                    --runtime win-x64
                    --self-contained true
                    --output "${LUMEN_WINDOWS_UI_PUBLISH_DIR}"
                    --property:ContinuousIntegrationBuild=true
                    --property:Version=${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}
                    --property:InformationalVersion=${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}
                    --property:IncludeSourceRevisionInInformationalVersion=false
                    --property:AssemblyVersion=${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}.0
                    --property:FileVersion=${LUMEN_WINDOWS_FILE_VERSION}
            COMMAND "${CMAKE_COMMAND}"
                    -DLUMEN_WINDOWS_UI_PUBLISH_DIR=${LUMEN_WINDOWS_UI_PUBLISH_DIR}
                    -P "${CMAKE_SOURCE_DIR}/cmake/scripts/prune_windows_ui_locales.cmake"
            BYPRODUCTS "${LUMEN_WINDOWS_UI_PUBLISH_DIR}/Lumen.exe"
            COMMENT "Publishing the native C# WinUI management app"
            VERBATIM)
endif()
