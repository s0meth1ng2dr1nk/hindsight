$ErrorActionPreference = "Stop"

# ============================================================
# Configuration
# ============================================================

$Root = "C:\develop\hindsight"

$Venv = Join-Path $Root ".venv"
$Hindsight = Join-Path $Venv "Scripts\hindsight-api.exe"

$InstructionSource = Join-Path $Root "copilot-instructions.md"
$MemoryFile = Join-Path $Root "memory.md"

$CopilotHome = Join-Path $HOME ".copilot"
$GlobalInstructionFile = Join-Path $CopilotHome "copilot-instructions.md"

$HostAddress = "127.0.0.1"
$Port = 8888
$BankId = "main"

$LlmProvider = "github-copilot"
$LlmModel = "gpt-5.6-luna"
$ReasoningEffort = "high"

$ReadyUrl = "http://$HostAddress`:$Port/health/ready"
$McpUrl = "http://$HostAddress`:$Port/mcp/$BankId/"

$HindsightMarkerStart = "<!-- HINDSIGHT-START -->"
$HindsightMarkerEnd = "<!-- HINDSIGHT-END -->"

# ============================================================
# Copilot instructions
# ============================================================

function Sync-CopilotInstructions {
    if (-not (Test-Path $InstructionSource)) {
        throw "Instructions file が存在しません: $InstructionSource"
    }

    $Source = Get-Content -Raw -Path $InstructionSource

    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw "Instructions file が空です: $InstructionSource"
    }

    New-Item -ItemType Directory -Force -Path $CopilotHome | Out-Null

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
        $Updated = $Existing.TrimEnd() + "`r`n`r`n" + $ManagedBlock
    }

    [System.IO.File]::WriteAllText(
        $GlobalInstructionFile,
        $Updated,
        [System.Text.UTF8Encoding]::new($false)
    )
}

# ============================================================
# Stop existing Hindsight
# ============================================================

function Stop-ExistingHindsight {
    $TargetPath = [System.IO.Path]::GetFullPath($Hindsight)

    $Processes = @(
        Get-CimInstance Win32_Process -Filter "Name='hindsight-api.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                ([System.IO.Path]::GetFullPath($_.ExecutablePath) -ieq $TargetPath)
            }
    )

    foreach ($ProcessInfo in $Processes) {
        Write-Host "既存の Hindsight を停止しています... PID=$($ProcessInfo.ProcessId)"

        Stop-Process `
            -Id $ProcessInfo.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue
    }

    if ($Processes.Count -gt 0) {
        $Deadline = (Get-Date).AddSeconds(15)

        while ((Get-Date) -lt $Deadline) {
            $Running = @(
                $Processes |
                    ForEach-Object {
                        Get-Process `
                            -Id $_.ProcessId `
                            -ErrorAction SilentlyContinue
                    }
            )

            if ($Running.Count -eq 0) {
                break
            }

            Start-Sleep -Milliseconds 250
        }
    }
}

# ============================================================
# Ready check
# ============================================================

function Test-HindsightReady {
    try {
        $Response = Invoke-WebRequest `
            -Uri $ReadyUrl `
            -Method Get `
            -TimeoutSec 3 `
            -UseBasicParsing `
            -ErrorAction Stop

        return (
            $Response.StatusCode -ge 200 -and
            $Response.StatusCode -lt 300
        )
    }
    catch {
        return $false
    }
}

function Wait-HindsightReady {
    param(
        [int]$TimeoutSeconds = 120
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $Deadline) {
        if (Test-HindsightReady) {
            return
        }

        Start-Sleep -Seconds 1
    }

    throw "Hindsight が $TimeoutSeconds 秒以内に ready になりませんでした: $ReadyUrl"
}

# ============================================================
# Memory export
# ============================================================

function Get-MemoryItems {
    $Limit = 500
    $Offset = 0
    $AllItems = [System.Collections.Generic.List[object]]::new()

    while ($true) {
        $Url = "http://$HostAddress`:$Port/v1/default/banks/$([uri]::EscapeDataString($BankId))/memories/list?limit=$Limit&offset=$Offset"

        $Response = Invoke-RestMethod `
            -Uri $Url `
            -Method Get `
            -TimeoutSec 120 `
            -ErrorAction Stop

        $Items = @()

        if ($null -ne $Response.items) {
            $Items = @($Response.items)
        }
        elseif ($null -ne $Response.memories) {
            $Items = @($Response.memories)
        }
        elseif ($null -ne $Response.results) {
            $Items = @($Response.results)
        }
        elseif ($Response -is [System.Array]) {
            $Items = @($Response)
        }

        foreach ($Item in $Items) {
            $AllItems.Add($Item)
        }

        if ($Items.Count -lt $Limit) {
            break
        }

        $Offset += $Limit
    }

    return @($AllItems)
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    foreach ($Name in $Names) {
        $Property = $Object.PSObject.Properties[$Name]

        if ($null -ne $Property) {
            return $Property.Value
        }
    }

    return $null
}

