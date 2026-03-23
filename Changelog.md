# Changelog

## 0.5.0 (Unreleased)

0.4.0 からの主なユーザー向け変更点:

- `Command + C` のダブルコピー起動を追加（macOS）
  - 同一テキストを短時間で2回コピーするとアプリを前面表示して翻訳を開始
- ダブルコピー起動時の前面化動作を強化
  - ウィンドウ復帰・キーウィンドウ化を行い、すぐ操作できる状態に改善
- Foundation Models の部分表示を改善
  - `snapshot.rawContent.jsonString` から途中の `translation` を抽出し、ストリーミング中の見た目の更新を改善
- 構造化出力のガードを強化
  - `translation` に `kind` ラベルのみが返るケースを不正として再試行/フォールバックへ回すよう改善

## 0.4.0

0.2.0 からの主なユーザー向け変更点:

- セグメント種別 (`kind`) 推定を導入
  - 空行境界・会話行グループ・短行グループなどを使って `heading / dialogue / ui-labels / lists / general` を推定
  - 推定 `kind` を翻訳パイプラインへ受け渡し
- Foundation Models 構造化生成を強化
  - 各セグメントで `preprocess-kind` と `structured-kind` を Console に記録
  - `@Generable` / `@Guide` ベースの型付き生成に対応し、構造をプロンプト依存にしない方針へ移行
  - 構造化出力の再試行とフォールバック動作を改善し、プレースホルダ混入時の完走性を向上
- Developer Console の使い勝手を改善
  - 一括コピーしやすいテキスト表示へ変更
  - `Clear` ボタンを追加
- 観測性の改善
  - セッション単位ログ (`[Sx]`) とタイミング指標を拡充
  - セッション開始時に `kind` サマリを表示

## 0.2.0

0.1.0 からの主なユーザー向け変更点:

- URLスキーム起動時に既存ウインドウを再利用するよう改善
  - 前回のターゲット言語や画面状態を保持しやすくなりました
- URL起動の重複実行抑制を改善
  - 同一 `text + target language + processing mode` の重複処理をスキップ
- 出力ステータス表示を段階化
  - `Ready` / `Preprocessing` / `Translating x/y` / `Completed` を表示
  - 翻訳中に停止ボタン（Stop）を利用可能
- Developer Mode の可観測性を強化
  - Deterministic / Heuristic Analysis を分離表示
  - 各処理時間の表示を追加
  - Console 表示を追加し、エラー詳細やヒューリスティック段階ログを確認可能
- セグメント処理を改善
  - 明示境界（空行・会話形式）ベースの分割
  - AIヒューリスティックによる前段/後段の再セグメント化
- Foundation Models 翻訳の安定性向上
  - ストリームの停止ガード（時間・回数・文字数）を追加
  - unsafe 検出時の再試行とセグメント単位フォールバックで完走性を改善
