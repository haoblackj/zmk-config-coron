# zmk-config-coron

## この fork での主な変更点（upstream 比）

このリポジトリは、fork 元の `keebJP/zmk-config-coron` をベースに、JIS 配列、トラックボール操作、DYA Studio 連携を追加・調整した coron 用 ZMK 設定です。

主な差分は `upstream/main` と比較して次の通りです。

### JIS キーマップ

- `config/coron.keymap` を Vial 由来の JIS 配列に合わせて再構成しています。
- `DEF` / `NUM` / `SYM` / `L3` / `FUN` / `BTL` / `AMS` / `SCR` のレイヤー定義を追加しました。
- Vial で使っていたコンボを ZMK の combo 定義へ移植しました。
- Bluetooth / bootloader / system reset / Studio unlock 用のシステムレイヤーを追加しました。
- オートマウス用レイヤーとスクロール用レイヤーを分離しました。

### トラックボールとスクロール

- `boards/shields/coron/coron_R.overlay` にトラックボール用の input processor 設定を追加しています。
- 通常ポインタ移動には `mouse_runtime_input_processor` と一時レイヤー切り替えを設定しました。
- スクロール時には `zip_xy_to_scroll_mapper`、Y 方向スケーラー、Y 反転、`scroll_runtime_input_processor` を通す構成にしました。
- デッドゾーン processor を追加し、微小な入力を抑制するようにしました。
- PMW3610 の向きを 180 度から 0 度設定へ変更しました。

### DYA Studio 対応

- `config/west.yml` の ZMK 本体を `cormoran` fork の `v0.3-branch+dya` に変更しています。
- DYA Studio 用モジュールとして、BLE management、battery history、settings RPC、runtime input processor を追加しています。
- `boards/shields/coron/coron_R.conf` で Studio、BLE management、battery history、settings RPC、split relay event、runtime input processor を有効化しています。
- `boards/shields/coron/coron_L.conf` でも battery history、settings RPC、split relay event、settings 保存 debounce を有効化しています。
- BLE 接続数とペアリング数を Studio 利用を前提に `5` に設定しました。

### 依存モジュール

- `zmk-module-ble-management` と `zmk-module-runtime-input-processor` は `zmk-v0.3.0.0` に固定しました。
- `zmk-input-processor-deadzone` を追加し、特定コミットに固定しました。
- 既存の PMW3610 ドライバ依存は維持しています。

### その他

- 左手 overlay に battery history request behavior の include を追加しました。
- `.claude/settings.local.json` を `.gitignore` に追加しました。