function Export-Memory {
    Write-Host "memory.md を更新しています..."

    $Items = Get-MemoryItems

    $Lines = [System.Collections.Generic.List[string]]::new()

    $Lines.Add("# Hindsight Memory")
    $Lines.Add("")
    $Lines.Add("Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")")
    $Lines.Add("")
    $Lines.Add("Bank: `$BankId`")
    $Lines.Add("")
    $Lines.Add("Memory count: $($Items.Count)")
    $Lines.Add("")
    $Lines.Add("---")
    $Lines.Add("")

    if ($Items.Count -eq 0) {
        $Lines.Add("_No memories._")
    }
    else {
        foreach ($Item in $Items) {
            $Text = Get-PropertyValue $Item @("text", "content")
            $Type = Get-PropertyValue $Item @("fact_type", "type")
            $Context = Get-PropertyValue $Item @("context")
            $CreatedAt = Get-PropertyValue $Item @("created_at", "date")
            $MentionedAt = Get-PropertyValue $Item @("mentioned_at")
            $Id = Get-PropertyValue $Item @("id")

            if ($null -ne $Text -and "$Text" -ne "") {
                $DisplayText = "$Text"
            }
            else {
                $DisplayText = "(no text)"
            }

            $Lines.Add("## $DisplayText")
            $Lines.Add("")

            if ($null -ne $Type -and "$Type" -ne "") {
                $Lines.Add("- Type: `$Type`")
            }

            if ($null -ne $Context -and "$Context" -ne "") {
                $Lines.Add("- Context: $Context")
            }

            if ($null -ne $CreatedAt -and "$CreatedAt" -ne "") {
                $Lines.Add("- Created: `$CreatedAt`")
            }

            if ($null -ne $MentionedAt -and "$MentionedAt" -ne "") {
                $Lines.Add("- Mentioned: `$MentionedAt`")
            }

            if ($null -ne $Id -and "$Id" -ne "") {
                $Lines.Add("- ID: `$Id`")
            }

            $Lines.Add("")
        }
    }

    [System.IO.File]::WriteAllLines(
        $MemoryFile,
        $Lines,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "memory.md を更新しました: $MemoryFile"
}

# ============================================================
# Schedule
# ============================================================

function Get-NextHalfHour {
    $Now = Get-Date

    if ($Now.Minute -lt 30) {
        return $Now.Date.AddHours($Now.Hour).AddMinutes(30)
    }

    return $Now.Date.AddHours($Now.Hour + 1).AddMinutes(30)
}

# ============================================================
# Validation
# ============================================================

if (-not (Test-Path $Hindsight)) {
    throw "Hindsight がインストールされていません: $Hindsight`n先に setup.ps1 を実行してください。"
}

if (-not (Test-Path $InstructionSource)) {
    throw "Instructions file が存在しません: $InstructionSource"
}

# ============================================================
# Sync instructions
# ============================================================

Sync-CopilotInstructions

# ============================================================
# Environment
# ============================================================

$env:HINDSIGHT_API_HOST = $HostAddress
$env:HINDSIGHT_API_PORT = "$Port"
$env:HINDSIGHT_API_DATABASE_URL = "pg0"

$env:HINDSIGHT_API_LLM_PROVIDER = $LlmProvider
$env:HINDSIGHT_API_LLM_MODEL = $LlmModel
$env:HINDSIGHT_API_LLM_REASONING_EFFORT = $ReasoningEffort

# ============================================================
# Restart Hindsight
# ============================================================

Stop-ExistingHindsight

Write-Host "Hindsight を起動しています..."

$Process = Start-Process `
    -FilePath $Hindsight `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -PassThru

try {
    Write-Host "Hindsight の ready 待ち..."

    Wait-HindsightReady

    Write-Host "Hindsight ready: $McpUrl"

    Export-Memory

    # ========================================================
    # Resident loop
    # ========================================================

    while ($true) {
        if ($Process.HasExited) {
            throw "Hindsight プロセスが終了しました。ExitCode=$($Process.ExitCode)"
        }

        $NextRun = Get-NextHalfHour

        $WaitSeconds = [Math]::Max(
            1,
            [int][Math]::Ceiling(
                ($NextRun - (Get-Date)).TotalSeconds
            )
        )

        Write-Host "次回 memory.md 更新: $($NextRun.ToString("yyyy-MM-dd HH:mm:ss"))"

        Start-Sleep -Seconds $WaitSeconds

        if ($Process.HasExited) {
            throw "Hindsight プロセスが終了しました。ExitCode=$($Process.ExitCode)"
        }

        Export-Memory
    }
}
finally {
    if ($null -ne $Process) {
        try {
            if (-not $Process.HasExited) {
                Write-Host "Hindsight を停止しています..."

                Stop-Process `
                    -Id $Process.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }
}
