# Changelog

Alle nennenswerten Änderungen an diesem Projekt. Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach [SemVer](https://semver.org/lang/de/).

## [1.0.0] – 2026-11-27

Erste öffentliche Version.

### Neu
- Grafische Oberfläche (WinForms) mit Ampel, Punktzahl, Gesamteinschätzung und Kacheln je Bereich
- Rund 100 Prüfungen in 13 Bereichen: Verfügbarkeit, Lizenz & Software, Server & Cache, Pools & Disks, vDisks & Spiegel, Host-Pfade, Replikation & Schutz, Monitore & Alarme, Betrieb, Windows, Netzwerk, Spiegelstrecke, Leistung
- Leistungsmessung über alle Ebenen (Host, Spiegel, Cache, Pool, Disk, Port, Replikation) mit Ursachenkette
- Host-Pfad-Analyse je vDisk inkl. Erkennung von Hosts mit nur einer Initiator-IP
- Spiegelstrecke: Subnetz-Prüfung ein- und ausgehender Sessions, Pfadtrennung, Ping-, Paketverlust- und MTU-Tests
- Optionale Tiefenanalyse per `pktmon`: erkennt Initiatoren, die sich mit falscher Quell-IP anmelden
- Reiter Befunde (Filter, Suche, Details), Bestand, Messwerte, Vergleich, Protokoll
- Export als HTML, JSON und CSV; Vergleich mit früheren JSON-Berichten
- Konsolenmodus (`-NoGui`) für geplante Aufgaben
- Demo-Modus (`-Demo`) mit erfundenen Daten für Schulungen und Vorführungen

[1.0.0]: ../../releases/tag/v1.0.0
