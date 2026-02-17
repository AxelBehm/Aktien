#!/usr/bin/env python3
"""Test-Skript für den Kursziel-Extraktor"""

import sys
import os

# Füge aktuelles Verzeichnis zum Python-Pfad hinzu
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from kursziel_extractor import get_kursziele_table
    print("✅ Modul importiert")
    
    # Teste mit Rheinmetall URL
    test_url = "https://www.finanzen.net/kursziele/703000"
    print(f"\n🔍 Teste URL: {test_url}")
    
    result = get_kursziele_table(test_url)
    
    if result is not None and not result.empty:
        print(f"\n✅ Erfolg! {len(result)} Zeilen extrahiert")
        print("\n📊 Erste Zeilen:")
        print(result.head())
        print("\n📋 Spalten:")
        print(list(result.columns))
        
        # Prüfe ob Kursziel-Spalte vorhanden
        kursziel_cols = [col for col in result.columns if 'kursziel' in col.lower()]
        if kursziel_cols:
            print(f"\n✅ Kursziel-Spalte gefunden: {kursziel_cols}")
            print(f"\n📈 Kursziel-Werte:")
            for col in kursziel_cols:
                print(f"  {col}: {result[col].dropna().tolist()}")
        else:
            print("\n⚠️ Keine Kursziel-Spalte gefunden")
    else:
        print("\n❌ Keine Daten extrahiert")
        sys.exit(1)
        
except ImportError as e:
    print(f"❌ Import-Fehler: {e}")
    print("\nBitte installieren Sie die Abhängigkeiten:")
    print("pip3 install pandas openpyxl requests beautifulsoup4 lxml html5lib")
    sys.exit(1)
except Exception as e:
    print(f"❌ Fehler: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
