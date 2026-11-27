#requires -Version 5.1
<#
.SYNOPSIS
    SANsymphony Diagnose 1.0.0 - prüft einen DataCore-SANsymphony-Server und seine Gruppe umfassend,
    bewertet alle Ergebnisse je Bereich und gibt eine Gesamteinschätzung ab.
    Community-Werkzeug, kein offizielles Produkt der DataCore Software Corporation.

.DESCRIPTION
    Läuft direkt auf einem SANsymphony-Server (Windows PowerShell 5.1, Administratorrechte).
    Nutzt die lokal installierten DataCore-Cmdlets und Windows-Bordmittel. Rein lesend - ändert nichts.
    Optional: Tiefenanalyse per Paketmitschnitt (pktmon, nur wenn kein anderer Mitschnitt läuft).

    Start:  Start-SsyDiagnose.cmd doppelklicken
    Ohne Oberfläche:
      .\SsyDiagnose.ps1 -NoGui -Seconds 60 -ReportPath C:\Temp\bericht.html -JsonPath C:\Temp\bericht.json
      .\SsyDiagnose.ps1 -NoGui -CompareWith C:\Temp\alt.json -DeepAnalysis
    Demo ohne SANsymphony (Beispieldaten, z. B. zum Kennenlernen oder für Schulungen):
      .\SsyDiagnose.ps1 -Demo
#>
[CmdletBinding()]
param(
    [switch]$NoGui,
    [ValidateRange(10, 600)][int]$Seconds = 30,
    [switch]$SkipPerformance,
    [switch]$DeepAnalysis,
    [string]$ReportPath,
    [string]$JsonPath,
    [string]$CompareWith,
    [switch]$Demo,
    [string]$CaptureDir,
    [switch]$BuildFormOnly
)

$ToolVersion = '1.0.0'

# ============================================================================
#  Kernlogik (läuft in der Oberfläche in einem Hintergrund-Runspace)
# ============================================================================
$CoreScript = @'
$script:T = @{
    MinIops = 5; FeWarnMs = 10; FeCritMs = 20; MirrorWarnMs = 5; MirrorCritMs = 15
    PoolWarnMs = 20; PoolCritMs = 50; DiskWarnMs = 20; DiskCritMs = 50; PortWarnMs = 10
    QueueWarn = 8; CacheHitWarnPct = 80; MemWarnPct = 10; MemCritPct = 5
    PollerWarn = 80; PollerCrit = 95; PendingMirrorWarn = 32; AsymmetryFactor = 3
    PingWarnMs = 2; PoolFreeWarnPct = 20; PoolFreeCritPct = 10; CpuWarnPct = 85
    TimeSkewWarnSec = 5; TimeSkewCritSec = 300; ReplLagWarnSec = 900; ReplBufferWarnPct = 30
    BackupWarnDays = 7; AlertHours = 24; UptimeInfoDays = 180; SysFreeWarnPct = 10
}
$script:Categories = @('Verfügbarkeit', 'Lizenz & Software', 'Server & Cache', 'Pools & Disks', 'vDisks & Spiegel', 'Host-Pfade',
    'Replikation & Schutz', 'Monitore & Alarme', 'Betrieb', 'Windows', 'Netzwerk', 'Spiegelstrecke', 'Leistung', 'Tool')
$script:Checks = New-Object System.Collections.Generic.List[object]
$script:Inventory = New-Object System.Text.StringBuilder
$script:Conn = $null
$script:PerfNarrative = ''

function Write-SsyProgress([int]$Percent, [string]$Text) {
    if ($sync) { $sync.Progress = $Percent; $sync.Status = $Text; [void]$sync.Log.Add("$(Get-Date -Format HH:mm:ss)  $Text") }
    else { Write-Host ('[{0,3}%] {1}' -f $Percent, $Text) }
}
function Write-SsyLog([string]$Text) { if ($sync) { [void]$sync.Log.Add("$(Get-Date -Format HH:mm:ss)  $Text") } else { Write-Verbose $Text } }

function Add-SsyCheck {
    param([string]$Category, [string]$Check, [string]$Object, [ValidateSet('OK', 'Info', 'Warnung', 'Kritisch')][string]$Status,
        [string]$Result, [string]$Recommendation = '', [string]$Details = '')
    $rank = @{ Kritisch = 3; Warnung = 2; Info = 1; OK = 0 }[$Status]
    $script:Checks.Add([pscustomobject]@{ Status = $Status; Rank = $rank; Category = $Category; Check = $Check; Object = $Object
            Result = $Result; Recommendation = $Recommendation; Details = $Details; Key = "$Category|$Check|$Object" })
}
function Invoke-SsyStep([string]$Category, [string]$Name, [scriptblock]$Body) {
    try { & $Body } catch {
        Write-SsyLog "FEHLER in '$Name': $($_.Exception.Message)"
        Add-SsyCheck 'Tool' $Name $Category 'Info' "Prüfung konnte nicht vollständig ausgeführt werden: $($_.Exception.Message)" 'Tool als Administrator auf einem SANsymphony-Server starten; ggf. ältere SANsymphony-Version ohne diese Funktion'
    }
}
function Add-SsyInventory([string]$Title, $Rows, [string[]]$Columns) {
    [void]$script:Inventory.AppendLine("=== $Title ===")
    $r = @($Rows)
    if ($r.Count) {
        $t = if ($Columns) { $r | Select-Object $Columns } else { $r }
        [void]$script:Inventory.AppendLine((($t | Format-Table -AutoSize -Wrap | Out-String -Width 400).Trim()))
    } else { [void]$script:Inventory.AppendLine('(keine)') }
    [void]$script:Inventory.AppendLine('')
}

#region Hilfsfunktionen
function ConvertTo-SsyNumber($v) {
    if ($null -eq $v) { return $null }
    if ($v.PSObject.Properties['Value']) { return [double]$v.Value }
    if ($v -is [ValueType]) { return [double]$v }
    try { return [double]"$v" } catch { return $null }
}
function Format-SsyGB($v) { $n = ConvertTo-SsyNumber $v; if ($null -eq $n) { '' } else { '{0:N1} GB' -f ($n / 1GB) } }
function Get-SsyServerFromCaption([string]$ext) { if ($ext -match ' on (.+)$') { $Matches[1] } else { $null } }
function Get-SsyDelta($a, $b, [string]$p) {
    if (-not $a.PSObject.Properties[$p] -or -not $b.PSObject.Properties[$p]) { return $null }
    [double]$b.$p - [double]$a.$p
}
function Get-SsyRatio($num, $den, [int]$digits = 2) { if ($null -eq $num -or $null -eq $den -or $den -le 0) { return $null }; [math]::Round($num / $den, $digits) }
function Get-SsyHitPct($h, $m) { if ($null -eq $h -or $null -eq $m -or ($h + $m) -le 0) { return $null }; [math]::Round(100 * $h / ($h + $m), 1) }
function ConvertTo-SsyUInt32([string]$ip) { $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
function Get-SsySubnet([string]$ip, [int]$prefix) {
    $mask = if ($prefix -le 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix)) }
    [pscustomobject]@{ Net = ((ConvertTo-SsyUInt32 $ip) -band $mask); Mask = $mask; Prefix = $prefix; Text = "$ip/$prefix" }
}
function Test-SsySubnetOverlap($a, $b) { ((($a.Net -band $b.Mask) -eq $b.Net) -or (($b.Net -band $a.Mask) -eq $a.Net)) }
function Test-SsyInSubnet([string]$ip, $subnet) { ((ConvertTo-SsyUInt32 $ip) -band $subnet.Mask) -eq $subnet.Net }
function Get-SsyCleanIp($addr) { ("$addr" -replace '^::(ffff:)?', '').Trim() }
function Get-SsyShort([string]$s, [int]$n = 90) { if (-not $s) { return '' }; $s = $s.Trim(); if ($s.Length -le $n) { $s } else { $s.Substring(0, $n) + '…' } }
function Get-SsyPerf($id) { try { Get-DcsPerformanceCounter -Object ([string]$id) -ErrorAction Stop } catch { $null } }
function Test-SsyTcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $ar = $c.BeginConnect($HostName, $Port, $null, $null); $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected; $ok } catch { $false } finally { $c.Close() }
}
#endregion

function Initialize-Ssy {
    $dll = 'C:\Program Files\DataCore\Powershell Support\DataCore.Executive.Cmdlets.dll'
    if (-not (Test-Path $dll)) {
        $base = (Get-ItemProperty 'HKLM:\SOFTWARE\DataCore\SANsymphony' -ErrorAction SilentlyContinue).InstallPath
        if ($base) { $alt = Join-Path (Split-Path $base -Parent) 'Powershell Support\DataCore.Executive.Cmdlets.dll'; if (Test-Path $alt) { $dll = $alt } }
    }
    if (-not (Test-Path $dll)) { throw 'DataCore-PowerShell-Cmdlets nicht gefunden. Das Tool muss auf einem SANsymphony-Server laufen.' }
    if (-not (Get-Command Connect-DcsServer -ErrorAction SilentlyContinue)) { Import-Module $dll -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop }
    $script:Conn = Connect-DcsServer
    $script:LocalServerId = "$((Get-ItemProperty 'HKLM:\SOFTWARE\DataCore\Executive' -ErrorAction SilentlyContinue).ServerID)"
    $script:Group = Get-DcsServerGroup | Where-Object { $_.OurGroup } | Select-Object -First 1
    $script:AllServers = @(Get-DcsServer)
    $script:OwnServers = @($script:AllServers | Where-Object { "$($_.GroupId)" -eq "$($script:Group.Id)" })
    $script:OwnNames = @($script:OwnServers | ForEach-Object { $_.Caption })
    $script:OwnIds = @($script:OwnServers | ForEach-Object { "$($_.Id)" })
    $script:LocalServer = $script:OwnServers | Where-Object { "$($_.Id)" -eq $script:LocalServerId } | Select-Object -First 1
    $script:Ports = @(Get-DcsPort)
    $script:PortConns = @(Get-DcsPortConnection)
    $script:VDisks = @(Get-DcsVirtualDisk)
    $script:LDisks = @(Get-DcsLogicalDisk)
    $script:Pools = @(Get-DcsPool | Where-Object { $script:OwnIds -contains "$($_.ServerId)" })
    $script:PDisks = @(Get-DcsPhysicalDisk | Where-Object { $script:OwnIds -contains "$($_.HostId)" })
    $script:Repl = @(); try { $script:Repl = @(Get-DcsReplication -ErrorAction Stop) } catch {}
    $script:IsVm = [bool]($script:LocalServer.IsVirtualMachine) -or ("$((Get-CimInstance Win32_ComputerSystem).Model)" -match 'VMware|Virtual|KVM|HVM')
    # lokale iSCSI-Karten (Frontend/Mirror) für Netzwerk- und Pfadprüfungen
    $script:Nics = New-Object System.Collections.Generic.List[object]
    foreach ($p in $script:Ports | Where-Object { "$($_.HostId)" -eq $script:LocalServerId -and $_.ServerPortProperties -and $_.ServerPortProperties.IScsiPortalsConfig }) {
        $role = "$($p.ServerPortProperties.Role)"
        if ($role -notmatch 'Frontend|Mirror') { continue }
        foreach ($portal in $p.ServerPortProperties.IScsiPortalsConfig) {
            $ip = Get-SsyCleanIp $portal.Address
            $nip = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ip -ErrorAction SilentlyContinue
            if (-not $nip) { $script:Nics.Add([pscustomobject]@{ Port = $p.Caption; Role = $role; IP = $ip; Missing = $true }); continue }
            $ad = Get-NetAdapter -InterfaceIndex $nip.InterfaceIndex
            $script:Nics.Add([pscustomobject]@{ Port = $p.Caption; Role = $role; IP = $ip; Missing = $false; Prefix = [int]$nip.PrefixLength; Adapter = $ad.Name; Desc = $ad.InterfaceDescription
                    IfIndex = $nip.InterfaceIndex; Guid = $ad.InterfaceGuid; SpeedGbps = [math]::Round($ad.Speed / 1e9, 1); Mtu = [int](Get-NetIPInterface -InterfaceIndex $nip.InterfaceIndex -AddressFamily IPv4).NlMtu
                    Subnet = (Get-SsySubnet $ip ([int]$nip.PrefixLength)); Driver = "$($ad.DriverVersion)"; Status = "$($ad.Status)" })
        }
    }
}

#region Konfiguration: Gruppe, Lizenz, Server
function Test-SsyGroupAndServers {
    $g = $script:Group
    Invoke-SsyStep 'Lizenz & Software' 'Servergruppe' {
        if ($g.OutOfCompliance) { Add-SsyCheck 'Lizenz & Software' 'Lizenz-Compliance' $g.Caption 'Kritisch' 'Servergruppe ist außerhalb der Lizenzbedingungen' 'Lizenz prüfen und aktualisieren' }
        else { Add-SsyCheck 'Lizenz & Software' 'Lizenz-Compliance' $g.Caption 'OK' "Lizenztyp: $($g.LicenseType)" }
        if ("$($g.LicenseType)" -match 'Trial') { Add-SsyCheck 'Lizenz & Software' 'Lizenztyp' $g.Caption 'Info' 'Testlizenz (Trial) aktiv' 'Vor Produktivbetrieb reguläre Lizenz einspielen' }
        $exp = $g.NextExpirationDate
        if ($exp -and ([datetime]$exp).Year -gt 2000) {
            $days = [int]((([datetime]$exp) - (Get-Date)).TotalDays)
            $st = if ($days -lt 0) { 'Kritisch' } elseif ($days -lt 30) { 'Warnung' } else { 'OK' }
            Add-SsyCheck 'Lizenz & Software' 'Lizenzablauf' $g.Caption $st "Nächster Ablauf: $(([datetime]$exp).ToString('dd.MM.yyyy')) ($days Tage)" $(if ($st -ne 'OK') { 'Lizenz rechtzeitig verlängern - abgelaufene Lizenz stoppt Server' })
        }
        $vers = @($script:OwnServers | ForEach-Object { "$($_.ProductVersion) (Build $($_.ProductBuild))" } | Sort-Object -Unique)
        if ($vers.Count -gt 1) { Add-SsyCheck 'Lizenz & Software' 'Gleicher Versionsstand' $g.Caption 'Warnung' "Unterschiedliche Versionen: $($vers -join '; ')" 'Alle Server auf denselben PSP-Stand bringen' }
        else { Add-SsyCheck 'Lizenz & Software' 'Gleicher Versionsstand' $g.Caption 'OK' "Alle Server auf $($vers -join '')" }
        if ($script:OwnServers.Count -lt 2) { Add-SsyCheck 'Verfügbarkeit' 'Anzahl Server' $g.Caption 'Info' "Gruppe hat $($script:OwnServers.Count) Server - keine synchrone Spiegelung möglich" '' }
        else { Add-SsyCheck 'Verfügbarkeit' 'Anzahl Server' $g.Caption 'OK' "$($script:OwnServers.Count) Server in der Gruppe" }
        if ($script:OwnServers.Count -eq 2) {
            $wit = @(); try { $wit = @(Get-DcsWitness -ErrorAction Stop) } catch {}
            if (-not $wit.Count -and -not $g.DefaultWitness) { Add-SsyCheck 'Verfügbarkeit' 'Witness (Split-Brain-Schutz)' $g.Caption 'Info' 'Kein Witness konfiguriert' 'Bei zwei Servern einen Witness einrichten, damit bei Verbindungsverlust automatisch die richtige Seite aktiv bleibt' }
            else { Add-SsyCheck 'Verfügbarkeit' 'Witness (Split-Brain-Schutz)' $g.Caption 'OK' 'Witness vorhanden' }
        }
        if ("$($g.State)" -notmatch 'Present|Online|Healthy') { Add-SsyCheck 'Verfügbarkeit' 'Gruppenstatus' $g.Caption 'Warnung' "Status: $($g.State)" 'Gruppenstatus in der Konsole prüfen' }
        try {
            $cs = Get-DcsConfigurationState -ErrorAction Stop | Select-Object -First 1
            if ("$($cs.State)" -ne 'Synchronized') { Add-SsyCheck 'Betrieb' 'Konfiguration synchron' $g.Caption 'Warnung' "Konfigurationsstatus: $($cs.State)" 'Konfiguration ist nicht auf allen Servern synchron - Verbindung zwischen den Servern prüfen' }
            else { Add-SsyCheck 'Betrieb' 'Konfiguration synchron' $g.Caption 'OK' 'Synchronized' }
        } catch {}
    }
    Invoke-SsyStep 'Server & Cache' 'Server' {
        $rows = foreach ($s in $script:OwnServers) {
            if ("$($s.State)" -ne 'Online') { Add-SsyCheck 'Verfügbarkeit' 'Serverstatus' $s.Caption 'Kritisch' "Status: $($s.State)" 'Server und Dienst DataCore Executive prüfen' }
            else { Add-SsyCheck 'Verfügbarkeit' 'Serverstatus' $s.Caption 'OK' 'Online' }
            if ($s.MaintenanceModeEnabled) { Add-SsyCheck 'Verfügbarkeit' 'Wartungsmodus' $s.Caption 'Warnung' 'Server ist im Wartungsmodus' 'Wartungsmodus nach Abschluss der Arbeiten beenden' }
            if ("$($s.CacheState)" -notmatch '^Writeback') { Add-SsyCheck 'Server & Cache' 'Schreib-Cache-Modus' $s.Caption 'Kritisch' "Cache-Status: $($s.CacheState)" 'Write-Through kostet massiv Leistung: Ursache klären (Partner offline, USV, Speicher)' }
            else { Add-SsyCheck 'Server & Cache' 'Schreib-Cache-Modus' $s.Caption 'OK' "$($s.CacheState)" }
            if ("$($s.PowerState)" -ne 'ACOnline') { Add-SsyCheck 'Server & Cache' 'Stromversorgung' $s.Caption 'Warnung' "Power-Status: $($s.PowerState)" 'USV/Stromversorgung prüfen' }
            else { Add-SsyCheck 'Server & Cache' 'Stromversorgung' $s.Caption 'OK' 'Netzbetrieb' }
            if ("$($s.LogStatus)" -and "$($s.LogStatus)" -ne 'Operational') { Add-SsyCheck 'Server & Cache' 'Protokollierung' $s.Caption 'Warnung' "LogStatus: $($s.LogStatus)" 'Ereignisprotokollierung von DataCore prüfen (Platz auf C:, Dienst)' }
            if ($s.LicenseExceeded) { Add-SsyCheck 'Lizenz & Software' 'Lizenzkapazität' $s.Caption 'Kritisch' 'Lizenz überschritten' 'Kapazität erweitern oder Lizenz aufstocken' }
            if ($s.OutOfCompliance) { Add-SsyCheck 'Lizenz & Software' 'Server-Lizenz' $s.Caption 'Kritisch' 'Server außerhalb der Lizenzbedingungen' 'Lizenz prüfen' }
            $total = ConvertTo-SsyNumber $s.TotalSystemMemory; $avail = ConvertTo-SsyNumber $s.AvailableSystemMemory
            $cache = $null; try { $cache = ConvertTo-SsyNumber (Get-DcsServerCacheSize -Server $s.Caption -ErrorAction Stop) } catch {}
            if ($total) {
                $pct = [math]::Round(100 * $avail / $total, 1)
                $txt = "$([math]::Round($avail/1GB,2)) GB von $([math]::Round($total/1GB,1)) GB frei ($pct %)"
                if ($pct -le $script:T.MemCritPct) { Add-SsyCheck 'Server & Cache' 'Freier Arbeitsspeicher' $s.Caption 'Kritisch' $txt 'RAM erweitern; DataCore-Cache und Windows brauchen Reserve' }
                elseif ($pct -le $script:T.MemWarnPct) { Add-SsyCheck 'Server & Cache' 'Freier Arbeitsspeicher' $s.Caption 'Warnung' $txt 'RAM erweitern oder Speicherverbraucher (z. B. ILDC/ZFS-Cache, andere Software) begrenzen' }
                else { Add-SsyCheck 'Server & Cache' 'Freier Arbeitsspeicher' $s.Caption 'OK' $txt }
                if ($cache) {
                    $cp = [math]::Round(100 * $cache / $total, 0)
                    $txt2 = "$([math]::Round($cache/1GB,2)) GB Cache ($cp % des RAM)"
                    if ($cache -lt 2GB) { Add-SsyCheck 'Server & Cache' 'Cache-Größe' $s.Caption 'Warnung' $txt2 'Sehr kleiner Schreib-/Lesecache - RAM erweitern (DataCore-Empfehlung: großzügig RAM für Cache)' }
                    else { Add-SsyCheck 'Server & Cache' 'Cache-Größe' $s.Caption 'OK' $txt2 }
                }
            }
            if ($s.IsVirtualMachine) { Add-SsyCheck 'Server & Cache' 'Plattform' $s.Caption 'Info' 'Virtueller SANsymphony-Server' 'RAM und CPU im Hypervisor reservieren, VMXNET3-NICs, Pass-Through für Speicher bevorzugen' }
            [pscustomobject]@{ Server = $s.Caption; Status = "$($s.State)"; Version = "$($s.ProductVersion)"; Build = "$($s.ProductBuild)"; Cache = "$($s.CacheState)"
                RAM = "$([math]::Round($total/1GB,1)) GB"; Frei = "$([math]::Round($avail/1GB,2)) GB"; CacheGröße = $(if ($cache) { "$([math]::Round($cache/1GB,1)) GB" }); CPU = "$($s.ProcessorInfo.NumberCores) Kerne"
                VM = $s.IsVirtualMachine; IPs = "$($s.IpAddresses)" }
        }
        Add-SsyInventory "Servergruppe $($g.Caption) - Server" $rows
        $foreign = @($script:AllServers | Where-Object { $script:OwnIds -notcontains "$($_.Id)" })
        if ($foreign.Count) { Add-SsyInventory 'Server anderer Gruppen (Partner)' ($foreign | ForEach-Object { [pscustomobject]@{ Server = $_.Caption; Status = "$($_.State)" } }) }
    }
    Invoke-SsyStep 'Betrieb' 'Zeitsynchronisation' {
        foreach ($s in $script:OwnServers) {
            $t0 = [datetime]::UtcNow
            $st = Get-DcsServerTime -Server $s.Caption -ErrorAction Stop
            $t1 = [datetime]::UtcNow
            $mid = $t0.AddTicks(($t1 - $t0).Ticks / 2)
            $skew = [math]::Round([math]::Abs((([datetime]$st).ToUniversalTime() - $mid).TotalSeconds), 1)
            $txt = "Abweichung zu diesem Server: $skew s"
            if ($skew -ge $script:T.TimeSkewCritSec) { Add-SsyCheck 'Betrieb' 'Uhrzeit synchron' $s.Caption 'Kritisch' $txt 'Zeitsynchronisation (NTP/Domäne) auf allen Servern einrichten' }
            elseif ($skew -ge $script:T.TimeSkewWarnSec) { Add-SsyCheck 'Betrieb' 'Uhrzeit synchron' $s.Caption 'Warnung' $txt 'Zeitsynchronisation (NTP/Domäne) prüfen - abweichende Uhren erschweren Fehleranalyse und Replikation' }
            else { Add-SsyCheck 'Betrieb' 'Uhrzeit synchron' $s.Caption 'OK' $txt }
        }
    }
    Invoke-SsyStep 'Betrieb' 'Konfigurationssicherung' {
        foreach ($s in $script:OwnServers) {
            $f = "$(Get-DcsBackUpFolder -Server $s.Caption -ErrorAction Stop)"
            if (-not $f) { Add-SsyCheck 'Betrieb' 'Konfigurationssicherung' $s.Caption 'Warnung' 'Kein Sicherungsordner für die DataCore-Konfiguration festgelegt' 'Sicherungsordner festlegen und Konfiguration regelmäßig sichern (Backup-DcsConfiguration)'; continue }
            if ("$($s.Id)" -eq $script:LocalServerId) {
                $last = Get-ChildItem -Path $f -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $last) { Add-SsyCheck 'Betrieb' 'Konfigurationssicherung' $s.Caption 'Warnung' "Ordner $f enthält keine Sicherung" 'Konfiguration sichern und regelmäßig wiederholen' }
                else {
                    $age = [int]((Get-Date) - $last.LastWriteTime).TotalDays
                    $st = if ($age -gt $script:T.BackupWarnDays) { 'Warnung' } else { 'OK' }
                    Add-SsyCheck 'Betrieb' 'Konfigurationssicherung' $s.Caption $st "Letzte Sicherung: $($last.Name) vor $age Tag(en)" $(if ($st -ne 'OK') { 'Konfiguration nach jeder Änderung und regelmäßig sichern' })
                }
            } else { Add-SsyCheck 'Betrieb' 'Konfigurationssicherung' $s.Caption 'OK' "Sicherungsordner: $f (Inhalt nur lokal prüfbar)" }
        }
    }
    Invoke-SsyStep 'Betrieb' 'Benachrichtigung' {
        $smtp = $null; try { $smtp = Get-DcsSMTPSettings -ErrorAction Stop } catch {}
        $sys = $null; try { $sys = Get-DcsSyslogSettings -ErrorAction Stop } catch {}
        if (-not $smtp -and -not $sys -and -not $script:Group.SmtpSettings -and -not $script:Group.SyslogSettings) {
            Add-SsyCheck 'Betrieb' 'Alarmierung (E-Mail/Syslog)' $script:Group.Caption 'Warnung' 'Weder E-Mail- noch Syslog-Benachrichtigung eingerichtet' 'SMTP oder Syslog einrichten, damit Ausfälle und Warnungen jemand erfährt'
        } else { Add-SsyCheck 'Betrieb' 'Alarmierung (E-Mail/Syslog)' $script:Group.Caption 'OK' "$(if ($smtp -or $script:Group.SmtpSettings) { 'E-Mail ' })$(if ($sys -or $script:Group.SyslogSettings) { 'Syslog' })" }
        $tel = $script:Group.TelemetryStatusInfo
        if ($tel -and "$($tel.Status)" -and "$($tel.Status)" -ne 'Connected' -and "$($script:Group.Telemetry)" -eq 'Enabled') {
            Add-SsyCheck 'Betrieb' 'Telemetrie/Support-Verbindung' $script:Group.Caption 'Info' "Status: $($tel.Status) $($tel.Reason)" 'Internetzugang für DataCore Insight Services prüfen'
        }
    }
}
#endregion

