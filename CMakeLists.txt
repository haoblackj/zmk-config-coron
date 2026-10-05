# 実機用のビルド（coron_L / coron_R）にだけ、致命的エラーで再起動する処理を足す。
# テスト（native_sim）や settings_reset には入れない。
if(CONFIG_SHIELD_CORON_L OR CONFIG_SHIELD_CORON_R)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/fatal_reboot.c)
endif()

# 右手側（PC へのペリフェラルと左手側へのセントラルを兼ねる側）にだけ、PC と未接続のあいだ
# 左手側との通信をゆっくりにする処理を足す。
if(CONFIG_SHIELD_CORON_R)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/split_yield.c)
endif()
