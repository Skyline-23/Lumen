# windows specific target definitions
set_target_properties(lumen PROPERTIES LINK_SEARCH_START_STATIC 1)
list(APPEND LUMEN_EXTERNAL_LIBRARIES
        $<TARGET_OBJECTS:lumen_rc_object>
        Windowsapp.lib
        Wtsapi32.lib)