#region Pools, Disks
function Test-SsyPoolsDisks {
    Invoke-SsyStep 'Pools & Disks' 'Pools' {
        $members = @(); try { $members = @(Get-DcsPoolMember -ErrorAction Stop) } catch {}
        $rows = foreach ($p in $script:Pools) {
            if ("$($p.PoolStatus)" -ne 'Running') { Add-SsyCheck 'Pools & Disks' 'Pool-Status' $p.ExtendedCaption 'Kritisch' "Status: $($p.PoolStatus)" 'Pool-Disks und Backend prüfen' }
            else { Add-SsyCheck 'Pools & Disks' 'Pool-Status' $p.ExtendedCaption 'OK' 'Running' }
            if ("$($p.PoolMode)" -and "$($p.PoolMode)" -ne 'ReadWrite') { Add-SsyCheck 'Pools & Disks' 'Pool-Modus' $p.ExtendedCaption 'Warnung' "Modus: $($p.PoolMode)" 'Pool ist nicht beschreibbar - Ursache prüfen' }
            $pc = Get-SsyPerf $p.Id
            $free = $null
            if ($pc -and $null -ne $pc.PercentAvailable) {
                $free = [double]$pc.PercentAvailable
                $txt = "$free % frei ($([math]::Round($pc.BytesAvailable/1GB,1)) GB von $([math]::Round($pc.BytesTotal/1GB,1)) GB)"
                if ($free -le $script:T.PoolFreeCritPct) { Add-SsyCheck 'Pools & Disks' 'Freie Kapazität' $p.ExtendedCaption 'Kritisch' $txt 'Sofort Kapazität erweitern - voller Pool stoppt Schreibzugriffe' }
                elseif ($free -le $script:T.PoolFreeWarnPct) { Add-SsyCheck 'Pools & Disks' 'Freie Kapazität' $p.ExtendedCaption 'Warnung' $txt 'Kapazitätserweiterung planen' }
                else { Add-SsyCheck 'Pools & Disks' 'Freie Kapazität' $p.ExtendedCaption 'OK' $txt }
                if ($pc.BytesOverSubscribed -gt 0) { Add-SsyCheck 'Pools & Disks' 'Überbuchung' $p.ExtendedCaption 'Info' "$([math]::Round($pc.BytesOverSubscribed/1GB,1)) GB mehr vergeben als physisch vorhanden (Thin Provisioning)" 'Belegung regelmäßig beobachten' }
            }
            $pm = @($members | Where-Object { "$($_.DiskPoolId)" -eq "$($p.Id)" })
            foreach ($m in $pm | Where-Object { "$($_.MemberState)" -ne 'Healthy' }) { Add-SsyCheck 'Pools & Disks' 'Pool-Disk-Status' $m.ExtendedCaption 'Kritisch' "Status: $($m.MemberState)" 'Disk prüfen/ersetzen' }
            $tiers = @($pm | ForEach-Object { $_.DiskTier } | Sort-Object -Unique)
            if ($pm.Count -eq 1) { Add-SsyCheck 'Pools & Disks' 'Disks im Pool' $p.ExtendedCaption 'Info' 'Pool besteht aus nur einer Disk' 'Ausfallsicherheit hängt vollständig am Backend-RAID - sicherstellen, dass die Disk redundant ist' }
            if ($p.AutoTieringEnabled -and $tiers.Count -gt 1) { Add-SsyCheck 'Pools & Disks' 'Auto-Tiering' $p.ExtendedCaption 'OK' "Aktiv über $($tiers.Count) Tiers ($($tiers -join ', '))" }
            [pscustomobject]@{ Pool = $p.ExtendedCaption; Status = "$($p.PoolStatus)"; Typ = "$($p.Type)"; Chunk = "$($p.ChunkSize)"; Tiering = $p.AutoTieringEnabled; Tiers = ($tiers -join ','); Disks = $pm.Count
                Frei = $(if ($null -ne $free) { "$free %" }); Gesamt = $(if ($pc) { '{0:N1} GB' -f ($pc.BytesTotal / 1GB) }); Dedup = "$($p.DeduplicationState)"; Verschlüsselt = $p.HasEncryption }
        }
        Add-SsyInventory 'Disk-Pools' $rows
    }
    Invoke-SsyStep 'Pools & Disks' 'Physische Disks' {
        $rows = foreach ($d in $script:PDisks) {
            $srv = Get-SsyServerFromCaption $d.ExtendedCaption
            if ("$($d.Type)" -eq 'Pool' -or $d.PoolMemberId) {
                if ("$($d.DiskStatus)" -ne 'Online') { Add-SsyCheck 'Pools & Disks' 'Disk-Status' $d.ExtendedCaption 'Kritisch' "Status: $($d.DiskStatus)" 'Disk/Pfad prüfen' }
                if ("$($d.SmartStatus)" -match 'Fail|Bad|Critical|Predict') { Add-SsyCheck 'Pools & Disks' 'S.M.A.R.T.' $d.ExtendedCaption 'Kritisch' "SMART: $($d.SmartStatus)" 'Disk vorsorglich ersetzen' }
                if ("$($d.PresenceStatus)" -ne 'Present') { Add-SsyCheck 'Pools & Disks' 'Disk vorhanden' $d.ExtendedCaption 'Kritisch' "Presence: $($d.PresenceStatus)" 'Disk fehlt - Verkabelung/Controller prüfen' }
            } elseif ("$($d.Type)" -notmatch 'Mirror|Client|Proxy|Remote|Replication|Witness|Rollback|Stream' -and -not $d.IsBootDisk -and -not $d.InUse -and -not $d.Partitioned -and "$($d.PresenceStatus)" -eq 'Present') {
                Add-SsyCheck 'Pools & Disks' 'Ungenutzte Disk' $d.ExtendedCaption 'Info' "$(Format-SsyGB $d.Size) unpartitioniert und ungenutzt ($($d.BusType))" 'Bei Bedarf einem Pool hinzufügen'
            }
            [pscustomobject]@{ Disk = $d.Caption; Server = $srv; Typ = "$($d.Type)"; Größe = (Format-SsyGB $d.Size); Bus = "$($d.BusType)"; SSD = $d.IsSolidState; Status = "$($d.DiskStatus)"; SMART = "$($d.SmartStatus)"; Pool = [bool]$d.PoolMemberId; Inquiry = "$($d.InquiryData)".Trim() }
        }
        Add-SsyInventory 'Physische Disks' $rows
    }
}
#endregion

#region vDisks, Spiegel, Host-Pfade
function Test-SsyVirtualDisks {
    Invoke-SsyStep 'vDisks & Spiegel' 'Virtuelle Disks' {
        $profiles = @{}; try { foreach ($sp in Get-DcsStorageProfile -ErrorAction Stop) { $profiles["$($sp.Id)"] = $sp.Caption } } catch {}
        $rows = foreach ($v in $script:VDisks) {
            $sz = Format-SsyGB $v.Size
            $mine = @($script:LDisks | Where-Object { "$($_.VirtualDiskId)" -eq "$($v.Id)" -and $script:OwnNames -contains (Get-SsyServerFromCaption $_.ExtendedCaption) })
            if (-not $mine.Count) { continue }   # vDisk gehört zu anderer Gruppe
            if ("$($v.DiskStatus)" -ne 'Online') { Add-SsyCheck 'vDisks & Spiegel' 'vDisk-Status' $v.Caption 'Kritisch' "Status: $($v.DiskStatus)" 'Spiegelstatus, Logical Disks und Pools prüfen' }
            else { Add-SsyCheck 'vDisks & Spiegel' 'vDisk-Status' $v.Caption 'OK' "Online, $($v.Type), $sz" }
            if ($v.Offline -or $v.Disabled) { Add-SsyCheck 'vDisks & Spiegel' 'vDisk deaktiviert' $v.Caption 'Warnung' "Offline=$($v.Offline) Disabled=$($v.Disabled)" 'Prüfen, ob gewollt' }
            if ("$($v.Type)" -match 'NonMirrored|Single') { Add-SsyCheck 'Verfügbarkeit' 'Spiegelung' $v.Caption 'Info' 'vDisk ist nicht gespiegelt - fällt ihr Server aus, ist sie nicht erreichbar' 'Für produktive Daten gespiegelte vDisks verwenden' }
            if ($v.WriteThrough) { Add-SsyCheck 'vDisks & Spiegel' 'Write-Through erzwungen' $v.Caption 'Warnung' 'vDisk arbeitet ohne Schreib-Cache' 'Prüfen, ob gewollt - kostet deutlich Latenz' }
            if (-not $v.IsServed) { Add-SsyCheck 'vDisks & Spiegel' 'An Host ausgeliefert' $v.Caption 'Info' 'vDisk ist keinem Host zugeordnet' 'Ungenutzte vDisk? Ggf. löschen oder zuordnen' }
            if ($v.ManualRecovery) { Add-SsyCheck 'vDisks & Spiegel' 'Manuelle Wiederherstellung' $v.Caption 'Info' 'Spiegel-Recovery muss manuell gestartet werden' 'Nach Ausfällen Recovery in der Konsole anstoßen' }
            foreach ($l in $mine) {
                if ("$($l.Failure)" -and "$($l.Failure)" -ne 'Healthy') { Add-SsyCheck 'vDisks & Spiegel' 'Logical-Disk-Fehler' $l.ExtendedCaption 'Kritisch' "Failure: $($l.Failure)" 'Backend/Pool dieser Seite prüfen' }
                if ("$($l.DataStatus)" -and "$($l.DataStatus)" -ne 'UpToDate') { Add-SsyCheck 'vDisks & Spiegel' 'Datenstand Spiegelseite' $l.ExtendedCaption 'Warnung' "DataStatus: $($l.DataStatus)" 'Spiegelseite ist nicht aktuell - Recovery/Resync prüfen' }
                if ("$($l.PresenceStatus)" -ne 'Present') { Add-SsyCheck 'vDisks & Spiegel' 'Spiegelseite vorhanden' $l.ExtendedCaption 'Kritisch' "Presence: $($l.PresenceStatus)" 'Server/Pool dieser Seite prüfen' }
                if ($l.MirrorAccessDisabled) { Add-SsyCheck 'vDisks & Spiegel' 'Spiegelzugriff' $l.ExtendedCaption 'Warnung' 'Spiegelzugriff deaktiviert' 'Prüfen, ob gewollt' }
                if ($l.WitnessContactFailed) { Add-SsyCheck 'Verfügbarkeit' 'Witness erreichbar' $l.ExtendedCaption 'Warnung' 'Witness nicht erreichbar' 'Witness-Verbindung prüfen' }
                $pc = Get-SsyPerf $l.Id
                if ($pc -and $pc.BytesToRecover -gt 0) { Add-SsyCheck 'vDisks & Spiegel' 'Spiegel-Resynchronisation' $l.ExtendedCaption 'Warnung' "Resync läuft: $([math]::Round($pc.BytesToRecover/1GB,2)) GB offen ($($pc.PercentRecovered) %)" 'Während des Resync ist die Redundanz eingeschränkt; Backend und Spiegelnetz sind zusätzlich belastet' }
            }
            [pscustomobject]@{ vDisk = $v.Caption; Typ = "$($v.Type)"; Größe = $sz; Status = "$($v.DiskStatus)"; Ausgeliefert = $v.IsServed; Profil = $profiles["$($v.StorageProfileId)"]; Recovery = "$($v.RecoveryPriority)"
                WriteThrough = $v.WriteThrough; Seiten = (($mine | ForEach-Object { "$(Get-SsyServerFromCaption $_.ExtendedCaption):$($_.DataStatus)" }) -join ', ') }
        }
        Add-SsyInventory 'Virtuelle Disks' $rows
        $mir = @(); try { $mir = @(Get-DcsMirror -ErrorAction Stop) } catch {}
        foreach ($m in $mir) {
            $vd = $script:VDisks | Where-Object { "$($_.Id)" -eq "$($m.VirtualDiskId)" } | Select-Object -First 1
            $name = if ($vd) { $vd.Caption } else { $m.Caption }
            $rec = @("$($m.FirstRecovery)", "$($m.SecondRecovery)") | Where-Object { $_ -and $_ -notmatch '^(NoRecoveryNeeded|Undefined|None)$' }
            if ("$($m.DataStatus)" -ne 'UpToDate') { Add-SsyCheck 'vDisks & Spiegel' 'Spiegelzustand' $name 'Warnung' "DataStatus: $($m.DataStatus)" 'Spiegel ist nicht synchron' }
            elseif ($rec) { Add-SsyCheck 'vDisks & Spiegel' 'Spiegelzustand' $name 'Warnung' "Recovery: $($rec -join ', ')" 'Recovery läuft oder steht aus' }
        }
        if ($mir.Count -and -not @($script:Checks.ToArray() | Where-Object { $_.Check -eq 'Spiegelzustand' }).Count) { Add-SsyCheck 'vDisks & Spiegel' 'Spiegelzustand' $script:Group.Caption 'OK' "$($mir.Count) Spiegelbeziehung(en) synchron" }
    }
}

