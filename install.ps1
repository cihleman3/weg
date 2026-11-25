# Installs weg into ~/.local/share/weg (script) and ~/.local/bin (commands for PowerShell, cmd and Git Bash).
# Adds ~/.local/bin to the user's PATH if it is missing. Needs no administrator rights.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$share = Join-Path $HOME '.local\share\weg'
$bin = Join-Path $HOME '.local\bin'
New-Item -ItemType Directory -Force $share, $bin | Out-Null
Copy-Item 'weg.ps1' (Join-Path $share 'weg.ps1') -Force
Copy-Item 'launcher\weg.cmd', 'launcher\weg' $bin -Force
Write-Host "Installed: $(Join-Path $bin 'weg.cmd')"

# Setting the variable this way also tells Windows about the change; new windows see it without signing out.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = if ($userPath) { $userPath -split ';' | Where-Object { $_ } } else { @() }
if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $bin })) {
    [Environment]::SetEnvironmentVariable('Path', (@($entries) + $bin) -join ';', 'User')
    Write-Host "Added $bin to your PATH. Open a new terminal to use weg."
}
