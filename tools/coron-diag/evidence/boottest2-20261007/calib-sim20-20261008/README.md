# 模擬試験の記録（2026-10-08 20:09〜20:21、`calib-sim.py --jobs 4`、実機ループ初回の 1 件への対応後（校正 46 場面 + ループ 37 場面））
`selftest.txt` が `calib-selftest.ps1` の結果（実機から読んだインスタンス ID を入力にした照合関数の直接検証 15 件）。`report.txt` が判定表（自己試験の結果、終了コードの期待と実測、`results:` 行、不一致の有無）と各場面の決め手の行。`results.json` が同じ内容の機械可読版。`expect/<場面>.json` が各場面の期待。`logs/<場面>/` が全体実行（`calib-all.ps1`）の `summary.log` と各段のログ。
省いたもの: 子の標準出力の複製（`child-*.out`、`*-ioN.out`。内容は各段のログに同じものが入る）、交換ごとの模擬ポートの缶詰（`*-ioN.mock.json`）、場面ファイル本体（`gen-scenarios.py` が再生成する）。
ループの場面（`loop-*`）には台帳 `ledger.json`/`ledger.csv` と各試行の結果 `result-*.json` も含む。
同じ 83 場面の 19:01〜19:17 の初回の実行は、校正の 3 場面（`flash-ack-lost`、`step6-ack-lost`、`step7-ack-lost`）の照合条件「`acknowledged` が出ない」が第 0、8 段の `PASS c acknowledged (ZDIAG ring cleared)` に当たって不一致になった。スクリプトは変えず、条件を `b acknowledged`/`r acknowledged` が出ないことに狭めてこの実行で置き換えた（初回の記録は残していない）。
