#!/usr/bin/env python3
"""Erstellt eine Beispiel-Excel-Datei für den Kursziel-Extraktor"""

import pandas as pd

# Beispiel-URLs (Rheinmetall und andere deutsche Aktien)
data = {
    'Url': [
        'https://www.finanzen.net/kursziele/703000',  # Rheinmetall
        'https://www.finanzen.net/kursziele/716460',  # SAP
        'https://www.finanzen.net/kursziele/514000',  # Deutsche Bank
    ],
    'WKN': ['703000', '716460', '514000'],
    'Bezeichnung': ['Rheinmetall AG', 'SAP SE', 'Deutsche Bank AG']
}

df = pd.DataFrame(data)

# Speichere als Excel
output_file = 'Kursziele_Input.xlsx'
df.to_excel(output_file, sheet_name='Kursziele_Input', index=False)
print(f"✅ Beispiel-Excel erstellt: {output_file}")
print(f"📊 {len(df)} URLs hinzugefügt")
print("\nInhalt:")
print(df)
