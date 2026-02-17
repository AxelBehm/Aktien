# Kursziel-Extraktor

Python-Skript zum Extrahieren von Kurszielen aus Webseiten (entspricht dem Power Query M-Code).

## Installation

```bash
pip3 install pandas openpyxl requests beautifulsoup4 lxml html5lib
```

Oder mit requirements.txt:
```bash
pip3 install -r requirements.txt
```

## Verwendung

### 1. Excel-Datei vorbereiten

Erstellen Sie eine Excel-Datei mit:
- **Arbeitsblatt-Name**: `Kursziele_Input`
- **Spalte**: `Url` (mit den URLs zu den Kursziel-Seiten)

Beispiel:
| Url | WKN | Bezeichnung |
|-----|-----|-------------|
| https://www.finanzen.net/kursziele/703000 | 703000 | Rheinmetall AG |
| https://www.finanzen.net/kursziele/716460 | 716460 | SAP SE |

### 2. Skript ausführen

```bash
python3 kursziel_extractor.py pfad/zur/Kursziele_Input.xlsx
```

### 3. Ergebnis

Das Skript erstellt eine neue Excel-Datei `Kursziele_Input_kursziele.xlsx` mit allen extrahierten Kursziel-Daten.

## Beispiel-Excel erstellen

Eine CSV-Vorlage finden Sie in `Kursziele_Input.csv`. Diese können Sie in Excel öffnen und als `.xlsx` speichern.

## Was das Skript macht

1. ✅ Liest URLs aus Excel
2. ✅ Ruft jede Webseite ab
3. ✅ Findet HTML-Tabellen mit "Kursziel" in den Spalten
4. ✅ Konvertiert Kursziel-Werte zu Zahlen
5. ✅ Fügt alle Daten zusammen
6. ✅ Speichert Ergebnis in neue Excel-Datei

## Debugging

Das Skript gibt detaillierte Informationen aus:
- ✅ Welche URLs verarbeitet werden
- ✅ Welche Tabellen gefunden wurden
- ✅ Fehlermeldungen bei Problemen
