[CmdletBinding()]
param(
    [string]$Action,
    [string]$Name = 'multica-squad',
    [string]$User = 'agent',
    [switch]$Force,
    [switch]$Yes
)

function Assert-SquadWindows {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows の PowerShell で実行してください。' }
}

# PowerShell 5.1 の native 引数渡しでも、空白・引用符・末尾の \ を保つ。
function ConvertTo-SquadNativeArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value.Replace("`r`n", "`n"), '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-SquadWsl {
    param([string[]]$WslArguments, [switch]$AllowFailure)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:SquadWslPath
    $info.Arguments = (($WslArguments | ForEach-Object { ConvertTo-SquadNativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.EnvironmentVariables['WSL_UTF8'] = '1'
    # WSLENV に挙がったホストの変数（トークンなど）を、ゲストへ渡さない。
    $info.EnvironmentVariables.Remove('WSLENV')
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'wsl.exe を起動できません。' }
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $code = $process.ExitCode
    } finally { $process.Dispose() }
    if ($code -ne 0 -and -not $AllowFailure) { throw "wsl.exe が失敗しました（終了コード $code）。" }
    return [pscustomobject]@{ Code = $code; Output = $output.Trim() }
}

function Get-SquadDistributions {
    param([switch]$Running)
    $arguments = @('--list', '--quiet')
    if ($Running) { $arguments += '--running' }
    $result = Invoke-SquadWsl -WslArguments $arguments
    return @($result.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-SquadLocation {
    param([string]$DistroName)
    if (-not $env:LOCALAPPDATA -or -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA を確認してください。' }
    return Join-Path (Join-Path $env:LOCALAPPDATA 'multica-squad') $DistroName
}

function Remove-SquadLocation {
    param([string]$Location)
    if (Test-Path -LiteralPath $Location) { Remove-Item -LiteralPath $Location -Recurse -Force }
    $parent = Split-Path -Parent $Location
    if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) {
        Remove-Item -LiteralPath $parent -Force
    }
}

function Get-SquadKeeperArguments {
    param([string]$DistroName)
    return ((@('-d', $DistroName, '--exec', 'sleep', 'infinity') | ForEach-Object { ConvertTo-SquadNativeArgument $_ }) -join ' ')
}

function Get-SquadKeeperProcess {
    param([string]$DistroName)
    $result = Invoke-SquadWsl -WslArguments @('-d', $DistroName, '-u', 'root', '--exec', 'bash', '-c', 'if [ -f /var/lib/multica-squad-vm/keepalive.json ]; then cat /var/lib/multica-squad-vm/keepalive.json; fi')
    if (-not $result.Output) { return $null }
    try { $record = ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop } catch { return $null }
    if (-not $record -or -not $record.PSObject.Properties['KeeperId'] -or -not $record.PSObject.Properties['StartedAt'] -or -not $record.PSObject.Properties['Name']) { return $null }
    if (($record.KeeperId -isnot [int] -and $record.KeeperId -isnot [long]) -or $record.KeeperId -le 0 -or $record.StartedAt -notmatch '^\d+$' -or $record.Name -ne $DistroName) { return $null }
    $keeper = Get-Process -Id $record.KeeperId -ErrorAction SilentlyContinue
    if (-not $keeper) { return $null }
    if ($keeper.Path -ne $script:SquadWslPath -or $keeper.StartTime.ToUniversalTime().Ticks.ToString() -ne $record.StartedAt) { return $null }
    $native = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + $record.KeeperId)
    if (-not $native -or -not $native.CommandLine -or -not $native.CommandLine.EndsWith((' ' + (Get-SquadKeeperArguments $DistroName)), [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $keeper
}

function Start-SquadKeeper {
    param([string]$DistroName)
    if (Get-SquadKeeperProcess $DistroName) { return }
    $arguments = Get-SquadKeeperArguments $DistroName
    $previousUtf8 = $env:WSL_UTF8
    $previousWslenv = $env:WSLENV
    try {
        $env:WSL_UTF8 = '1'
        # 常駐する sleep が WSLENV のホストの変数を持たないよう、子に渡す間だけ外す。
        $env:WSLENV = $null
        $keeper = Start-Process -FilePath $script:SquadWslPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    } finally {
        $env:WSL_UTF8 = $previousUtf8
        $env:WSLENV = $previousWslenv
    }
    try {
        $record = @{ KeeperId = $keeper.Id; StartedAt = $keeper.StartTime.ToUniversalTime().Ticks.ToString(); Name = $DistroName } | ConvertTo-Json -Compress
        $write = 'set -eu; umask 077; mkdir -p /var/lib/multica-squad-vm; temporary=$(mktemp /var/lib/multica-squad-vm/keepalive.XXXXXX); printf "%s\n" "$1" >"$temporary"; mv -f "$temporary" /var/lib/multica-squad-vm/keepalive.json'
        $null = Invoke-SquadWsl -WslArguments @('-d', $DistroName, '-u', 'root', '--exec', 'bash', '-c', $write, '--', $record)
    } catch {
        Stop-Process -Id $keeper.Id -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Stop-SquadKeeper {
    param([string]$DistroName)
    $keeper = Get-SquadKeeperProcess $DistroName
    if ($keeper) { Stop-Process -Id $keeper.Id -Force }
    $null = Invoke-SquadWsl -WslArguments @('-d', $DistroName, '-u', 'root', '--exec', 'rm', '-f', '--', '/var/lib/multica-squad-vm/keepalive.json')
}

function Assert-SquadIdle {
    param([string]$DistroName)
    $probe = 'if ! command -v multica >/dev/null 2>&1; then printf ''{"status":"not_running"}\n''; else multica daemon status --output json; fi'
    $result = Invoke-SquadWsl -WslArguments @('-d', $DistroName, '--exec', 'bash', '-lc', $probe) -AllowFailure
    try { $status = ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop } catch { throw 'デーモンの状態が不明なため、止めません。必要なときだけ -Force を使ってください。' }
    if (-not $status -or -not $status.PSObject.Properties['status']) { throw 'デーモンの状態の応答が不正です。' }
    if ($status.status -eq 'stopped' -or $status.status -eq 'not_running') { return }
    if ($result.Code -ne 0 -or $status.status -ne 'running') { throw 'デーモンの状態を読めないため、止めません。' }
    $counts = @()
    foreach ($field in @('active_task_count', 'running_task_count', 'resource_wait_task_count')) {
        if (-not $status.PSObject.Properties[$field] -or $null -eq $status.$field) { continue }
        $count = $status.$field
        if (($count -isnot [int] -and $count -isnot [long] -and $count -isnot [double] -and $count -isnot [decimal]) -or $count -lt 0 -or [double]::IsInfinity($count) -or [double]::IsNaN($count) -or [Math]::Floor($count) -ne $count) { throw '実行中のタスク数が不正なため、止めません。' }
        $counts += $count
    }
    if ($counts.Count -eq 0) { throw '実行中のタスク数が不明なため、止めません。必要なときだけ -Force を使ってください。' }
    if (($counts | Measure-Object -Maximum).Maximum -gt 0) { throw '実行中のタスクがあります。必要なときだけ -Force を使ってください。' }
}

function Test-SquadGuest {
    param([string]$DistroName)
    $result = Invoke-SquadWsl -WslArguments @('-d', $DistroName, '--exec', 'bash', '/usr/local/lib/multica-squad-vm/verify.sh', 'wsl')
    if ($result.Output) { Write-Host $result.Output }
}

function Invoke-SquadWslVm {
    [CmdletBinding()]
    param([string]$Action, [string]$Name = 'multica-squad', [string]$User = 'agent', [switch]$Force, [switch]$Yes)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ($Action -notin @('create', 'start', 'stop', 'delete', 'verify')) { throw '操作は create、start、stop、delete、verify です。' }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { throw 'ディストリの名前が不正です。' }
    if ($Action -eq 'create') {
        if ($User -notmatch '^[a-z_][a-z0-9_-]*$' -or $User -eq 'root') { throw '使う人の名前が不正です。' }
        if ($Force -or $Yes) { throw 'create では -Force と -Yes は使いません。' }
    } elseif ($PSBoundParameters.ContainsKey('User')) { throw '-User は create だけで使えます。' }
    if ($Yes -and $Action -ne 'delete') { throw '-Yes は delete だけで使えます。' }
    Assert-SquadWindows
    $script:SquadWslPath = (Get-Command wsl.exe -CommandType Application -ErrorAction Stop).Source
    $versionOutput = (Invoke-SquadWsl -WslArguments @('--version')).Output
    $firstLine = @($versionOutput -split '\r?\n' | Where-Object { $_.Trim() })[0]
    if ($firstLine -notmatch '^WSL[^:]*:\s*(\d+\.\d+\.\d+(?:\.\d+)?)\s*$' -or [version]$Matches[1] -lt [version]'2.6.1') { throw 'WSL 2.6.1 以上の版が必要です。wsl --update で更新してください。' }
    $location = Get-SquadLocation $Name
    $distributions = @(Get-SquadDistributions)
    if ($Action -eq 'create') {
        if ($distributions -contains $Name -or (Test-Path -LiteralPath $location)) { throw '同じ名前のディストリか置き場所があります。先に delete してください。' }
        $guestSource = Join-Path $PSScriptRoot 'guest'
        foreach ($file in @('provision.sh', 'start-daemon', 'record-server', 'verify.sh')) {
            if (-not (Test-Path -LiteralPath (Join-Path $guestSource $file) -PathType Leaf)) { throw "ゲストのファイルがありません: $file" }
        }
        $attempted = $false
        try {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $location) -Force
            $attempted = $true
            $null = Invoke-SquadWsl -WslArguments @('--install', 'Ubuntu-24.04', '--name', $Name, '--location', $location, '--no-launch', '--version', '2')
            if (@(Get-SquadDistributions) -notcontains $Name) { throw 'ディストリが登録されていません。Windows の再起動が必要か確認してください。' }
            $guestPath = (Invoke-SquadWsl -WslArguments @('-d', $Name, '-u', 'root', '--exec', 'wslpath', '-au', $guestSource)).Output
            if ($guestPath -notmatch '^/' -or $guestPath -match '[\r\n]') { throw 'ゲストから読む原本のパスが不正です。' }
            $null = Invoke-SquadWsl -WslArguments @('-d', $Name, '-u', 'root', '--exec', 'bash', ($guestPath.TrimEnd('/') + '/provision.sh'), 'wsl', $User)
            $null = Invoke-SquadWsl -WslArguments @('--terminate', $Name)
            Start-SquadKeeper $Name
            Test-SquadGuest $Name
            Write-Host "ディストリを作りました。中に入る: cmd /c `"set WSLENV=&& wsl -d $Name`""
            Write-Host '中で manual.md の「受け取る人の準備」とセットアップの手順を流してください。'
        } catch {
            $failure = $_
            if ($attempted) {
                try {
                    if (@(Get-SquadDistributions) -contains $Name) {
                        if (@(Get-SquadDistributions -Running) -contains $Name) {
                            try { Stop-SquadKeeper $Name } catch { Write-Warning ('keepalive の停止に失敗しました: ' + $_.Exception.Message) }
                        }
                        $null = Invoke-SquadWsl -WslArguments @('--unregister', $Name)
                    }
                    Remove-SquadLocation $location
                } catch { Write-Warning ("作ったディストリの削除に失敗しました: " + $_.Exception.Message) }
            }
            throw $failure
        }
        return
    }
    if ($distributions -notcontains $Name) { throw '指定したディストリがありません。' }
    if ($Action -eq 'start') { Start-SquadKeeper $Name; return }
    $running = @(Get-SquadDistributions -Running) -contains $Name
    if ($Action -eq 'verify') {
        if (-not $running) { throw 'verify の前にディストリを起動してください。' }
        Test-SquadGuest $Name
        return
    }
    if ($Action -eq 'delete' -and -not $Yes) {
        $answer = Read-Host "ディストリ $Name を消します。中のログインと作業コピーもなくなります。消しますか [y/N]"
        if ($answer -notin @('y', 'Y')) { throw '削除を取りやめました。' }
    }
    if ($running) {
        if (-not $Force) { Assert-SquadIdle $Name }
        Stop-SquadKeeper $Name
        $null = Invoke-SquadWsl -WslArguments @('--terminate', $Name)
    }
    if ($Action -eq 'delete') {
        $null = Invoke-SquadWsl -WslArguments @('--unregister', $Name)
        Remove-SquadLocation $location
    }
}

# ドットで読み込むテストでは、関数の定義だけを行う。
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-SquadWslVm @PSBoundParameters } catch { Write-Error $_; exit 1 }
}
