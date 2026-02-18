#!/bin/bash
# Test: OpenAI Kursziel-Abruf wie in der App
# Zeigt, ob das Problem bei der App (Sandbox) oder der API liegt.
# API-Key: OPENAI_API_KEY setzen oder openai_key.local anlegen (siehe .gitignore)

# API-Key: aus Umgebungsvariable oder aus openai_key.local (nicht in Git!)
if [[ -n "$OPENAI_API_KEY" ]]; then
    API_KEY="$OPENAI_API_KEY"
elif [[ -f "$(dirname "$0")/openai_key.local" ]]; then
    API_KEY=$(cat "$(dirname "$0")/openai_key.local" | tr -d '\n\r ')
else
    API_KEY=""
fi
BEZEICHNUNG="Siemens Healthineers"
ISIN="DE0006231005"

# Ergebnis-Datei im gleichen Ordner wie dieses Skript (absoluter Pfad)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_FILE="$SCRIPT_DIR/openai_kursziel_result.json"

echo "━━━ OpenAI Kursziel-Test ━━━"
echo "Bezeichnung: $BEZEICHNUNG"
echo "ISIN: $ISIN"
echo ""

if [[ -z "$API_KEY" ]]; then
    echo "❌ API-Key fehlt. Optionen:"
    echo "   A) Umgebungsvariable: export OPENAI_API_KEY=sk-proj-..."
    echo "   B) Datei openai_key.local im gleichen Ordner (nur den Key, eine Zeile)"
    echo "   Datei: $(cd "$(dirname "$0")" && pwd)/test_openai_kursziel.sh"
    echo "   Die Ergebnis-Datei wird danach hier erstellt:"
    echo "   $SCRIPT_DIR/openai_kursziel_result.json"
    exit 1
fi

echo "📤 Sende Request an api.openai.com..."
curl -s -X POST "https://api.openai.com/v1/responses" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"gpt-4o\",\"tools\":[{\"type\":\"web_search\"}],\"tool_choice\":{\"type\":\"web_search\"},\"temperature\":0,\"input\":[{\"role\":\"system\",\"content\":\"Gib GENAU eine Zahl mit Dezimalpunkt zurück oder -1.\"},{\"role\":\"user\",\"content\":\"Aktienkursziel für $BEZEICHNUNG (ISIN $ISIN). Nur Zahl in EUR.\"}]}" \
  > "$RESULT_FILE"

if [[ ! -f "$RESULT_FILE" ]] || [[ ! -s "$RESULT_FILE" ]]; then
    echo "❌ Keine Antwort erhalten (Netzwerkfehler?)"
    exit 1
fi

echo "📥 Antwort gespeichert in:"
echo "   $RESULT_FILE"
echo ""
echo "   (Datei im Finder öffnen: open \"$(dirname "$RESULT_FILE")\")"
echo ""

# Kursziel aus JSON extrahieren (output[].content[].text wo type=output_text)
KURSZIEL=$(python3 << PYEOF
import json, sys
try:
    with open("$RESULT_FILE") as f:
        d = json.load(f)
    for item in d.get("output", []):
        for c in item.get("content", []):
            if c.get("type") == "output_text":
                print(c.get("text", "").strip())
                sys.exit(0)
    print("-1")
except Exception as e:
    print(f"Parse-Fehler: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

if [[ -n "$KURSZIEL" ]] && [[ "$KURSZIEL" != "-1" ]]; then
    echo "✅ Kursziel: $KURSZIEL EUR"
    echo ""
    echo "→ Wenn dieser Test funktioniert, die App aber nicht:"
    echo "  Problem liegt bei der App (Sandbox/Netzwerk-Berechtigung)."
    echo "  Prüfe: Aktien.entitlements mit com.apple.security.network.client"
else
    echo "❌ Kein Kursziel extrahiert. Rohantwort:"
    head -c 500 "$RESULT_FILE"
    echo ""
fi
