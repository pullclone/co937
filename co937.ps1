# co937.ps1
#
# PSReadLine history inspection and removal helpers.
#
# Aliases:
#   shiplog -> Show-PSReadLineHistoryFile
#   co937   -> Remove-PSReadLineHistoryLine
#   pshist  -> Show-PSReadLineHistoryFile
#   hforget -> Remove-PSReadLineHistoryLine
#
# Notes:
#   - No backup files are created, to avoid preserving sensitive history elsewhere.
#   - Matching history lines are deleted, not commented out.
#   - Removal clears the current session's PSReadLine in-memory history after writing.
#   - Other PowerShell sessions may still race by writing to the same history file.

function Get-Co937PSReadLineHistoryPath {
    [CmdletBinding()]
    param()

    try {
        $option = Get-PSReadLineOption -ErrorAction Stop
    }
    catch {
        throw "PSReadLine does not appear to be available in this session. Original error: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($option.HistorySavePath)) {
        throw "PSReadLine HistorySavePath is empty or unavailable."
    }

    $option.HistorySavePath
}

function Test-Co937IsWindows {
    [CmdletBinding()]
    param()

    $isWindowsValue = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue

    if ($isWindowsValue -eq $true) {
        return $true
    }

    # Windows PowerShell 5.1 does not define $IsWindows.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return $true
    }

    return $false
}

function Test-Co937IsMacOS {
    [CmdletBinding()]
    param()

    (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) -eq $true
}

function Show-PSReadLineHistoryFile {
    [CmdletBinding(DefaultParameterSetName = 'Tail')]
    param(
        [Parameter(ParameterSetName = 'Tail')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Tail = 50,

        [Parameter(Mandatory, ParameterSetName = 'Contains')]
        [string] $Contains,

        [Parameter(ParameterSetName = 'Open')]
        [switch] $Open,

        [Parameter(ParameterSetName = 'Path')]
        [switch] $Path
    )

    $historyPath = Get-Co937PSReadLineHistoryPath

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $historyPath
        return
    }

    if (-not (Test-Path -LiteralPath $historyPath)) {
        Write-Warning "PSReadLine history file does not exist yet: $historyPath"
        return
    }

    switch ($PSCmdlet.ParameterSetName) {
        'Contains' {
            Select-String -LiteralPath $historyPath -SimpleMatch -Pattern $Contains
            return
        }

        'Open' {
            if (Test-Co937IsWindows) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList @($historyPath)
                return
            }

            if (Test-Co937IsMacOS) {
                Start-Process -FilePath 'open' -ArgumentList @($historyPath)
                return
            }

            if (Get-Command xdg-open -ErrorAction SilentlyContinue) {
                Start-Process -FilePath 'xdg-open' -ArgumentList @($historyPath)
                return
            }

            if (Get-Command micro -ErrorAction SilentlyContinue) {
                & micro $historyPath
                return
            }

            Write-Warning "No opener found. History file path: $historyPath"
            return
        }

        default {
            Get-Content -LiteralPath $historyPath -Tail $Tail
            return
        }
    }
}

function Test-Co937HistoryLineMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Line,

        [Parameter(Mandatory)]
        [ValidateSet('Exact', 'Contains')]
        [string] $Mode,

        [Parameter(Mandatory)]
        [string] $Pattern
    )

    switch ($Mode) {
        'Exact' {
            return [string]::Equals($Line, $Pattern, [System.StringComparison]::Ordinal)
        }

        'Contains' {
            return $Line.Contains($Pattern)
        }
    }
}

