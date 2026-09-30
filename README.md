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
- Searches complete history entries using case-sensitive literal text matching; `-IgnoreCase` is available
- Opens the history file in a platform-appropriate editor/viewer
- Removes complete entries, including multiline commands, by exact command or literal substring match
- Previews matching entry locations before deletion; contents are hidden unless `-ShowSensitivePreview` is supplied
- Creates no backup files, to avoid preserving sensitive values elsewhere
- Deletes matching lines instead of commenting them out
- Supports `-WhatIf` and `-Confirm`
- Requires typing `DELETE` before removal unless `-Force` is used
- Uses PSReadLine's history-file mutex and aborts if history changes after the preview
- Atomically replaces the history file with retained entries while preserving access permissions
- Clears the current session's PSReadLine in-memory history after removal
- Blocks statically named helper commands, including quoted and compound invocations, from being saved to PSReadLine history
- Preserves existing history-handler decisions and suppresses history recording if that handler fails
- Adds a `Ctrl+Alt+H` key binding to prepare a safe exact-removal command for the current buffer

## Requirements

- PowerShell 7.3+ with PSReadLine
- PSReadLine available in the session

Windows PowerShell 5.1 is not supported by the atomic writer. Use a regular UTF-8 history file; symbolic-link paths and read-only files are refused. The filesystem must support atomic file replacement.

## Installation

Clone or create the repository somewhere stable, for example:

```bash
mkdir -p ~/Dev
cd ~/Dev
git clone https://github.com/pullclone/co937.git co937
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

From PowerShell:

```powershell
$scriptPath = Join-Path $HOME 'Dev/co937/co937.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "co937.ps1 was not found: $scriptPath"
}

$profileDir = Split-Path -Parent $PROFILE
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
if (-not (Test-Path -LiteralPath $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE | Out-Null
}

$loader = ". '" + $scriptPath.Replace("'", "''") + "'"
if (-not (Select-String -LiteralPath $PROFILE -SimpleMatch -Pattern $loader -Quiet)) {
    Add-Content -LiteralPath $PROFILE -Value $loader -Encoding utf8
}
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

Search and removal are case-sensitive by default. To match different capitalization, use `-IgnoreCase` on either command:

```powershell
shiplog -Contains "token" -IgnoreCase
co937 -Contains "token" -IgnoreCase -WhatIf
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

Removal previews show entry locations and counts without printing command contents. If you need to inspect the contents, opt in explicitly:

```powershell
co937 -Contains "token" -ShowSensitivePreview -WhatIf
```

Displayed contents can be captured by terminal logging or transcripts. Inspection commands such as `shiplog` intentionally display history contents.

Successful removal also returns an object containing `HistoryPath`, `RemovedCount`, and `MemoryCleared`. Failed writes do not report success or clear memory.

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

The tool uses the same named mutex as supported PSReadLine versions, waits up to five seconds for it, and compares the current history with the previewed contents. If history changed, it aborts without removing anything; run the command again to review the new entries. This coordinates cooperating PSReadLine writers, but external editors and other writers that ignore the mutex can still race. Close other shells when removing sensitive entries.

Atomic replacement uses a temporary file in the history directory containing only retained entries. It receives the history file's access permissions before any contents are written and is deleted on ordinary failure. No backup or copy of removed entries is created. A process crash can leave a temporary file containing retained history; atomic replacement is not a guarantee of physical erasure from disk, snapshots, or backups.

The history filter recognizes statically named commands in PowerShell syntax. Dynamically resolved invocations, such as a helper name stored in a variable, and new user-defined aliases are outside that protection. Use the provided names directly, or use `Ctrl+Alt+H`, when a removal argument contains sensitive text.

Initialization failures and unsuccessful PSReadLine memory cleanup produce visible warnings. PSReadLine history is separate from PowerShell's `Get-History` session history and from transcripts; this helper does not clear those stores.

## Verification

Run the regression suite in a separate process:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

The suite uses synthetic files in its own temporary directory and mocks profile integration. It does not read or change your real history or profile. GitHub Actions runs the suite on Windows, Linux, and macOS.

## License

MIT License
