# Hindsight for GitHub Copilot

Windows 上で Hindsight をネイティブ実行し、GitHub Copilot から永続メモリとして利用するためのセットアップです。

- Docker 不要
- 外部 PostgreSQL 不要
- Hindsight の embedded PostgreSQL (`pg0`) を使用
- すべての VS Code プロジェクトで同じ Hindsight bank `main` を共有
- GitHub Copilot のユーザー共通 MCP として登録
- GitHub Copilot のユーザー共通 instructions を使用
- Windows Startup から自動起動
- Hindsight は常駐
- 毎時 `HH:30` に `memory.md` を更新
- `setup.ps1` は冪等
- `hindsight.ps1` は起動済み Hindsight を再起動可能

## Directory

~~~
C:\develop\hindsight\
├── README.md
├── copilot-instructions.md
├── hindsight.ps1
├── setup.ps1
├── .gitignore
├── memory.md
└── .venv\
~~~

`memory.md` と `.venv` はセットアップ時に生成されるため、Git には含めません。

## Prerequisites

以下を事前にインストールしてください。

### Python 3.12

Python 3.12 をインストールし、`python` コマンドが PATH に存在する状態にしてください。

確認:

~~~powershell
python --version
~~~

### uv

Scoop を使用する場合:

~~~powershell
scoop install main/uv
~~~

確認:

~~~powershell
uv --version
~~~

### GitHub Copilot CLI

~~~powershell
scoop bucket add main
scoop install main/copilot-cli
~~~

その後、一度ログインします。

~~~powershell
copilot
~~~

Copilot CLI の認証が完了していることを確認してください。

確認:

~~~powershell
copilot --version
~~~

## Setup

このリポジトリを `C:\develop\hindsight` に配置します。

PowerShell で:

~~~powershell
cd C:\develop\hindsight
.\setup.ps1
~~~

`setup.ps1` は何度実行しても問題ありません。

例えば:

~~~powershell
.\setup.ps1
.\setup.ps1
.\setup.ps1
~~~

としても、既存の環境を壊さず、現在の設定値に環境を同期します。

## Configuration

Hindsight の設定値は `setup.ps1` と `hindsight.ps1` に直接記述しています。

主な設定:

~~~powershell
$HostAddress = "127.0.0.1"
$Port = 8888
$BankId = "main"

$LlmProvider = "github-copilot"
$LlmModel = "gpt-5.6-luna"
$ReasoningEffort = "high"
~~~

設定を変更した場合は:

~~~powershell
.\setup.ps1
~~~

を実行し、その後:

~~~powershell
.\hindsight.ps1
~~~

を実行してください。

`hindsight.ps1` は起動時に既存の Hindsight API プロセスを停止し、現在の設定値で再起動します。

## GitHub Copilot MCP

ユーザー共通の portable MCP 設定:

~~~
%USERPROFILE%\.copilot\mcp-config.json
~~~

登録されるサーバー:

~~~json
{
  "mcpServers": {
    "hindsight": {
      "type": "http",
      "url": "http://127.0.0.1:8888/mcp/main/"
    }
  }
}
~~~

Hindsight は `main` bank を直接指定しています。

## Copilot Instructions

このリポジトリの:

~~~
copilot-instructions.md
~~~

が Hindsight 用 instructions の source of truth です。

`hindsight.ps1` を起動するたびに、このファイルを読み込み:

~~~
%USERPROFILE%\.copilot\copilot-instructions.md
~~~

へ反映します。

そのため、instructions を変更した場合は:

~~~powershell
.\hindsight.ps1
~~~

を実行すれば反映されます。

既存のユーザー instructions がある場合でも、Hindsight 用の範囲だけを更新し、それ以外の内容は保持します。

## Hindsight

Hindsight は:

~~~
127.0.0.1:8888
~~~

で起動します。

データベースには embedded PostgreSQL (`pg0`) を使用します。

外部 PostgreSQL は使用しません。

## memory.md

`memory.md` は Hindsight のメモリのスナップショットです。

追記方式ではなく、毎回完全に上書きします。

更新タイミング:

1. `hindsight.ps1` 起動直後
2. 毎時 `HH:30`

例えば:

~~~
23:30
00:30
01:30
02:30
...
~~~

`hindsight.ps1` が終了すると更新も停止します。

## Startup

`setup.ps1` は Windows Startup にショートカットを作成します。

Startup:

~~~
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
~~~

ログイン時には:

~~~powershell
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\develop\hindsight\hindsight.ps1"
~~~

が実行されます。

Hindsight 自体も hidden window で起動します。

## Manual start

手動で起動する場合:

~~~powershell
cd C:\develop\hindsight
.\hindsight.ps1
~~~

この PowerShell プロセスは常駐します。

Hindsight API の子プロセス自体は hidden です。

## Restart behavior

`hindsight.ps1` の動作:

~~~
Hindsight が起動していない
        ↓
そのまま起動

Hindsight がすでに起動している
        ↓
既存プロセスを停止
        ↓
現在の設定で再起動
        ↓
ready 待ち
        ↓
memory.md を更新
        ↓
常駐
~~~

対象は `hindsight-api.exe` のみです。

## Idempotency

`setup.ps1` は現在のスクリプトに記述された設定を正とします。

例えば:

~~~powershell
$Port = 8888
~~~

を:

~~~powershell
$Port = 9000
~~~

へ変更して再実行すると、MCP 設定も:

~~~
http://127.0.0.1:9000/mcp/main/
~~~

へ更新されます。

同様に:

- LLM provider
- LLM model
- reasoning effort
- port
- bank ID

などの設定変更を次回セットアップ時に反映します。

既存の MCP 設定にある Hindsight 以外のサーバーは削除しません。

## Changing instructions

通常は:

~~~
copilot-instructions.md
~~~

だけ編集します。

例えば:

~~~powershell
notepad .\copilot-instructions.md
~~~

編集後:

~~~powershell
.\hindsight.ps1
~~~

とすれば、現在の Hindsight を再起動し、最新の instructions を Copilot のユーザー共通 instructions へ反映します。

## Stop Hindsight

`hindsight.ps1` を実行している PowerShell で:

~~~
Ctrl+C
~~~

を押します。

これにより Hindsight の子プロセスも停止します。

## Troubleshooting

### Hindsight が起動しない

~~~powershell
Get-Process hindsight-api -ErrorAction SilentlyContinue
~~~

ready 状態の確認:

~~~powershell
Invoke-WebRequest http://127.0.0.1:8888/health/ready
~~~

### MCP 設定確認

~~~powershell
Get-Content "$HOME\.copilot\mcp-config.json"
~~~

### Copilot instructions 確認

~~~powershell
Get-Content "$HOME\.copilot\copilot-instructions.md"
~~~

### Hindsight プロセス確認

~~~powershell
Get-CimInstance Win32_Process -Filter "Name='hindsight-api.exe'" |
    Select-Object ProcessId, ExecutablePath, CommandLine
~~~

## Security

Hindsight MCP は localhost のみに bind します。

~~~
127.0.0.1
~~~

外部ネットワークから Hindsight API を直接公開しません。

API key、アクセストークン、秘密鍵などはこのリポジトリに保存しないでください。