function Remove-PSReadLineHistoryLine {
    [CmdletBinding(
        SupportsShouldProcess = $true,
        ConfirmImpact = 'High',
        DefaultParameterSetName = 'Contains'
    )]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Contains')]
        [string] $Contains,

        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Exact')]
        [string] $Exact,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $PreviewLimit = 20,

        [switch] $Force
    )

    $historyPath = Get-Co937PSReadLineHistoryPath

    if (-not (Test-Path -LiteralPath $historyPath)) {
        Write-Warning "PSReadLine history file does not exist: $historyPath"
        return
    }

    $mode = $PSCmdlet.ParameterSetName

    if ($mode -eq 'Exact') {
        $pattern = $Exact
        $description = "exact line"
    }
    else {
        $pattern = $Contains
        $description = "line containing literal text"
    }

    $initialLines = [System.IO.File]::ReadAllLines(
        $historyPath,
        [System.Text.Encoding]::UTF8
    )

    $initialMatches = @(
        for ($i = 0; $i -lt $initialLines.Count; $i++) {
            if (Test-Co937HistoryLineMatch -Line $initialLines[$i] -Mode $mode -Pattern $pattern) {
                [pscustomobject]@{
                    LineNumber = $i + 1
                    Line       = $initialLines[$i]
                }
            }
        }
    )

    if ($initialMatches.Count -eq 0) {
        Write-Host "No matching PSReadLine history entries found."
        return
    }

    Write-Host ""
    Write-Host "Matching PSReadLine history entries:"
    Write-Host ""

    foreach ($match in ($initialMatches | Select-Object -First $PreviewLimit)) {
        Write-Host ("[{0}] {1}" -f $match.LineNumber, $match.Line)
    }

    if ($initialMatches.Count -gt $PreviewLimit) {
        Write-Host ""
        Write-Host "... plus $($initialMatches.Count - $PreviewLimit) additional match(es)."
    }

    Write-Host ""
    Write-Warning "No backup file will be created. This avoids preserving sensitive history elsewhere."
    Write-Warning "If removal proceeds, this session's PSReadLine in-memory history will also be cleared."

    $action = "Remove $($initialMatches.Count) matching PSReadLine history entr$(if ($initialMatches.Count -eq 1) { 'y' } else { 'ies' })"
    $target = $historyPath

    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        return
    }

    if (-not $Force) {
        Write-Host ""
        $confirmation = Read-Host "Type DELETE to permanently remove the matching history entries"

        if ($confirmation -cne 'DELETE') {
            Write-Host "Aborted. No history entries were removed."
            return
        }
    }

    # Re-read immediately before writing to reduce, but not eliminate, race risk with other sessions.
    $latestLines = [System.IO.File]::ReadAllLines(
        $historyPath,
        [System.Text.Encoding]::UTF8
    )

    $keptLines = [string[]] @(
        for ($i = 0; $i -lt $latestLines.Count; $i++) {
            if (-not (Test-Co937HistoryLineMatch -Line $latestLines[$i] -Mode $mode -Pattern $pattern)) {
                $latestLines[$i]
            }
        }
    )

    $removedCount = $latestLines.Count - $keptLines.Count

    if ($removedCount -eq 0) {
        Write-Host "No matching entries remained at write time. Nothing was changed."
        return
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false

    [System.IO.File]::WriteAllLines(
        $historyPath,
        $keptLines,
        $utf8NoBom
    )

    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
        Write-Warning "Current session PSReadLine in-memory history was cleared."
    }
    catch {
        Write-Verbose "Unable to clear current PSReadLine in-memory history: $($_.Exception.Message)"
    }

    Write-Host "Removed $removedCount matching PSReadLine history entr$(if ($removedCount -eq 1) { 'y' } else { 'ies' })."
}

function Set-Co937ToolAlias {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Value
    )

    $existing = Get-Command -Name $Name -ErrorAction SilentlyContinue

    if ($null -eq $existing) {
        Set-Alias -Name $Name -Value $Value -Scope Global
        return
    }

    Write-Verbose "Alias '$Name' was not installed because an existing command named '$Name' was found."
}

# Thematic aliases.
Set-Co937ToolAlias -Name shiplog -Value Show-PSReadLineHistoryFile
Set-Co937ToolAlias -Name co937   -Value Remove-PSReadLineHistoryLine

# Generic aliases.
Set-Co937ToolAlias -Name pshist  -Value Show-PSReadLineHistoryFile
Set-Co937ToolAlias -Name hforget -Value Remove-PSReadLineHistoryLine

# Prevent the inspection/removal commands themselves from being written to PSReadLine history.
#
# This is intentionally broad enough to catch the aliases and the full function names.
# The sentinel prevents repeatedly wrapping a previous handler during profile reloads.
try {
    $global:Co937HistoryToolBlockedCommandPattern =
        '^\s*(?:&\s*)?(?:shiplog|co937|pshist|hforget|Show-PSReadLineHistoryFile|Remove-PSReadLineHistoryLine)\b'

    if (-not (Get-Variable -Scope Global -Name Co937HistoryToolHandlerInstalled -ErrorAction SilentlyContinue)) {
        $global:Co937HistoryToolPreviousAddToHistoryHandler = (Get-PSReadLineOption).AddToHistoryHandler
        $global:Co937HistoryToolHandlerInstalled = $true
    }

    Set-PSReadLineOption -AddToHistoryHandler {
        param([string] $line)

        if ($line -match $global:Co937HistoryToolBlockedCommandPattern) {
            return $false
        }

        $previousHandler = $global:Co937HistoryToolPreviousAddToHistoryHandler

        if ($null -ne $previousHandler) {
            return & $previousHandler $line
        }

        return $true
    }
}
catch {
    Write-Verbose "Unable to install PSReadLine AddToHistoryHandler: $($_.Exception.Message)"
}

# Safety key binding:
#
#   Ctrl+Alt+H
#
# Replaces the current command line with:
#
#   Remove-PSReadLineHistoryLine -Exact '...'
#
# It does not execute the removal. You can review/edit the generated command first.
try {
    if (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue) {
        Set-PSReadLineKeyHandler `
            -Chord 'Ctrl+Alt+h' `
            -BriefDescription 'PrepareExactPSReadLineHistoryRemoval' `
            -LongDescription 'Replace the current buffer with an exact PSReadLine history removal command.' `
            -ScriptBlock {
                $line = $null
                $cursor = $null

                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState(
                    [ref] $line,
                    [ref] $cursor
                )

                if ([string]::IsNullOrWhiteSpace($line)) {
                    return
                }

                # Single-quote escape for safe literal insertion into a PowerShell string.
                $escapedLine = $line -replace "'", "''"

                $replacement = "Remove-PSReadLineHistoryLine -Exact '$escapedLine'"

                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert($replacement)
            }
    }
}
catch {
    Write-Verbose "Unable to install PSReadLine key binding: $($_.Exception.Message)"
}