function Test-SsyHostPaths {
    Invoke-SsyStep 'Host-Pfade' 'Hosts' {
        $clients = @(); try { $clients = @(Get-DcsClient -ErrorAction Stop) } catch {}
        $vlun = @(Get-DcsVirtualLogicalUnit | Where-Object { "$($_.Type)" -eq 'Client' })
        $connected = @{}
        foreach ($pc in $script:PortConns) { if ($pc.Connected) { $connected["$($pc.Caption)"] = $pc } }
        foreach ($c in $clients) {
            $obj = $c.ExtendedCaption
            if ("$($c.ConnectionState)" -and "$($c.ConnectionState)" -notmatch 'Connected') { Add-SsyCheck 'Host-Pfade' 'Host-Verbindung (vCenter)' $obj 'Warnung' "ConnectionState: $($c.ConnectionState)" 'Host im vCenter prüfen' }
            if ($c.InMaintenanceMode) { Add-SsyCheck 'Host-Pfade' 'Host im Wartungsmodus' $obj 'Info' 'Host ist im Wartungsmodus' '' }
            if (-not $c.MpioCapable) { Add-SsyCheck 'Host-Pfade' 'Multipathing' $obj 'Warnung' 'Host ist nicht als MPIO-fähig markiert' 'MPIO auf dem Host aktivieren und Host-Eigenschaft in DataCore setzen' }
            if ($c.PSObject.Properties['AluaSupport'] -and -not $c.AluaSupport) { Add-SsyCheck 'Host-Pfade' 'ALUA' $obj 'Info' 'ALUA nicht aktiv' 'Für bevorzugte Pfade ALUA aktivieren (Host-Typ passend wählen)' }
            # Pfade je vDisk
            $hostPorts = @($script:Ports | Where-Object { "$($_.HostId)" -eq "$($c.Id)" })
            $hpNames = @($hostPorts | ForEach-Object { $_.ExtendedCaption })
            $myVl = @($vlun | Where-Object { $hpNames -contains (("$($_.Caption)" -split ' \| ')[0]) })
            $paths = foreach ($vl in $myVl) {
                $parts = "$($vl.Caption)" -split ' \| '
                $ld = $script:LDisks | Where-Object { "$($_.Id)" -eq "$($vl.LogicalDiskId)" } | Select-Object -First 1
                $vd = if ($ld) { $script:VDisks | Where-Object { "$($_.Id)" -eq "$($ld.VirtualDiskId)" } | Select-Object -First 1 }
                $key = "$($parts[1]) to $($parts[0])"
                $pc = $connected[$key]
                $ips = ''
                if ($pc) { $ips = (@(foreach ($d in @($pc.PortADescriptor, $pc.PortBDescriptor)) { if ($d) { foreach ($cc in $d.Connections) { "$(Get-SsyCleanIp $cc.InitiatorIpAddress)->$(Get-SsyCleanIp $cc.TargetIpAddress)" } } }) -join ', ') }
                [pscustomobject]@{ Host = $c.Caption; vDisk = $(if ($vd) { $vd.Caption } else { '?' }); Initiator = $parts[0]; Ziel = $parts[1]; Server = (Get-SsyServerFromCaption $parts[1]); LUN = "$($vl.Lun)"
                    Aktiv = [bool]$pc; Freigegeben = $vl.Enabled; Verbindung = $ips; Zugriff = "$($vl.Access)" }
            }
            foreach ($g in @($paths) | Group-Object vDisk) {
                $tot = $g.Count; $act = @($g.Group | Where-Object { $_.Aktiv -and $_.Freigegeben }).Count
                $srvAct = @($g.Group | Where-Object { $_.Aktiv -and $_.Freigegeben } | ForEach-Object { $_.Server } | Sort-Object -Unique)
                $srvAll = @($g.Group | ForEach-Object { $_.Server } | Sort-Object -Unique)
                $o = "$($c.Caption) / $($g.Name)"
                if ($act -eq 0) { Add-SsyCheck 'Host-Pfade' 'Aktive Pfade je vDisk' $o 'Kritisch' "0 von $tot Pfaden aktiv" 'Host erreicht die vDisk nicht: iSCSI-Sessions, Netz und Mapping prüfen' }
                elseif ($act -lt $tot) {
                    $down = @($g.Group | Where-Object { -not ($_.Aktiv -and $_.Freigegeben) } | ForEach-Object { $_.Ziel })
                    Add-SsyCheck 'Host-Pfade' 'Aktive Pfade je vDisk' $o 'Warnung' "$act von $tot Pfaden aktiv; ohne Verbindung: $($down -join ', ')" 'Fehlende iSCSI-Sessions herstellen (Netz, Subnetze, VMkernel-Ports/Initiator-IPs, Discovery, Rescan)'
                } else { Add-SsyCheck 'Host-Pfade' 'Aktive Pfade je vDisk' $o 'OK' "$act von $tot Pfaden aktiv" }
                if ($srvAll.Count -ge 2 -and $srvAct.Count -lt 2) { Add-SsyCheck 'Verfügbarkeit' 'Host erreicht beide Spiegelseiten' $o 'Warnung' "Aktive Pfade nur zu: $($srvAct -join ', ')" 'Fällt dieser Server aus, verliert der Host die vDisk - Pfade zum zweiten Server herstellen' }
                elseif ($srvAll.Count -ge 2 -and $act -lt 4 -and $act -eq $srvAct.Count) { Add-SsyCheck 'Host-Pfade' 'Pfade je Server' $o 'Info' "Je Server nur ein aktiver Pfad" 'Zwei Pfade je Server erhöhen die Ausfallsicherheit (Netzkarte/Switch)' }
            }
            # Initiator-IPs des Hosts
            $hostIps = @(); $cross = @()
            foreach ($pc in $script:PortConns | Where-Object { $hpNames -contains (("$($_.Caption)" -split ' to ')[-1]) -and $_.Connected }) {
                foreach ($d in @($pc.PortADescriptor, $pc.PortBDescriptor)) {
                    if (-not $d) { continue }
                    foreach ($cc in $d.Connections) {
                        $src = Get-SsyCleanIp $cc.InitiatorIpAddress; $dst = Get-SsyCleanIp $cc.TargetIpAddress
                        if ($src -and $src -ne '0.0.0.0') { $hostIps += $src }
                        $n = $script:Nics | Where-Object { $_.IP -eq $dst -and -not $_.Missing } | Select-Object -First 1
                        if ($n -and $src -and $src -ne '0.0.0.0' -and -not (Test-SsyInSubnet $src $n.Subnet)) { $cross += "$src->$dst" }
                    }
                }
            }
            $hostIps = @($hostIps | Sort-Object -Unique)
            if ($hostIps.Count -eq 1 -and @($paths).Count -ge 2) { Add-SsyCheck 'Host-Pfade' 'Initiator-IPs des Hosts' $c.Caption 'Warnung' "Alle Sessions kommen von einer einzigen IP ($($hostIps[0]))" 'Zweiten iSCSI-Netzwerkport (z. B. VMkernel) im zweiten Netz anlegen, damit ein NIC-/Switch-Ausfall nicht alle Pfade trifft' }
            elseif ($hostIps.Count -ge 2) { Add-SsyCheck 'Host-Pfade' 'Initiator-IPs des Hosts' $c.Caption 'OK' ($hostIps -join ', ') }
            if ($cross) { Add-SsyCheck 'Host-Pfade' 'Sessions im passenden Subnetz' $c.Caption 'Warnung' "Sessions über Kreuz (Quelle nicht im Subnetz des Ziels): $($cross -join ', ')" 'Host-seitig jedem Netz einen eigenen iSCSI-Port mit passender Netzmaske geben' }
            Add-SsyInventory "Host-Pfade: $($c.Caption)" $paths
        }
        Add-SsyInventory 'Hosts' @($clients | ForEach-Object { [pscustomobject]@{ Host = $_.ExtendedCaption; Typ = "$($_.Type)"; Version = "$($_.Description)"; Status = "$($_.State)"; MPIO = $_.MpioCapable; ALUA = $_.AluaSupport; Pfadrichtlinie = "$($_.PathPolicy)" } })
        if (-not $clients.Count) { Add-SsyCheck 'Host-Pfade' 'Hosts' $script:Group.Caption 'Info' 'Keine Hosts registriert' '' }
    }
}
#endregion

#region Replikation, Snapshots, Monitore, Alarme
function Test-SsyProtection {
    Invoke-SsyStep 'Replikation & Schutz' 'Replikation' {
        $partners = @(Get-DcsServerGroup | Where-Object { -not $_.OurGroup })
        if ($partners.Count -and -not $script:Repl.Count) { Add-SsyCheck 'Replikation & Schutz' 'Replikation eingerichtet' ($partners.Caption -join ', ') 'Info' 'Partnergruppe verbunden, aber keine Replikation' 'Replikation für schutzbedürftige vDisks anlegen' }
        if (-not $partners.Count) { Add-SsyCheck 'Replikation & Schutz' 'Disaster Recovery' $script:Group.Caption 'Info' 'Keine Partnergruppe für Replikation' 'Für Standortausfälle Replikation an zweiten Standort erwägen' }
        $rows = foreach ($r in $script:Repl) {
            $state = "$($r.ReplicationState)"; $fail = "$($r.FailureStatus)"; $xfer = "$($r.TransferStatus)"
            $pc = Get-SsyPerf $r.Id
            $lag = if ($pc) { [double]$pc.TimeLag } else { $null }
            $init = if ($pc) { $pc.InitializationPercentage } else { $null }
            $toSend = if ($pc) { [math]::Round($pc.BytesToSend / 1MB, 1) } else { $null }
            $buf = if ($pc) { $pc.ReplicationBufferPercentFreeSpace } else { $null }
            $txt = "Status: $state; Übertragung: $xfer; Fehler: $(if ($fail) { $fail } else { 'keine' })" + $(if ($null -ne $init -and $state -match 'Init') { "; Initialisierung $init %" }) + $(if ($toSend) { "; $toSend MB ausstehend" })
            if ($r.Paused) { Add-SsyCheck 'Replikation & Schutz' 'Replikationsstatus' $r.Caption 'Warnung' "$txt; pausiert" 'Replikation fortsetzen, sonst wächst der Rückstand' }
            elseif ($fail -and $fail -notmatch '^(None|Ok|NoFailure)$') { Add-SsyCheck 'Replikation & Schutz' 'Replikationsstatus' $r.Caption 'Warnung' $txt 'Verbindung zur Partnergruppe und Replikationspuffer prüfen' }
            elseif ("$($r.InitializationFailureStatus)" -and "$($r.InitializationFailureStatus)" -ne 'NoFailure') { Add-SsyCheck 'Replikation & Schutz' 'Replikationsstatus' $r.Caption 'Warnung' "$txt; Initialisierungsfehler: $($r.InitializationFailureStatus)" 'Initialisierung neu starten' }
            elseif ($state -match 'Init') { Add-SsyCheck 'Replikation & Schutz' 'Replikationsstatus' $r.Caption 'Info' $txt 'Erstkopie läuft - erzeugt zusätzliche Last auf Quelle und Netz; Ziel ist erst danach nutzbar' }
            else { Add-SsyCheck 'Replikation & Schutz' 'Replikationsstatus' $r.Caption 'OK' $txt }
            if ($null -ne $lag -and $lag -gt $script:T.ReplLagWarnSec -and $state -notmatch 'Init') { Add-SsyCheck 'Replikation & Schutz' 'Replikationsrückstand' $r.Caption 'Warnung' "Zeitversatz $([math]::Round($lag/60,1)) min" 'Bandbreite zur DR-Seite und Puffer prüfen - bei Ausfall gingen diese Daten verloren' }
            if ($null -ne $buf -and $buf -lt $script:T.ReplBufferWarnPct -and $r.IsActiveSide) { Add-SsyCheck 'Replikation & Schutz' 'Replikationspuffer' $r.Caption 'Warnung' "Nur $buf % frei" 'Puffer vergrößern oder Übertragung beschleunigen - voller Puffer stoppt die Replikation' }
            if ("$($r.BackendStatus)" -and "$($r.BackendStatus)" -notmatch '^(Normal|NA|None|NotApplicable)$') { Add-SsyCheck 'Replikation & Schutz' 'Replikations-Backend' $r.Caption 'Warnung' "BackendStatus: $($r.BackendStatus)" 'Replikationspuffer-Datenträger prüfen' }
            if ("$($r.TestModeStatus)" -and "$($r.TestModeStatus)" -ne 'Disabled') { Add-SsyCheck 'Replikation & Schutz' 'DR-Testmodus' $r.Caption 'Info' "Testmodus: $($r.TestModeStatus)" 'Testmodus nach dem DR-Test beenden' }
            if ($r.IsActiveSide -and $script:OwnIds -contains "$($r.FirstServerId)") {
                $srv = $script:OwnServers | Where-Object { "$($_.Id)" -eq "$($r.FirstServerId)" } | Select-Object -First 1
                $bf = ''; try { $bf = "$(Get-DcsReplicationBufferFolder -Server $srv.Caption -ErrorAction Stop)" } catch {}
                if (-not $bf) { Add-SsyCheck 'Replikation & Schutz' 'Replikationspuffer-Ordner' $srv.Caption 'Warnung' 'Kein Pufferordner gesetzt' 'Pufferordner auf eigenem, ausreichend großem Datenträger festlegen' }
            }
            [pscustomobject]@{ Replikation = $r.ExtendedCaption; Status = $state; Übertragung = $xfer; Fehler = $fail; Pausiert = $r.Paused; AktiveSeite = $r.IsActiveSide; Init = $init; AusstehendMB = $toSend; VersatzSek = $lag; PufferFrei = $buf }
        }
        Add-SsyInventory 'Replikationen' $rows
    }
    Invoke-SsyStep 'Replikation & Schutz' 'Snapshots & CDP' {
        $snaps = @(); try { $snaps = @(Get-DcsSnapshot -ErrorAction Stop) } catch {}
        $old = @()
        foreach ($s in $snaps) {
            $ts = $null
            foreach ($pn in 'TimeStamp', 'CreationTime', 'Created', 'CreationDate') { if ($s.PSObject.Properties[$pn] -and $s.$pn) { $ts = [datetime]$s.$pn; break } }
            if ($ts -and ((Get-Date) - $ts).TotalDays -gt 14) { $old += "$($s.Caption) ($([int]((Get-Date) - $ts).TotalDays) Tage)" }
        }
        if ($old) { Add-SsyCheck 'Replikation & Schutz' 'Alte Snapshots' $script:Group.Caption 'Warnung' "Älter als 14 Tage: $($old -join ', ')" 'Alte Snapshots belegen Platz und kosten Leistung - löschen oder Zweck prüfen' }
        $cdp = @($script:LDisks | Where-Object { "$($_.StreamState)" -and "$($_.StreamState)" -ne 'NotPresent' })
        $rb = @(); try { $rb = @(Get-DcsRollback -ErrorAction Stop) } catch {}
        Add-SsyCheck 'Replikation & Schutz' 'Snapshots/CDP/Rollbacks' $script:Group.Caption $(if ($snaps.Count -or $cdp.Count) { 'OK' } else { 'Info' }) "$($snaps.Count) Snapshot(s), $($cdp.Count) vDisk-Seite(n) mit CDP, $($rb.Count) Rollback(s)" $(if (-not $snaps.Count -and -not $cdp.Count) { 'Kein Schutz gegen logische Fehler/Ransomware innerhalb SANsymphony - Snapshots oder CDP für wichtige vDisks erwägen' })
        if ($rb.Count) { Add-SsyCheck 'Replikation & Schutz' 'Offene Rollbacks' $script:Group.Caption 'Info' "$($rb.Count) Rollback(s) vorhanden" 'Nicht mehr benötigte Rollbacks entfernen' }
    }
}

function Test-SsyMonitorsAlerts {
    Invoke-SsyStep 'Monitore & Alarme' 'Monitore' {
        $mons = @(Get-DcsMonitor)
        $bad = @($mons | Where-Object { "$($_.State)" -notin 'Healthy', 'Undefined' })
        foreach ($mo in $bad) {
            $st = if ("$($mo.State)" -match 'Critical|Error|Failed') { 'Kritisch' } else { 'Warnung' }
            Add-SsyCheck 'Monitore & Alarme' $mo.Caption $mo.ExtendedCaption $st "$($mo.MessageText) (seit $($mo.TimeStamp))" 'Siehe DataCore-Konsole, Bereich Monitore'
        }
        Add-SsyCheck 'Monitore & Alarme' 'DataCore-Monitore' $script:Group.Caption 'OK' "$(@($mons | Where-Object { "$($_.State)" -eq 'Healthy' }).Count) gesund, $($bad.Count) auffällig"
    }
    Invoke-SsyStep 'Monitore & Alarme' 'Alarme' {
        $since = (Get-Date).ToUniversalTime().AddHours(-$script:T.AlertHours)
        $al = @(Get-DcsAlert | Where-Object { $_.TimeStamp -and ([datetime]$_.TimeStamp).ToUniversalTime() -gt $since })
        $err = @($al | Where-Object { "$($_.Level)" -eq 'Error' }); $warn = @($al | Where-Object { "$($_.Level)" -eq 'Warning' })
        $top = @($err | Group-Object { Get-SsyShort (($_.MessageText -replace '\d+', '#')) 80 } | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object { "$($_.Count)× $($_.Name)" })
        $st = if ($err.Count) { 'Warnung' } elseif ($warn.Count) { 'Info' } else { 'OK' }
        Add-SsyCheck 'Monitore & Alarme' "Alarme letzte $($script:T.AlertHours) h" $script:Group.Caption $st "$($err.Count) Fehler, $($warn.Count) Warnungen" $(if ($err.Count) { 'Häufigste Fehler prüfen (Details)' }) ($top -join "`r`n")
        $lic = @($al | Where-Object { $_.MessageText -match 'licen' -and "$($_.Level)" -eq 'Error' })
        if ($lic.Count) {
            # Alte Meldungen nur dann kritisch werten, wenn die Lizenz jetzt noch ein Problem hat
            $g = $script:Group; $why = @()
            if ($g.OutOfCompliance) { $why += 'Gruppe außerhalb der Lizenzbedingungen' }
            $exp = $g.NextExpirationDate
            if ($exp -and ([datetime]$exp).Year -gt 2000 -and ([datetime]$exp) -lt (Get-Date)) { $why += "Lizenz abgelaufen am $(([datetime]$exp).ToString('dd.MM.yyyy'))" }
            foreach ($s in $script:OwnServers) {
                if ($s.OutOfCompliance) { $why += "$($s.Caption) außerhalb der Lizenzbedingungen" }
                if ($s.LicenseExceeded) { $why += "$($s.Caption) Lizenzkapazität überschritten" }
                if ("$($s.State)" -ne 'Online') { $why += "$($s.Caption) nicht online ($($s.State))" }
            }
            $last = ($lic | Sort-Object { [datetime]$_.TimeStamp } -Descending | Select-Object -First 1)
            $lastTxt = ([datetime]$last.TimeStamp).ToLocalTime().ToString('dd.MM.yyyy HH:mm')
            $base = "$($lic.Count) Lizenz-Fehlermeldungen in $($script:T.AlertHours) h (letzte $lastTxt), z. B.: $(Get-SsyShort $last.MessageText 120)"
            if ($why.Count) {
                Add-SsyCheck 'Lizenz & Software' 'Lizenz-Alarme' $g.Caption 'Kritisch' "$base - aktuell: $($why -join '; ')" 'Lizenz sofort prüfen/erneuern - abgelaufene Lizenz deaktiviert Server'
            } else {
                Add-SsyCheck 'Lizenz & Software' 'Lizenz-Alarme' $g.Caption 'Info' "$base - aktuelle Lizenz ist gültig ($($g.LicenseType)), alle Server online" 'Lizenz ist inzwischen gültig - Meldungen vermutlich vor der Erneuerung entstanden; nur prüfen, falls neue hinzukommen'
            }
        }
        $ack = @(Get-DcsAlert | Where-Object { $_.NeedsAcknowledge })
        if ($ack.Count) { Add-SsyCheck 'Monitore & Alarme' 'Unbestätigte Alarme' $script:Group.Caption 'Info' "$($ack.Count) Alarm(e) warten auf Bestätigung" 'In der Konsole prüfen und bestätigen' }
    }
}
#endregion

