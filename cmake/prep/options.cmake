# Publisher Metadata
set(LUMEN_PUBLISHER_NAME "SudoMaker"
        CACHE STRING "The name of the publisher (or fork developer) of the application.")
set(LUMEN_PUBLISHER_WEBSITE "https://www.sudomaker.com"
        CACHE STRING "The URL of the publisher's website.")
set(LUMEN_PUBLISHER_ISSUE_URL "https://github.com/Skyline-23/Lumen/issues"
        CACHE STRING "The URL of the publisher's support site or issue tracker.
        If you provide a modified version of Lumen, use your own url.")

option(BUILD_WERROR "Enable -Werror flag." OFF)

# if this option is set, the build will exit after configuring special package configuration files
option(LUMEN_CONFIGURE_ONLY "Configure special files only, then exit." OFF)
