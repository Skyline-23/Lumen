if(APPLE)
    if(${SUNSHINE_CONFIGURE_HOMEBREW})
        configure_file(packaging/sunshine.rb sunshine.rb @ONLY)
    endif()
endif()

if(APPLE)
    if(${SUNSHINE_CONFIGURE_PORTFILE})
        configure_file(packaging/macos/Portfile Portfile @ONLY)
    endif()
endif()

# return if configure only is set
if(${SUNSHINE_CONFIGURE_ONLY})
    # message
    message(STATUS "SUNSHINE_CONFIGURE_ONLY: ON, exiting...")
    set(END_BUILD ON)
else()
    set(END_BUILD OFF)
endif()
