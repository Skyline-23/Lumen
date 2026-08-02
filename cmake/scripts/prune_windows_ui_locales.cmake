cmake_minimum_required(VERSION 3.20)

if(NOT DEFINED LUMEN_WINDOWS_UI_PUBLISH_DIR)
    message(FATAL_ERROR "LUMEN_WINDOWS_UI_PUBLISH_DIR is required")
endif()

set(LUMEN_WINDOWS_UI_LOCALES "en-us;ja-JP;ko-KR")
file(GLOB LUMEN_WINDOWS_UI_DIRECTORIES
        LIST_DIRECTORIES true
        "${LUMEN_WINDOWS_UI_PUBLISH_DIR}/*")
foreach(directory IN LISTS LUMEN_WINDOWS_UI_DIRECTORIES)
    if(NOT IS_DIRECTORY "${directory}")
        continue()
    endif()
    if(NOT EXISTS "${directory}/Microsoft.ui.xaml.dll.mui")
        continue()
    endif()
    get_filename_component(locale "${directory}" NAME)
    if(NOT locale IN_LIST LUMEN_WINDOWS_UI_LOCALES)
        file(REMOVE_RECURSE "${directory}")
    endif()
endforeach()
