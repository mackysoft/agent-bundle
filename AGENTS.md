# AGENTS.md

## 基本方針

- ユーザーへの応答は日本語で行い、一般的でない略語や、対象と責務を省いた短縮表現を避ける。
- 作業前に `git status --short --branch` と対象差分を確認し、既存の未コミット変更や未追跡ファイルを他者の作業として保持する。
- `AGENTS.md` は作業者向けの安定した判断規則を持つ。`README.md` は、インストール方法、CLI の使用例、公開パッケージに含まれる Skill と custom agent の案内を利用者へ示す反映先とし、その内容をここへ複製しない。カタログの正本は `bundle/bundle.json` と `bundle/definitions/**` とする。

## プロジェクト概要

AgentBundle は、再利用可能な Skill と custom agent を一つの正規 bundle として配布する .NET global tool である。NuGet パッケージ `MackySoft.AgentBundle` は、`agent-bundle` CLI とホスト別に生成された Agent Distribution bundle を一つの成果物として配布する。

ホストに依存しない Skill と custom agent の列挙、選択、書き出し、導入、更新、診断などの中核処理は `MackySoft.AgentDistribution` が所有する。このリポジトリは、AgentBundle のカタログ、生成済み成果物の同梱、NuGet パッケージおよびリリース処理を所有する。公開 JSON、エラー、終了コードは Agent Distribution の契約をそのまま使い、CLI 層へ重複実装しない。

## プロジェクト構造

| パス | 責務 |
| --- | --- |
| `bundle/bundle.json` | カタログ ID と bundle version を定める正本。 |
| `bundle/definitions/skills/<category>/<skill>/` | Skill の正本。`skill.json` が表示情報と依存関係、`SKILL.md.template` が本文、`references/*.template` が参照資料を持つ。 |
| `bundle/definitions/agents/<agent>/` | custom agent の正本。`agent.json` が表示情報と直接 Skill 依存、`AGENT.md.template` がホスト非依存の指示、`hosts/*.json` が host binding を持つ。 |
| `bundle/generated/` | 正本から生成され、コミットと NuGet パッケージへ含める派生物。手作業では編集しない。 |
| `src/AgentBundle/` | .NET CLI 本体とパッケージ設定。 |
| `src/AgentBundle/Hosting/Cli/Common/` | Agent Distribution の `skills` と `agents` resource group を登録する CLI 境界。 |
| `src/AgentBundle/Hosting/Composition/` | DI と Agent Distribution runtime を構成する場所。 |
| `scripts/` | bundle 生成、整形、ビルド、パッケージ検証、リリースでローカルと CI が共有する入口。 |
| `.github/workflows/` | bundle 同期、変更検証、パッケージ公開の自動化。 |

`AgentBundle.slnx` は本体のプロジェクト構成、`src/AgentBundle/AgentBundle.csproj` は global tool と生成済み bundle の同梱、`Directory.Build.props` は共通の NuGet メタデータ、`.config/dotnet-tools.json` は生成ツールの固定バージョンを所有する。

## bundle の変更

- Skill と custom agent の追加、本文、description、依存関係、参照資料、host binding は `bundle/definitions/**` で変更する。
- `bundle/generated/**` にある digest、manifest、`agent-skill.json`、`agent-manifest.json`、host artifact は直接編集しない。
- 正本を変更したら `bash scripts/generate-bundle.sh` を実行し、対応する生成差分を正本と同じ変更へ含める。
- 通常のローカル生成、bundle 同期、機能変更では `bundle/bundle.json` の `bundleVersion` を変更しない。通常CIは最新の公開 GitHub Release と同じ値だけを受け入れる。
- 公開パッケージの利用方法、カテゴリ、同梱 Skill または custom agent が変わる場合は、正本の内容を利用者向けに `README.md` へ反映する。
- カタログと依存関係の整合は bundle の正本と `bash scripts/verify-bundle.sh` で確認する。`scripts/verify-cli-package.sh` は、生成済み bundle の同梱と、配布された CLI が Skill と custom agent のカタログを読み込めることを確認する。
- `.github/workflows/bundle-sync.yaml` による push 後の同期を、ローカルでの生成と確認の代わりにしない。

## CLI と C# の変更

- `skills` と `agents` の command surface、JSON、エラー、終了コード、引数は Agent Distribution の公開契約に従う。旧契約の変換、互換引数、alias を追加しない。
- DI は `Hosting/Composition/` に置く。新しい product-owned CLI 責務を追加する場合だけ、Agent Distribution の resource group と独立した境界を設ける。
- C# の書式と命名は `.editorconfig`、標準の整形入口は `bash scripts/code-quality.sh format` とする。
- `--no-restore` は、同じ作業で restore が成功している場合だけ使用する。

