# coron-diag（計測用モジュール。本番の像には入れない）

右手側（coron_R）の起動停止の調査用。`src/diag_min.c` がコンソール命令（`d`/`r`/`b`/`h`/`H`/`G`/`S`/`c`）、`src/diag_boot.c` が起動経路の計測器（`CONFIG_CORON_DIAG_BOOT`）、`src/diag_prof.c` が BLE の接続プロファイルの読み出し。

ビルドは `evidence/boottest2-20261007/build-boottest2.sh`（`ZMK_EXTRA_MODULES` にこのディレクトリを足し、`EXTRA_CONF_FILE` に `boottest.conf` か `boottest-alt.conf`、`EXTRA_DTC_OVERLAY_FILE` に `diagrec.overlay` を渡す）。10/08 の v4 の像を作ったときのソースは、このディレクトリの内容と同一（`evidence/boottest2-20261007/README.md` の md5）。

証拠の束と状態遷移表、校正手順は `evidence/boottest2-20261007/README.md`。経緯は haoblackj/zmk-workspace の issue #1。
