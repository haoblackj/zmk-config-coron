target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/diag_min.c)
# diag_prof.c reads the BLE host profiles, which only the central half (coron_R) has.
if(CONFIG_SHIELD_CORON_R)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/diag_prof.c)
endif()
# Boot-path instrument (test builds only). Every record it writes carries a build tag so a saved
# PC is resolved against the ELF of the firmware that recorded it, not the one reading it.
# Production: boot-entry clean and breadcrumb (never together with the test instrument, which
# defines the same early hook; Kconfig enforces it).
if(CONFIG_CORON_DIAG_ENTRY)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/diag_entry.c)
endif()
if(CONFIG_CORON_DIAG_BOOT)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/diag_boot.c)
  if(NOT DEFINED CORON_BUILD_TAG)
    string(TIMESTAMP _coron_ts "%m%d%H%M")
    set(CORON_BUILD_TAG "${CONFIG_SHIELD}-${_coron_ts}")
  endif()
  target_compile_definitions(app PRIVATE CORON_BUILD_TAG="${CORON_BUILD_TAG}")
endif()
