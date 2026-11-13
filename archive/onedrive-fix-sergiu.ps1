param(
    [Parameter(Mandatory=$true)]
    [string]$ComputerName
)

Write-Host "Pripájam sa na vzdialený počítač: $ComputerName" -ForegroundColor Cyan

Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    # Close OneDrive
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue

    # Define registry location
    $RegPath = "HKCU:\Software\Microsoft\OneDrive"

    if (Test-Path $RegPath) {
        # Export a backup
        $Backup = "$env:TEMP\OneDrive-registry-backup.reg"
        reg.exe export "HKCU\Software\Microsoft\OneDrive" $Backup /y

        if ($LASTEXITCODE -ne 0) {
            throw "Registry backup failed. No changes made."
        }

        # Rename the configuration key
        $NewName = "OneDrive.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Rename-Item -Path $RegPath -NewName $NewName -ErrorAction Stop

        Write-Host "Registry configuration backed up and renamed" -ForegroundColor Green
    }
    else {
        Write-Host "OneDrive registry key not found" -ForegroundColor Yellow
    }

    # Start OneDrive
    Start-Process "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
}