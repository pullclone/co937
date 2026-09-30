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
        [switch] $Path,

        [switch] $IgnoreCase
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
            $content = [IO.File]::ReadAllText($historyPath, [Text.UTF8Encoding]::new($false, $true))
            foreach ($entry in @(Read-Co937HistorySnapshot -Content $content)) {
                if (Test-Co937HistoryLineMatch -Line $entry.Text -Mode Contains -Pattern $Contains -IgnoreCase:$IgnoreCase) {
                    $match = $entry.Text | Select-String -SimpleMatch -Pattern $Contains -CaseSensitive:(-not $IgnoreCase)
                    $match.LineNumber = $entry.LineNumber
                    $match.Path = $historyPath
                    $match
                }
            }
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


function Read-Co937HistorySnapshot {
    param([AllowEmptyString()][string] $Content)
    $entries = [Collections.Generic.List[object]]::new()
    $raw = ''; $text = ''; $start = 1; $number = 0
    foreach ($match in [regex]::Matches($Content, '([^\r\n]*)(\r\n|\n|\r|$)')) {
        if ($match.Length -eq 0) { continue }
        $number++; $line = $match.Groups[1].Value; $raw += $match.Value
        if ($line.EndsWith([string][char]96, [StringComparison]::Ordinal)) {
            $text += $line.Substring(0, $line.Length - 1) + [char]10
        } else {
            $text += $line
            $entries.Add([pscustomobject]@{ LineNumber = $start; Text = $text; Raw = $raw })
            $raw = ''; $text = ''; $start = $number + 1
        }
    }
    if ($raw.Length -gt 0) { throw 'History ends in an incomplete multiline entry. No changes were made.' }
    $entries.ToArray()
}

function Test-Co937HistoryLineMatch {
    param([AllowEmptyString()][string] $Line, [ValidateSet('Exact','Contains')][string] $Mode,
        [string] $Pattern, [switch] $IgnoreCase)
    $comparison = [StringComparison]::Ordinal
    if ($IgnoreCase) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    $Pattern = $Pattern.Replace([string][char]13 + [char]10, [string][char]10)
    if ($Mode -eq 'Exact') { return [string]::Equals($Line, $Pattern, $comparison) }
    return $Line.IndexOf($Pattern, $comparison) -ge 0
}

