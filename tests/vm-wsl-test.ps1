param([string]$Root, [string]$TestDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:StatePath = Join-Path $TestDirectory 'state.json'
$script:CallsPath = Join-Path $TestDirectory 'calls.jsonl'
$env:LOCALAPPDATA = Join-Path $TestDirectory "Windows user's data"
$script:NextKeeperId = 3000
function Assert-Test { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Save-State { param($State) $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:StatePath -Encoding utf8 }
function Read-State { return (Get-Content -Raw -LiteralPath $script:StatePath | ConvertFrom-Json) }
function Read-Calls { return @(Get-Content -LiteralPath $script:CallsPath | Where-Object { $_.Trim() } | ForEach-Object { ConvertFrom-Json -InputObject $_ }) }
function Reset-Test {
    if (Test-Path -LiteralPath $env:LOCALAPPDATA) { Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force }
    Save-State @{ names = @('ordinary-ubuntu'); running = @(); configured = $true }
    Set-Content -LiteralPath $script:CallsPath -Value ''
    $script:Processes = @{}
    $script:CommandLines = @{}
    $script:Started = @()
    $script:Stopped = @()
}
function Set-TestState {
    param([hashtable]$Values)
    $state = Read-State
    foreach ($key in $Values.Keys) { $state | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] -Force }
    Save-State $state
}
function Existing-Test {
    Set-TestState @{ names = @('ordinary-ubuntu', 'multica-squad'); running = @('multica-squad') }
}
function Deny-Test {
    param([scriptblock]$Operation)
    $denied = $false
    try { & $Operation } catch { $denied = $true }
    Assert-Test $denied 'Operation unexpectedly succeeded'
}
function Assert-NoMutation {
    foreach ($call in @(Read-Calls)) {
        Assert-Test ($call.args[0] -in @('--version', '--list', '-d')) 'WSL lifecycle was changed'
        if ($call.args[0] -eq '-d') { Assert-Test (($call.args -join ' ') -match 'multica daemon status') 'Unexpected guest mutation' }
    }
    Assert-Test ($script:Started.Count -eq 0 -and $script:Stopped.Count -eq 0) 'Keeper was changed'
}
Reset-Test
. (Join-Path $Root 'vm/wsl.ps1')
Assert-Test (@(Read-Calls).Count -eq 0) 'Dot sourcing invoked WSL'
function Assert-SquadWindows { }
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string[]]$ArgumentList, [string]$WindowStyle, [switch]$PassThru)
    Assert-Test ($WindowStyle -eq 'Hidden' -and $PassThru) 'Keeper window is not hidden'
    Assert-Test ($env:WSL_UTF8 -eq '1') 'Keeper does not use UTF-8'
    $state = Read-State
    if ($state.PSObject.Properties['fail'] -and $state.fail -eq 'keeper-start') { throw 'intentional keeper startup failure' }
    $script:NextKeeperId++
    $keeper = [pscustomobject]@{ Id = $script:NextKeeperId; Path = $FilePath; StartTime = [DateTime]::UtcNow }
    $script:Processes[$keeper.Id] = $keeper
    $script:CommandLines[$keeper.Id] = ('"' + $FilePath + '" ' + ($ArgumentList -join ' '))
    $script:Started += $keeper.Id
    return $keeper
}
function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    return $script:Processes[$Id]
}
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Filter)
    Assert-Test ($ClassName -eq 'Win32_Process' -and $Filter -match '^ProcessId = (\d+)$') 'Unsafe process query'
    return [pscustomobject]@{ CommandLine = $script:CommandLines[[int]$Matches[1]] }
}
function Stop-Process {
    [CmdletBinding()]
    param([int]$Id, [switch]$Force)
    Assert-Test ($script:Processes.ContainsKey($Id)) 'Stopped an unknown PID'
    $script:Stopped += $Id
    $script:Processes.Remove($Id)
}
function Read-Host { param([string]$Prompt) $script:Prompt = $Prompt; return $script:Answer }

Invoke-SquadWslVm -Action create
$calls = @(Read-Calls)
$install = @($calls | Where-Object { $_.args[0] -eq '--install' })[0]
$location = Join-Path (Join-Path $env:LOCALAPPDATA 'multica-squad') 'multica-squad'
Assert-Test (($install.args -join '|') -eq "--install|Ubuntu-24.04|--name|multica-squad|--location|$location|--no-launch|--version|2") 'Wrong installation arguments'
Assert-Test (@($calls | Where-Object { $_.utf8 -ne '1' }).Count -eq 0) 'WSL_UTF8 was not set'
Assert-Test ((Read-State).user -eq 'agent') 'Default guest user was not provisioned'
Assert-Test ($script:Started.Count -eq 1) 'Keeper was not started'
$terminateIndex = -1
$verifyIndex = -1
for ($i = 0; $i -lt $calls.Count; $i++) {
    if ($calls[$i].args[0] -eq '--terminate') { $terminateIndex = $i }
    if (($calls[$i].args -join '|') -eq '-d|multica-squad|--exec|bash|/usr/local/lib/multica-squad-vm/verify.sh|wsl') { $verifyIndex = $i }
}
Assert-Test ($terminateIndex -ge 0 -and $verifyIndex -gt $terminateIndex) 'Isolation was not applied before verification'
Assert-Test ((Read-State).record.Name -eq 'multica-squad') 'Keeper record was not kept in the guest'
Invoke-SquadWslVm -Action start
Assert-Test ($script:Started.Count -eq 1) 'Repeated start duplicated the keeper'
Invoke-SquadWslVm -Action verify
Invoke-SquadWslVm -Action stop
Assert-Test ($script:Stopped.Count -eq 1 -and (Read-State).running.Count -eq 0) 'Stop did not stop the keeper and distro'
Write-Output 'PASS WSL: install, provision as root, reboot, hidden keeper and guest verification; repeated start reuses the keeper'

