if(APPLE)
    if(${LUMEN_CONFIGURE_PORTFILE})
        configure_file(packaging/macos/Portfile Portfile @ONLY)
    endif()
endif()

# return if configure only is set
if(${LUMEN_CONFIGURE_ONLY})
    # message
    message(STATUS "LUMEN_CONFIGURE_ONLY: ON, exiting...")
    set(END_BUILD ON)
else()
    set(END_BUILD OFF)
endif()