function Test-Co937HistoryToolCommand {
    param([AllowEmptyString()][string] $Line)
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$parseErrors)
    $names = @('shiplog','co937','pshist','hforget','Show-PSReadLineHistoryFile','Remove-PSReadLineHistoryLine')
    foreach ($command in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true)) {
        $commandName = $command.GetCommandName()
        if ($null -ne $commandName -and ($commandName.Split('\')[-1] -in $names)) { return $true }
    }
    if ($parseErrors.Count -gt 0) {
        foreach ($token in $tokens) {
            if ($token.Text.Trim("'""") -in $names) { return $true }
        }
    }
    return $false
}

function Invoke-Co937PreviousHistoryHandler {
    param($Handler, [string] $Line)
    if ($null -eq $Handler) { return $true }
    if ($Handler -is [scriptblock]) { return & $Handler $Line }
    return $Handler.Invoke($Line)
}

function Get-Co937HistoryMutexName {
    param([string] $Path)
    if (Test-Co937IsWindows) { $Path = $Path.ToLower() }
    # Matches PSReadLine's FNV-1a hash of both bytes of each UTF-16 character.
    [ulong] $hash = 2166136261
    foreach ($byte in [Text.Encoding]::Unicode.GetBytes($Path)) {
        $hash = (($hash -bxor [ulong]$byte) * 16777619) -band 4294967295
    }
    'PSReadLineHistoryFile_' + $hash.ToString()
}

function Write-Co937HistoryAtomically {
    param([string] $Path, [AllowEmptyString()][string] $Content)
    $temporaryPath = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.co937-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        # Copy permissions before writing retained history. Removed entries never enter the temporary file.
        if (Test-Co937IsWindows) {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $accessRules = [Security.AccessControl.FileSecurity]::new()
            $accessRules.SetSecurityDescriptorSddlForm(
                $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access),
                [Security.AccessControl.AccessControlSections]::Access)
            $stream = [IO.FileSystemAclExtensions]::Create(
                [IO.FileInfo]::new($temporaryPath), [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None,
                4096, [IO.FileOptions]::None, $accessRules)
            # Creation can materialize inherited rules as explicit rules on Windows.
            # Reapply the source DACL before writing any history to avoid duplicated grants.
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($temporaryPath), $accessRules)
        } else {
            $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            [IO.File]::SetUnixFileMode($temporaryPath, [IO.File]::GetUnixFileMode($Path))
        }
        $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        if (Test-Co937IsWindows) {
            # ReplaceFile merges DACLs and can turn inherited rules into explicit duplicates.
            # A same-directory overwrite rename retains the temporary file's restored DACL.
            [IO.File]::Move($temporaryPath, $Path, $true)
        } else {
            [IO.File]::Replace($temporaryPath, $Path, [Management.Automation.Language.NullString]::Value)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Remove-PSReadLineHistoryLine {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Contains')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Contains')][string] $Contains,
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Exact')][string] $Exact,
        [ValidateRange(1, [int]::MaxValue)][int] $PreviewLimit = 20,
        [switch] $Force, [switch] $IgnoreCase, [switch] $ShowSensitivePreview
    )
    $historyPath = Get-Co937PSReadLineHistoryPath
    if (-not [IO.File]::Exists($historyPath)) {
        Write-Warning "PSReadLine history file does not exist: $historyPath"
        return
    }
    $historyPath = [IO.Path]::GetFullPath($historyPath)
    if (([IO.File]::GetAttributes($historyPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing to replace a symbolic-link history file. Use a regular HistorySavePath.'
    }
    if (([IO.File]::GetAttributes($historyPath) -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        throw 'History file is read-only. No changes were made.'
    }
    $mode = $PSCmdlet.ParameterSetName; $pattern = $Contains
    if ($mode -eq 'Exact') { $pattern = $Exact }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $initialContent = [IO.File]::ReadAllText($historyPath, $encoding)
    $entries = @(Read-Co937HistorySnapshot -Content $initialContent)
    $matches = @($entries | Where-Object {
        Test-Co937HistoryLineMatch -Line $_.Text -Mode $mode -Pattern $pattern -IgnoreCase:$IgnoreCase
    })
    if ($matches.Count -eq 0) { Write-Host 'No matching PSReadLine history entries found.'; return }
    Write-Host "Matching PSReadLine history entries: $($matches.Count)"
    foreach ($match in ($matches | Select-Object -First $PreviewLimit)) {
        if ($ShowSensitivePreview) { Write-Host ("[{0}] {1}" -f $match.LineNumber, $match.Text) }
        else { Write-Host ("[{0}] [content hidden; use -ShowSensitivePreview to display]" -f $match.LineNumber) }
    }
    if ($matches.Count -gt $PreviewLimit) { Write-Host "... plus $($matches.Count - $PreviewLimit) additional match(es)." }
    Write-Warning 'No backup file will be created. Current session PSReadLine history will be cleared after removal.'
    if (-not $PSCmdlet.ShouldProcess($historyPath, "Remove $($matches.Count) matching PSReadLine history entries")) { return }
    if (-not $Force -and (Read-Host 'Type DELETE to permanently remove the matching history entries') -cne 'DELETE') {
        Write-Host 'Aborted. No history entries were removed.'; return
    }
    $mutex = [Threading.Mutex]::new($false, (Get-Co937HistoryMutexName -Path $historyPath))
    $acquired = $false; $historyStream = $null; $reader = $null
    try {
        try { $acquired = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'History is busy. No changes were made; retry when other sessions are idle.' }
        if (([IO.File]::GetAttributes($historyPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'History path became a symbolic link. No changes were made.'
        }
        if (([IO.File]::GetAttributes($historyPath) -band [IO.FileAttributes]::ReadOnly) -ne 0) {
            throw 'History file became read-only. No changes were made.'
        }
        # Exclude writes during validation; the PSReadLine mutex covers replacement.
        $historyStream = [IO.File]::Open($historyPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read -bor [IO.FileShare]::Delete)
        $reader = [IO.StreamReader]::new($historyStream, $encoding, $true)
        $latestContent = $reader.ReadToEnd()
        if (-not [string]::Equals($initialContent, $latestContent, [StringComparison]::Ordinal)) {
            throw 'History changed after preview. No changes were made; run the command again to review the new history.'
        }
        $kept = @($entries | Where-Object {
            -not (Test-Co937HistoryLineMatch -Line $_.Text -Mode $mode -Pattern $pattern -IgnoreCase:$IgnoreCase)
        })
        $newContent = ($kept | ForEach-Object { $_.Raw }) -join ''
        $reader.Dispose(); $reader = $null; $historyStream = $null
        Write-Co937HistoryAtomically -Path $historyPath -Content $newContent
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $historyStream) { $historyStream.Dispose() }
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    $memoryCleared = $false
    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
        $memoryCleared = $true
        Write-Warning 'Current session PSReadLine in-memory history was cleared.'
    } catch { Write-Warning 'File entries were removed, but current PSReadLine memory could not be cleared. Restart this shell.' }
    Write-Host "Removed $($matches.Count) matching PSReadLine history entries."
    [pscustomobject]@{ HistoryPath = $historyPath; RemovedCount = $matches.Count; MemoryCleared = $memoryCleared }
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

    $currentHandler = (Get-PSReadLineOption).AddToHistoryHandler
    $installedHandler = Get-Variable -Scope Global -Name Co937HistoryToolInstalledHandler -ValueOnly -ErrorAction SilentlyContinue
    $legacyInstalled = Get-Variable -Scope Global -Name Co937HistoryToolHandlerInstalled -ValueOnly -ErrorAction SilentlyContinue
    # Preserve the saved delegate when upgrading an already-loaded original helper.
    if (-not [object]::ReferenceEquals($currentHandler, $installedHandler) -and
        -not ($legacyInstalled -and $null -eq $installedHandler)) {
        $global:Co937HistoryToolPreviousAddToHistoryHandler = $currentHandler
    }

    Set-PSReadLineOption -AddToHistoryHandler {
        param([string] $line)

        if (Test-Co937HistoryToolCommand -Line $line) {
            return $false
        }

        $previousHandler = $global:Co937HistoryToolPreviousAddToHistoryHandler

        if ($null -ne $previousHandler) {
            try { return Invoke-Co937PreviousHistoryHandler -Handler $previousHandler -Line $line }
            catch {
                Write-Warning 'The previous history handler failed. This command will not be added to history.'
                return $false
            }
        }

        return $true
    }
    $global:Co937HistoryToolHandlerInstalled = $true
    $global:Co937HistoryToolInstalledHandler = (Get-PSReadLineOption).AddToHistoryHandler
}
catch {
    Write-Warning "Unable to install co937 history protection: $($_.Exception.Message)"
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
    Write-Warning "Unable to install co937 safety key binding: $($_.Exception.Message)"
}
