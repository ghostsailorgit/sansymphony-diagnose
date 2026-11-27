#requires -Version 5.1
<#
.SYNOPSIS
    Baut das Release-Paket SsyDiagnose-<Version>.zip aus src\ (Syntaxprüfung inklusive).
#>
param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root 'src'
$out = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $out -Force | Out-Null

$script = Join-Path $src 'SsyDiagnose.ps1'
$errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs)
if ($errs) { $errs | ForEach-Object { Write-Error "$($_.Extent.StartLineNumber): $($_.Message)" }; throw 'Syntaxfehler - Abbruch.' }
if ((Get-Content $script -Raw) -notmatch "\`$ToolVersion = '$([regex]::Escape($Version))'") { throw "ToolVersion in SsyDiagnose.ps1 ist nicht $Version." }

$zip = Join-Path $out "SsyDiagnose-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $src 'SsyDiagnose.ps1'), (Join-Path $src 'Start-SsyDiagnose.cmd'), (Join-Path $src 'LIESMICH.txt'), (Join-Path $root 'LICENSE') -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
"$hash  SsyDiagnose-$Version.zip" | Set-Content -Path "$zip.sha256" -Encoding ASCII
"Paket: $zip"
"SHA256: $hash"
