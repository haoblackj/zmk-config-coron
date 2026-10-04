# 実機用のビルド（coron_L / coron_R）にだけ、致命的エラーで再起動する処理を足す。
# テスト（native_sim）や settings_reset には入れない。
if(CONFIG_SHIELD_CORON_L OR CONFIG_SHIELD_CORON_R)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/fatal_reboot.c)
endif()
