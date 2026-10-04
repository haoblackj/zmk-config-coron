/*
 * Coron のテスト共通定義。
 *
 * 実機のキーマップ (config/coron.keymap) をそのまま読み込んで、native_sim 上で検証する。
 * モック kscan を 1 行 51 列にして、列番号がキー位置になるようにしている。
 * PRESS / RELEASE の第2引数は、そのイベントのあと次のイベントまでの待ち時間 (ms)。
 *
 * 実行はワークスペースのルートから:
 *   zmk/app/run-test.sh config/zmk-config-coron/tests
 */

#include <dt-bindings/zmk/kscan_mock.h>

#define PRESS(pos, ms) ZMK_MOCK_PRESS(0, pos, ms)
#define RELEASE(pos, ms) ZMK_MOCK_RELEASE(0, pos, ms)

#define POS_Q 1
#define POS_A 13
#define POS_S 14
#define POS_D 15
#define POS_F 16
#define POS_H 20
#define POS_J 21
#define POS_K 22
#define POS_L 23
#define POS_AT 24

#define POS_MUHENKAN 45 /* 左サム: 無変換 / レイヤー3 */
#define POS_SPACE_L 46  /* 左サム内側: スペース */
#define POS_SPACE_R 47  /* 右サム内側: スペース / レイヤー4 (FUN) */
#define POS_HENKAN 48   /* 右サム: 変換 / レイヤー2 (SYM) */
