# Windows Installer compares a versioned file's four-part FILEVERSION when it
# decides whether to replace that file during a same-ProductVersion upgrade.
# Keep this version independent from the user-facing semantic ProductVersion.

set(LUMEN_WINDOWS_FILE_VERSION_EPOCH 2)

function(lumen_validate_windows_version_part name value)
    if(NOT "${value}" MATCHES "^(0|[1-9][0-9]*)$")
        message(FATAL_ERROR
                "${name} must be an unsigned decimal integer without leading zeros; got '${value}'.")
    endif()

    string(LENGTH "${value}" value_length)
    if(value_length GREATER 5)
        message(FATAL_ERROR
                "${name} must fit in a 16-bit Windows version part (0..65535); got '${value}'.")
    endif()
    if(value GREATER 65535)
        message(FATAL_ERROR
                "${name} must fit in a 16-bit Windows version part (0..65535); got '${value}'.")
    endif()
endfunction()

foreach(version_part IN ITEMS
        PROJECT_VERSION_MAJOR
        PROJECT_VERSION_MINOR
        PROJECT_VERSION_PATCH)
    if(NOT DEFINED ${version_part})
        message(FATAL_ERROR "${version_part} is required to calculate the Windows FileVersion.")
    endif()
    lumen_validate_windows_version_part(${version_part} "${${version_part}}")
endforeach()

if(DEFINED LUMEN_WINDOWS_BUILD_NUMBER AND
   NOT "${LUMEN_WINDOWS_BUILD_NUMBER}" STREQUAL "")
    set(lumen_windows_build_number_source "LUMEN_WINDOWS_BUILD_NUMBER")
elseif(DEFINED ENV{GITHUB_RUN_NUMBER} AND
       NOT "$ENV{GITHUB_RUN_NUMBER}" STREQUAL "")
    set(LUMEN_WINDOWS_BUILD_NUMBER "$ENV{GITHUB_RUN_NUMBER}")
    set(lumen_windows_build_number_source "GITHUB_RUN_NUMBER")
else()
    find_package(Git QUIET)
    if(NOT GIT_EXECUTABLE)
        message(FATAL_ERROR
                "Git is required to calculate LUMEN_WINDOWS_BUILD_NUMBER outside GitHub Actions. "
                "Set LUMEN_WINDOWS_BUILD_NUMBER explicitly for a source-only build.")
    endif()

    execute_process(
            COMMAND "${GIT_EXECUTABLE}" -C "${CMAKE_SOURCE_DIR}"
                    rev-parse --is-shallow-repository
            RESULT_VARIABLE lumen_git_shallow_result
            OUTPUT_VARIABLE lumen_git_is_shallow
            ERROR_VARIABLE lumen_git_shallow_error
            OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT lumen_git_shallow_result EQUAL 0)
        message(FATAL_ERROR
                "Could not inspect the Git checkout for Windows FileVersion generation: "
                "${lumen_git_shallow_error}")
    endif()
    if(lumen_git_is_shallow STREQUAL "true")
        message(FATAL_ERROR
                "A shallow checkout cannot provide a stable Git commit count. "
                "Set LUMEN_WINDOWS_BUILD_NUMBER or GITHUB_RUN_NUMBER.")
    endif()

    execute_process(
            COMMAND "${GIT_EXECUTABLE}" -C "${CMAKE_SOURCE_DIR}"
                    rev-list --count HEAD
            RESULT_VARIABLE lumen_git_count_result
            OUTPUT_VARIABLE LUMEN_WINDOWS_BUILD_NUMBER
            ERROR_VARIABLE lumen_git_count_error
            OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT lumen_git_count_result EQUAL 0)
        message(FATAL_ERROR
                "Could not calculate the Git commit count for Windows FileVersion generation: "
                "${lumen_git_count_error}")
    endif()
    set(lumen_windows_build_number_source "Git commit count")
endif()

lumen_validate_windows_version_part(
        LUMEN_WINDOWS_BUILD_NUMBER
        "${LUMEN_WINDOWS_BUILD_NUMBER}")

math(EXPR LUMEN_WINDOWS_FILE_VERSION_MAJOR
        "${LUMEN_WINDOWS_FILE_VERSION_EPOCH} + ${PROJECT_VERSION_MAJOR}")
set(LUMEN_WINDOWS_FILE_VERSION_MINOR "${PROJECT_VERSION_MINOR}")
set(LUMEN_WINDOWS_FILE_VERSION_PATCH "${PROJECT_VERSION_PATCH}")
set(LUMEN_WINDOWS_FILE_VERSION_BUILD "${LUMEN_WINDOWS_BUILD_NUMBER}")

foreach(version_part IN ITEMS
        LUMEN_WINDOWS_FILE_VERSION_MAJOR
        LUMEN_WINDOWS_FILE_VERSION_MINOR
        LUMEN_WINDOWS_FILE_VERSION_PATCH
        LUMEN_WINDOWS_FILE_VERSION_BUILD)
    lumen_validate_windows_version_part(${version_part} "${${version_part}}")
endforeach()

set(LUMEN_WINDOWS_FILE_VERSION
        "${LUMEN_WINDOWS_FILE_VERSION_MAJOR}.${LUMEN_WINDOWS_FILE_VERSION_MINOR}.${LUMEN_WINDOWS_FILE_VERSION_PATCH}.${LUMEN_WINDOWS_FILE_VERSION_BUILD}")
message(STATUS
        "Windows FileVersion: ${LUMEN_WINDOWS_FILE_VERSION} "
        "(${lumen_windows_build_number_source}); ProductVersion: "
        "${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}")