#region Windows
function Test-SsyHostOs {
    $me = $env:COMPUTERNAME
    Invoke-SsyStep 'Windows' 'Dienste' {
        foreach ($svc in @(@{ N = 'Dcsx'; D = 'DataCore Executive'; C = 'Kritisch' }, @{ N = 'DcsTmy'; D = 'DataCore Intelligence Service'; C = 'Info' }, @{ N = 'dcmpio'; D = 'DataCore MPIO'; C = 'Warnung' }, @{ N = 'MSiSCSI'; D = 'Microsoft iSCSI-Initiator'; C = 'Warnung' }, @{ N = 'VMTools'; D = 'VMware Tools'; C = 'Info' })) {
            $s = Get-Service -Name $svc.N -ErrorAction SilentlyContinue
            if (-not $s) { continue }
            if ($svc.N -eq 'VMTools' -and -not $script:IsVm) { continue }
            if ("$($s.Status)" -ne 'Running') { Add-SsyCheck 'Windows' "Dienst $($svc.D)" $me $svc.C "Status: $($s.Status), Starttyp $($s.StartType)" 'Dienst starten und Ereignisprotokoll prüfen' }
            else { Add-SsyCheck 'Windows' "Dienst $($svc.D)" $me 'OK' 'läuft' }
        }
    }
    Invoke-SsyStep 'Windows' 'Energieoptionen' {
        $line = (powercfg /getactivescheme) | Out-String
        if ($line -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c|e9a42b02-d5df-448d-aa00-03f14749eb61') { Add-SsyCheck 'Windows' 'Energiesparplan' $me 'OK' 'Höchstleistung' }
        else { Add-SsyCheck 'Windows' 'Energiesparplan' $me 'Warnung' ($line.Trim() -replace '^.*\(', '(') 'Energiesparplan Höchstleistung aktivieren (DataCore-Empfehlung)' }
    }
    Invoke-SsyStep 'Windows' 'CPU' {
        $cs = Get-CimInstance Win32_ComputerSystem
        $n = [int]$cs.NumberOfLogicalProcessors
        $samples = 1..3 | ForEach-Object { (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime; Start-Sleep -Milliseconds 700 }
        $avg = [math]::Round(($samples | Measure-Object -Average).Average, 0)
        $poller = $null; if ($script:LocalServer) { $pc = Get-SsyPerf $script:LocalServer.Id; if ($pc) { $poller = $pc.PollerDedicatedCPUs } }
        $txt = "$n logische CPUs, Auslastung $avg %"
        if ($poller) {
            $rest = $n - $poller
            $est = if ($rest -gt 0) { [math]::Round([math]::Max(0, ($avg * $n - 100 * $poller) / $rest), 0) } else { 100 }
            $txt += "; $poller für DataCore-Poller reserviert, geschätzte Last der übrigen CPUs ~$est %"
            if ($rest -lt 2) { Add-SsyCheck 'Windows' 'CPU-Ausstattung' $me 'Warnung' $txt 'Mehr CPUs zuweisen - für Windows bleiben zu wenige übrig' }
            elseif ($est -ge $script:T.CpuWarnPct) { Add-SsyCheck 'Windows' 'CPU-Auslastung' $me 'Warnung' $txt 'CPU-Engpass: mehr CPUs zuweisen oder Last (Replikations-Erstkopie, Dedup/Kompression) reduzieren' }
            else { Add-SsyCheck 'Windows' 'CPU-Auslastung' $me 'OK' $txt }
        } elseif ($avg -ge $script:T.CpuWarnPct) { Add-SsyCheck 'Windows' 'CPU-Auslastung' $me 'Warnung' $txt 'CPU-Engpass prüfen' } else { Add-SsyCheck 'Windows' 'CPU-Auslastung' $me 'OK' $txt }
    }
    Invoke-SsyStep 'Windows' 'System' {
        $os = Get-CimInstance Win32_OperatingSystem
        $up = (Get-Date) - $os.LastBootUpTime
        if ($up.TotalDays -gt $script:T.UptimeInfoDays) { Add-SsyCheck 'Windows' 'Laufzeit seit Neustart' $me 'Info' "$([int]$up.TotalDays) Tage" 'Lange Laufzeit deutet auf ausstehende Updates hin - Patchstand prüfen' }
        else { Add-SsyCheck 'Windows' 'Laufzeit seit Neustart' $me 'OK' "$([int]$up.TotalDays) Tage, $($up.Hours) h" }
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $pct = [math]::Round(100 * $d.FreeSpace / $d.Size, 1); $txt = "$([math]::Round($d.FreeSpace/1GB,1)) GB frei ($pct %)"
        if ($pct -lt $script:T.SysFreeWarnPct) { Add-SsyCheck 'Windows' 'Freier Platz C:' $me 'Warnung' $txt 'Platz schaffen - Logs, Support-Bundles und Updates brauchen Raum' } else { Add-SsyCheck 'Windows' 'Freier Platz C:' $me 'OK' $txt }
        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        if ($pending) { Add-SsyCheck 'Windows' 'Ausstehender Neustart' $me 'Info' 'Windows wartet auf einen Neustart' 'Neustart geplant durchführen (vorher Spiegel prüfen, Server in der Konsole stoppen)' }
        else { Add-SsyCheck 'Windows' 'Ausstehender Neustart' $me 'OK' 'keiner' }
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if (-not $pf.Count) { Add-SsyCheck 'Windows' 'Auslagerungsdatei' $me 'Info' 'Keine Auslagerungsdatei' 'Für Speicherabbilder bei Abstürzen eine Auslagerungsdatei auf C: vorsehen' }
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) { $age = [int]((Get-Date) - $hf.InstalledOn).TotalDays; Add-SsyCheck 'Windows' 'Letztes Windows-Update' $me $(if ($age -gt 120) { 'Info' } else { 'OK' }) "$($hf.HotFixID) vom $($hf.InstalledOn.ToString('dd.MM.yyyy')) (vor $age Tagen)" $(if ($age -gt 120) { 'Patchstand prüfen (nur von DataCore freigegebene Updates)' }) }
    }
    Invoke-SsyStep 'Windows' 'Ereignisprotokoll' {
        $start = (Get-Date).AddHours(-24)
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $start } -MaxEvents 2000 -ErrorAction SilentlyContinue)
        $rel = @($ev | Where-Object { $_.ProviderName -match 'disk|iScsiPrt|Ntfs|stor|e1i|e1e|e1r|vmxnet|Tcpip|NDIS|mpio|DataCore|dcs|Kernel-Power|EventLog|WHEA' })
        $crit = @($rel | Where-Object { $_.Level -le 2 })
        $top = @($rel | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Count)× $($_.Name): $(Get-SsyShort ($_.Group[0].Message -split "`n")[0] 90)" })
        $st = if (@($crit | Where-Object { $_.ProviderName -match 'disk|iScsiPrt|stor|WHEA|Ntfs' }).Count) { 'Warnung' } elseif ($rel.Count) { 'Info' } else { 'OK' }
        Add-SsyCheck 'Windows' 'Systemprotokoll 24 h (Speicher/Netz)' $me $st "$($crit.Count) Fehler, $($rel.Count - $crit.Count) Warnungen relevanter Quellen" $(if ($st -ne 'OK') { 'Häufigste Einträge in den Details prüfen' }) ($top -join "`r`n")
        $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = $start } -MaxEvents 1000 -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'DataCore|Dcs' })
        if ($app.Count) { Add-SsyCheck 'Windows' 'Anwendungsprotokoll 24 h (DataCore)' $me 'Info' "$($app.Count) Fehler von DataCore-Quellen" 'Details prüfen' (@($app | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Count)× $($_.Name): $(Get-SsyShort ($_.Group[0].Message -split "`n")[0] 90)" }) -join "`r`n") }
    }
    Invoke-SsyStep 'Windows' 'Sicherheit' {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if ($mp.RealTimeProtectionEnabled) {
                $ex = @((Get-MpPreference).ExclusionPath)
                if (-not ($ex | Where-Object { $_ -match 'DataCore' })) { Add-SsyCheck 'Windows' 'Virenschutz-Ausnahmen' $me 'Warnung' 'Defender-Echtzeitschutz aktiv, keine Ausnahme für DataCore-Ordner' 'Ausnahmen gemäß DataCore-Empfehlung setzen (Installationsordner, Pufferordner, Prozesse) - Scanner kann I/O verzögern' }
                else { Add-SsyCheck 'Windows' 'Virenschutz-Ausnahmen' $me 'OK' 'Ausnahme für DataCore vorhanden' }
            } else { Add-SsyCheck 'Windows' 'Virenschutz-Ausnahmen' $me 'OK' 'Defender-Echtzeitschutz aus' }
        } catch {}
        $fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object Enabled)
        if ($fw.Count) {
            $rules = @(Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | Where-Object { "$($_.LocalPort)" -match '(^|,)\s*(3260|3793)\s*(,|$)' -or $_.LocalPort -eq 'Any' })
            Add-SsyCheck 'Windows' 'Firewall' $me $(if ($rules.Count) { 'OK' } else { 'Warnung' }) "Aktiv in: $(($fw.Name) -join ', ')" $(if (-not $rules.Count) { 'Eingehend TCP 3260 (iSCSI) und 3793 (DataCore) freigeben' })
        } else { Add-SsyCheck 'Windows' 'Firewall' $me 'Info' 'Windows-Firewall in allen Profilen aus' 'Bei Bedarf aktivieren und iSCSI/DataCore-Ports freigeben' }
    }
}
#endregion

#region Netzwerk und Spiegelstrecke
function Invoke-SsyPing([string]$Source, [string]$Target, [int]$Count = 10, [int]$Size = 32, [switch]$NoFragment) {
    $a = @('-n', $Count, '-l', $Size, '-w', 1000); if ($NoFragment) { $a += '-f' }; if ($Source) { $a += @('-S', $Source) }
    $out = (& ping.exe @a $Target) | Out-String
    [pscustomobject]@{ LossPct = $(if ($out -match '\((\d+)\s*%') { [int]$Matches[1] } else { 100 }); AvgMs = $(if ($out -match '(Average|Mittelwert)\s*=\s*(\d+)\s*ms') { [int]$Matches[2] } else { $null })
        MaxMs = $(if ($out -match 'Maximum\s*=\s*(\d+)\s*ms') { [int]$Matches[1] } else { $null }); FragmentNeeded = ($out -match 'fragment|Fragmentierung') }
}

function Test-SsyNetwork {
    if (-not $script:LocalServer) { Add-SsyCheck 'Netzwerk' 'Lokaler Server' $env:COMPUTERNAME 'Info' 'Lokaler Server nicht in der Gruppe gefunden - Netzwerkprüfung übersprungen' ''; return }
    $me = $script:LocalServer.Caption
    $nics = @($script:Nics.ToArray())
    Invoke-SsyStep 'Netzwerk' 'iSCSI-Netzwerkkarten' {
        foreach ($n in $nics | Where-Object Missing) { Add-SsyCheck 'Netzwerk' 'Portal-IP vorhanden' "$($n.Port) ($($n.IP))" 'Warnung' 'IP-Adresse ist keiner Windows-Netzwerkkarte zugeordnet' 'IP-Konfiguration der Karte und des DataCore-Ports abgleichen' }
        $ok = @($nics | Where-Object { -not $_.Missing })
        foreach ($n in $ok) {
            $obj = "$($n.Adapter) ($($n.Port), $($n.IP)/$($n.Prefix))"
            if ($n.Status -ne 'Up') { Add-SsyCheck 'Netzwerk' 'Link-Status' $obj 'Kritisch' "Status: $($n.Status)" 'Kabel/vSwitch prüfen' }
            if ($n.Desc -match 'E1000|82574|82545|PRO/1000|8254\d') { Add-SsyCheck 'Netzwerk' 'Netzwerkkarten-Typ' $obj $(if ($script:IsVm) { 'Warnung' } else { 'Info' }) "Emulierte/ältere NIC: $($n.Desc)" 'Im Hypervisor auf VMXNET3 (paravirtualisiert) umstellen - geringere Latenz und CPU-Last pro Paket' }
            else { Add-SsyCheck 'Netzwerk' 'Netzwerkkarten-Typ' $obj 'OK' "$($n.Desc), Treiber $($n.Driver)" }
            if ($n.Role -match 'Mirror' -and $n.SpeedGbps -lt 10) { Add-SsyCheck 'Netzwerk' 'Bandbreite Spiegelnetz' $obj 'Info' "$($n.SpeedGbps) Gbit/s" 'Für Spiegelstrecken sind 10 Gbit/s oder mehr üblich' }
            $ack = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($n.Guid)" -ErrorAction SilentlyContinue).TcpAckFrequency
            if ("$ack" -ne '1') { Add-SsyCheck 'Netzwerk' 'Delayed ACK' $obj 'Info' 'Delayed ACK aktiv (Windows-Standard)' 'Für iSCSI-Schnittstellen TcpAckFrequency=1 setzen (verringert Latenzspitzen; Neustart der Karte nötig)' }
            $pm = Get-NetAdapterPowerManagement -Name $n.Adapter -ErrorAction SilentlyContinue
            if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { Add-SsyCheck 'Netzwerk' 'Energiesparen der Karte' $obj 'Warnung' 'Windows darf die Karte zum Energiesparen abschalten' 'In den Karteneigenschaften die Energiesparoption deaktivieren' }
            $rss = Get-NetAdapterRss -Name $n.Adapter -ErrorAction SilentlyContinue
            if ($rss -and -not $rss.Enabled) { Add-SsyCheck 'Netzwerk' 'Receive Side Scaling' $obj 'Info' 'RSS aus' 'RSS aktivieren, damit Netzlast auf mehrere CPUs verteilt wird' }
            $gw = (Get-NetIPConfiguration -InterfaceIndex $n.IfIndex -ErrorAction SilentlyContinue).IPv4DefaultGateway
            if ($gw) { Add-SsyCheck 'Netzwerk' 'Gateway auf iSCSI-Karte' $obj 'Info' "Standardgateway $($gw.NextHop) gesetzt" 'iSCSI-Karten brauchen in der Regel kein Gateway - kann zu falschem Routing führen' }
            $dns = (Get-DnsClient -InterfaceIndex $n.IfIndex -ErrorAction SilentlyContinue).RegisterThisConnectionsAddress
            if ($dns) { Add-SsyCheck 'Netzwerk' 'DNS-Registrierung' $obj 'Info' 'Karte registriert ihre IP im DNS' 'Für iSCSI-Karten DNS-Registrierung abschalten, damit der Servername auf die Verwaltungs-IP auflöst' }
            $st = Get-NetAdapterStatistics -Name $n.Adapter -ErrorAction SilentlyContinue
            if ($st) {
                $err = [int64]$st.ReceivedPacketErrors + [int64]$st.OutboundPacketErrors; $disc = [int64]$st.ReceivedDiscardedPackets + [int64]$st.OutboundDiscardedPackets
                if ($err -gt 0) { Add-SsyCheck 'Netzwerk' 'Übertragungsfehler' $obj 'Warnung' "$err Paketfehler seit Systemstart" 'Kabel, NIC, Switch-Port bzw. vSwitch prüfen' }
                elseif ($disc -gt 1000) { Add-SsyCheck 'Netzwerk' 'Verworfene Pakete' $obj 'Info' "$disc verworfene Pakete seit Systemstart" 'Puffer (Receive/Transmit Buffers) und Last prüfen' }
                else { Add-SsyCheck 'Netzwerk' 'Übertragungsfehler' $obj 'OK' 'keine Fehler' }
            }
        }
        $overlaps = @()
        for ($i = 0; $i -lt $ok.Count; $i++) { for ($j = $i + 1; $j -lt $ok.Count; $j++) { $a = $ok[$i]; $b = $ok[$j]; if ($a.Adapter -ne $b.Adapter -and (Test-SsySubnetOverlap $a.Subnet $b.Subnet)) { $overlaps += "$($a.Adapter) $($a.Subnet.Text) <-> $($b.Adapter) $($b.Subnet.Text)" } } }
        if ($overlaps) { Add-SsyCheck 'Netzwerk' 'Getrennte Subnetze je Pfad' $me 'Warnung' ('Mehrere Karten liegen im selben IP-Netz: ' + ($overlaps -join '; ')) 'Jedem Pfad ein eigenes Subnetz geben (z. B. /24 je Netz) - auf allen Servern UND auf den Hosts. Reihenfolge beachten, sonst brechen Pfade weg' }
        elseif ($ok.Count) { Add-SsyCheck 'Netzwerk' 'Getrennte Subnetze je Pfad' $me 'OK' 'Jede iSCSI-Karte hat ein eigenes Subnetz' }
        foreach ($grp in $ok | Group-Object { if ($_.Role -match 'Mirror') { 'Mirror' } else { 'Frontend' } }) {
            $mtus = @($grp.Group | ForEach-Object { $_.Mtu } | Sort-Object -Unique)
            if ($mtus.Count -gt 1) { Add-SsyCheck 'Netzwerk' "MTU einheitlich ($($grp.Name))" $me 'Warnung' "Unterschiedliche MTU: $($mtus -join ', ')" 'MTU auf allen Karten und Switches einheitlich setzen' }
            else { Add-SsyCheck 'Netzwerk' "MTU einheitlich ($($grp.Name))" $me 'OK' "MTU $($mtus -join '')" }
        }
        Add-SsyInventory "iSCSI-Karten $me" ($ok | ForEach-Object { [pscustomobject]@{ Karte = $_.Adapter; Port = $_.Port; Rolle = $_.Role; IP = "$($_.IP)/$($_.Prefix)"; MTU = $_.Mtu; Gbit = $_.SpeedGbps; Typ = $_.Desc; Treiber = $_.Driver; Status = $_.Status } })
    }
    Invoke-SsyStep 'Netzwerk' 'Verbindung zu Partnerservern' {
        foreach ($s in $script:OwnServers | Where-Object { "$($_.Id)" -ne $script:LocalServerId }) {
            $hn = if ($s.HostName) { $s.HostName } else { $s.Caption }
            $res = $null; try { $res = [System.Net.Dns]::GetHostAddresses($hn) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1 } catch {}
            if (-not $res) { Add-SsyCheck 'Netzwerk' 'Namensauflösung Partner' $s.Caption 'Warnung' "$hn lässt sich nicht auflösen" 'DNS oder hosts-Datei pflegen'; continue }
            $ok = Test-SsyTcpPort $hn 3793 2500
            if ($ok) { Add-SsyCheck 'Netzwerk' 'DataCore-Verwaltungsport 3793' $s.Caption 'OK' "$hn ($($res.IPAddressToString)) erreichbar" }
            else { Add-SsyCheck 'Netzwerk' 'DataCore-Verwaltungsport 3793' $s.Caption 'Warnung' "$hn ($($res.IPAddressToString)) auf TCP 3793 nicht erreichbar" 'Firewall/Netz zwischen den Servern prüfen - Server können sich sonst nicht abstimmen' }
        }
    }
    Invoke-SsyStep 'Spiegelstrecke' 'iSCSI-Sessions (TCP)' {
        $ok = @($nics | Where-Object { -not $_.Missing })
        $localIps = @($ok | ForEach-Object { $_.IP })
        $tcp = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { ($_.RemotePort -eq 3260 -or $_.LocalPort -eq 3260) -and $localIps -contains $_.LocalAddress })
        $rows = foreach ($c in $tcp) {
            $n = $ok | Where-Object { $_.IP -eq $c.LocalAddress } | Select-Object -First 1
            $dir = if ($c.LocalPort -eq 3260) { 'eingehend' } else { 'ausgehend' }
            $inNet = Test-SsyInSubnet $c.RemoteAddress $n.Subnet
            [pscustomobject]@{ Richtung = $dir; Lokal = $c.LocalAddress; Karte = $n.Adapter; Rolle = $n.Role; Gegenstelle = $c.RemoteAddress; ImSubnetz = $inNet }
        }
        $rows = @($rows)
        $bad = @($rows | Where-Object { -not $_.ImSubnetz })
        if ($bad.Count) { Add-SsyCheck 'Spiegelstrecke' 'Sessions im passenden Subnetz' $me 'Warnung' "$($bad.Count) Session(s) über Kreuz: $(($bad | ForEach-Object { "$($_.Gegenstelle)->$($_.Lokal) ($($_.Richtung))" }) -join ', ')" 'Gegenstelle nutzt eine Quell-IP aus einem anderen Netz - Subnetze/Netzmasken auf beiden Seiten angleichen und Sessions neu anmelden' }
        elseif ($rows.Count) { Add-SsyCheck 'Spiegelstrecke' 'Sessions im passenden Subnetz' $me 'OK' "$($rows.Count) iSCSI-Session(s), alle im Subnetz ihrer Karte" }
        $out = @($rows | Where-Object { $_.Richtung -eq 'ausgehend' -and $_.Rolle -match 'Mirror' })
        $mrNics = @($ok | Where-Object { $_.Role -match 'Mirror' } | ForEach-Object { $_.Adapter } | Sort-Object -Unique)
        $usedSrc = @($out | ForEach-Object { $_.Lokal } | Sort-Object -Unique); $dsts = @($out | ForEach-Object { $_.Gegenstelle } | Sort-Object -Unique)
        if ($mrNics.Count -ge 2 -and $dsts.Count -ge 2 -and $usedSrc.Count -lt 2) { Add-SsyCheck 'Spiegelstrecke' 'Pfadtrennung Spiegel-Sessions' $me 'Warnung' "Alle ausgehenden Spiegel-Sessions ($($dsts -join ', ')) nutzen dieselbe Quell-IP $($usedSrc -join '') - die zweite Spiegelkarte sendet nicht" 'Spiegelnetze in getrennte Subnetze legen, damit jeder Spiegelpfad seine eigene Karte nutzt' }
        elseif ($out.Count) { Add-SsyCheck 'Spiegelstrecke' 'Pfadtrennung Spiegel-Sessions' $me 'OK' "$($usedSrc.Count) Quell-IP(s) für $($dsts.Count) Ziel(e)" }
        foreach ($n in $ok | Where-Object { $_.Role -match 'Mirror' }) {
            $cnt = @($rows | Where-Object { $_.Lokal -eq $n.IP }).Count
            if ($cnt -eq 0 -and $script:OwnServers.Count -ge 2) { Add-SsyCheck 'Spiegelstrecke' 'Spiegelkarte in Benutzung' "$($n.Adapter) ($($n.IP))" 'Warnung' 'Keine einzige iSCSI-Session über diese Spiegelkarte' 'Spiegelpfad über diese Karte herstellen (Gegenstelle, Subnetz, iSCSI-Anmeldung)' }
        }
        $pairs = @($out | Select-Object Lokal, Gegenstelle -Unique)
        foreach ($pr in $pairs) {
            $obj = "$($pr.Lokal) -> $($pr.Gegenstelle)"
            $r = Invoke-SsyPing -Source $pr.Lokal -Target $pr.Gegenstelle -Count 5
            if ($r.LossPct -gt 0) { Add-SsyCheck 'Spiegelstrecke' 'Erreichbarkeit/Paketverlust' $obj 'Warnung' "$($r.LossPct) % Verlust, Ø $($r.AvgMs) ms, max $($r.MaxMs) ms" 'Netzpfad (NIC, vSwitch, Switch) prüfen' }
            elseif ($r.AvgMs -ge $script:T.PingWarnMs) { Add-SsyCheck 'Spiegelstrecke' 'Netzlaufzeit' $obj 'Warnung' "Ø $($r.AvgMs) ms, max $($r.MaxMs) ms" 'Für synchrone Spiegelung sollte die Laufzeit deutlich unter 1 ms liegen' }
            else { Add-SsyCheck 'Spiegelstrecke' 'Netzlaufzeit' $obj 'OK' "Ø $($r.AvgMs) ms, max $($r.MaxMs) ms, kein Verlust" }
            $n = $ok | Where-Object { $_.IP -eq $pr.Lokal } | Select-Object -First 1; $mtu = if ($n) { $n.Mtu } else { 1500 }
            $f = Invoke-SsyPing -Source $pr.Lokal -Target $pr.Gegenstelle -Count 2 -Size ($mtu - 28) -NoFragment
            if ($f.LossPct -gt 0 -or $f.FragmentNeeded) { Add-SsyCheck 'Spiegelstrecke' 'MTU Ende-zu-Ende' $obj 'Kritisch' "Pakete mit MTU $mtu kommen nicht unfragmentiert an" 'MTU auf allen Strecken (NIC, vSwitch, Switch, Gegenseite) angleichen' }
            else { Add-SsyCheck 'Spiegelstrecke' 'MTU Ende-zu-Ende' $obj 'OK' "MTU $mtu durchgängig" }
        }
        foreach ($c in $script:PortConns | Where-Object { $_.Caption -match '^Microsoft iSCSI Initiator on' -and "$($_.Caption)" -match [regex]::Escape("on $me ") }) {
            foreach ($d in @($c.PortADescriptor, $c.PortBDescriptor)) { if (-not $d) { continue }; foreach ($cc in $d.Connections) {
                    if ("$($cc.ConnectionParams.DataDigestMode)" -match 'CRC' -or "$($cc.ConnectionParams.HeaderDigestMode)" -match 'CRC') { Add-SsyCheck 'Spiegelstrecke' 'iSCSI-Digest' $c.Caption 'Info' "Header $($cc.ConnectionParams.HeaderDigestMode), Data $($cc.ConnectionParams.DataDigestMode)" 'CRC-Digest kostet CPU und Latenz - nur nutzen, wenn nötig' } } } }
        foreach ($c in $script:PortConns | Where-Object { $_.Caption -match '^Microsoft iSCSI Initiator on' -and -not $_.Connected }) { Add-SsyCheck 'Spiegelstrecke' 'Spiegel-/Replikationssession verbunden' $c.Caption 'Warnung' 'Session nicht verbunden' 'iSCSI-Anmeldung in der Konsole prüfen' }
        Add-SsyInventory "iSCSI-Sessions über die Karten von $me" $rows
    }
}

