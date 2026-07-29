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
