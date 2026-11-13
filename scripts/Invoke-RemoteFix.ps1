param(
    [Parameter(Mandatory=$true, Position=0)][string]$PC,
    [Parameter(Mandatory=$true, Position=1)][string]$Issue,
    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'
$TicketsDir = "$env:USERPROFILE\Documents\tickets"
$File = Join-Path $env:TEMP 'remote_fix.ps1'

try {
    $cred = Import-Clixml "$HOME\Documents\admin_cred.xml"

    Push-Location $TicketsDir
    try {
        $Prompt = "Target PC: $PC. Issue: $Issue. Use existing skills if applicable. Output ONLY raw executable PowerShell code without markdown backticks, comments or explanations."
        $Code = (claude -p $Prompt) -join "`n"
    }
    finally {
        Pop-Location
    }

    $Code = $Code -replace '(?m)^\s*```(powershell|ps1)?\s*$', ''
    Set-Content -Path $File -Value $Code -Encoding utf8 -Force -Confirm:$false

    if (-not $AutoApprove) {
        throw "Code saved to $File. Re-run with -AutoApprove to execute it on $PC."
    }

    $ScriptBlock = [scriptblock]::Create((Get-Content -Path $File -Raw))
    Invoke-Command -ComputerName $PC -Credential $cred -ScriptBlock $ScriptBlock -ErrorAction Stop
    Write-Output "SUCCESS: Fix executed on $PC"
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
}
