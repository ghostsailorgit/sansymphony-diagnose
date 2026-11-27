# Mitmachen

Danke für jeden Beitrag – besonders für Erfahrungen aus echten Einsätzen, die sich als neue Prüfung abbilden lassen.

## Beiträge nur über Issues

Dieses Projekt nimmt **keine Pull Requests** an. Bitte alles als Issue einreichen:

- [**Fehlerbericht**](../../issues/new?template=bug_report.md) – etwas funktioniert nicht oder eine Prüfung liefert ein falsches Ergebnis
- [**Neue Prüfung vorschlagen**](../../issues/new?template=neue_pruefung.md) – ein Problem aus der Praxis, das das Tool künftig erkennen soll

Code-Vorschläge gern direkt im Issue als Codeblock (siehe Muster unten). Gute Vorschläge werden übernommen und im [Changelog](CHANGELOG.md) erwähnt.

**Bitte keine Kundendaten** (Namen, IP-Adressen, IQNs, Seriennummern) in Issues, Screenshots oder Logs. Werte anonymisieren oder den Demo-Modus (`-Demo`) verwenden.

## Grundregeln für Prüfungen

1. **Rein lesend.** Prüfungen dürfen nichts verändern: nur `Get-Dcs*`-Cmdlets und lesende Windows-Abfragen. Aktive Tests (Ping, `pktmon`) nur, wenn sie harmlos sind und hinterher aufräumen.
2. **Jeder Befund braucht eine Empfehlung**, die ein Techniker ohne Rückfrage umsetzen kann.
3. **Windows PowerShell 5.1** bleibt Zielplattform (keine `??`, `?:`, `&&`).

## Muster für eine neue Prüfung

Prüfungen liegen im Block `$CoreScript` in `src/SsyDiagnose.ps1`, gruppiert nach `#region`. Ergebnisse werden mit `Add-SsyCheck` gemeldet:

```powershell
Invoke-SsyStep 'Betrieb' 'Meine Prüfung' {
    $wert = ...   # lesend ermitteln
    if ($wert -gt 10) {
        Add-SsyCheck 'Betrieb' 'Meine Prüfung' $objekt 'Warnung' "Ergebnis: $wert" 'Was zu tun ist'
    } else {
        Add-SsyCheck 'Betrieb' 'Meine Prüfung' $objekt 'OK' "Ergebnis: $wert"
    }
}
```

- Status: `Kritisch`, `Warnung`, `Info` oder `OK`. Auch OK-Ergebnisse melden – Techniker sollen sehen, was geprüft wurde.
- Bereich: einer aus `$script:Categories`.
- `Invoke-SsyStep` fängt Fehler ab, damit eine fehlschlagende Prüfung nicht den ganzen Lauf beendet.
- Schwellwerte gehören in `$script:T`.

## Für Maintainer

```powershell
# Syntax prüfen
$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('src\SsyDiagnose.ps1', [ref]$null, [ref]$e); $e
# Oberfläche ohne SANsymphony
.\src\SsyDiagnose.ps1 -Demo
# Vorschaubilder neu erzeugen (unsichtbar gerendert, nur Demo-Daten)
.\src\SsyDiagnose.ps1 -CaptureDir docs\images -ReportPath docs\beispielbericht-demo.html
# Release-Paket bauen
.\build\New-ReleasePackage.ps1 -Version 1.0.0
```
