#!/usr/bin/env python3
"""
Kursziel-Extraktor: Liest URLs aus Excel und extrahiert Kursziele von Webseiten
Entspricht dem Power Query M-Code
"""

import pandas as pd
import requests
from bs4 import BeautifulSoup
import re
from typing import Optional, List, Dict
import time

def get_kursziele_table(page_url: str) -> Optional[pd.DataFrame]:
    """
    Lädt eine Webseite und extrahiert die Kursziel-Tabelle.
    
    Args:
        page_url: URL der Kursziel-Seite
        
    Returns:
        DataFrame mit der Kursziel-Tabelle oder None
    """
    try:
        headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }
        
        response = requests.get(page_url, headers=headers, timeout=10)
        response.raise_for_status()
        
        soup = BeautifulSoup(response.content, 'html.parser')
        
        # Finde alle Tabellen
        tables = soup.find_all('table')
        
        if not tables:
            print(f"  ⚠️  Keine Tabellen gefunden auf {page_url}")
            return None
        
        # Suche nach Tabelle mit "Kursziel" in Spaltenüberschriften
        for table in tables:
            # Versuche Header zu finden
            headers_row = table.find('thead')
            if headers_row:
                headers_text = [th.get_text(strip=True).lower() for th in headers_row.find_all(['th', 'td'])]
            else:
                # Erste Zeile als Header verwenden
                first_row = table.find('tr')
                if first_row:
                    headers_text = [td.get_text(strip=True).lower() for td in first_row.find_all(['th', 'td'])]
                else:
                    continue
            
            # Prüfe ob "kursziel" in einem Header vorkommt
            if any('kursziel' in h for h in headers_text):
                # Extrahiere Tabelle als DataFrame
                df = pd.read_html(str(table), flavor='bs4')[0]
                
                # Bereinige Spaltennamen
                df.columns = [col.strip() for col in df.columns]
                
                # Finde Kursziel-Spalte
                kursziel_col = None
                for col in df.columns:
                    if 'kursziel' in col.lower():
                        kursziel_col = col
                        break
                
                if kursziel_col:
                    # Konvertiere Kursziel zu Zahl
                    def parse_kursziel(value):
                        if pd.isna(value):
                            return None
                        # Zu String konvertieren
                        txt = str(value)
                        # Währung/Leerzeichen entfernen
                        stripped = txt.replace('€', '').replace('EUR', '').replace('USD', '').replace(' ', '')
                        # Tausenderpunkte entfernen, Dezimalkomma -> Punkt
                        norm = stripped.replace('.', '').replace(',', '.')
                        try:
                            return float(norm)
                        except (ValueError, TypeError):
                            return None
                    
                    df[kursziel_col] = df[kursziel_col].apply(parse_kursziel)
                    print(f"  ✅ Kursziel-Tabelle gefunden: {len(df)} Zeilen, Spalte '{kursziel_col}'")
                    return df
        
        # Falls keine passende Tabelle gefunden, nimm die erste
        if tables:
            try:
                df = pd.read_html(str(tables[0]), flavor='bs4')[0]
                df.columns = [col.strip() for col in df.columns]
                print(f"  ⚠️  Erste Tabelle verwendet (keine Kursziel-Spalte gefunden): {len(df)} Zeilen")
                return df
            except Exception as e:
                print(f"  ❌ Fehler beim Parsen der Tabelle: {e}")
        
        return None
        
    except requests.RequestException as e:
        print(f"  ❌ HTTP-Fehler: {e}")
        return None
    except Exception as e:
        print(f"  ❌ Fehler: {e}")
        return None


def process_kursziele_from_excel(excel_path: str, sheet_name: str = "Kursziele_Input", url_column: str = "Url") -> pd.DataFrame:
    """
    Liest URLs aus Excel und extrahiert Kursziele von den Webseiten.
    
    Args:
        excel_path: Pfad zur Excel-Datei
        sheet_name: Name des Arbeitsblatts (Standard: "Kursziele_Input")
        url_column: Name der Spalte mit URLs (Standard: "Url")
        
    Returns:
        DataFrame mit allen extrahierten Daten
    """
    print(f"📖 Lese Excel-Datei: {excel_path}")
    
    try:
        # Lese Excel
        df = pd.read_excel(excel_path, sheet_name=sheet_name)
        print(f"✅ {len(df)} Zeilen gelesen")
        
        # Bereinige URLs (entferne leere/null Werte)
        df = df[df[url_column].notna()]
        df[url_column] = df[url_column].astype(str).str.strip()
        df = df[df[url_column] != '']
        
        print(f"✅ {len(df)} URLs nach Bereinigung")
        
        # Extrahiere Kursziele für jede URL
        results = []
        for idx, row in df.iterrows():
            url = row[url_column]
            print(f"\n🔍 Verarbeite URL {idx+1}/{len(df)}: {url}")
            
            kursziel_table = get_kursziele_table(url)
            
            if kursziel_table is not None and len(kursziel_table) > 0:
                # Füge URL als Spalte hinzu
                kursziel_table['Source_URL'] = url
                # Füge alle ursprünglichen Spalten hinzu
                for col in df.columns:
                    if col != url_column:
                        kursziel_table[col] = row[col]
                
                results.append(kursziel_table)
                time.sleep(1)  # Pause zwischen Requests
            else:
                print(f"  ⚠️  Keine Daten extrahiert")
        
        # Zusammenführen aller Ergebnisse
        if results:
            final_df = pd.concat(results, ignore_index=True)
            print(f"\n✅ Insgesamt {len(final_df)} Zeilen extrahiert")
            return final_df
        else:
            print("\n⚠️  Keine Daten extrahiert")
            return pd.DataFrame()
            
    except FileNotFoundError:
        print(f"❌ Datei nicht gefunden: {excel_path}")
        return pd.DataFrame()
    except Exception as e:
        print(f"❌ Fehler: {e}")
        return pd.DataFrame()


def main():
    """Hauptfunktion - Beispiel-Nutzung"""
    import sys
    
    if len(sys.argv) > 1:
        excel_path = sys.argv[1]
    else:
        excel_path = input("Pfad zur Excel-Datei: ").strip()
    
    if not excel_path:
        print("❌ Kein Pfad angegeben")
        return
    
    result = process_kursziele_from_excel(excel_path)
    
    if not result.empty:
        # Speichere Ergebnis
        output_path = excel_path.replace('.xlsx', '_kursziele.xlsx').replace('.xls', '_kursziele.xlsx')
        result.to_excel(output_path, index=False)
        print(f"\n💾 Ergebnis gespeichert: {output_path}")
        print(f"\n📊 Übersicht:")
        print(result.head(10))
    else:
        print("\n❌ Keine Daten zum Speichern")


if __name__ == "__main__":
    main()