## セットアップと検証

初回または依存関係の変更後は、リポジトリルートで次を実行する。

```bash
dotnet tool restore
dotnet restore AgentBundle.slnx
```

bundle の正本を変更した場合は、生成と生成物の検査を行う。

```bash
bash scripts/generate-bundle.sh
bash scripts/verify-bundle.sh
```

C# の変更中は、必要な範囲で整形する。

```bash
bash scripts/code-quality.sh format
```

完了前の標準検証は次のコマンドとする。これは生成物の整合、C# の書式、Release build を確認する。

```bash
bash scripts/verify.sh
```

NuGet パッケージ、同梱物、CLI の配線へ影響する場合は、`verify.sh` に加えてパッケージのスモークテストも行う。通常開発時のバージョンは `Directory.Build.props` を確認する。

```bash
dotnet pack src/AgentBundle/AgentBundle.csproj \
  --configuration Release \
  --no-restore \
  -p:Version=<package-version> \
  -p:PackageVersion=<package-version> \
  --output artifacts/packages
bash scripts/verify-cli-package.sh artifacts/packages <package-version>
```

## リリース

リリース処理の正本は `.github/workflows/package-publish.yaml` と、そこから呼び出す `scripts/` のリリース用スクリプトである。タグは接頭辞なしの `<major>.<minor>.<patch>` 形式を使用する。リリースは既定ブランチから `workflow_dispatch` で明示的に実行し、最新の公開 GitHub Release の bundle version から次の値を一度だけ解決する。Agent Distribution の release action が専用の `release/<version>` ブランチで `bundle/bundle.json` の更新、生成、コミットを所有する。その厳密なコミットを通常の必須検証で確認し、PR を既定ブランチへマージした後、マージコミットへタグを付けて `pack`、スモークテスト、NuGet.org への公開、公開確認、GitHub Release への反映を行う。既定ブランチが既に同じリリース bundle version を持つ再実行では新たな増分を作らず、その状態へ収束させる。明示的なリリース依頼がない通常作業では、bundle version の更新、タグ作成、パッケージ公開、グローバル環境の更新を行わない。

## リリース後のグローバル反映

NuGet.org へのパッケージ公開が成功したら、公開した同じバージョンの CLI と内蔵 bundle をグローバル環境へ反映し、その後に Codex の user scope へ配置する Skill と custom agent を反映する。CLI の更新だけでは、ホストへ配置済みの成果物は変わらない。

1. 公開したバージョンを指定して CLI と内蔵 bundle を更新する。

   ```bash
   dotnet tool update --global MackySoft.AgentBundle --version <release-version>
   ```

2. CLI のバージョンが `<release-version>` と一致することを確認する。

   ```bash
   agent-bundle --version
   ```

3. 更新した CLI が提供する Skill カテゴリと custom agent 名を確認する。

   ```bash
   agent-bundle skills list
   agent-bundle agents list
   ```

4. 一覧に含まれるすべての Skill カテゴリを指定し、同梱されている全 Skill を Codex の user scope へ更新する。

   ```bash
   agent-bundle skills update --host codex --scope user --category <comma-separated-skill-categories>
   ```

5. 一覧に含まれるすべての custom agent 名を指定し、同梱されている custom agent とその依存 Skill を Codex の user scope へ更新する。

   ```bash
   agent-bundle agents update --host codex --scope user --agent <comma-separated-agent-names>
   ```

6. リリースで Skill または custom agent を削除または改名した場合は、旧名を指定して管理済み成果物を明示的に削除する。`update` は削除済み項目を prune しない。同じ host、scope、および導入時の target override を使って必要な各名前へ実行する。

   ```bash
   agent-bundle skills prune --host codex --scope user --skill <removed-or-renamed-skill>
   agent-bundle agents prune --host codex --scope user --agent <removed-or-renamed-agent>
   ```

### 反映後の確認

`update` が成功したら、同じ Skill カテゴリと custom agent 名を指定して、Codex の user scope に配置した Skill と custom agent に問題がないことを確認する。

```bash
agent-bundle skills doctor --host codex --scope user --category <comma-separated-skill-categories>
agent-bundle agents doctor --host codex --scope user --agent <comma-separated-agent-names>
```

反映した Skill と custom agent を読み込ませるため、Codex アプリを再起動するか、新しいセッションを開始する。

更新、`doctor` による確認、再読み込みが完了するまで、リリース後のローカル反映を完了扱いにしない。失敗した場合は、失敗したコマンドと原因を報告する。