Reset-Test
Invoke-SquadWslVm -Action create -Name 'custom_vm' -User 'worker'
Assert-Test ((Read-State).user -eq 'worker' -and (Read-State).names -contains 'custom_vm') 'Custom name or user was lost'
Reset-Test
Existing-Test
Deny-Test { Invoke-SquadWslVm -Action create }
Assert-NoMutation
foreach ($version in @('WSL version: 2.6.0.0', 'unknown')) {
    Reset-Test
    Set-TestState @{ version = $version }
    Deny-Test { Invoke-SquadWslVm -Action create }
    Assert-NoMutation
}
foreach ($parameters in @(@{Action='unknown'}, @{Action='create';Name='../escape'}, @{Action='create';User='root'}, @{Action='create';Force=$true}, @{Action='start';User='worker'}, @{Action='start';Yes=$true})) {
    Reset-Test
    Deny-Test { Invoke-SquadWslVm @parameters }
    Assert-Test (@(Read-Calls).Count -eq 0) 'Invalid arguments reached WSL'
}
Write-Output 'PASS WSL: custom name and user, duplicate name, unsupported version and invalid arguments'

foreach ($change in @(@{fail='--install'}, @{partial_install=$true}, @{no_registration=$true}, @{fail='provision'}, @{fail='verify'}, @{fail='keeper-start'}, @{fail='pid-write'}, @{fail='pid-read'})) {
    Reset-Test
    Set-TestState $change
    Deny-Test { Invoke-SquadWslVm -Action create }
    Assert-Test ((Read-State).names -notcontains 'multica-squad') 'Failed creation left a distro'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'multica-squad'))) 'Failed creation left files'
    Assert-Test ((Read-State).names -contains 'ordinary-ubuntu') 'Unrelated distro was removed'
}
Write-Output 'PASS WSL: failed installation, registration, provisioning, keepalive and verification remove only the new distro and its directory'

foreach ($daemon in @(@{status='running';active_task_count=1}, @{status='running';active_task_count=0;resource_wait_task_count=2}, @{status='running'}, @{status='running';active_task_count='0'}, @{status='running';active_task_count=-1}, @{status='unknown'}, 'invalid json')) {
    foreach ($operation in @('stop','delete')) {
        Reset-Test
        Existing-Test
        Set-TestState @{daemon=$daemon}
        if ($operation -eq 'delete') { Deny-Test { Invoke-SquadWslVm -Action delete -Yes } }
        else { Deny-Test { Invoke-SquadWslVm -Action stop } }
        Assert-NoMutation
    }
}
foreach ($change in @(@{daemon=@{status='running';active_task_count=0;running_task_count=0}}, @{daemon=@{status='stopped'};status_code=1}, @{daemon=@{status='not_running'};status_code=1}, @{cli_missing=$true})) {
    Reset-Test
    Existing-Test
    Set-TestState $change
    Invoke-SquadWslVm -Action stop
    Assert-Test ((Read-State).running.Count -eq 0) 'Safe stop was refused'
}
Reset-Test
Existing-Test
Set-TestState @{status_code=1}
Deny-Test { Invoke-SquadWslVm -Action stop }
Assert-NoMutation
Reset-Test
Existing-Test
Set-TestState @{daemon=@{status='running';active_task_count=3}}
Invoke-SquadWslVm -Action stop -Force
Assert-Test (@(Read-Calls | Where-Object { ($_.args -join ' ') -match 'daemon status' }).Count -eq 0) 'Force queried tasks'
Write-Output 'PASS WSL: task count maximum, busy or unknown states, stopped daemon, missing CLI and explicit Force'

Reset-Test
Existing-Test
$script:Answer = 'n'
Deny-Test { Invoke-SquadWslVm -Action delete }
Assert-NoMutation
$script:Answer = 'y'
Invoke-SquadWslVm -Action delete
Assert-Test ($script:Prompt -match 'multica-squad') 'Delete confirmation omitted the name'
Assert-Test ((Read-State).names -notcontains 'multica-squad') 'Confirmed delete failed'
foreach ($mismatch in @('StartedAt', 'Path', 'Arguments')) {
    Reset-Test
    Invoke-SquadWslVm -Action create
    $owned = $script:Started[0]
    switch ($mismatch) {
        'StartedAt' { $script:Processes[$owned].StartTime = [DateTime]::UtcNow.AddMinutes(-1) }
        'Path' { $script:Processes[$owned].Path = 'another.exe' }
        'Arguments' { $script:CommandLines[$owned] = 'wsl.exe -d ordinary-ubuntu --exec sleep infinity' }
    }
    $script:Answer = 'n'
    Invoke-SquadWslVm -Action delete -Yes -Force
    Assert-Test ($script:Stopped -notcontains $owned) 'PID reuse killed another process'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'multica-squad'))) 'Delete left a host directory'
    Assert-Test (Test-Path -LiteralPath $env:LOCALAPPDATA) 'Delete removed LOCALAPPDATA'
}
Write-Output 'PASS WSL: delete confirmation and Yes; stale PID is not stopped and host installation directory is removed'

Reset-Test
Existing-Test
Set-TestState @{running=@()}
Deny-Test { Invoke-SquadWslVm -Action verify }
Invoke-SquadWslVm -Action stop
Assert-Test (@(Read-Calls | Where-Object { $_.args[0] -eq '-d' -or $_.args[0] -eq '--terminate' }).Count -eq 0) 'Stopped distro was booted by stop'
Write-Output 'PASS WSL: verify requires a running distro and stop does not boot a stopped distro'
