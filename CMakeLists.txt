# 実機用のビルド（coron_L / coron_R）にだけ、致命的エラーで再起動する処理を足す。
# テスト（native_sim）や settings_reset には入れない。
# zmk-feature-watchdog の致命的エラーの検知を有効にしたときは、そちらが同じ関数を定義して
# 記録のあと再起動するので、入れない（両方あると、どちらが使われるかはリンク次第になる）。
if((CONFIG_SHIELD_CORON_L OR CONFIG_SHIELD_CORON_R) AND NOT CONFIG_ZMK_WATCHDOG_FATAL_DETECT)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/fatal_reboot.c)
endif()

# 右手側（PC へのペリフェラルと左手側へのセントラルを兼ねる側）にだけ、PC と未接続のあいだ
# 左手側との通信をゆっくりにする処理を足す。
if(CONFIG_SHIELD_CORON_R)
  target_sources(app PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/split_yield.c)
endif()
