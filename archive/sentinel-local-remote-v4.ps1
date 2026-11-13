[CmdletBinding()]
param(
    [switch]$Local,
    [string[]]$ComputerName,
    [string]$MakePackage,
    [string]$OutDir,
    [switch]$CheckOnly,
    [switch]$TryEnableWinRM,
    [switch]$Yes,
    [string]$InstallerName = 'SentinelOneInstaller_windows_64bit_v25_2_6_442.exe',
    [string]$MachinesFile  = "$HOME\Documents\machines.txt",
    [string]$ConfigFile    = "$HOME\Documents\sentinel_sites.json",
    [string]$CredFile      = "$HOME\Documents\admin_cred.xml",
    [string]$TokenFile     = '',
    [int]$StaleDays        = 30
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Color
}

function New-Result {
    param($Computer, $Status, $Reason = '', $IP = '', $Version = '')
    [pscustomobject]@{
        Computer = $Computer
        IP       = $IP
        Status   = $Status
        Version  = $Version
        Reason   = ($Reason -replace '\s+', ' ').Trim()
    }
}

function New-FailResult {
    param($Computer, $Status, $Reason, $IP = '', $Version = '')
    Write-Host "  RESULT: $Status" -ForegroundColor Red
    Write-Host "  REASON: $Reason" -ForegroundColor Red
    New-Result $Computer $Status $Reason $IP $Version
}

function Invoke-OnTarget {
    param($Session, [scriptblock]$Block, [object[]]$ArgList = @())
    if ($Session) { Invoke-Command -Session $Session -ScriptBlock $Block -ArgumentList $ArgList }
    else          { & $Block @ArgList }
}

function Test-TcpPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $client.Connected
    } catch { return $false }
    finally { $client.Close() }
}

function Get-WinRMFailureReason {
    param([string]$Text)
    switch -Regex ($Text) {
        'Access is denied|AccessDenied|Logon failure|bad password|unknown user name' {
            return 'Authentication/authorization failed: wrong credentials in admin_cred.xml, account is not local admin on the target, or UAC remote restrictions apply (local, non-domain account).' }
        'target principal name is incorrect|Kerberos|SPN' {
            return 'Kerberos/SPN problem: the name does not match the machine that answered. Typical for a stale DNS record pointing to another host.' }
        'TrustedHosts' {
            return 'Name could not be authenticated with Kerberos (IP address, or machine not in the domain) and the target is not in TrustedHosts.' }
        'cannot be resolved|No such host is known|name could not be resolved' {
            return 'DNS name could not be resolved.' }
        'WinRMOperationTimeout|timed out|time-out|OperationTimeout' {
            return 'WinRM connection timed out: firewall silently dropping 5985, or the host is not really there.' }
        'cannot connect to the destination|CannotConnect|refused|service is not running|WinRM client cannot process' {
            return 'Cannot connect to WinRM: the WinRM service is stopped/not configured on the target, or a firewall blocks port 5985.' }
        default {
            return 'Unclassified WinRM error - see the raw message.' }
    }
}

function Enable-WinRMViaDcom {
    param([string]$Computer, [pscredential]$Credential)
    $opt = New-CimSessionOption -Protocol Dcom
    $cim = New-CimSession -ComputerName $Computer -Credential $Credential -SessionOption $opt -ErrorAction Stop
    try {
        $res = Invoke-CimMethod -CimSession $cim -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck"'
        }
        return ($res.ReturnValue -eq 0)
    } finally { Remove-CimSession $cim -ErrorAction SilentlyContinue }
}

$script:StateBlock = {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $app = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -match '^Sentinel Agent|^SentinelOne' } |
           Select-Object -First 1
    $svc = Get-Service -Name 'SentinelAgent' -ErrorAction SilentlyContinue

    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
               [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations

    $ctlStatus = $null
    $ctl = Get-ChildItem 'C:\Program Files\SentinelOne' -Directory -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -First 1 |
           ForEach-Object { Join-Path $_.FullName 'SentinelCtl.exe' }
    if ($ctl -and (Test-Path $ctl)) {
        try { $ctlStatus = (& $ctl status 2>&1 | Out-String).Trim() } catch {}
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Version       = $app.DisplayVersion
        DisplayName   = $app.DisplayName
        Service       = if ($svc) { [string]$svc.Status } else { $null }
        FreeGB        = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
        OS            = $os.Caption
        LastBoot      = $os.LastBootUpTime
        RebootPending = $pending
        CtlStatus     = $ctlStatus
    }
}

