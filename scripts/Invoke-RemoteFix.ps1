param(
    [Parameter(Mandatory=$true, Position=0)][string]$PC,
    [Parameter(Mandatory=$true, Position=1)][string]$Issue,
    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'
$TicketsDir = "$env:USERPROFILE\Documents\tickets"
$File = "$env:TEMP\remote_fix.ps1"

# Prepnutie do tickets\ zabezpečí, že Claude použije vaše lokálne .claude\skills\ a šetrí tokeny
Push-Location $TicketsDir
try {
    Write-Host "Analyzujem a generujem opravu pre $PC..." -ForegroundColor Yellow
    
    # Požiadame Claude iba o čistý PowerShell kód bez markdownu a omáčok
    $Prompt = "Target PC: $PC. Issue: $Issue. Use existing skills if applicable. Output ONLY raw executable PowerShell code without markdown backticks or explanations."
    claude -p $Prompt | Out-File $File -Encoding utf8
}
finally {
    Pop-Location
}

# Očistenie prípadných markdown značiek
(Get-Content $File -Raw) -replace '```powershell|```', '' | Set-Content $File -Encoding utf8

Write-Host "`n--- VYGENEROVANÝ KÓD ---" -ForegroundColor Magenta
Get-Content $File
Write-Host "------------------------`n" -ForegroundColor Magenta

# Neinteraktívny prepínač vs. manuálne potvrdenie
if ($AutoApprove) {
    $Confirm = 'A'
} else {
    $Confirm = Read-Host "Spustiť na $PC cez WinRM? (A/N)"
}

if ($Confirm -match '^[AaYy]$') {
    $ScriptBlock = [scriptblock]::Create((Get-Content $File -Raw))
    Invoke-Command -ComputerName $PC -ScriptBlock $ScriptBlock
    Write-Host "[HOTOVO] Príkaz bol vykonaný na $PC." -ForegroundColor Green
} else {
    Write-Host "[ZRUŠENÉ]" -ForegroundColor Red
}