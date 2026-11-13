param(
    [Parameter(Mandatory=$true)]
    [string]$ComputerName
)

try {
    $cred = Import-Clixml "$HOME\Documents\admin_cred.xml"

    Invoke-Command -ComputerName $ComputerName -Credential $cred -ScriptBlock {
        $ErrorActionPreference = 'Stop'

        Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue

        $RegPath = 'HKCU:\Software\Microsoft\OneDrive'

        if (Test-Path $RegPath) {
            $Backup = Join-Path $env:TEMP 'OneDrive-registry-backup.reg'
            reg.exe export 'HKCU\Software\Microsoft\OneDrive' $Backup /y
            if ($LASTEXITCODE -ne 0) { throw 'Registry backup failed. No changes made.' }

            $NewName = "OneDrive.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Rename-Item -Path $RegPath -NewName $NewName -Force -Confirm:$false -ErrorAction Stop
        }

        Start-Process 'C:\Program Files\Microsoft OneDrive\OneDrive.exe' -ErrorAction Stop
    }

    Write-Output "SUCCESS: OneDrive registry reset on $ComputerName"
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
}
