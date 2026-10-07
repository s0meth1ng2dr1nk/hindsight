$ErrorActionPreference = "Stop"

# ============================================================
# Configuration
# ============================================================

$Root = "C:\develop\hindsight"

$Venv = Join-Path $Root ".venv"
$Python = Join-Path $Venv "Scripts\python.exe"

$InstructionSource = Join-Path $Root "copilot-instructions.md"

$CopilotHome = Join-Path $HOME ".copilot"
$McpFile = Join-Path $CopilotHome "mcp-config.json"
$GlobalInstructionFile = Join-Path $CopilotHome "copilot-instructions.md"

$HostAddress = "127.0.0.1"
$Port = 8888
$BankId = "main"

$LlmProvider = "github-copilot"
$LlmModel = "gpt-5.6-luna"
$ReasoningEffort = "high"

$HindsightMarkerStart = "<!-- HINDSIGHT-START -->"
$HindsightMarkerEnd = "<!-- HINDSIGHT-END -->"

$StartupDirectory = Join-Path `
    $env:APPDATA `
    "Microsoft\Windows\Start Menu\Programs\Startup"

$StartupShortcut = Join-Path `
    $StartupDirectory `
    "Hindsight.lnk"

$HindsightScript = Join-Path `
    $Root `
    "hindsight.ps1"

# ============================================================
# Helpers
# ============================================================

function Read-JsonFile {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $Raw = Get-Content -Raw -Path $Path

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $null
    }

    try {
        return $Raw | ConvertFrom-Json
    }
    catch {
        throw "JSON を読み込めません: $Path"
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Object
    )

    $Json = $Object | ConvertTo-Json -Depth 50

    [System.IO.File]::WriteAllText(
        $Path,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Sync-CopilotInstructions {
    if (-not (Test-Path $InstructionSource)) {
        throw "Instructions file が存在しません: $InstructionSource"
    }

    $Source = Get-Content -Raw -Path $InstructionSource

    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw "Instructions file が空です: $InstructionSource"
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $CopilotHome |
        Out-Null

    $Source = $Source.Trim()

    $ManagedBlock = @"
$HindsightMarkerStart
$Source
$HindsightMarkerEnd
"@

    if (Test-Path $GlobalInstructionFile) {
        $Existing = Get-Content -Raw -Path $GlobalInstructionFile
    }
    else {
        $Existing = ""
    }

    $Pattern = '(?s)<!-- HINDSIGHT-START -->.*?<!-- HINDSIGHT-END -->'

    if ($Existing -match $Pattern) {
        $Updated = [regex]::Replace(
            $Existing,
            $Pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($Match)
                $ManagedBlock
            }
        )
    }
    elseif ([string]::IsNullOrWhiteSpace($Existing)) {
        $Updated = $ManagedBlock
    }
    else {
        $Updated = `
            $Existing.TrimEnd() +
            "`r`n`r`n" +
            $ManagedBlock
    }

    [System.IO.File]::WriteAllText(
        $GlobalInstructionFile,
        $Updated,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Update-McpConfig {
    New-Item `
        -ItemType Directory `
        -Force `
        -Path $CopilotHome |
        Out-Null

    $Config = Read-JsonFile -Path $McpFile

    if ($null -eq $Config) {
        $Config = [pscustomobject]@{}
    }

    if (-not ($Config.PSObject.Properties.Name -contains "mcpServers")) {
        $Config | Add-Member `
            -NotePropertyName "mcpServers" `
            -NotePropertyValue ([pscustomobject]@{})
    }

    $McpUrl = "http://$HostAddress`:$Port/mcp/$BankId/"

    $HindsightServer = [pscustomobject]@{
        type = "http"
        url  = $McpUrl
    }

    if ($Config.mcpServers.PSObject.Properties.Name -contains "hindsight") {
        $Config.mcpServers.hindsight = $HindsightServer
    }
    else {
        $Config.mcpServers |
            Add-Member `
                -NotePropertyName "hindsight" `
                -NotePropertyValue $HindsightServer
    }

    Write-JsonFile `
        -Path $McpFile `
        -Object $Config
}

function Update-StartupShortcut {
    New-Item `
        -ItemType Directory `
        -Force `
        -Path $StartupDirectory |
        Out-Null

    $Shell = New-Object -ComObject WScript.Shell

    try {
        $Shortcut = $Shell.CreateShortcut($StartupShortcut)

        $Shortcut.TargetPath = `
            "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

        $Shortcut.Arguments = `
            "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HindsightScript`""

        $Shortcut.WorkingDirectory = $Root
        $Shortcut.WindowStyle = 7

        $Shortcut.Save()
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Shell) |
            Out-Null
    }
}

# ============================================================
# Start
# ============================================================

Write-Host "== Hindsight setup =="

# ============================================================
# Validate prerequisites
# ============================================================

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python がインストールされていません。README.md を確認してください。"
}

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw "uv がインストールされていません。README.md を確認してください。"
}

if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) {
    throw "GitHub Copilot CLI がインストールされていません。README.md を確認してください。"
}

# ============================================================
# Directories
# ============================================================

New-Item `
    -ItemType Directory `
    -Force `
    -Path $Root |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $CopilotHome |
    Out-Null

Set-Location $Root

# ============================================================
# Validate source files
# ============================================================

if (-not (Test-Path $InstructionSource)) {
    throw "copilot-instructions.md がありません: $InstructionSource"
}

if (-not (Test-Path $HindsightScript)) {
    throw "hindsight.ps1 がありません: $HindsightScript"
}

# ============================================================
# Python environment
# ============================================================

Write-Host "[1/4] Python 環境を確認しています..."

if (-not (Test-Path $Python)) {
    Write-Host "  .venv を作成しています..."

    uv venv `
        --python 3.12 `
        $Venv
}

# ============================================================
# Hindsight
# ============================================================

Write-Host "[2/4] Hindsight を同期しています..."

uv pip install `
    --python $Python `
    --upgrade `
    hindsight-api

# ============================================================
# MCP
# ============================================================

Write-Host "[3/4] GitHub Copilot MCP 設定を同期しています..."

Update-McpConfig

# ============================================================
# Instructions
# ============================================================

Write-Host "  Copilot instructions を同期しています..."

Sync-CopilotInstructions

# ============================================================
# Startup
# ============================================================

Write-Host "[4/4] Windows Startup を同期しています..."

Update-StartupShortcut

# ============================================================
# Done
# ============================================================

Write-Host ""
Write-Host "Setup complete."
Write-Host ""
Write-Host "Root:         $Root"
Write-Host "Hindsight:    $($Venv)\Scripts\hindsight-api.exe"
Write-Host "MCP:          http://$HostAddress`:$Port/mcp/$BankId/"
Write-Host "Model:        $LlmModel"
Write-Host "Reasoning:    $ReasoningEffort"
Write-Host "Instructions: $GlobalInstructionFile"
Write-Host "Startup:      $StartupShortcut"
Write-Host ""
Write-Host "Hindsight を起動するには:"
Write-Host "  .\hindsight.ps1"
