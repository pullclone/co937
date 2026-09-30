# Run in an isolated process: pwsh -NoProfile -File ./tests/Run-Tests.ps1
$ErrorActionPreference = 'Stop'
$script:checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
$root = Split-Path -Parent $PSScriptRoot
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('co937-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
$script:historyPath = Join-Path $testDirectory 'history.txt'
$script:handler = [Func[string,object]] { param($line) 'MemoryOnly' }
$script:binding = $null
function Get-PSReadLineOption { [pscustomobject]@{ HistorySavePath = $script:historyPath; AddToHistoryHandler = $script:handler } }
function Set-PSReadLineOption { param([Func[string,object]] $AddToHistoryHandler) $script:handler = $AddToHistoryHandler }
function Set-PSReadLineKeyHandler { param($Chord, $BriefDescription, $LongDescription, $ScriptBlock) $script:binding = $ScriptBlock }
function Read-Host { param($Prompt) if ($script:changeDuringConfirmation) { [IO.File]::AppendAllText($script:historyPath, "new entry`n") }; return $script:confirmation }
function Set-Fixture([string] $Content) { [IO.File]::WriteAllText($script:historyPath, $Content, [Text.UTF8Encoding]::new($false)) }
function Get-Fixture { [IO.File]::ReadAllText($script:historyPath) }
function Get-FixturePermissions {
    if (-not (Test-Co937IsWindows)) { return [IO.File]::GetUnixFileMode($script:historyPath) }
    $acl = Get-Acl -LiteralPath $script:historyPath
    # Windows replacement can normalize DACL control flags (for example D:P to D:PAI).
    # Compare every access rule and inheritance protection, rather than the SDDL spelling.
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.IdentityReference.Value, [int]$_.FileSystemRights,
            $_.AccessControlType, $_.InheritanceFlags, $_.PropagationFlags, $_.IsInherited
    } | Sort-Object)
    [pscustomobject]@{ Protected = $acl.AreAccessRulesProtected; Rules = $rules } | ConvertTo-Json -Compress
}
try {
    . (Join-Path $root 'co937.ps1')
    Assert-True ($script:handler.Invoke('Get-Date') -eq 'MemoryOnly') 'delegate result preserved'
    foreach ($line in @("co937 -Exact 'secret'", "& 'co937' -Exact 'secret'", "Get-Date; hforget secret", "if (`$true) { co937 secret }")) {
        Assert-True ($script:handler.Invoke($line) -eq $false) "helper input blocked: $line"
    }
    Assert-True (-not (Test-Co937HistoryToolCommand 'co937-extra hello')) 'unrelated command allowed'
    Assert-True (-not (Test-Co937HistoryToolCommand "Write-Output 'co937'")) 'ordinary argument allowed'
    Assert-True (Test-Co937HistoryToolCommand 'example\co937 secret') 'module-qualified helper blocked'
    . (Join-Path $root 'co937.ps1')
    Assert-True ($script:handler.Invoke('Get-Date') -eq 'MemoryOnly') 'reload does not recurse'
    $script:handler = [Func[string,object]] { param($line) 'replacement' }
    . (Join-Path $root 'co937.ps1')
    Assert-True ($script:handler.Invoke('Get-Date') -eq 'replacement') 'reload preserves a replacement handler'
    Remove-Variable -Scope Global -Name Co937HistoryToolInstalledHandler
    . (Join-Path $root 'co937.ps1')
    Assert-True ($script:handler.Invoke('Get-Date') -eq 'replacement') 'legacy loaded helper upgrades without recursion'
    $global:Co937HistoryToolPreviousAddToHistoryHandler = [Func[string,object]] { throw 'synthetic handler failure' }
    Assert-True ($script:handler.Invoke('Get-Date') -eq $false) 'handler errors fail closed'
    Assert-True ($null -ne $script:binding) 'key binding installed'

    # Verify mutex naming against the installed PSReadLine implementation without invoking its history I/O.
    Import-Module PSReadLine
    $hashType = [Microsoft.PowerShell.PSConsoleReadLine].Assembly.GetType('Microsoft.PowerShell.FNV1a32Hash')
    $hashMethod = $hashType.GetMethod('ComputeHash', [Reflection.BindingFlags]'Static,NonPublic')
    $hashPath = $script:historyPath
    if (Test-Co937IsWindows) { $hashPath = $hashPath.ToLower() }
    $expectedMutex = 'PSReadLineHistoryFile_' + $hashMethod.Invoke($null, @([string]$hashPath)).ToString()
    Assert-True ((Get-Co937HistoryMutexName $script:historyPath) -eq $expectedMutex) 'mutex matches PSReadLine'

    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'co937.ps1'), [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) 'script parses without errors'

    Set-Fixture "TOKEN`ntoken`nkeep`n"
    Assert-True (@(Show-PSReadLineHistoryFile -Contains token).Count -eq 1) 'search defaults to case sensitive'
    Assert-True (@(Show-PSReadLineHistoryFile -Contains token -IgnoreCase).Count -eq 2) 'ignore-case search'
    $preview = @(Remove-PSReadLineHistoryLine -Contains token -WhatIf -Confirm:$false 6>&1)
    Assert-True (-not (($preview | Out-String) -cmatch '\[2\] token')) 'default preview hides command contents'
    $sensitivePreview = @(Remove-PSReadLineHistoryLine -Contains token -ShowSensitivePreview -WhatIf -Confirm:$false 6>&1)
    Assert-True (($sensitivePreview | Out-String) -cmatch '\[2\] token') 'explicit preview shows contents'
    $permissionsBefore = Get-FixturePermissions
    $result = Remove-PSReadLineHistoryLine -Contains token -Force -Confirm:$false
    Assert-True ($result.RemovedCount -eq 1 -and (Get-Fixture) -ceq "TOKEN`nkeep`n") 'only case-sensitive match removed'
    $permissionsAfter = Get-FixturePermissions
    Assert-True ($permissionsBefore -eq $permissionsAfter) "file permissions preserved; before: $permissionsBefore; after: $permissionsAfter"
    $result = Remove-PSReadLineHistoryLine -Contains token -IgnoreCase -Force -Confirm:$false
    Assert-True ((Get-Fixture) -ceq "keep`n") 'ignore-case removal'

    if (Test-Co937IsWindows) {
        # Reproduce Windows DACL normalization using a protected, explicitly assigned ACL.
        $originalPath = $script:historyPath
        $script:historyPath = Join-Path $testDirectory 'protected-history.txt'
        try {
            $acl = [Security.AccessControl.FileSecurity]::new()
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow'))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'ExecuteFile', 'Deny'))
            $stream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($script:historyPath),
                [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write,
                [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $acl)
            $stream.Dispose()
            Set-Fixture "secret`nkeep`n"
            $permissionsBefore = Get-FixturePermissions
            $result = Remove-PSReadLineHistoryLine -Exact secret -Force -Confirm:$false
            Assert-True ((Get-Fixture) -ceq "keep`n") 'protected history removal'
            Assert-True ($permissionsBefore -ceq (Get-FixturePermissions)) 'protected allow and deny rules preserved'
        } finally { $script:historyPath = $originalPath }
    }

    $command = "Write-Output 'α'`nWrite-Output 'secret'"
    $serialized = $command.Replace("`n", ([string][char]96 + [char]10)) + "`n"
    Set-Fixture ($serialized + "keep`r`nlast")
    $found = @(Show-PSReadLineHistoryFile -Contains secret)
    Assert-True ($found.Count -eq 1 -and $found[0].LineNumber -eq 1 -and $found[0].Line -ceq $command) 'search returns complete multiline entry'
    $result = Remove-PSReadLineHistoryLine -Exact $command -Force -Confirm:$false
    Assert-True ($result.RemovedCount -eq 1 -and (Get-Fixture) -ceq "keep`r`nlast") 'exact multiline removal preserves retained bytes'
    Set-Fixture ($serialized + "keep`n")
    $result = Remove-PSReadLineHistoryLine -Contains secret -Force -Confirm:$false
    Assert-True ((Get-Fixture) -ceq "keep`n") 'substring removes entire multiline entry'
    Set-Fixture "secret`nsecret`n"
    $result = Remove-PSReadLineHistoryLine -Exact secret -Force -Confirm:$false
    Assert-True ($result.RemovedCount -eq 2 -and (Get-Fixture) -eq '') 'duplicates and empty output'

    Set-Fixture "secret`nkeep`n"
    Remove-PSReadLineHistoryLine -Contains secret -WhatIf -Confirm:$false | Out-Null
    Assert-True ((Get-Fixture) -ceq "secret`nkeep`n") 'WhatIf never writes'
    $script:confirmation = 'NO'
    Remove-PSReadLineHistoryLine -Contains secret -Confirm:$false | Out-Null
    Assert-True ((Get-Fixture) -ceq "secret`nkeep`n") 'cancellation never writes'
    $script:confirmation = 'DELETE'; $script:changeDuringConfirmation = $true
    $failed = $false
    try { Remove-PSReadLineHistoryLine -Contains secret -Confirm:$false | Out-Null } catch { $failed = $_.Exception.Message -like '*changed after preview*' }
    Assert-True ($failed -and (Get-Fixture) -ceq "secret`nkeep`nnew entry`n") 'concurrent change aborts without losing appended entry'
    $script:changeDuringConfirmation = $false

    Set-Fixture ("secret`nunfinished" + [char]96 + "`n")
    $failed = $false
    try { Remove-PSReadLineHistoryLine -Contains secret -Force -Confirm:$false | Out-Null } catch { $failed = $_.Exception.Message -like '*incomplete multiline*' }
    Assert-True $failed 'incomplete multiline history fails safely'
    Set-Fixture "secret`nkeep`n"
    $item = Get-Item -LiteralPath $script:historyPath
    try {
        $item.IsReadOnly = $true; $failed = $false
        try { Remove-PSReadLineHistoryLine -Contains secret -Force -Confirm:$false | Out-Null } catch { $failed = $true }
        Assert-True ($failed -and (Get-Fixture) -ceq "secret`nkeep`n") 'write failure preserves original'
    } finally { $item.IsReadOnly = $false }
    Assert-True (@(Get-ChildItem -LiteralPath $testDirectory -Force -Filter '.co937-*.tmp').Count -eq 0) 'temporary files cleaned after success and failure'
    # A writer holding the destination prevents replacement. Failure must preserve data and remove the temporary file.
    $held = $null
    $replacementTarget = $script:historyPath
    if (Test-Co937IsWindows) {
        $held = [IO.File]::Open($script:historyPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    } else {
        # Unix allows replacing an open file; use an invalid directory destination to force replacement failure.
        $replacementTarget = Join-Path $testDirectory 'blocked-target'
        [IO.Directory]::CreateDirectory($replacementTarget) | Out-Null
    }
    try {
        $failed = $false
        try { Write-Co937HistoryAtomically -Path $replacementTarget -Content 'keep' } catch { $failed = $true }
        Assert-True ($failed -and (Get-Fixture) -ceq "secret`nkeep`n") 'atomic replacement failure preserves original'
    } finally { if ($null -ne $held) { $held.Dispose() } }
    Assert-True (@(Get-ChildItem -LiteralPath $testDirectory -Force -Filter '.co937-*.tmp').Count -eq 0) 'failed replacement cleans temporary file'
    Write-Host "PASS: $script:checks checks"
} finally {
    # Delete only this test's explicitly created temporary directory.
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
