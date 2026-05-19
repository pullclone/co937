# co937

`co937` is a PowerShell PSReadLine history inspection and removal helper.

It provides small profile-loadable functions and aliases for viewing, searching, opening, and permanently removing entries from your PSReadLine history file at:

```powershell
(Get-PSReadLineOption).HistorySavePath
```

The tool executes shell hygiene tasks such as removing accidental secrets, tokens, malformed commands, or noisy history entries.

## Commands

| Alias     | Function                       | Purpose                                                       |
| --------- | ------------------------------ | ------------------------------------------------------------- |
| `shiplog` | `Show-PSReadLineHistoryFile`   | View, search, open, or print the PSReadLine history file path |
| `co937`   | `Remove-PSReadLineHistoryLine` | Remove matching PSReadLine history entries                    |
| `pshist`  | `Show-PSReadLineHistoryFile`   | Generic alias for viewing/searching history                   |
| `hforget` | `Remove-PSReadLineHistoryLine` | Generic alias for removing history entries                    |

## Features

- Uses the active PSReadLine history file from `(Get-PSReadLineOption).HistorySavePath`
- Shows recent history entries
- Searches history using literal text matching
- Opens the history file in a platform-appropriate editor/viewer
- Removes entries by exact line or literal substring match
- Previews matching entries before deletion
- Creates no backup files, to avoid preserving sensitive values elsewhere
- Deletes matching lines instead of commenting them out
- Supports `-WhatIf` and `-Confirm`
- Requires typing `DELETE` before removal unless `-Force` is used
- Re-reads the history file immediately before writing to reduce race-condition risk
- Clears the current session's PSReadLine in-memory history after removal
- Blocks the helper commands themselves from being saved to PSReadLine history
- Adds a `Ctrl+Alt+H` key binding to prepare a safe exact-removal command for the current buffer

## Requirements

- PowerShell 7+ recommended
- PSReadLine available in the session

This may also work in Windows PowerShell 5.1, but PowerShell 7+ is the primary target.

## Installation

Clone or create the repository somewhere stable, for example:

```bash
mkdir -p ~/Dev
cd ~/Dev
git clone <your-repo-url> co937
```

If you are creating it locally instead of cloning:

```bash
mkdir -p ~/Dev/co937
cd ~/Dev/co937
git init
```

Place `co937.ps1` in the repo:

```text
~/Dev/co937/co937.ps1
```

Then add it to your PowerShell profile.

From Bash or another shell:

```bash
pwsh -NoProfile -Command '
$profileDir = Split-Path -Parent $PROFILE

if (-not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}

if (-not (Test-Path -LiteralPath $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

$line = ". ''$HOME/Dev/co937/co937.ps1''"

if (-not (Select-String -LiteralPath $PROFILE -SimpleMatch -Pattern $line -Quiet -ErrorAction SilentlyContinue)) {
    Add-Content -LiteralPath $PROFILE -Value $line
}

Write-Host "Added co937 loader to profile:"
Write-Host $PROFILE
'
```

Restart PowerShell, or dot-source it immediately:

```powershell
. ~/Dev/co937/co937.ps1
```

Verify the aliases:

```powershell
Get-Alias shiplog, co937, pshist, hforget
```

## Usage

Show the PSReadLine history file path:

```powershell
shiplog -Path
```

Show the most recent history entries:

```powershell
shiplog
```

Show a specific number of recent entries:

```powershell
shiplog -Tail 100
```

Search the history file using literal text:

```powershell
shiplog -Contains "token"
```

Open the history file:

```powershell
shiplog -Open
```

Remove entries containing literal text:

```powershell
co937 -Contains "token"
```

Remove one exact history line:

```powershell
co937 -Exact "curl -H 'Authorization: Bearer example-token' https://example.invalid"
```

Preview what would happen without writing changes:

```powershell
co937 -Contains "token" -WhatIf
```

Skip the extra `DELETE` prompt:

```powershell
co937 -Contains "token" -Force
```

Use PowerShell confirmation behavior:

```powershell
co937 -Contains "token" -Confirm
```

## Safety key binding

`co937` installs this PSReadLine key binding:

```text
Ctrl+Alt+H
```

When your current command line contains a command you want to remove from history, press `Ctrl+Alt+H`.

It replaces the current buffer with an exact-removal command like:

```powershell
Remove-PSReadLineHistoryLine -Exact 'the original command line'
```

It does not execute the command automatically. Review it, then press Enter if correct.

This avoids parsing hazards from commands containing pipes, semicolons, quotes, redirects, or other shell syntax.

## Important safety notes

`co937` intentionally does not create backup files. This helps avoid copying sensitive history entries to another location.

After removal, it attempts to clear the current session's PSReadLine in-memory history:

```powershell
[Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory()
```

This means your current session's up-arrow history may be wiped.

Other open PowerShell sessions may still have the removed entries in memory or may write to the same history file later. Close or restart other sessions after removing sensitive entries.

The tool re-reads the history file immediately before writing, but race conditions are still possible if multiple shells are writing to the PSReadLine history file at the same time.

## License

MIT License