function Invoke-SsyDeepAnalysis([int]$Seconds = 20) {
    Invoke-SsyStep 'Spiegelstrecke' 'Tiefenanalyse (Paketmitschnitt)' {
        if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) { Add-SsyCheck 'Tool' 'Tiefenanalyse' $env:COMPUTERNAME 'Info' 'pktmon nicht verfügbar (ab Windows Server 2019)' ''; return }
        $stat = (pktmon status) -join ' '
        if ($stat -notmatch 'not running|nicht ausgef|wird nicht') { Add-SsyCheck 'Tool' 'Tiefenanalyse' $env:COMPUTERNAME 'Info' 'Es läuft bereits ein Paketmitschnitt - Tiefenanalyse übersprungen' ''; return }
        $flt = (pktmon filter list) -join ' '
        if ($flt -notmatch 'None|Keine') { Add-SsyCheck 'Tool' 'Tiefenanalyse' $env:COMPUTERNAME 'Info' 'Es sind bereits pktmon-Filter gesetzt - Tiefenanalyse übersprungen, um sie nicht zu verändern' ''; return }
        $dir = Join-Path $env:TEMP ("SsyDiag_" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            pktmon filter add SsyIscsi -t TCP -p 3260 | Out-Null
            pktmon start --capture --pkt-size 128 --file-name (Join-Path $dir 'c.etl') | Out-Null
            for ($i = 1; $i -le $Seconds; $i++) { Start-Sleep -Seconds 1 }
            pktmon stop | Out-Null
            pktmon etl2txt (Join-Path $dir 'c.etl') --out (Join-Path $dir 'c.txt') | Out-Null
            $lines = Get-Content (Join-Path $dir 'c.txt') -ErrorAction SilentlyContinue
            $portals = @($script:Nics.ToArray() | Where-Object { -not $_.Missing })
            $syn = @{}
            foreach ($l in $lines) {
                if ($l -match '(\d+\.\d+\.\d+\.\d+)\.(\d+) > (\d+\.\d+\.\d+\.\d+)\.3260: Flags \[S(EW)?\]') {
                    $src = $Matches[1]; $dst = $Matches[3]
                    $n = $portals | Where-Object { $_.IP -eq $dst } | Select-Object -First 1
                    if ($n) { $syn["$src>$dst"] = [pscustomobject]@{ Src = $src; Dst = $dst; Nic = $n } }
                }
            }
            $established = @(Get-NetTCPConnection -State Established -LocalPort 3260 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.RemoteAddress)>$($_.LocalAddress)" })
            $fails = @($syn.Values | Where-Object { $established -notcontains "$($_.Src)>$($_.Dst)" })
            foreach ($f in $fails) {
                $wrong = -not (Test-SsyInSubnet $f.Src $f.Nic.Subnet)
                Add-SsyCheck 'Spiegelstrecke' 'Fehlschlagende Anmeldeversuche' "$($f.Src) -> $($f.Dst) ($($f.Nic.Adapter))" 'Warnung' $(if ($wrong) { "Initiator $($f.Src) versucht sich anzumelden, liegt aber nicht im Subnetz der Zielkarte - Antwort kann nicht zugestellt werden" } else { "Verbindungsversuche von $($f.Src) ohne Erfolg" }) $(if ($wrong) { 'Auf der Initiator-Seite (Host/Partner) einen Netzwerkport im passenden Subnetz verwenden bzw. Netzmasken angleichen (z. B. ESXi: VMkernel-Port mit /24 im Zielnetz)' } else { 'Zielport, Firewall und iSCSI-Konfiguration prüfen' })
            }
            if (-not $fails.Count) { Add-SsyCheck 'Spiegelstrecke' 'Fehlschlagende Anmeldeversuche' $env:COMPUTERNAME 'OK' "Keine im Mitschnitt ($Seconds s)" }
        } finally {
            if (((pktmon status) -join ' ') -notmatch 'not running|nicht ausgef|wird nicht') { $null = & pktmon stop 2>&1 }
            $null = & pktmon filter remove 2>&1
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

#region Leistung
function Get-SsySnapshot {
    $items = New-Object System.Collections.Generic.List[object]
    $add = { param($kind, $obj, $name, $server) $pc = Get-SsyPerf $obj.Id; if ($pc -and $pc.CollectionTime -and ([datetime]$pc.CollectionTime).Year -gt 2000) { $items.Add([pscustomobject]@{ Kind = $kind; Id = [string]$obj.Id; Name = $name; Server = $server; Counter = $pc; Object = $obj }) } }
    foreach ($s in $script:OwnServers) { & $add 'Server' $s $s.Caption $s.Caption }
    foreach ($p in $script:Pools) { & $add 'Pool' $p $p.ExtendedCaption (Get-SsyServerFromCaption $p.ExtendedCaption) }
    foreach ($v in $script:VDisks) { & $add 'VirtualDisk' $v $v.Caption $null }
    foreach ($l in $script:LDisks) { $sv = Get-SsyServerFromCaption $l.ExtendedCaption; if ($script:OwnNames -contains $sv) { & $add 'LogicalDisk' $l $l.ExtendedCaption $sv } }
    foreach ($d in $script:PDisks | Where-Object { $_.PoolMemberId }) { & $add 'PhysicalDisk' $d $d.ExtendedCaption (Get-SsyServerFromCaption $d.ExtendedCaption) }
    foreach ($pt in $script:Ports) {
        if ($script:OwnIds -notcontains "$($pt.HostId)" -or "$($pt.PortType)" -eq 'Loopback' -or -not $pt.Connected -or -not $pt.ServerPortProperties) { continue }
        if ("$($pt.ServerPortProperties.Role)" -notmatch 'Frontend|Mirror' -or "$($pt.PortMode)" -eq 'Initiator') { continue }
        & $add 'Port' $pt $pt.ExtendedCaption (Get-SsyServerFromCaption $pt.ExtendedCaption)
    }
    foreach ($r in $script:Repl) { & $add 'Replication' $r $r.ExtendedCaption $null }
    $items
}

function Measure-SsyPerformance([int]$Seconds = 30) {
    $s1 = Get-SsySnapshot
    for ($i = 1; $i -le $Seconds; $i++) { Start-Sleep -Seconds 1; if ($i % 5 -eq 0 -or $i -eq $Seconds) { Write-SsyProgress ([int](55 + 35 * $i / $Seconds)) "Messe Leistung … $i / $Seconds s" } }
    $s2 = Get-SsySnapshot
    $first = @{}; foreach ($x in $s1) { $first["$($x.Kind)|$($x.Id)"] = $x }
    foreach ($b in $s2) {
        $a = $first["$($b.Kind)|$($b.Id)"]; if (-not $a) { continue }
        $c1 = $a.Counter; $c2 = $b.Counter
        $dt = ([datetime]$c2.CollectionTime - [datetime]$c1.CollectionTime).TotalSeconds; if ($dt -le 0) { $dt = $Seconds }
        $D = { param($p) Get-SsyDelta $c1 $c2 $p }
        $rate = { param($v) if ($null -eq $v) { $null } else { [math]::Round($v / $dt, 1) } }
        $ops = & $D 'TotalOperations'; $rd = & $D 'TotalReads'; $wr = & $D 'TotalWrites'; $by = & $D 'TotalBytesTransferred'
        $mb = if ($null -ne $by) { $by / 1MB } else { $null }
        $r = [ordered]@{ Kind = $b.Kind; Name = $b.Name; Server = $b.Server; IntervalSec = [math]::Round($dt, 1) }
        switch ($b.Kind) {
            'Server' {
                $feOps = & $D 'FrontEndTargetOperations'; $miOps = & $D 'MirrorTargetOperations'; $poOps = & $D 'PoolOperations'
                $r.FeIOPS = & $rate $feOps; $r.FeLatMs = Get-SsyRatio (& $D 'FrontEndTargetTotalOperationsTime') $feOps
                $r.MirrorIOPS = & $rate $miOps; $r.MirrorLatMs = Get-SsyRatio (& $D 'MirrorTargetTotalOperationsTime') $miOps
                $r.PoolIOPS = & $rate $poOps; $r.PoolLatMs = Get-SsyRatio (& $D 'PoolTotalOperationsTime') $poOps
                $tb = & $D 'TargetBytesTransferred'; $r.MBps = & $rate ($(if ($null -ne $tb) { $tb / 1MB }))
                $r.CacheWriteHitPct = Get-SsyHitPct (& $D 'CacheWriteHits') (& $D 'CacheWriteMisses'); $r.CacheReadHitPct = Get-SsyHitPct (& $D 'CacheReadHits') (& $D 'CacheReadMisses')
                $r.PollerLoad = $c2.PollerLoad; $r.ReplMBToSend = [math]::Round($c2.ReplicationBytesToSend / 1MB, 1)
            }
            'Pool' { $r.IOPS = & $rate $ops; $r.ReadIOPS = & $rate $rd; $r.WriteIOPS = & $rate $wr; $r.MBps = & $rate $mb; $r.LatMs = Get-SsyRatio (& $D 'TotalOperationsTime') $ops; $r.ReadLatMs = Get-SsyRatio (& $D 'TotalReadTime') $rd; $r.WriteLatMs = Get-SsyRatio (& $D 'TotalWriteTime') $wr }
            'PhysicalDisk' { $r.IOPS = & $rate $ops; $r.MBps = & $rate $mb; $r.LatMs = Get-SsyRatio (& $D 'TotalOperationsTime') $ops; $r.ReadLatMs = Get-SsyRatio (& $D 'TotalReadsTime') $rd; $r.WriteLatMs = Get-SsyRatio (& $D 'TotalWritesTime') $wr; $r.QueueLen = $c2.AverageQueueLength }
            'LogicalDisk' {
                $r.IOPS = & $rate $ops; $r.WriteIOPS = & $rate $wr; $r.MBps = & $rate $mb; $r.ReadLatMs = Get-SsyRatio (& $D 'TotalReadTime') $rd; $r.WriteLatMs = Get-SsyRatio (& $D 'TotalWriteTime') $wr
                $r.BackendLatMs = Get-SsyRatio (& $D 'CacheBackendTotalOperationsTime') (& $D 'CacheBackendTotalOperations'); $r.CacheWriteHitPct = Get-SsyHitPct (& $D 'CacheWriteHits') (& $D 'CacheWriteMisses'); $r.PendingToMirror = $c2.PendingClientIOsToMirror
            }
            'VirtualDisk' { $r.IOPS = & $rate $ops; $r.ReadIOPS = & $rate $rd; $r.WriteIOPS = & $rate $wr; $r.MBps = & $rate $mb; $r.AvgKB = Get-SsyRatio ($(if ($null -ne $by) { $by / 1KB })) $ops 1; $r.CacheWriteHitPct = Get-SsyHitPct (& $D 'CacheWriteHits') (& $D 'CacheWriteMisses'); $r.CacheReadHitPct = Get-SsyHitPct (& $D 'CacheReadHits') (& $D 'CacheReadMisses') }
            'Port' {
                $tOps = & $D 'TargetOperations'; $r.Role = "$($b.Object.ServerPortProperties.Role)"; $r.IOPS = & $rate $ops; $r.MBps = & $rate $mb; $r.LatMs = Get-SsyRatio (& $D 'TargetTotalOperationsTime') $tOps
                $err = 0; foreach ($e in 'LinkFailureCount', 'LossOfSyncCount', 'LossOfSignalCount', 'PrimitiveSeqProtocolErrCount', 'InvalidTransmissionWordCount', 'InvalidCrcCount') { $v = & $D $e; if ($v) { $err += $v } }
                $r.ErrorsDelta = $err; $r.BusyDelta = & $D 'BusyCount'
            }
            'Replication' { $sent = & $D 'BytesSent'; $r.MBps = & $rate ($(if ($null -ne $sent) { $sent / 1MB })); $r.MBToSend = [math]::Round($c2.BytesToSend / 1MB, 1); $r.TimeLagSec = $c2.TimeLag; $r.InitPct = $c2.InitializationPercentage; $r.BufferFreePct = $c2.ReplicationBufferPercentFreeSpace }
        }
        [pscustomobject]$r
    }
}

function Format-SsyMeasurement($m) {
    $cols = [ordered]@{
        Server = 'Name', 'FeIOPS', 'FeLatMs', 'MirrorIOPS', 'MirrorLatMs', 'PoolIOPS', 'PoolLatMs', 'MBps', 'CacheWriteHitPct', 'CacheReadHitPct', 'PollerLoad', 'ReplMBToSend'
        VirtualDisk = 'Name', 'IOPS', 'ReadIOPS', 'WriteIOPS', 'MBps', 'AvgKB', 'CacheWriteHitPct', 'CacheReadHitPct'
        LogicalDisk = 'Name', 'IOPS', 'WriteIOPS', 'MBps', 'ReadLatMs', 'WriteLatMs', 'BackendLatMs', 'CacheWriteHitPct', 'PendingToMirror'
        Pool = 'Name', 'IOPS', 'ReadIOPS', 'WriteIOPS', 'MBps', 'LatMs', 'ReadLatMs', 'WriteLatMs'
        PhysicalDisk = 'Name', 'IOPS', 'MBps', 'LatMs', 'ReadLatMs', 'WriteLatMs', 'QueueLen'
        Port = 'Name', 'Role', 'IOPS', 'MBps', 'LatMs', 'ErrorsDelta', 'BusyDelta'
        Replication = 'Name', 'MBps', 'MBToSend', 'TimeLagSec', 'InitPct', 'BufferFreePct'
    }
    $titles = @{ Server = 'Server (Fe = Host-Zugriffe, Mirror = eingehende Spiegel-Schreibvorgänge)'; VirtualDisk = 'Virtuelle Disks'; LogicalDisk = 'Logical Disks (je Server)'; Pool = 'Disk-Pools'; PhysicalDisk = 'Pool-Disks'; Port = 'Frontend- und Spiegel-Ports'; Replication = 'Replikationen' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $cols.Keys) {
        $g = @($m | Where-Object Kind -eq $k); if (-not $g.Count) { continue }
        [void]$sb.AppendLine("=== $($titles[$k]) - Intervall $($g[0].IntervalSec) s ===")
        [void]$sb.AppendLine((($g | Select-Object $cols[$k] | Format-Table -AutoSize | Out-String -Width 400).Trim())); [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('Einheiten: IOPS = Operationen/s, MBps = MB/s, *LatMs = mittlere Antwortzeit in ms, *Pct = Prozent.')
    $sb.ToString()
}

function Test-SsyPerformance($m) {
    $T = $script:T; $m = @($m)
    $sev = { param($v, $warn, $crit) if ($null -eq $v) { $null } elseif ($v -ge $crit) { 'Kritisch' } elseif ($v -ge $warn) { 'Warnung' } else { $null } }
    $srv = @($m | Where-Object Kind -eq 'Server'); $narr = @()
    foreach ($s in $srv) {
        if ($s.FeIOPS -ge $T.MinIops) {
            $x = & $sev $s.FeLatMs $T.FeWarnMs $T.FeCritMs; $cause = @()
            foreach ($p in $srv | Where-Object { $_.Name -ne $s.Name -and $_.MirrorIOPS -ge $T.MinIops }) {
                if ($p.MirrorLatMs -ge $T.MirrorWarnMs) { $cause += "Spiegelziel $($p.Name) braucht $($p.MirrorLatMs) ms pro Spiegel-Schreibvorgang" }
                if ($p.PoolLatMs -ge $T.PoolWarnMs) { $cause += "Pool-Backend auf $($p.Name) braucht $($p.PoolLatMs) ms" }
            }
            if ($s.PoolLatMs -ge $T.PoolWarnMs) { $cause += "eigenes Pool-Backend braucht $($s.PoolLatMs) ms" }
            if ($null -ne $s.CacheWriteHitPct -and $s.CacheWriteHitPct -lt $T.CacheHitWarnPct) { $cause += "Schreib-Cache-Trefferquote nur $($s.CacheWriteHitPct) %" }
            $line = "$($s.Name): $($s.FeIOPS) IOPS von Hosts, mittlere Antwortzeit $($s.FeLatMs) ms"
            if ($x) { $why = if ($cause) { 'Wahrscheinliche Ursache: ' + ($cause -join '; ') } else { 'Keine eindeutige Ursache in Spiegel/Pool/Cache - Frontend-Netz und Host-Seite prüfen' }; Add-SsyCheck 'Leistung' 'Antwortzeit für Hosts' $s.Name $x "$($s.FeLatMs) ms bei $($s.FeIOPS) IOPS / $($s.MBps) MB/s" $why; $narr += "$line - zu hoch. $why." }
            else { Add-SsyCheck 'Leistung' 'Antwortzeit für Hosts' $s.Name 'OK' "$($s.FeLatMs) ms bei $($s.FeIOPS) IOPS"; $narr += "$line - im grünen Bereich." }
        }
        if ($s.MirrorIOPS -ge $T.MinIops) {
            $x = & $sev $s.MirrorLatMs $T.MirrorWarnMs $T.MirrorCritMs
            if ($x) {
                $cacheOk = ($null -eq $s.CacheWriteHitPct -or $s.CacheWriteHitPct -ge $T.CacheHitWarnPct); $poolOk = ($null -eq $s.PoolLatMs -or $s.PoolLatMs -lt $T.PoolWarnMs)
                $rec = if ($cacheOk -and $poolOk) { "Cache ($($s.CacheWriteHitPct) % Treffer) und Pool ($($s.PoolLatMs) ms) auf $($s.Name) sind unauffällig - die Zeit geht auf der Spiegelstrecke verloren (NIC-Typ, Subnetz-Design, CPU-Last, iSCSI-Einstellungen; siehe Netzwerk/Spiegelstrecke)" } else { "Ziel $($s.Name) kann nicht schnell genug aufnehmen (Cache-Treffer $($s.CacheWriteHitPct) %, Pool $($s.PoolLatMs) ms) - RAM/Cache und Backend dort prüfen" }
                Add-SsyCheck 'Leistung' 'Spiegel-Schreiblatenz' $s.Name $x "$($s.MirrorLatMs) ms bei $($s.MirrorIOPS) Spiegel-IOPS (jeder Host-Schreibvorgang wartet darauf)" $rec
            } else { Add-SsyCheck 'Leistung' 'Spiegel-Schreiblatenz' $s.Name 'OK' "$($s.MirrorLatMs) ms bei $($s.MirrorIOPS) IOPS" }
        }
        if ($s.PoolIOPS -ge 1) { $x = & $sev $s.PoolLatMs $T.PoolWarnMs $T.PoolCritMs; if ($x) { Add-SsyCheck 'Leistung' 'Pool-Backend-Latenz' $s.Name $x "$($s.PoolLatMs) ms bei $($s.PoolIOPS) Ops/s" 'Darunterliegenden Speicher (RAID, Disks, Datastore) prüfen oder Last verteilen' } else { Add-SsyCheck 'Leistung' 'Pool-Backend-Latenz' $s.Name 'OK' "$($s.PoolLatMs) ms" } }
        if ($null -ne $s.CacheWriteHitPct -and $s.CacheWriteHitPct -lt $T.CacheHitWarnPct -and ($s.FeIOPS + $s.MirrorIOPS) -ge $T.MinIops) { Add-SsyCheck 'Leistung' 'Schreib-Cache-Trefferquote' $s.Name 'Warnung' "$($s.CacheWriteHitPct) %" 'Cache läuft voll: Backend schreibt nicht schnell genug weg oder zu wenig RAM für Cache' }
        $x = & $sev $s.PollerLoad $T.PollerWarn $T.PollerCrit; if ($x) { Add-SsyCheck 'Leistung' 'Poller-Last' $s.Name $x "$($s.PollerLoad) %" 'Mehr Poller-CPUs oder Last verteilen' }
    }
    if (-not ($srv | Where-Object { $_.FeIOPS -ge $T.MinIops })) {
        $narr += "Im Messzeitraum lag kaum Host-Last an (unter $($T.MinIops) IOPS) - Antwortzeiten sind so nicht aussagekräftig. Messung unter typischer Last wiederholen."
        Add-SsyCheck 'Leistung' 'Messung aussagekräftig' $script:Group.Caption 'Info' 'Zu wenig Host-Last im Messzeitraum' 'Messung unter typischer Last wiederholen'
    }
    $pools = @($m | Where-Object { $_.Kind -eq 'Pool' -and $_.IOPS -ge 1 -and $_.LatMs })
    if ($pools.Count -ge 2) {
        $slow = $pools | Sort-Object LatMs -Descending | Select-Object -First 1; $fast = $pools | Sort-Object LatMs | Select-Object -First 1
        if ($fast.LatMs -gt 0 -and ($slow.LatMs / $fast.LatMs) -ge $T.AsymmetryFactor -and $slow.LatMs -ge 5) { Add-SsyCheck 'Leistung' 'Gleichmäßige Pools' $slow.Name 'Warnung' "$([math]::Round($slow.LatMs / $fast.LatMs, 1))-mal langsamer als $($fast.Name) ($($slow.LatMs) vs. $($fast.LatMs) ms)" 'Bei gespiegelten vDisks bestimmt die langsamere Seite das Tempo - Backends angleichen' }
    }
    foreach ($d in $m | Where-Object { $_.Kind -eq 'PhysicalDisk' -and $_.IOPS -ge 1 }) {
        $x = & $sev $d.LatMs $T.DiskWarnMs $T.DiskCritMs; if ($x) { Add-SsyCheck 'Leistung' 'Disk-Latenz' $d.Name $x "$($d.LatMs) ms bei $($d.IOPS) IOPS" 'Disk/Datastore prüfen, ggf. ersetzen oder entlasten' }
        if ($d.QueueLen -ge $T.QueueWarn) { Add-SsyCheck 'Leistung' 'Disk-Warteschlange' $d.Name 'Warnung' "Warteschlange $($d.QueueLen) bei $($d.IOPS) IOPS, $($d.LatMs) ms" 'Disk ist ausgelastet - Last verteilen oder schnellere Disk (unkritisch, solange die Latenz niedrig bleibt)' }
    }
    foreach ($l in $m | Where-Object Kind -eq 'LogicalDisk') {
        if ($l.PendingToMirror -ge $T.PendingMirrorWarn) { Add-SsyCheck 'Leistung' 'Wartende Spiegel-Schreibvorgänge' $l.Name 'Warnung' "$($l.PendingToMirror) ausstehend" 'Spiegelpfad und Partner prüfen' }
        if ($l.IOPS -ge $T.MinIops) { $x = & $sev $l.BackendLatMs $T.PoolWarnMs $T.PoolCritMs; if ($x) { Add-SsyCheck 'Leistung' 'Cache-Destage-Latenz' $l.Name $x "$($l.BackendLatMs) ms" 'Backend dieser Seite prüfen' } }
    }
    foreach ($p in $m | Where-Object Kind -eq 'Port') {
        if ($p.ErrorsDelta -gt 0) { Add-SsyCheck 'Leistung' 'Port-Fehler' $p.Name 'Warnung' "$($p.ErrorsDelta) Übertragungsfehler im Messintervall" 'Verkabelung, NIC, Switch-Port prüfen' }
        if ($p.BusyDelta -gt 0) { Add-SsyCheck 'Leistung' 'Port überlastet' $p.Name 'Warnung' "$($p.BusyDelta) Busy-Antworten" 'Last auf weitere Ports verteilen' }
        if ($p.IOPS -ge $T.MinIops -and $p.LatMs -ge $T.PortWarnMs) { Add-SsyCheck 'Leistung' 'Port-Antwortzeit' $p.Name 'Warnung' "$($p.LatMs) ms ($($p.Role)) bei $($p.IOPS) IOPS" 'Latenz entsteht hinter dem Port (Cache/Spiegel/Backend) oder im Netz' }
    }
    foreach ($r in $m | Where-Object Kind -eq 'Replication') { if ($r.MBps -gt 0) { $narr += "Replikation $($r.Name): $($r.MBps) MB/s übertragen, $($r.MBToSend) MB ausstehend$(if ($r.InitPct) { ", Initialisierung $($r.InitPct) %" })." } }
    $script:PerfNarrative = $narr -join "`r`n"
}
#endregion

#region Bewertung, Vergleich, Bericht
function Get-SsyAssessment {
    $c = $script:Checks.ToArray()
    $cnt = { param($st) @($c | Where-Object Status -eq $st).Count }
    $crit = & $cnt 'Kritisch'; $warn = & $cnt 'Warnung'; $info = & $cnt 'Info'; $ok = & $cnt 'OK'
    $dist = { param($st) @($c | Where-Object Status -eq $st | Select-Object -ExpandProperty Check -Unique).Count }
    # Abzug je ART von Befund (nicht je Objekt): kritisch 20 (max. 60), Warnung 3 (max. 45), Hinweis 1 (max. 5)
    $score = [int][math]::Max(0, 100 - [math]::Min(60, 20 * (& $dist 'Kritisch')) - [math]::Min(45, 3 * (& $dist 'Warnung')) - [math]::Min(5, (& $dist 'Info')))
    $grade = if ($crit) { 'Rot' } elseif ($warn) { 'Gelb' } else { 'Grün' }
    $cats = foreach ($cat in $script:Categories) {
        $g = @($c | Where-Object Category -eq $cat); if (-not $g.Count) { continue }
        $worst = ($g | Sort-Object Rank -Descending | Select-Object -First 1).Status
        [pscustomobject]@{ Category = $cat; Worst = $worst; Critical = @($g | Where-Object Status -eq 'Kritisch').Count; Warnings = @($g | Where-Object Status -eq 'Warnung').Count; Infos = @($g | Where-Object Status -eq 'Info').Count; Ok = @($g | Where-Object Status -eq 'OK').Count }
    }
    $verdict = switch ($grade) { 'Rot' { 'Es gibt kritische Befunde, die Verfügbarkeit oder Leistung unmittelbar gefährden. Diese zuerst beheben.' } 'Gelb' { 'Die Umgebung läuft, hat aber Schwachstellen bei Leistung, Ausfallsicherheit oder Betrieb.' } default { 'Keine Auffälligkeiten - die Umgebung ist in gutem Zustand.' } }
    $area = { param([string[]]$names) $w = @($c | Where-Object { $names -contains $_.Category -and $_.Rank -ge 2 }); if (@($w | Where-Object Rank -eq 3).Count) { 'kritisch' } elseif ($w.Count) { "$($w.Count) Warnung(en)" } else { 'in Ordnung' } }
    $top = @($c | Where-Object { $_.Rank -ge 2 -and $_.Recommendation } | Sort-Object Rank -Descending | Group-Object Recommendation | Select-Object -First 6 | ForEach-Object { $f = $_.Group[0]; "[$($f.Status)] $($f.Check) - $($f.Object): $($f.Recommendation)" })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Gesamtbewertung: $grade ($score von 100 Punkten)")
    [void]$sb.AppendLine("Kritisch: $crit   Warnungen: $warn   Hinweise: $info   OK: $ok")
    [void]$sb.AppendLine($verdict)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Verfügbarkeit: $(& $area @('Verfügbarkeit','vDisks & Spiegel','Host-Pfade'))  |  Leistung: $(& $area @('Leistung','Spiegelstrecke','Server & Cache'))  |  Schutz/DR: $(& $area @('Replikation & Schutz'))  |  Betrieb: $(& $area @('Betrieb','Lizenz & Software','Monitore & Alarme','Windows','Netzwerk','Pools & Disks'))")
    if ($script:PerfNarrative) { [void]$sb.AppendLine(''); [void]$sb.AppendLine('Leistung:'); [void]$sb.AppendLine($script:PerfNarrative) }
    if ($top) { [void]$sb.AppendLine(''); [void]$sb.AppendLine('Wichtigste Maßnahmen:'); $i = 1; foreach ($t in $top) { [void]$sb.AppendLine("$i. $t"); $i++ } }
    [pscustomobject]@{ Grade = $grade; Score = $score; Critical = $crit; Warnings = $warn; Infos = $info; Ok = $ok; Categories = @($cats); Summary = $sb.ToString().TrimEnd() }
}

function Get-SsyArray($x) { if ($null -ne $x -and $x.PSObject.Properties['value'] -and $x.PSObject.Properties['Count'] -and -not ($x -is [array])) { @($x.value) } else { @($x) } }
function Compare-SsyResult($Old, $New) {
    $sb = New-Object System.Text.StringBuilder
    $Old = $Old | Select-Object *, @{ n = 'ChecksA'; e = { Get-SsyArray $_.Checks } }, @{ n = 'MeasA'; e = { Get-SsyArray $_.Measurements } }
    $Old.Checks = $Old.ChecksA; $Old.Measurements = $Old.MeasA
    $oc = @{}; foreach ($c in @($Old.Checks)) { $oc["$($c.Category)|$($c.Check)|$($c.Object)"] = $c }
    $nc = @{}; foreach ($c in @($New.Checks)) { $nc["$($c.Category)|$($c.Check)|$($c.Object)"] = $c }
    [void]$sb.AppendLine("Vergleich: alt $($Old.Time) ($($Old.Server))  ->  neu $($New.Time) ($($New.Server))")
    [void]$sb.AppendLine("Bewertung: $($Old.Assessment.Grade) $($Old.Assessment.Score)/100  ->  $($New.Assessment.Grade) $($New.Assessment.Score)/100  (Δ $($New.Assessment.Score - $Old.Assessment.Score))")
    [void]$sb.AppendLine("Kritisch $($Old.Assessment.Critical) -> $($New.Assessment.Critical), Warnungen $($Old.Assessment.Warnings) -> $($New.Assessment.Warnings), Hinweise $($Old.Assessment.Infos) -> $($New.Assessment.Infos)")
    $newBad = @($nc.Keys | Where-Object { $nc[$_].Rank -ge 1 -and (-not $oc.ContainsKey($_) -or [int]$oc[$_].Rank -lt [int]$nc[$_].Rank) } | Sort-Object)
    $fixed = @($oc.Keys | Where-Object { [int]$oc[$_].Rank -ge 1 -and (-not $nc.ContainsKey($_) -or [int]$nc[$_].Rank -lt [int]$oc[$_].Rank) } | Sort-Object)
    [void]$sb.AppendLine(''); [void]$sb.AppendLine("=== Neu oder schlechter ($($newBad.Count)) ===")
    foreach ($k in $newBad) { $n = $nc[$k]; $was = if ($oc.ContainsKey($k)) { $oc[$k].Status } else { 'neu' }; [void]$sb.AppendLine("[$was -> $($n.Status)] $($n.Category) / $($n.Check) / $($n.Object): $($n.Result)") }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine("=== Behoben oder besser ($($fixed.Count)) ===")
    foreach ($k in $fixed) { $o = $oc[$k]; $now = if ($nc.ContainsKey($k)) { $nc[$k].Status } else { 'entfällt' }; [void]$sb.AppendLine("[$($o.Status) -> $now] $($o.Category) / $($o.Check) / $($o.Object): war: $($o.Result)") }
    [void]$sb.AppendLine(''); [void]$sb.AppendLine('=== Leistung (Server) ===')
    $om = @{}; foreach ($x in @($Old.Measurements | Where-Object Kind -eq 'Server')) { $om[$x.Name] = $x }
    foreach ($x in @($New.Measurements | Where-Object Kind -eq 'Server')) {
        $o = $om[$x.Name]
        $f = { param($p) $a = if ($o) { $o.$p } else { '-' }; "${p}: $a -> $($x.$p)" }
        [void]$sb.AppendLine("$($x.Name): " + ((@('FeIOPS', 'FeLatMs', 'MirrorIOPS', 'MirrorLatMs', 'PoolLatMs', 'CacheWriteHitPct') | ForEach-Object { & $f $_ }) -join ' | '))
    }
    $sb.ToString()
}

function ConvertTo-SsyHtml($Result) {
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $a = $Result.Assessment
    $color = @{ 'Rot' = '#c0392b'; 'Gelb' = '#d4a017'; 'Grün' = '#2e8b57' }[$a.Grade]
    $cc = @{ Kritisch = '#c0392b'; Warnung = '#d4a017'; Info = '#3b7dd8'; OK = '#2e8b57' }
    $css = 'body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222;background:#fff}h1{margin:0 0 4px}small{color:#666}' +
    '.grade{display:inline-block;padding:14px 22px;border-radius:8px;color:#fff;font-size:22px;font-weight:600;margin:14px 0}' +
    '.tiles{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0 16px}.tile{border-left:6px solid #999;background:#f6f6f6;padding:6px 10px;border-radius:4px;font-size:13px;min-width:150px}' +
    'pre{background:#f6f6f6;padding:12px;border-radius:6px;white-space:pre-wrap;font-family:Consolas,monospace;font-size:12px;overflow-x:auto}' +
    'table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #ddd;padding:5px 7px;text-align:left;vertical-align:top}th{background:#f0f0f0;position:sticky;top:0}' +
    'tr.Kritisch{background:#f8d7da}tr.Warnung{background:#fff3cd}tr.Info{background:#e7f1ff}tr.OK{background:#eef8f0}details{margin:6px 0}' +
    '@media (prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}pre,.tile{background:#2a2a2a}th{background:#333}th,td{border-color:#444}tr.Kritisch{background:#5a2328}tr.Warnung{background:#5a4a1a}tr.Info{background:#1f3550}tr.OK{background:#1f3a28}}'
    $tiles = foreach ($t in $a.Categories) { "<div class='tile' style='border-left-color:$($cc[$t.Worst])'><b>$(& $enc $t.Category)</b><br>$($t.Critical) K · $($t.Warnings) W · $($t.Infos) I · $($t.Ok) OK</div>" }
    $rows = foreach ($c in $Result.Checks) { "<tr class='$($c.Status)'><td>$(& $enc $c.Status)</td><td>$(& $enc $c.Category)</td><td>$(& $enc $c.Check)</td><td>$(& $enc $c.Object)</td><td>$(& $enc $c.Result)$(if ($c.Details) { "<details><summary>Details</summary><pre>$(& $enc $c.Details)</pre></details>" })</td><td>$(& $enc $c.Recommendation)</td></tr>" }
    $cmp = if ($Result.Comparison) { "<h2>Vergleich mit früherem Bericht</h2><pre>$(& $enc $Result.Comparison)</pre>" } else { '' }
    @"
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SANsymphony Diagnose $(& $enc $Result.Server)</title><style>$css</style></head><body>
<h1>SANsymphony Diagnose</h1><small>Server $(& $enc $Result.Server) · Gruppe $(& $enc $Result.Group) · $(& $enc $Result.Time) · Messdauer $($Result.Seconds) s · Tool $(& $enc $Result.ToolVersion)</small><br>
<div class="grade" style="background:$color">$(& $enc $a.Grade) - $($a.Score)/100</div>
<div class="tiles">$($tiles -join '')</div>
<pre>$(& $enc $a.Summary)</pre>
$cmp
<h2>Befunde</h2><table><tr><th>Status</th><th>Bereich</th><th>Prüfung</th><th>Objekt</th><th>Ergebnis</th><th>Empfehlung</th></tr>
$($rows -join "`n")
</table>
<h2>Messwerte</h2><pre>$(& $enc $Result.MeasurementText)</pre>
<h2>Bestand</h2><pre>$(& $enc $Result.InventoryText)</pre>
</body></html>
"@
}

function Invoke-SsyDiagnosis([int]$Seconds = 30, [switch]$SkipPerformance, [switch]$DeepAnalysis, [string]$ToolVersion = '', $Compare = $null) {
    $script:Checks = New-Object System.Collections.Generic.List[object]
    $script:Inventory = New-Object System.Text.StringBuilder
    $script:PerfNarrative = ''
    try {
        Write-SsyProgress 2 'Verbinde mit DataCore und lese Konfiguration …'; Initialize-Ssy
        Write-SsyProgress 8 'Prüfe Gruppe, Lizenz, Server, Zeit, Sicherung, Alarmierung …'; Test-SsyGroupAndServers
        Write-SsyProgress 16 'Prüfe Pools und Disks …'; Test-SsyPoolsDisks
        Write-SsyProgress 22 'Prüfe virtuelle Disks und Spiegel …'; Test-SsyVirtualDisks
        Write-SsyProgress 28 'Prüfe Host-Pfade …'; Test-SsyHostPaths
        Write-SsyProgress 33 'Prüfe Replikation, Snapshots, Monitore und Alarme …'; Test-SsyProtection; Test-SsyMonitorsAlerts
        Write-SsyProgress 40 'Prüfe Windows (Dienste, Energie, CPU, Ereignisse, Sicherheit) …'; Test-SsyHostOs
        Write-SsyProgress 46 'Prüfe Netzwerk und Spiegelstrecke (Ping-/MTU-Tests) …'; Test-SsyNetwork
        if ($DeepAnalysis) { Write-SsyProgress 52 'Tiefenanalyse: Paketmitschnitt iSCSI (20 s) …'; Invoke-SsyDeepAnalysis -Seconds 20 }
        $m = @()
        if (-not $SkipPerformance) { Write-SsyProgress 55 "Messe Leistung ($Seconds s) …"; $m = @(Measure-SsyPerformance -Seconds $Seconds); Write-SsyProgress 92 'Bewerte Leistung …'; Test-SsyPerformance $m }
        else { $script:PerfNarrative = 'Leistungsmessung übersprungen.' }
        $checks = @($script:Checks.ToArray() | Sort-Object @{ e = 'Rank'; Descending = $true }, Category, Check, Object)
        $res = [pscustomobject]@{
            Time = (Get-Date).ToString('dd.MM.yyyy HH:mm'); Server = $env:COMPUTERNAME; Group = $script:Group.Caption; Seconds = $(if ($SkipPerformance) { 0 } else { $Seconds }); ToolVersion = $ToolVersion
            Checks = $checks; Measurements = $m; MeasurementText = $(if ($m.Count) { Format-SsyMeasurement $m } else { 'Keine Leistungsmessung.' }); InventoryText = $script:Inventory.ToString()
            Assessment = (Get-SsyAssessment); Comparison = $null
        }
        if ($Compare) { try { $res.Comparison = Compare-SsyResult $Compare $res } catch { $res.Comparison = "Vergleich nicht möglich: $($_.Exception.Message)" } }
        if ($sync) { $sync.Result = $res }
        Write-SsyProgress 100 "Fertig: $($checks.Count) Prüfergebnisse."
        $res
    } catch { if ($sync) { $sync.Error = "$($_.Exception.Message)" }; throw }
    finally {
        if ($script:Conn) { try { Disconnect-DcsServer -Connection $script:Conn | Out-Null } catch {}; $script:Conn = $null }
        if ($sync) { $sync.Done = $true }
    }
}

function New-SsyDemoResult([string]$ToolVersion = '') {
    # Frei erfundene Beispieldaten - keine echte Umgebung. Für Demo, Schulung und Vorschaubilder.
    $script:Checks = New-Object System.Collections.Generic.List[object]
    $script:Inventory = New-Object System.Text.StringBuilder
    $script:Group = [pscustomobject]@{ Caption = 'DEMO-GROUP' }
    $c = @(
        @('Lizenz & Software', 'Lizenzablauf', 'DEMO-GROUP', 'Warnung', 'Nächster Ablauf: in 21 Tagen', 'Lizenz rechtzeitig verlängern - abgelaufene Lizenz stoppt Server'),
        @('Lizenz & Software', 'Lizenz-Compliance', 'DEMO-GROUP', 'OK', 'Lizenztyp: Standard', ''),
        @('Lizenz & Software', 'Gleicher Versionsstand', 'DEMO-GROUP', 'OK', 'Alle Server auf 10.0 PSP 22 (Build 15.0.2200.53414)', ''),
        @('Verfügbarkeit', 'Serverstatus', 'SDS-A', 'OK', 'Online', ''), @('Verfügbarkeit', 'Serverstatus', 'SDS-B', 'OK', 'Online', ''),
        @('Verfügbarkeit', 'Witness (Split-Brain-Schutz)', 'DEMO-GROUP', 'Info', 'Kein Witness konfiguriert', 'Bei zwei Servern einen Witness einrichten, damit bei Verbindungsverlust automatisch die richtige Seite aktiv bleibt'),
        @('Verfügbarkeit', 'Host erreicht beide Spiegelseiten', 'esx02.demo.local / VD-SQL01', 'Warnung', 'Aktive Pfade nur zu: SDS-A', 'Fällt dieser Server aus, verliert der Host die vDisk - Pfade zum zweiten Server herstellen'),
        @('Server & Cache', 'Schreib-Cache-Modus', 'SDS-A', 'OK', 'WritebackGlobal', ''), @('Server & Cache', 'Schreib-Cache-Modus', 'SDS-B', 'OK', 'WritebackGlobal', ''),
        @('Server & Cache', 'Freier Arbeitsspeicher', 'SDS-B', 'Warnung', '1.4 GB von 64 GB frei (2.2 %)', 'RAM erweitern oder Speicherverbraucher begrenzen'),
        @('Server & Cache', 'Cache-Größe', 'SDS-A', 'OK', '38.4 GB Cache (60 % des RAM)', ''),
        @('Pools & Disks', 'Freie Kapazität', 'Pool1 on SDS-A', 'Warnung', '14 % frei (2.1 TB von 15.0 TB)', 'Kapazitätserweiterung planen'),
        @('Pools & Disks', 'Freie Kapazität', 'Pool1 on SDS-B', 'OK', '41 % frei (6.2 TB von 15.0 TB)', ''),
        @('Pools & Disks', 'S.M.A.R.T.', 'Disk 7 on SDS-B', 'Kritisch', 'SMART: PredictFailure', 'Disk vorsorglich ersetzen'),
        @('vDisks & Spiegel', 'Spiegel-Resynchronisation', 'VD-FILE01 on SDS-B', 'Warnung', 'Resync läuft: 312.4 GB offen (63 %)', 'Während des Resync ist die Redundanz eingeschränkt'),
        @('vDisks & Spiegel', 'vDisk-Status', 'VD-SQL01', 'OK', 'Online, MultiPathMirrored, 2048.0 GB', ''),
        @('Host-Pfade', 'Aktive Pfade je vDisk', 'esx01.demo.local / VD-SQL01', 'OK', '4 von 4 Pfaden aktiv', ''),
        @('Host-Pfade', 'Aktive Pfade je vDisk', 'esx02.demo.local / VD-SQL01', 'Warnung', '2 von 4 Pfaden aktiv; ohne Verbindung: SDS-B-FE1 on SDS-B, SDS-B-FE2 on SDS-B', 'Fehlende iSCSI-Sessions herstellen (Netz, Subnetze, VMkernel-Ports/Initiator-IPs, Discovery, Rescan)'),
        @('Host-Pfade', 'Initiator-IPs des Hosts', 'esx02.demo.local', 'Warnung', 'Alle Sessions kommen von einer einzigen IP (10.20.1.12)', 'Zweiten iSCSI-Netzwerkport (z. B. VMkernel) im zweiten Netz anlegen'),
        @('Replikation & Schutz', 'Replikationsstatus', 'VD-SQL01', 'OK', 'Status: Replicating; Übertragung: Enabled; Fehler: keine', ''),
        @('Replikation & Schutz', 'Replikationsrückstand', 'VD-FILE01', 'Warnung', 'Zeitversatz 42.5 min', 'Bandbreite zur DR-Seite und Puffer prüfen - bei Ausfall gingen diese Daten verloren'),
        @('Replikation & Schutz', 'Snapshots/CDP/Rollbacks', 'DEMO-GROUP', 'OK', '6 Snapshot(s), 2 vDisk-Seite(n) mit CDP, 0 Rollback(s)', ''),
        @('Monitore & Alarme', 'Alarme letzte 24 h', 'DEMO-GROUP', 'Warnung', '12 Fehler, 31 Warnungen', 'Häufigste Fehler prüfen (Details)'),
        @('Monitore & Alarme', 'I/O latency', 'I/O latency of Virtual Disk VD-SQL01', 'Warnung', 'The I/O latency is >= 120ms', 'Siehe DataCore-Konsole, Bereich Monitore'),
        @('Betrieb', 'Alarmierung (E-Mail/Syslog)', 'DEMO-GROUP', 'Warnung', 'Weder E-Mail- noch Syslog-Benachrichtigung eingerichtet', 'SMTP oder Syslog einrichten, damit Ausfälle und Warnungen jemand erfährt'),
        @('Betrieb', 'Uhrzeit synchron', 'SDS-B', 'OK', 'Abweichung zu diesem Server: 0.4 s', ''),
        @('Betrieb', 'Konfigurationssicherung', 'SDS-A', 'Warnung', 'Letzte Sicherung: BACKUP_SDS-A.zip vor 38 Tag(en)', 'Konfiguration nach jeder Änderung und regelmäßig sichern'),
        @('Windows', 'Energiesparplan', 'SDS-A', 'OK', 'Höchstleistung', ''),
        @('Windows', 'Virenschutz-Ausnahmen', 'SDS-A', 'Warnung', 'Defender-Echtzeitschutz aktiv, keine Ausnahme für DataCore-Ordner', 'Ausnahmen gemäß DataCore-Empfehlung setzen'),
        @('Windows', 'CPU-Auslastung', 'SDS-A', 'OK', '16 logische CPUs, Auslastung 38 %; 2 für DataCore-Poller reserviert', ''),
        @('Netzwerk', 'Getrennte Subnetze je Pfad', 'SDS-A', 'Warnung', 'Mehrere Karten liegen im selben IP-Netz: MR1 10.30.0.0/16 <-> MR2 10.30.0.0/16', 'Jedem Pfad ein eigenes Subnetz geben (z. B. /24 je Netz) - auf allen Servern UND auf den Hosts'),
        @('Netzwerk', 'Netzwerkkarten-Typ', 'MR1 (SDS-A-MR1, 10.30.1.11/16)', 'Warnung', 'Emulierte/ältere NIC: Intel(R) 82574L Gigabit Network Connection', 'Im Hypervisor auf VMXNET3 (paravirtualisiert) umstellen'),
        @('Netzwerk', 'Energiesparen der Karte', 'FE1 (SDS-A-FE1, 10.20.1.11/24)', 'Warnung', 'Windows darf die Karte zum Energiesparen abschalten', 'In den Karteneigenschaften die Energiesparoption deaktivieren'),
        @('Netzwerk', 'DataCore-Verwaltungsport 3793', 'SDS-B', 'OK', 'sds-b.demo.local (10.10.0.12) erreichbar', ''),
        @('Spiegelstrecke', 'Pfadtrennung Spiegel-Sessions', 'SDS-A', 'Warnung', 'Alle ausgehenden Spiegel-Sessions (10.30.1.12, 10.30.2.12) nutzen dieselbe Quell-IP 10.30.1.11 - die zweite Spiegelkarte sendet nicht', 'Spiegelnetze in getrennte Subnetze legen, damit jeder Spiegelpfad seine eigene Karte nutzt'),
        @('Spiegelstrecke', 'Netzlaufzeit', '10.30.1.11 -> 10.30.1.12', 'OK', 'Ø 0 ms, max 1 ms, kein Verlust', ''),
        @('Spiegelstrecke', 'MTU Ende-zu-Ende', '10.30.1.11 -> 10.30.1.12', 'OK', 'MTU 9000 durchgängig', ''),
        @('Spiegelstrecke', 'Fehlschlagende Anmeldeversuche', '10.20.1.12 -> 10.20.2.11 (FE2)', 'Warnung', 'Initiator 10.20.1.12 versucht sich anzumelden, liegt aber nicht im Subnetz der Zielkarte', 'Auf der Initiator-Seite einen Netzwerkport im passenden Subnetz verwenden (z. B. ESXi: VMkernel-Port mit /24 im Zielnetz)'),
        @('Leistung', 'Antwortzeit für Hosts', 'SDS-A', 'Warnung', '14.8 ms bei 412 IOPS / 51.5 MB/s', 'Wahrscheinliche Ursache: Spiegelziel SDS-B braucht 9.6 ms pro Spiegel-Schreibvorgang'),
        @('Leistung', 'Spiegel-Schreiblatenz', 'SDS-B', 'Warnung', '9.6 ms bei 288 Spiegel-IOPS (jeder Host-Schreibvorgang wartet darauf)', 'Cache (99 % Treffer) und Pool (1.2 ms) auf SDS-B sind unauffällig - die Zeit geht auf der Spiegelstrecke verloren'),
        @('Leistung', 'Pool-Backend-Latenz', 'SDS-A', 'OK', '1.1 ms', '')
    )
    foreach ($x in $c) { Add-SsyCheck $x[0] $x[1] $x[2] $x[3] $x[4] $x[5] }
    ($script:Checks | Where-Object Check -eq 'Alarme letzte 24 h').Details = "7× The I/O latency of Virtual Disk VD-SQL# from DEMO-GROUP is >= #ms`r`n3× Connection to server {#} has been lost.`r`n2× Mirror path to SDS-B is down"
    $script:PerfNarrative = "SDS-A: 412 IOPS von Hosts, mittlere Antwortzeit 14.8 ms - zu hoch. Wahrscheinliche Ursache: Spiegelziel SDS-B braucht 9.6 ms pro Spiegel-Schreibvorgang.`r`nReplikation VD-FILE01: 18.2 MB/s übertragen, 9 830 MB ausstehend."
    Add-SsyInventory 'Servergruppe DEMO-GROUP - Server' @(
        [pscustomobject]@{ Server = 'SDS-A'; Status = 'Online'; Version = '10.0 PSP 22'; Cache = 'WritebackGlobal'; RAM = '64 GB'; Frei = '9.8 GB'; CacheGröße = '38.4 GB'; CPU = '16 Kerne' },
        [pscustomobject]@{ Server = 'SDS-B'; Status = 'Online'; Version = '10.0 PSP 22'; Cache = 'WritebackGlobal'; RAM = '64 GB'; Frei = '1.4 GB'; CacheGröße = '38.4 GB'; CPU = '16 Kerne' })
    Add-SsyInventory 'Disk-Pools' @(
        [pscustomobject]@{ Pool = 'Pool1 on SDS-A'; Status = 'Running'; Tiering = $true; Tiers = '1,2,3'; Disks = 12; Frei = '14 %'; Gesamt = '15 360 GB' },
        [pscustomobject]@{ Pool = 'Pool1 on SDS-B'; Status = 'Running'; Tiering = $true; Tiers = '1,2,3'; Disks = 12; Frei = '41 %'; Gesamt = '15 360 GB' })
    Add-SsyInventory 'Virtuelle Disks' @(
        [pscustomobject]@{ vDisk = 'VD-SQL01'; Typ = 'MultiPathMirrored'; Größe = '2048 GB'; Status = 'Online'; Ausgeliefert = $true; Seiten = 'SDS-A:UpToDate, SDS-B:UpToDate' },
        [pscustomobject]@{ vDisk = 'VD-FILE01'; Typ = 'MultiPathMirrored'; Größe = '4096 GB'; Status = 'Online'; Ausgeliefert = $true; Seiten = 'SDS-A:UpToDate, SDS-B:Recovering' })
    Add-SsyInventory 'Host-Pfade: esx02.demo.local' @(
        [pscustomobject]@{ vDisk = 'VD-SQL01'; Ziel = 'SDS-A-FE1 on SDS-A'; Aktiv = $true; Verbindung = '10.20.1.12->10.20.1.11' },
        [pscustomobject]@{ vDisk = 'VD-SQL01'; Ziel = 'SDS-A-FE2 on SDS-A'; Aktiv = $true; Verbindung = '10.20.2.12->10.20.2.11' },
        [pscustomobject]@{ vDisk = 'VD-SQL01'; Ziel = 'SDS-B-FE1 on SDS-B'; Aktiv = $false; Verbindung = '' },
        [pscustomobject]@{ vDisk = 'VD-SQL01'; Ziel = 'SDS-B-FE2 on SDS-B'; Aktiv = $false; Verbindung = '' })
    $m = @(
        [pscustomobject]@{ Kind = 'Server'; Name = 'SDS-A'; IntervalSec = 60; FeIOPS = 412; FeLatMs = 14.8; MirrorIOPS = 3.1; MirrorLatMs = 1.2; PoolIOPS = 96; PoolLatMs = 1.1; MBps = 51.5; CacheWriteHitPct = 99.2; CacheReadHitPct = 71.4; PollerLoad = 22; ReplMBToSend = 9830 },
        [pscustomobject]@{ Kind = 'Server'; Name = 'SDS-B'; IntervalSec = 60; FeIOPS = 0; FeLatMs = $null; MirrorIOPS = 288; MirrorLatMs = 9.6; PoolIOPS = 81; PoolLatMs = 1.2; MBps = 36.0; CacheWriteHitPct = 99.0; CacheReadHitPct = $null; PollerLoad = 18; ReplMBToSend = 0 },
        [pscustomobject]@{ Kind = 'Pool'; Name = 'Pool1 on SDS-A'; IntervalSec = 60; IOPS = 96; ReadIOPS = 41; WriteIOPS = 55; MBps = 38.2; LatMs = 1.1; ReadLatMs = 0.9; WriteLatMs = 1.3 },
        [pscustomobject]@{ Kind = 'Port'; Name = 'SDS-A-FE1 on SDS-A'; IntervalSec = 60; Role = 'Frontend'; IOPS = 208; MBps = 26.0; LatMs = 14.5; ErrorsDelta = 0; BusyDelta = 0 },
        [pscustomobject]@{ Kind = 'Port'; Name = 'SDS-B-MR1 on SDS-B'; IntervalSec = 60; Role = 'Mirror'; IOPS = 288; MBps = 36.0; LatMs = 9.4; ErrorsDelta = 0; BusyDelta = 0 },
        [pscustomobject]@{ Kind = 'Replication'; Name = 'VD-FILE01 from DEMO-GROUP'; IntervalSec = 60; MBps = 18.2; MBToSend = 9830; TimeLagSec = 2550; InitPct = $null; BufferFreePct = 64 }
    )
    $checks = @($script:Checks.ToArray() | Sort-Object @{ e = 'Rank'; Descending = $true }, Category, Check, Object)
    [pscustomobject]@{ Time = (Get-Date).ToString('dd.MM.yyyy HH:mm'); Server = 'SDS-A'; Group = 'DEMO-GROUP'; Seconds = 60; ToolVersion = "$ToolVersion (Demo)"
        Checks = $checks; Measurements = $m; MeasurementText = (Format-SsyMeasurement $m); InventoryText = $script:Inventory.ToString(); Assessment = (Get-SsyAssessment); Comparison = $null }
}

function ConvertTo-SsyJson($Result) {
    # Windows PowerShell 5.1 schreibt Arrays sonst als {"value":[...],"Count":n}
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
    $Result | Select-Object Time, Server, Group, Seconds, ToolVersion,
    @{ n = 'Checks'; e = { $_.Checks | Select-Object Status, Rank, Category, Check, Object, Result, Recommendation, Details } },
    @{ n = 'Measurements'; e = { $_.Measurements } }, @{ n = 'Assessment'; e = { $_.Assessment } }, MeasurementText, InventoryText, Comparison | ConvertTo-Json -Depth 6
}
#endregion
'@

# ============================================================================
#  Oberfläche
# ============================================================================
function Show-SsyGui([switch]$NoShow, $Result = $null, [string]$CaptureDir) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    . ([scriptblock]::Create($CoreScript))   # für Bericht/Vergleich im Vordergrund
    $font = New-Object System.Drawing.Font('Segoe UI', 9); $mono = New-Object System.Drawing.Font('Consolas', 9)
    $colors = @{ Kritisch = [System.Drawing.Color]::FromArgb(248, 215, 218); Warnung = [System.Drawing.Color]::FromArgb(255, 243, 205); Info = [System.Drawing.Color]::FromArgb(231, 241, 255); OK = [System.Drawing.Color]::FromArgb(232, 245, 233) }
    $strong = @{ Kritisch = [System.Drawing.Color]::FromArgb(192, 57, 43); Warnung = [System.Drawing.Color]::FromArgb(212, 160, 23); Info = [System.Drawing.Color]::FromArgb(59, 125, 216); OK = [System.Drawing.Color]::FromArgb(46, 139, 87) }
    $gradeColors = @{ 'Rot' = $strong.Kritisch; 'Gelb' = $strong.Warnung; 'Grün' = $strong.OK }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "SANsymphony Diagnose $ToolVersion - $(if ($Result) { "$($Result.Server) (Demo)" } else { $env:COMPUTERNAME })"; $form.Size = New-Object System.Drawing.Size(1320, 900); $form.MinimumSize = New-Object System.Drawing.Size(1000, 650)
    $form.StartPosition = 'CenterScreen'; $form.Font = $font

    # --- Werkzeugleiste
    $top = New-Object System.Windows.Forms.FlowLayoutPanel; $top.Dock = 'Top'; $top.Height = 44; $top.Padding = '8,8,8,0'; $top.WrapContents = $false
    $mk = { param($type, $text, $w) $c = New-Object $type; $c.Text = $text; if ($w) { $c.Width = $w }; $c.Margin = '0,0,8,0'; $c }
    $btnRun = & $mk System.Windows.Forms.Button 'Diagnose starten' 130; $btnRun.Height = 28
    $btnStop = & $mk System.Windows.Forms.Button 'Abbrechen' 85; $btnStop.Height = 28; $btnStop.Enabled = $false
    $lblSec = & $mk System.Windows.Forms.Label 'Messdauer:' 70; $lblSec.TextAlign = 'MiddleRight'; $lblSec.Height = 28
    $cmbSec = & $mk System.Windows.Forms.ComboBox '' 70; $cmbSec.DropDownStyle = 'DropDownList'; [void]$cmbSec.Items.AddRange(@('15 s', '30 s', '60 s', '120 s', '300 s')); $cmbSec.SelectedIndex = 1
    $chkPerf = & $mk System.Windows.Forms.CheckBox 'Leistung messen' 120; $chkPerf.Checked = $true; $chkPerf.Height = 28
    $chkDeep = & $mk System.Windows.Forms.CheckBox 'Tiefenanalyse (Paketmitschnitt 20 s)' 230; $chkDeep.Height = 28
    $btnSave = & $mk System.Windows.Forms.Button 'Bericht speichern …' 130; $btnSave.Height = 28; $btnSave.Enabled = $false
    $btnCmp = & $mk System.Windows.Forms.Button 'Mit früherem vergleichen …' 170; $btnCmp.Height = 28; $btnCmp.Enabled = $false
    $top.Controls.AddRange(@($btnRun, $btnStop, $lblSec, $cmbSec, $chkPerf, $chkDeep, $btnSave, $btnCmp))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($chkDeep, 'Schneidet 20 s lang iSCSI-Verbindungsaufbauten mit (pktmon) und erkennt Initiatoren, die sich mit falscher Quell-IP anmelden. Läuft nur, wenn kein anderer Mitschnitt aktiv ist.')
    $tip.SetToolTip($btnCmp, 'Lädt einen früher gespeicherten JSON-Bericht und zeigt, was neu, behoben oder schlechter ist.')

    $statusBar = New-Object System.Windows.Forms.Panel; $statusBar.Dock = 'Top'; $statusBar.Height = 26; $statusBar.Padding = '8,2,8,2'
    $prog = New-Object System.Windows.Forms.ProgressBar; $prog.Dock = 'Left'; $prog.Width = 300
    $lblStatus = New-Object System.Windows.Forms.Label; $lblStatus.Dock = 'Fill'; $lblStatus.TextAlign = 'MiddleLeft'; $lblStatus.Padding = '10,0,0,0'; $lblStatus.Text = 'Bereit. Das Tool prüft nur und ändert nichts.'
    $statusBar.Controls.Add($lblStatus); $statusBar.Controls.Add($prog)

    # --- Bewertung + Kategorien
    $assess = New-Object System.Windows.Forms.Panel; $assess.Dock = 'Top'; $assess.Height = 175; $assess.Padding = '8,4,8,4'
    $lblGrade = New-Object System.Windows.Forms.Label; $lblGrade.Dock = 'Left'; $lblGrade.Width = 170; $lblGrade.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $lblGrade.TextAlign = 'MiddleCenter'; $lblGrade.BackColor = [System.Drawing.Color]::Gainsboro; $lblGrade.Text = 'Noch keine Diagnose'
    $sp1 = New-Object System.Windows.Forms.Panel; $sp1.Dock = 'Left'; $sp1.Width = 8
    $txtSummary = New-Object System.Windows.Forms.TextBox; $txtSummary.Multiline = $true; $txtSummary.ReadOnly = $true; $txtSummary.ScrollBars = 'Vertical'; $txtSummary.Dock = 'Fill'
    $txtSummary.Font = New-Object System.Drawing.Font('Segoe UI', 9.5); $txtSummary.BackColor = [System.Drawing.Color]::White
    $txtSummary.Text = "Diagnose starten prüft rund 100 Punkte in 13 Bereichen: Verfügbarkeit, Lizenz, Server & Cache, Pools & Disks, vDisks & Spiegel, Host-Pfade, Replikation & Schutz, Monitore & Alarme, Betrieb (Zeit, Sicherung, Alarmierung), Windows, Netzwerk, Spiegelstrecke und Leistung - und bewertet alles mit Ursachenkette."
    $assess.Controls.Add($txtSummary); $assess.Controls.Add($sp1); $assess.Controls.Add($lblGrade)
    $tiles = New-Object System.Windows.Forms.FlowLayoutPanel; $tiles.Dock = 'Top'; $tiles.Height = 104; $tiles.Padding = '8,2,8,2'; $tiles.AutoScroll = $true

    # --- Reiter
    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock = 'Fill'
    $tpF = New-Object System.Windows.Forms.TabPage; $tpF.Text = 'Befunde'
    $tpI = New-Object System.Windows.Forms.TabPage; $tpI.Text = 'Bestand'
    $tpM = New-Object System.Windows.Forms.TabPage; $tpM.Text = 'Messwerte'
    $tpC = New-Object System.Windows.Forms.TabPage; $tpC.Text = 'Vergleich'
    $tpL = New-Object System.Windows.Forms.TabPage; $tpL.Text = 'Protokoll'
    $filter = New-Object System.Windows.Forms.FlowLayoutPanel; $filter.Dock = 'Top'; $filter.Height = 32; $filter.Padding = '4,4,4,0'; $filter.WrapContents = $false
    $cmbCat = New-Object System.Windows.Forms.ComboBox; $cmbCat.DropDownStyle = 'DropDownList'; $cmbCat.Width = 180; [void]$cmbCat.Items.Add('Alle Bereiche'); $cmbCat.SelectedIndex = 0
    $cmbSt = New-Object System.Windows.Forms.ComboBox; $cmbSt.DropDownStyle = 'DropDownList'; $cmbSt.Width = 160; [void]$cmbSt.Items.AddRange(@('Alle Status', 'Nur Auffälligkeiten', 'Kritisch', 'Warnung', 'Info', 'OK')); $cmbSt.SelectedIndex = 1
    $lblSearch = New-Object System.Windows.Forms.Label; $lblSearch.Text = 'Suche:'; $lblSearch.Width = 45; $lblSearch.TextAlign = 'MiddleRight'; $lblSearch.Height = 24
    $txtSearch = New-Object System.Windows.Forms.TextBox; $txtSearch.Width = 220
    $lblCount = New-Object System.Windows.Forms.Label; $lblCount.Width = 260; $lblCount.TextAlign = 'MiddleLeft'; $lblCount.Height = 24
    $filter.Controls.AddRange(@($cmbCat, $cmbSt, $lblSearch, $txtSearch, $lblCount))
    $split = New-Object System.Windows.Forms.SplitContainer; $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.SplitterDistance = 330
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.RowHeadersVisible = $false; $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.AutoSizeColumnsMode = 'Fill'; $grid.AutoSizeRowsMode = 'AllCells'; $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.DefaultCellStyle.WrapMode = 'True'; $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black; $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::LightSteelBlue
    foreach ($c in @(@('Status', 7), @('Bereich', 11), @('Prüfung', 15), @('Objekt', 20), @('Ergebnis', 25), @('Empfehlung', 28))) { $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $col.HeaderText = $c[0]; $col.Name = $c[0]; $col.FillWeight = $c[1]; [void]$grid.Columns.Add($col) }
    $txtDetail = New-Object System.Windows.Forms.TextBox; $txtDetail.Multiline = $true; $txtDetail.ReadOnly = $true; $txtDetail.ScrollBars = 'Vertical'; $txtDetail.Dock = 'Fill'; $txtDetail.Font = New-Object System.Drawing.Font('Segoe UI', 9.5); $txtDetail.BackColor = [System.Drawing.Color]::White
    $txtDetail.Text = 'Befund auswählen, um Details und Empfehlung zu sehen.'
    $split.Panel1.Controls.Add($grid); $split.Panel2.Controls.Add($txtDetail)
    $tpF.Controls.Add($split); $tpF.Controls.Add($filter)
    $newText = { $t = New-Object System.Windows.Forms.TextBox; $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Both'; $t.WordWrap = $false; $t.Dock = 'Fill'; $t.Font = $mono; $t.BackColor = [System.Drawing.Color]::White; $t }
    $txtInv = & $newText; $tpI.Controls.Add($txtInv)
    $txtMeas = & $newText; $tpM.Controls.Add($txtMeas)
    $txtCmp = & $newText; $txtCmp.Text = 'Nach einer Diagnose: »Mit früherem vergleichen …« und einen gespeicherten JSON-Bericht wählen.'; $tpC.Controls.Add($txtCmp)
    $txtLog = & $newText; $tpL.Controls.Add($txtLog)
    [void]$tabs.TabPages.AddRange(@($tpF, $tpI, $tpM, $tpC, $tpL))

    # Beim Reiterwechsel keinen Text vollständig markiert anzeigen
    $tabs.Add_SelectedIndexChanged({ foreach ($tb in @($txtInv, $txtMeas, $txtCmp, $txtLog)) { $tb.SelectionStart = 0; $tb.SelectionLength = 0 } })
    $form.Controls.Add($tabs); $form.Controls.Add($tiles); $form.Controls.Add($assess); $form.Controls.Add($statusBar); $form.Controls.Add($top)

    $script:GuiResult = $null; $script:Job = $null; $script:LogIndex = 0; $script:Visible = @()

    # Detailansicht: Befund hängt direkt an der Zeile (Tag), keine Index-Zuordnung
    $showDetail = {
        if ($grid.SelectedRows.Count -eq 0) { return }
        $c = $grid.SelectedRows[0].Tag; if (-not $c) { return }
        $txtDetail.Text = "[$($c.Status)] $($c.Category) / $($c.Check)`r`nObjekt: $($c.Object)`r`n`r`nErgebnis:`r`n$($c.Result)`r`n`r`nEmpfehlung:`r`n$(if ($c.Recommendation) { $c.Recommendation } else { '-' })$(if ($c.Details) { "`r`n`r`nDetails:`r`n$($c.Details -replace "`r?`n", "`r`n")" })"
    }
    $fillGrid = {
        $grid.Rows.Clear(); $script:Visible = @()
        if (-not $script:GuiResult) { return }
        $cat = "$($cmbCat.SelectedItem)"; $st = "$($cmbSt.SelectedItem)"; $q = $txtSearch.Text.Trim()
        foreach ($c in $script:GuiResult.Checks) {
            if ($cat -ne 'Alle Bereiche' -and $c.Category -ne $cat) { continue }
            if ($st -eq 'Nur Auffälligkeiten' -and $c.Rank -eq 0) { continue }
            if ($st -in 'Kritisch', 'Warnung', 'Info', 'OK' -and $c.Status -ne $st) { continue }
            if ($q -and -not ("$($c.Check) $($c.Object) $($c.Result) $($c.Recommendation) $($c.Details)" -like "*$q*")) { continue }
            $i = $grid.Rows.Add($c.Status, $c.Category, $c.Check, $c.Object, $c.Result, $c.Recommendation)
            $grid.Rows[$i].Tag = $c; $grid.Rows[$i].DefaultCellStyle.BackColor = $colors[$c.Status]; $script:Visible += $c
        }
        $lblCount.Text = "$($script:Visible.Count) von $(@($script:GuiResult.Checks).Count) Prüfergebnissen"
        if ($grid.Rows.Count) { $grid.ClearSelection(); $grid.Rows[0].Selected = $true; & $showDetail } else { $txtDetail.Text = 'Keine Befunde für diesen Filter.' }
    }
    $cmbCat.Add_SelectedIndexChanged($fillGrid); $cmbSt.Add_SelectedIndexChanged($fillGrid); $txtSearch.Add_TextChanged($fillGrid)
    $grid.Add_SelectionChanged({ & $showDetail })

    $buildTiles = {
        $tiles.Controls.Clear()
        foreach ($t in $script:GuiResult.Assessment.Categories) {
            $b = New-Object System.Windows.Forms.Button; $b.Width = 140; $b.Height = 46; $b.FlatStyle = 'Flat'; $b.Margin = '0,0,5,4'; $b.UseMnemonic = $false
            $b.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
            $b.FlatAppearance.BorderColor = $strong[$t.Worst]; $b.FlatAppearance.BorderSize = 2; $b.BackColor = $colors[$t.Worst]
            $b.Text = "$($t.Category)`r`n$($t.Critical) K · $($t.Warnings) W · $($t.Infos) I · $($t.Ok) OK"; $b.Tag = $t.Category
            $b.Add_Click({ param($s, $e) $idx = $cmbCat.Items.IndexOf($s.Tag); if ($idx -ge 0) { $cmbCat.SelectedIndex = $idx }; $cmbSt.SelectedIndex = 0; $tabs.SelectedTab = $tpF })
            $tiles.Controls.Add($b)
        }
    }
    $showResult = {
        $a = $script:GuiResult.Assessment
        $lblGrade.Text = "$($a.Grade)`r`n$($a.Score) / 100"; $lblGrade.BackColor = $gradeColors[$a.Grade]; $lblGrade.ForeColor = [System.Drawing.Color]::White
        $txtSummary.Text = ($a.Summary -replace "`r?`n", "`r`n")
        $txtMeas.Text = ($script:GuiResult.MeasurementText -replace "`r?`n", "`r`n"); $txtInv.Text = ($script:GuiResult.InventoryText -replace "`r?`n", "`r`n")
        $cmbCat.Items.Clear(); [void]$cmbCat.Items.Add('Alle Bereiche'); foreach ($t in $a.Categories) { [void]$cmbCat.Items.Add($t.Category) }; $cmbCat.SelectedIndex = 0
        & $buildTiles; & $fillGrid
        $btnSave.Enabled = $true; $btnCmp.Enabled = $true
        $lblStatus.Text = "Fertig: $($a.Critical) kritisch, $($a.Warnings) Warnungen, $($a.Infos) Hinweise, $($a.Ok) OK"
    }

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 300
    $timer.Add_Tick({
            $s = $script:Job.Sync
            $prog.Value = [math]::Min(100, [math]::Max(0, [int]$s.Progress)); if ($s.Status) { $lblStatus.Text = $s.Status }
            while ($script:LogIndex -lt $s.Log.Count) { $txtLog.AppendText($s.Log[$script:LogIndex] + "`r`n"); $script:LogIndex++ }
            $state = "$($script:Job.PS.InvocationStateInfo.State)"
            if ($s.Done -or $state -in 'Completed', 'Failed', 'Stopped') {
                $timer.Stop()
                try { if ($state -ne 'Stopped') { [void]$script:Job.PS.EndInvoke($script:Job.Handle) } } catch {}
                foreach ($e in $script:Job.PS.Streams.Error) { $txtLog.AppendText("Fehler: $e`r`n") }
                try { $script:Job.PS.Dispose(); $script:Job.RS.Close() } catch {}
                $btnRun.Enabled = $true; $btnStop.Enabled = $false; $cmbSec.Enabled = $true; $chkPerf.Enabled = $true; $chkDeep.Enabled = $true
                if ($state -eq 'Stopped') { $lblGrade.Text = 'Abgebrochen'; $lblGrade.BackColor = [System.Drawing.Color]::DimGray; $lblGrade.ForeColor = [System.Drawing.Color]::White; $lblStatus.Text = 'Abgebrochen.'; $txtSummary.Text = 'Diagnose wurde abgebrochen. Mit »Diagnose starten« neu beginnen.'; return }
                if ($s.Error -or -not $s.Result) {
                    $lblGrade.Text = 'Fehler'; $lblGrade.BackColor = [System.Drawing.Color]::DimGray; $lblGrade.ForeColor = [System.Drawing.Color]::White
                    $txtSummary.Text = "Die Diagnose konnte nicht abgeschlossen werden:`r`n$($s.Error)`r`n`r`nTool als Administrator auf einem SANsymphony-Server starten; Dienst DataCore Executive muss laufen."
                    $lblStatus.Text = 'Fehler - siehe Protokoll'; return
                }
                $script:GuiResult = $s.Result; & $showResult
            }
        })

    $btnRun.Add_Click({
            $btnRun.Enabled = $false; $btnStop.Enabled = $true; $cmbSec.Enabled = $false; $chkPerf.Enabled = $false; $chkDeep.Enabled = $false; $btnSave.Enabled = $false; $btnCmp.Enabled = $false
            $grid.Rows.Clear(); $txtLog.Clear(); $txtMeas.Clear(); $txtInv.Clear(); $tiles.Controls.Clear(); $script:LogIndex = 0; $script:GuiResult = $null
            $txtDetail.Text = ''; $lblGrade.Text = 'Läuft …'; $lblGrade.BackColor = [System.Drawing.Color]::Gainsboro; $lblGrade.ForeColor = [System.Drawing.Color]::Black
            $txtSummary.Text = 'Diagnose läuft. Die Oberfläche bleibt währenddessen bedienbar.'
            $sec = [int](($cmbSec.SelectedItem -replace '\D', ''))
            $sync = [hashtable]::Synchronized(@{ Progress = 0; Status = 'Starte …'; Done = $false; Result = $null; Error = $null; Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) })
            $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open(); $rs.SessionStateProxy.SetVariable('sync', $sync)
            $ps = [powershell]::Create(); $ps.Runspace = $rs
            $args2 = "-Seconds $sec -ToolVersion '$ToolVersion'" + $(if (-not $chkPerf.Checked) { ' -SkipPerformance' }) + $(if ($chkDeep.Checked) { ' -DeepAnalysis' })
            [void]$ps.AddScript($CoreScript + "`nInvoke-SsyDiagnosis $args2 | Out-Null")
            $script:Job = @{ PS = $ps; RS = $rs; Sync = $sync; Handle = $ps.BeginInvoke() }
            $timer.Start()
        })
    $btnStop.Add_Click({ if ($script:Job) { $btnStop.Enabled = $false; $lblStatus.Text = 'Breche ab …'; [void]$script:Job.PS.BeginStop($null, $null) } })

    $btnSave.Add_Click({
            if (-not $script:GuiResult) { return }
            $dlg = New-Object System.Windows.Forms.SaveFileDialog
            $dlg.Filter = 'HTML-Bericht (*.html)|*.html|JSON für späteren Vergleich (*.json)|*.json|CSV-Befunde (*.csv)|*.csv'
            $dlg.FileName = "SsyDiagnose_$($env:COMPUTERNAME)_$(Get-Date -Format yyyyMMdd_HHmm)"
            if ($dlg.ShowDialog() -eq 'OK') {
                $utf8 = New-Object Text.UTF8Encoding $true
                switch ($dlg.FilterIndex) {
                    2 { [IO.File]::WriteAllText($dlg.FileName, (ConvertTo-SsyJson $script:GuiResult), $utf8) }
                    3 { $script:GuiResult.Checks | Select-Object Status, Category, Check, Object, Result, Recommendation, Details | Export-Csv -Path $dlg.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8 }
                    default { [IO.File]::WriteAllText($dlg.FileName, (ConvertTo-SsyHtml $script:GuiResult), $utf8) }
                }
                $lblStatus.Text = "Gespeichert: $($dlg.FileName)"
            }
        })
    $btnCmp.Add_Click({
            if (-not $script:GuiResult) { return }
            $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Filter = 'JSON-Bericht (*.json)|*.json'
            if ($dlg.ShowDialog() -eq 'OK') {
                try {
                    $old = Get-Content $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $script:GuiResult.Comparison = Compare-SsyResult $old $script:GuiResult
                    $txtCmp.Text = ($script:GuiResult.Comparison -replace "`r?`n", "`r`n"); $tabs.SelectedTab = $tpC
                } catch { [void][System.Windows.Forms.MessageBox]::Show("Vergleich nicht möglich:`r`n$($_.Exception.Message)", 'Vergleich', 'OK', 'Warning') }
            }
        })
    $form.Add_FormClosing({ $timer.Stop(); if ($script:Job -and "$($script:Job.PS.InvocationStateInfo.State)" -eq 'Running') { try { $script:Job.PS.Stop() } catch {} } })

    if ($NoShow) { "Oberfläche aufgebaut: $($form.Controls.Count) Hauptbereiche, $($grid.Columns.Count) Spalten, $($tabs.TabPages.Count) Reiter, Filter und Detailbereich"; $form.Dispose(); return }
    if ($Result) {
        # Vorab geladenes Ergebnis (Demo): sofort anzeigen; »Diagnose starten« bleibt für echte Läufe verfügbar
        $form.Add_Shown({ $script:GuiResult = $Result; & $showResult; $lblStatus.Text = 'Demo-Modus: frei erfundene Beispieldaten.' })
    }
    if ($CaptureDir) {
        # Vorschaubilder ohne sichtbares Fenster rendern
        New-Item -ItemType Directory -Path $CaptureDir -Force | Out-Null
        $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point(-4000, -4000); $form.Size = New-Object System.Drawing.Size(1400, 960); $form.ShowInTaskbar = $false
        $form.Show(); [System.Windows.Forms.Application]::DoEvents()
        $snap = { param($name) [System.Windows.Forms.Application]::DoEvents(); foreach ($tb in @($txtInv, $txtMeas, $txtCmp, $txtLog, $txtSummary)) { $tb.SelectionStart = 0; $tb.SelectionLength = 0 }; $btnRun.Focus() | Out-Null
            Start-Sleep -Milliseconds 300; [System.Windows.Forms.Application]::DoEvents()
            $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height); $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmp.Save((Join-Path $CaptureDir $name), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); "Bild: $name" }
        $idx = 0; for ($k = 0; $k -lt $grid.Rows.Count; $k++) { if ("$($grid.Rows[$k].Cells[2].Value)" -eq 'Pfadtrennung Spiegel-Sessions') { $idx = $k } }
        if ($grid.Rows.Count) { $grid.ClearSelection(); $grid.Rows[$idx].Selected = $true; $grid.FirstDisplayedScrollingRowIndex = 0; & $showDetail }
        & $snap '01-uebersicht-befunde.png'
        $cmbCat.SelectedIndex = [math]::Max(0, $cmbCat.Items.IndexOf('Host-Pfade')); $cmbSt.SelectedIndex = 0
        if ($grid.Rows.Count -gt 1) { $grid.ClearSelection(); $grid.Rows[1].Selected = $true; & $showDetail }
        & $snap '02-filter-host-pfade.png'
        $cmbCat.SelectedIndex = 0; $cmbSt.SelectedIndex = 1
        $tabs.SelectedTab = $tpI; & $snap '03-bestand.png'
        $tabs.SelectedTab = $tpM; & $snap '04-messwerte.png'
        $form.Close(); $form.Dispose(); return
    }
    [void]$form.ShowDialog(); $form.Dispose()
}

# ============================================================================
#  Start
# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($BuildFormOnly) { Show-SsyGui -NoShow; return }

if ($Demo -or $CaptureDir) {
    # Demo-Modus: braucht weder SANsymphony noch Administratorrechte
    . ([scriptblock]::Create($CoreScript))
    $demoResult = New-SsyDemoResult -ToolVersion $ToolVersion
    $utf8 = New-Object Text.UTF8Encoding $true
    if ($ReportPath) { [IO.File]::WriteAllText($ReportPath, (ConvertTo-SsyHtml $demoResult), $utf8); "Demo-Bericht gespeichert: $ReportPath" }
    if ($JsonPath) { [IO.File]::WriteAllText($JsonPath, (ConvertTo-SsyJson $demoResult), $utf8); "Demo-JSON gespeichert: $JsonPath" }
    if ($NoGui) { $demoResult.Assessment.Summary; return }
    Show-SsyGui -Result $demoResult -CaptureDir $CaptureDir; return
}

if ($NoGui) {
    . ([scriptblock]::Create($CoreScript))
    $old = $null; if ($CompareWith) { $old = Get-Content $CompareWith -Raw -Encoding UTF8 | ConvertFrom-Json }
    $r = Invoke-SsyDiagnosis -Seconds $Seconds -SkipPerformance:$SkipPerformance -DeepAnalysis:$DeepAnalysis -ToolVersion $ToolVersion -Compare $old
    ''; $r.Assessment.Summary; ''
    ($r.Assessment.Categories | Format-Table Category, Worst, Critical, Warnings, Infos, Ok -AutoSize | Out-String).TrimEnd(); ''
    $r.Checks | Where-Object Rank -gt 0 | Select-Object Status, Category, Check, Object, Result | Format-Table -AutoSize -Wrap | Out-String -Width 250
    if ($r.Comparison) { $r.Comparison }
    $utf8 = New-Object Text.UTF8Encoding $true
    if ($ReportPath) { [IO.File]::WriteAllText($ReportPath, (ConvertTo-SsyHtml $r), $utf8); "Bericht gespeichert: $ReportPath" }
    if ($JsonPath) { [IO.File]::WriteAllText($JsonPath, (ConvertTo-SsyJson $r), $utf8); "JSON gespeichert: $JsonPath" }
    return
}

if (-not $isAdmin) {
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"") }
    catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show("Das Tool benötigt Administratorrechte.`r`n$($_.Exception.Message)", 'SANsymphony Diagnose', 'OK', 'Warning') }
    return
}
try { Show-SsyGui }
catch { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show("Unerwarteter Fehler:`r`n$($_.Exception.Message)", 'SANsymphony Diagnose', 'OK', 'Error') }
