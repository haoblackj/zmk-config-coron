# 模擬試験の記録（2026-10-08 14:54〜15:03、`calib-sim.py --jobs 4`、レビュー #18 への対応後（校正 43 場面 + ループ 33 場面））
`selftest.txt` が `calib-selftest.ps1` の結果（実機から読んだインスタンス ID を入力にした照合関数の直接検証 15 件）。`report.txt` が判定表（自己試験の結果、終了コードの期待と実測、`results:` 行、不一致の有無）と各場面の決め手の行。`results.json` が同じ内容の機械可読版。`expect/<場面>.json` が各場面の期待。`logs/<場面>/` が全体実行（`calib-all.ps1`）の `summary.log` と各段のログ。
省いたもの: 子の標準出力の複製（`child-*.out`、`*-ioN.out`。内容は各段のログに同じものが入る）、交換ごとの模擬ポートの缶詰（`*-ioN.mock.json`）、場面ファイル本体（`gen-scenarios.py` が再生成する）。
ループの場面（`loop-*`）には台帳 `ledger.json`/`ledger.csv` と各試行の結果 `result-*.json` も含む。