function Invoke-Deploy {
    param(
        [Parameter(Mandatory)][string]$Computer,
        [switch]$IsLocal,
        $LocalInfo
    )

    $session    = $null
    $ip         = ''
    $token      = $null
    $sourceFile = $null

    if ($IsLocal) {
        if ($LocalInfo) { $token = $LocalInfo.Token; $sourceFile = $LocalInfo.InstallerPath }
    }
    else {
        $prefix = $Computer.Substring(0, [Math]::Min(3, $Computer.Length)).ToUpper()
        $site   = $script:Config.$prefix
        if (-not $site) {
            return New-FailResult $Computer 'SKIPPED' "Unknown site prefix '$prefix' - not defined in $ConfigFile."
        }
        $token      = $site.Token
        $sourceFile = Join-Path $site.SourcePath $InstallerName

        if ($script:HaveAD) {
            $ad = $null
            try { $ad = Get-ADComputer -Identity $Computer -Properties LastLogonDate, Enabled -ErrorAction Stop } catch {}
            if (-not $ad) {
                Write-Step 'AD: computer object NOT FOUND (typo, or deleted from AD).' Yellow
            } else {
                $age = if ($ad.LastLogonDate) { [int]((Get-Date) - $ad.LastLogonDate).TotalDays } else { $null }
                Write-Step ("AD: enabled={0}, last logon={1} ({2} days ago)" -f $ad.Enabled, $ad.LastLogonDate, $age)
                if (-not $ad.Enabled) { Write-Step 'WARNING: computer account is DISABLED in AD.' Yellow }
                if ($null -eq $age -or $age -gt $StaleDays) {
                    Write-Step "WARNING: no domain logon for more than $StaleDays days - machine is probably off, retired or off-network (DNS record may be stale)." Yellow
                }
            }
        }

        $ips = @()
        try {
            $ips = @(Resolve-DnsName -Name $Computer -Type A -ErrorAction Stop |
                     Where-Object { $_.Type -eq 'A' } | ForEach-Object IPAddress)
        } catch {}
        if (-not $ips) {
            return New-FailResult $Computer 'DNS_FAIL' 'DNS cannot resolve the computer name (no A record).'
        }
        $ip = $ips -join ', '
        Write-Step "DNS: $ip"
        if ($ips.Count -gt 1) { Write-Step 'WARNING: multiple A records for one name (duplicate/stale DNS entries?).' Yellow }
        foreach ($i in $ips) {
            $ptr = @(Resolve-DnsName -Name $i -Type PTR -ErrorAction SilentlyContinue |
                     Where-Object { $_.Type -eq 'PTR' } | ForEach-Object NameHost)
            if (-not $ptr) {
                Write-Step "WARNING: no reverse DNS record for $i - cannot confirm the IP belongs to $Computer." Yellow
            } elseif (-not ($ptr -like "$Computer*")) {
                Write-Step "WARNING: $i reverse-resolves to '$($ptr -join ', ')', not $Computer - stale or wrong DNS record." Yellow
            }
        }

        $ping  = Test-Connection -ComputerName $Computer -Count 2 -Quiet
        $winrm = Test-TcpPort $Computer 5985
        $smb   = Test-TcpPort $Computer 445
        $rpc   = Test-TcpPort $Computer 135
        Write-Step ("Network: ping={0}  WinRM(5985)={1}  SMB(445)={2}  RPC(135)={3}" -f $ping, $winrm, $smb, $rpc)

        if (-not ($ping -or $winrm -or $smb -or $rpc)) {
            return New-FailResult $Computer 'OFFLINE' "No reply on ping, 5985, 445 or 135. Machine is off, off-network, in another segment, or the DNS record ($ip) is wrong." $ip
        }
        if ($ping -and -not ($winrm -or $smb -or $rpc)) {
            Write-Step "NOTE: answers ping but no Windows ports are open - the IP $ip is likely a router/firewall/other device, not this PC." Yellow
        }

        if (-not $winrm) {
            if ($TryEnableWinRM -and -not $CheckOnly -and ($rpc -or $smb)) {
                Write-Step 'Port 5985 closed - trying to enable WinRM through DCOM...' Yellow
                try {
                    if (Enable-WinRMViaDcom -Computer $Computer -Credential $script:Cred) {
                        Start-Sleep -Seconds 10
                        $winrm = Test-TcpPort $Computer 5985
                    }
                } catch { Write-Step "DCOM attempt failed: $($_.Exception.Message)" Red }
            }
            if (-not $winrm) {
                return New-FailResult $Computer 'WINRM_PORT_CLOSED' "TCP 5985 is closed: WinRM service not running/configured on the target, a firewall blocks it, or $ip is not this machine. Fix with GPO (WinRM + firewall rule), -TryEnableWinRM, or use -MakePackage + TeamViewer." $ip
            }
        }

        try {
            $session = New-PSSession -ComputerName $Computer -Credential $script:Cred -ErrorAction Stop
        } catch {
            $raw   = "$($_.FullyQualifiedErrorId) | $($_.Exception.Message)"
            $cause = Get-WinRMFailureReason $raw
            Write-Step "Raw error: $raw" DarkGray
            return New-FailResult $Computer 'WINRM_SESSION_FAIL' $cause $ip
        }
    }

    try {
        $state = Invoke-OnTarget $session $script:StateBlock
        $ver   = $null
        $verOk = [version]::TryParse([string]$state.Version, [ref]$ver)

        Write-Step "OS: $($state.OS) | last boot: $($state.LastBoot) | free C: $($state.FreeGB) GB | reboot pending: $($state.RebootPending)"
        if ($state.Version) {
            Write-Step "SentinelOne installed: $($state.DisplayName) $($state.Version) | service: $($state.Service)" Green
            if ($state.CtlStatus) {
                Write-Step 'SentinelCtl status:' DarkGray
                ($state.CtlStatus -split "`r?`n" | Select-Object -First 12) | ForEach-Object { Write-Step "    $_" DarkGray }
            }
        } else {
            Write-Step 'SentinelOne is NOT installed.' Yellow
        }

        $installed    = [bool]$state.Version
        $needsUpgrade = $installed -and (-not $verOk -or $ver -lt $TargetVersion)
        $isNewer      = $installed -and $verOk -and $ver -gt $TargetVersion
        $serviceUp    = $state.Service -eq 'Running'

        if ($isNewer) {
            Write-Step "Installed version $($state.Version) is NEWER than installer $TargetVersion - nothing to do." Green
            return New-Result $Computer 'OK_NEWER' 'Installed version is newer than the installer' $ip $state.Version
        }
        if ($installed -and -not $needsUpgrade -and $serviceUp) {
            Write-Step "Up to date ($($state.Version)) and the service is running. Nothing to do." Green
            return New-Result $Computer 'OK' '' $ip $state.Version
        }

        if ($needsUpgrade) {
            Write-Step "UPDATE NEEDED: $($state.Version) -> $TargetVersion" Yellow
            if ($state.RebootPending) { Write-Step 'WARNING: a reboot is pending on this machine; the upgrade may need a restart to complete.' Yellow }
        }

        if ($CheckOnly) {
            $st = if (-not $installed) { 'NOT_INSTALLED' } elseif ($needsUpgrade) { 'NEEDS_UPDATE' } else { 'SERVICE_DOWN' }
            Write-Step "Check-only: no changes made ($st)." Yellow
            return New-Result $Computer $st "Service state: $($state.Service)" $ip $state.Version
        }

        if ($installed -and -not $needsUpgrade -and -not $serviceUp) {
            Write-Step "Service is '$($state.Service)'. Trying to start it..." Yellow
            $started = Invoke-OnTarget $session {
                try { Start-Service -Name 'SentinelAgent' -ErrorAction Stop; (Get-Service 'SentinelAgent').Status -eq 'Running' }
                catch { $false }
            }
            if ($started) {
                Write-Step 'Service started.' Green
                return New-Result $Computer 'SERVICE_STARTED' 'Service was stopped, started successfully' $ip $state.Version
            }
            Write-Step 'Service could not be started - falling back to reinstall.' Yellow
        }

        if ($state.FreeGB -lt 1) {
            return New-FailResult $Computer 'LOW_DISK' "Only $($state.FreeGB) GB free on C: - not enough for the installer." $ip $state.Version
        }

        if (-not $sourceFile -or -not (Test-Path -LiteralPath $sourceFile)) {
            return New-FailResult $Computer 'INSTALLER_MISSING' "Installer not found / not readable from this PC: $sourceFile (file share down, wrong name, or no permission)." $ip $state.Version
        }

        if ($IsLocal) {
            $installerOnTarget = $sourceFile
            if (-not $Yes) {
                return New-FailResult $Computer 'CANCELLED' 'Local run needs -Yes (silent mode, no prompt).' $ip $state.Version
            }
        }
        else {
            $installerOnTarget = "C:\Temp\$InstallerName"
            Invoke-OnTarget $session {
                if (-not (Test-Path 'C:\Temp')) { New-Item -ItemType Directory -Path 'C:\Temp' -Force -Confirm:$false | Out-Null }
            } | Out-Null
            Write-Step 'Copying installer...' Cyan
            $copied = $false; $copyErrors = @()
            try {
                Copy-Item -LiteralPath $sourceFile -Destination "\\$Computer\C$\Temp\$InstallerName" -Force -Confirm:$false -ErrorAction Stop
                $copied = $true
            } catch { $copyErrors += "admin share: $($_.Exception.Message)" }
            if (-not $copied) {
                try {
                    Copy-Item -LiteralPath $sourceFile -Destination $installerOnTarget -ToSession $session -Force -Confirm:$false -ErrorAction Stop
                    $copied = $true
                } catch { $copyErrors += "WinRM copy: $($_.Exception.Message)" }
            }
            if (-not $copied) {
                return New-FailResult $Computer 'COPY_FAIL' ("Could not copy the installer. " + ($copyErrors -join ' || ')) $ip $state.Version
            }
        }

        Write-Step 'Running silent install/upgrade...' Cyan
        $exit = Invoke-OnTarget $session {
            param($file, $tok)
            $p = Start-Process -FilePath $file -ArgumentList @('-t', $tok, '-q') -Wait -PassThru
            $p.ExitCode
        } @($installerOnTarget, $token)
        $exit = @($exit)[-1]

        if ($exit -notin 0, 3010) {
            $hint = if ($installed) { ' If this is an upgrade, check in the SentinelOne console that local upgrade is authorized for the machine/policy, and look at the installer log in C:\Windows\Temp on the target.' } else { '' }
            return New-FailResult $Computer 'INSTALL_FAIL' "Installer exit code $exit.$hint" $ip $state.Version
        }
        if ($exit -eq 3010) { Write-Step 'Installer reports that a reboot is required (3010).' Yellow }

        Write-Step 'Waiting 20 s and verifying...' Cyan
        Start-Sleep -Seconds 20
        $after = Invoke-OnTarget $session $script:StateBlock
        if (-not $IsLocal) {
            Invoke-OnTarget $session { param($f) Remove-Item $f -Force -Confirm:$false -ErrorAction SilentlyContinue } @($installerOnTarget) | Out-Null
        }

        $afterVer = $null
        [void][version]::TryParse([string]$after.Version, [ref]$afterVer)
        if ($after.Service -eq 'Running' -and $afterVer -and $afterVer -ge $TargetVersion) {
            $st = if ($installed) { 'UPGRADED' } else { 'INSTALLED' }
            Write-Step "DONE: version $($after.Version), service running." Green
            return New-Result $Computer $st "Exit code $exit" $ip $after.Version
        }
        return New-FailResult $Computer 'VERIFY_FAIL' "Installer finished (exit $exit) but afterwards version=$($after.Version), service=$($after.Service). A reboot may be required; re-run -CheckOnly later." $ip $after.Version
    }
    catch {
        return New-FailResult $Computer 'ERROR' "Unexpected error: $($_.Exception.Message)" $ip
    }
    finally {
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

function Get-LocalSiteInfo {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $tf = if ($TokenFile) { $TokenFile } else { Join-Path $root 'token.txt' }
    $localInstaller = Join-Path $root $InstallerName

    if (Test-Path -LiteralPath $tf) {
        $parts = (Get-Content -LiteralPath $tf -Raw).Trim() -split '\|', 2
        if ($parts.Count -ne 2 -or $parts[1].Trim().Length -lt 20) {
            throw "Token file '$tf' has a wrong format (expected PREFIX|token). Create it with -MakePackage."
        }
        return [pscustomobject]@{
            Prefix = $parts[0].Trim().ToUpper(); Token = $parts[1].Trim()
            InstallerPath = $localInstaller; CleanupInstaller = $true; TokenFile = $tf
        }
    }
    if ($script:Config) {
        $prefix = $env:COMPUTERNAME.Substring(0, [Math]::Min(3, $env:COMPUTERNAME.Length)).ToUpper()
        $site = $script:Config.$prefix
        if (-not $site) { throw "Computer prefix '$prefix' is not defined in $ConfigFile." }
        $inst = if (Test-Path -LiteralPath $localInstaller) { $localInstaller } else { Join-Path $site.SourcePath $InstallerName }
        return [pscustomobject]@{
            Prefix = $prefix; Token = $site.Token
            InstallerPath = $inst; CleanupInstaller = $false; TokenFile = $null
        }
    }
    throw "No token.txt next to the script and no site config ($ConfigFile). Create a package with -MakePackage on your admin PC."
}

function Invoke-LocalRun {
    $computer = $env:COMPUTERNAME
    $info = $null
    $res  = $null
    try {
        if (-not $CheckOnly) {
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                return New-FailResult $computer 'NOT_ELEVATED' 'This session is NOT elevated. Open an Administrator PowerShell/terminal and run again.'
            }
            $info = Get-LocalSiteInfo
            if (-not $computer.StartsWith($info.Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                return New-FailResult $computer 'WRONG_SITE' "Computer name '$computer' does not start with '$($info.Prefix)'. Wrong machine or wrong site token - aborting."
            }
        }
        Write-Host "Local mode on $computer  (user $env:USERDOMAIN\$env:USERNAME)" -ForegroundColor Cyan
        $res = Invoke-Deploy -Computer $computer -IsLocal -LocalInfo $info
        return $res
    }
    catch {
        return New-FailResult $computer 'ERROR' $_.Exception.Message
    }
    finally {
        if (-not $CheckOnly -and $info) {
            if ($info.TokenFile -and (Test-Path -LiteralPath $info.TokenFile)) { Remove-Item -LiteralPath $info.TokenFile -Force -Confirm:$false -ErrorAction SilentlyContinue }
            if ($info.CleanupInstaller -and $res -and ($res.Status -in $script:Good) -and (Test-Path -LiteralPath $info.InstallerPath)) {
                Remove-Item -LiteralPath $info.InstallerPath -Force -Confirm:$false -ErrorAction SilentlyContinue
            }
            Write-Host '  Cleanup done (token file removed; installer removed after success).' -ForegroundColor DarkGray
        }
    }
}

function New-InstallPackage {
    if (-not $script:Config) { throw "Site config not found: $ConfigFile" }
    $root     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $selfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $prefix = $MakePackage.ToUpper()
    $site   = $script:Config.$prefix
    if (-not $site) { throw "Prefix '$prefix' is not defined in $ConfigFile." }
    $src = Join-Path $site.SourcePath $InstallerName
    if (-not (Test-Path -LiteralPath $src)) { throw "Installer not readable: $src" }

    $dir = if ($OutDir) { $OutDir } else { Join-Path $root "S1_package_$prefix" }
    New-Item -ItemType Directory -Path $dir -Force -Confirm:$false | Out-Null
    Copy-Item -LiteralPath $src      -Destination $dir -Force -Confirm:$false
    Copy-Item -LiteralPath $selfPath -Destination $dir -Force -Confirm:$false
    Set-Content -Path (Join-Path $dir 'token.txt') -Value "$prefix|$($site.Token)" -NoNewline -Force -Confirm:$false

    $scriptName = Split-Path $selfPath -Leaf
    Write-Host "Package created: $dir" -ForegroundColor Green
    Write-Host '  Contains: installer, this script, token.txt (site token - treat as secret).'
    Write-Host ''
    Write-Host '  1) TeamViewer > File transfer: send ALL files from that folder to C:\Temp\S1 on the target.'
    Write-Host '  2) On the target (admin terminal):'
    Write-Host '       cd C:\Temp\S1'
    Write-Host "       powershell -ExecutionPolicy Bypass -File .\$scriptName -Local -Yes"
    Write-Host '  3) Afterwards delete C:\Temp\S1 on the target AND the package folder on this PC.'
}

try {
    if ($InstallerName -notmatch 'v(\d+)_(\d+)_(\d+)_(\d+)') {
        throw "Cannot derive target version from installer name '$InstallerName'."
    }
    $TargetVersion = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
    if ($Local -and $ComputerName) { throw '-Local and -ComputerName cannot be combined.' }

    $script:Good = 'OK', 'OK_NEWER', 'UPGRADED', 'INSTALLED', 'SERVICE_STARTED'
    $script:Config = $null
    if (Test-Path -LiteralPath $ConfigFile) { $script:Config = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json }
    $script:HaveAD = [bool](Get-Command Get-ADComputer -ErrorAction SilentlyContinue)

    if ($MakePackage) {
        New-InstallPackage
        Write-Output "SUCCESS: package created for site $($MakePackage.ToUpper())"
    }
    else {
        Write-Host "Target SentinelOne version: $TargetVersion  (installer: $InstallerName)" -ForegroundColor Cyan
        if ($CheckOnly) { Write-Host 'CHECK-ONLY mode: nothing will be changed.' -ForegroundColor Yellow }

        if ($Local) {
            $results = @(Invoke-LocalRun)
        }
        else {
            if (-not $script:Config) { throw "Site config not found: $ConfigFile" }
            $script:Cred = Import-Clixml -Path $CredFile

            $computers = if ($ComputerName) { $ComputerName }
                         else { Get-Content -Path $MachinesFile }
            $computers = $computers | ForEach-Object { $_.Trim() } |
                         Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -Unique

            $results = foreach ($c in $computers) {
                Write-Host ('-' * 70)
                Write-Host "Processing: $c" -ForegroundColor Cyan
                Invoke-Deploy -Computer $c
            }
        }

        Write-Host ('=' * 70)
        $results | Format-Table Computer, IP, Status, Version, Reason -AutoSize -Wrap

        $failed = @($results | Where-Object { $_.Status -notin $script:Good })
        $summary = "$(@($results).Count) machine(s) processed, $($failed.Count) need attention"

        if (-not $Local) {
            $stamp  = Get-Date -Format 'yyyyMMdd_HHmm'
            $report = "$HOME\Documents\sentinel_report_$stamp.csv"
            $results | Export-Csv -Path $report -NoTypeInformation -Encoding UTF8 -Force -Confirm:$false

            if ($failed.Count -gt 0) {
                $retry = "$HOME\Documents\machines_retry_$stamp.txt"
                $failed.Computer | Set-Content -Path $retry -Force -Confirm:$false
                Write-Host "$($failed.Count) machine(s) need attention. Retry list: $retry" -ForegroundColor Yellow
            }
            Write-Host "CSV report: $report" -ForegroundColor Cyan
            $summary += "; report: $report"
        }
        Write-Output "SUCCESS: $summary"
    }
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
}
