# Spezifikation: Fabric Capacity Cockpit v2

**Zielordner:** `FabricCockpit-GUI` (eigenes Repo; die VS-Code-Variante liegt getrennt in `FabricCockpit-VSCode`)
**Adressat:** Claude Code
**Stand:** 13.09.2026

---

## 0. Hinweis zur Arbeitsweise

Dieses Dokument beschreibt den **Soll-Zustand**. Es wurde ohne Einsicht in den
vorhandenen Code geschrieben. Bitte zuerst den Bestand lesen (PowerShell-Skripte,
`tasks.json`, WinForms-Skript) und die hier beschriebenen Anforderungen in die
vorhandene Struktur einpassen, statt neu zu bauen.

An mehreren Stellen stehen Punkte unter **„Zu verifizieren"**. Dort bin ich mir
über das aktuelle Verhalten von Azure CLI bzw. der Fabric-API nicht sicher. Bitte
gegen die aktuelle Microsoft-Doku bzw. die tatsächliche Rückgabe der Kommandos
prüfen und nicht auf Annahmen aufbauen.

---

## 1. Ausgangslage

Bestehend sind zwei Varianten desselben Funktionsumfangs:

1. **VS-Code-Variante:** PowerShell-Skripte + `tasks.json`, als Statusleisten-Buttons
   über die Erweiterung „Tasks" (actboy168).
2. **WinForms-Cockpit:** ein einzelnes PowerShell-Skript mit GUI.

Beide arbeiten bisher gegen **eine fest konfigurierte Kapazität**. Beide setzen
Azure CLI und PowerShell voraus sowie ein einmaliges `az login`.

**Primäres Ziel dieser Ausbaustufe ist das WinForms-Cockpit.** Die
PowerShell-Skripte der VS-Code-Variante sollen dabei so parametrisiert werden
(`-SubscriptionId`, `-ResourceGroup`, `-CapacityName`), dass sie weiterhin
funktionieren und von beiden Varianten genutzt werden können. Keine Duplizierung
der Azure-Logik zwischen GUI und Skripten.

---

## 2. Geltungsbereich

### In dieser Ausbaustufe enthalten

- F1 — Auswahl der Kapazität aus einer Liste über alle Subscriptions
- F2 — Klarstellung: Pay-as-you-go
- F3 — Anmeldestatus sichtbar machen und Anmeldung aus der App heraus anstoßen
- F4 — Fortschrittsanzeige bei Pause/Resume mit Polling bis zum Zielstatus
- F5 — Auto-Pause nach X Minuten Inaktivität

### Ausdrücklich **nicht** enthalten

- Kostensumme über mehrere Kapazitäten hinweg (bewusst zurückgestellt)
- Anzeige der einer Kapazität zugewiesenen Workspaces
- Skalierung der SKU
- Service-Principal-Betrieb, unbeaufsichtigter Betrieb

---

## 3. Voraussetzungen

- Windows, Windows PowerShell 5.1 oder PowerShell 7 (bitte im Code angeben,
  wogegen getestet wurde; WinForms verhält sich in beiden nicht identisch)
- Azure CLI installiert und im PATH
- Berechtigung auf der Kapazität: mindestens Contributor für Pause/Resume,
  Reader für die reine Anzeige
- Keine Speicherung von Zugangsdaten im Code oder in Konfigurationsdateien

---

## 4. Feature F1 — Mehrere Kapazitäten

### 4.1 Verhalten

Beim Start lädt das Cockpit die Liste aller erreichbaren Fabric-Kapazitäten und
bietet sie in einem Dropdown an. Nach Auswahl einer Kapazität zeigt das Cockpit
exakt die bisherigen Informationen für **diese** Kapazität an, und Pause/Resume
sowie alle Links beziehen sich auf sie.

### 4.2 Ermittlung der Liste

Wichtig: `az resource list` arbeitet **nur gegen die aktuell aktive Subscription**.
Für „über alle Subscriptions" ist eine Iteration nötig.

**Standardweg (keine zusätzliche Erweiterung nötig):**

```powershell
# 1. Aktivierte Subscriptions ermitteln
az account list --all --query "[?state=='Enabled'].{id:id, name:name}" -o json

# 2. Je Subscription die Kapazitäten holen
az resource list --subscription <SUBSCRIPTION_ID> `
                 --resource-type Microsoft.Fabric/capacities -o json
```

**Schnellere Alternative (optional, wenn die Erweiterung vorhanden ist):**

```powershell
az graph query -q "Resources | where type =~ 'microsoft.fabric/capacities'" -o json
```

Azure Resource Graph fragt alle Subscriptions in einem Aufruf ab, erfordert aber
die Erweiterung `resource-graph`. Implementierung: Resource Graph versuchen, bei
Fehlen der Erweiterung transparent auf die Schleife zurückfallen. Der gewählte
Weg wird im Log vermerkt.

### 4.3 Anforderungen an das Laden

- Das Laden darf die GUI **nicht blockieren**. Bei vielen Subscriptions dauert die
  Schleife spürbar. Während des Ladens: Statuszeile „Lade Kapazitäten …",
  Dropdown deaktiviert.
- Die Liste wird in der Konfiguration zwischengespeichert (Name, SubscriptionId,
  Subscription-Name, ResourceGroup, Region, SKU). Beim Start wird zunächst der
  Cache angezeigt, damit das Fenster sofort bedienbar ist; die Aktualisierung
  läuft im Hintergrund.
- Ein Button **„Kapazitäten neu laden"** erzwingt die Neuermittlung.
- Sortierung: alphabetisch nach Name. Anzeigeformat im Dropdown:
  `<Name> — <Subscription-Name> / <ResourceGroup>` (Namen sind nur innerhalb einer
  Subscription eindeutig).
- Leere Liste ist ein regulärer Zustand, kein Fehler: Hinweistext
  „Keine Fabric-Kapazitäten gefunden. Angemeldetes Konto / Tenant prüfen."
- Die zuletzt gewählte Kapazität wird gespeichert und beim nächsten Start
  vorausgewählt, sofern sie noch existiert.

### 4.4 Anzeige je Kapazität

Wie bisher: Name, Subscription, Ressourcengruppe, Region, SKU, Status, Kosten (MTD).

**Zu beachten bei den Kosten:** Die bisherige Kostenermittlung läuft
(nach meinem Verständnis des bestehenden Posts) über die Kostenanalyse der
**Ressourcengruppe**. Mit mehreren Kapazitäten ist diese Zahl mehrdeutig: Liegen
zwei Kapazitäten in derselben Ressourcengruppe, zeigt sie die Summe beider, plus
alles andere in der Gruppe.

Anforderung für diese Ausbaustufe: **korrekt beschriften statt umbauen.** Das Feld
heißt nicht mehr „Kosten (MTD)", sondern
`Kosten (MTD, Ressourcengruppe <RG>)` mit einem Tooltip, der erklärt, dass es sich
um die gesamte Ressourcengruppe handelt. Die Umstellung auf eine Filterung nach
konkreter ResourceId ist eine Folgeaufgabe und ausdrücklich nicht Teil dieser
Ausbaustufe.

### 4.5 Zu verifizieren

- Ob die spezialisierte Erweiterung `az fabric` inzwischen ein Listen-Kommando für
  Kapazitäten bietet und welchen Preview-Stand sie hat. Falls ja, kann es den
  generischen Weg ersetzen. Bitte gegen die aktuelle Doku prüfen.
- Ob `az resource list` bereits alle benötigten Felder liefert oder ob pro
  Kapazität zusätzlich `az resource show` nötig ist (insbesondere für
  `properties.state` und `sku`).

---

## 5. Feature F2 — Pay-as-you-go deutlich machen

### 5.1 Hintergrund (bitte nicht ungeprüft in die UI übernehmen)

- **Trial-Kapazitäten** sind keine Azure-Ressourcen und tauchen in
  `az resource list` nicht auf. Die Liste enthält also von sich aus keine Trials.
- **P-SKUs** (Power BI Premium) liegen unter einem anderen Ressourcentyp und
  erscheinen hier ebenfalls nicht. Die Liste besteht aus F-SKUs.
- **Pay-as-you-go gegenüber Reservierung** ist eine Frage der Abrechnung, nicht
  eine Eigenschaft der Kapazitätsressource. Das Tool kann **nicht zuverlässig
  erkennen**, ob für eine Kapazität eine Reservierung besteht. Es darf das also
  auch nicht behaupten.

### 5.2 Umsetzung

Es geht um eine ehrliche Einordnung in der Oberfläche, nicht um Logik:

- Fenstertitel: `Fabric Capacity Cockpit — Pay-as-you-go (F-SKU)`
- Ein kurzer, dauerhaft sichtbarer Hinweis im Fußbereich:
  „Ausgelegt auf F-SKUs mit nutzungsbasierter Abrechnung. Pausieren spart die
  Compute-Kosten; OneLake-Speicher wird weiterhin berechnet. Bei bestehender
  Reservierung bringt Pausieren keine Ersparnis — das Tool kann Reservierungen
  nicht erkennen."
- Derselbe Absatz in der README.
- Vor dem Pausieren erscheint ohnehin eine Bestätigung (siehe F4). Dort denselben
  Speicher-Hinweis kurz wiederholen.

Keine Filterung und keine Ausgrauen von Kapazitäten aufgrund vermuteter
Abrechnungsart.

---

## 6. Feature F3 — Anmeldestatus

Ziel ist **nicht**, ein eigenes Login zu implementieren. Kein MSAL, kein
`Connect-AzAccount`, keine gespeicherten Secrets. Ziel ist, dass ein fehlender
oder abgelaufener Anmeldezustand sofort sichtbar und mit einem Klick behebbar ist.

### 6.1 Prüfung beim Start

```powershell
az account show -o json
```

- Exitcode 0 und auswertbares JSON → angemeldet.
- Alles andere → nicht angemeldet.

### 6.2 Anzeige

Eine Kopfzeile im Fenster, dauerhaft sichtbar:

- Angemeldet: `✔ <user.name> · Tenant <tenantId oder Anzeigename> · Subscription <name>`
- Nicht angemeldet: `✖ Nicht angemeldet` in Warnfarbe

Bei „nicht angemeldet" werden Kapazitätsauswahl, Pause, Resume und Refresh
deaktiviert. Nur der Button **„Anmelden"** ist aktiv.

### 6.3 Anmelde-Button

- Startet `az login`. Es öffnet sich ein Browserfenster, das ist erwartetes
  Verhalten und wird in der Statuszeile angekündigt.
- Während `az login` läuft: GUI nicht blockieren, Statuszeile „Anmeldung läuft,
  bitte im Browser abschließen …", Button deaktiviert.
- Nach Rückkehr: Anmeldestatus erneut prüfen, bei Erfolg automatisch die
  Kapazitätsliste laden.
- Der Button bleibt auch im angemeldeten Zustand sichtbar (dann beschriftet als
  **„Konto wechseln"**), damit ein Tenant-Wechsel möglich ist.

### 6.4 Ablauf während der Laufzeit

Jeder Azure-Aufruf muss Authentifizierungsfehler als solche erkennen und in den
Zustand „nicht angemeldet" zurückfallen, statt leere Felder oder eine rohe
Fehlermeldung zu zeigen.

Praktische Umsetzung: bei Exitcode ≠ 0 den stderr-Text auf Muster wie `az login`,
`AADSTS`, `ExpiredToken`, `re-authenticate`, `InvalidAuthenticationToken` prüfen
(Groß-/Kleinschreibung ignorieren). Bei Treffer:

- Kopfzeile auf `✖ Anmeldung abgelaufen` setzen
- Aktionsbuttons deaktivieren, „Anmelden" aktivieren
- Auto-Refresh und Auto-Pause-Timer anhalten
- Meldung in der Statuszeile

**Zu verifizieren:** Die genauen Fehlertexte hängen von der CLI-Version ab. Bitte
die tatsächlichen Ausgaben prüfen und die Mustererkennung großzügig auslegen: Im
Zweifel ist es besser, einen sonstigen Fehler als Anmeldeproblem zu behandeln, als
den Nutzer mit leeren Feldern stehen zu lassen. Jeder unerkannte Fehler wird
vollständig ins Log geschrieben.

---

## 7. Feature F4 — Fortschrittsanzeige für Pause und Resume

### 7.1 Problem

Resume und Pause kehren zurück, bevor die Kapazität den Zielzustand erreicht hat.
Der Nutzer weiß nicht, ob es läuft.

### 7.2 Verhalten

Symmetrisch für beide Richtungen:

1. **Bestätigungsdialog** mit Kapazitätsname und Zielzustand. Beim Pausieren
   zusätzlich der Hinweis, dass zugewiesene Workspaces bis zum Fortsetzen nicht
   verfügbar sind und OneLake-Speicher weiter berechnet wird.
2. Kommando absetzen (bestehender Mechanismus, siehe 7.4).
3. **Polling** auf den Status, Intervall 5 Sekunden.
4. Während des Pollings:
   - Fortschrittsanzeige im Marquee-Modus oder animierter Punktindikator
   - Statustext `Fortsetzen … (00:42)` mit laufender Sekundenanzeige
   - Pause-, Resume- und Kapazitätsauswahl deaktiviert
   - Ein Button **„Warten abbrechen"**
5. **Zielzustand erreicht:** Anzeige aktualisieren, Erfolgsmeldung mit
   Gesamtdauer ins Log, Buttons wieder aktivieren.
6. **Timeout nach 10 Minuten:** Polling beenden, Hinweis „Zielzustand nach 10
   Minuten nicht erreicht. Status im Azure-Portal prüfen." plus Portal-Link.
   Der Status wird danach weiter über den normalen Refresh aktualisiert.

### 7.3 Wichtig zur Abbruch-Schaltfläche

„Warten abbrechen" beendet **nur das Polling in der Anwendung**. Der Vorgang in
Azure läuft weiter. Das muss im Buttontext oder Tooltip unmissverständlich stehen,
sonst entsteht der Eindruck, man könne damit ein Resume zurücknehmen.

### 7.4 Statuswerte

Das Polling fragt denselben Statusweg ab wie die bestehende Statusanzeige. Es gibt
neben `Active` und `Paused` Übergangszustände.

**Zu verifizieren:** Die exakten Zeichenketten der Übergangszustände (vermutlich in
Richtung `Pausing` / `Resuming`, das ist aber nicht bestätigt). Bitte die real
beobachteten Werte während eines echten Pause- und Resume-Vorgangs ins Log
schreiben und die Behandlung daran ausrichten. Unbekannte Statuswerte führen nicht
zum Abbruch, sondern werden angezeigt und weitergepollt.

Ebenfalls zu verifizieren: ob der bestehende Pause/Resume-Aufruf über die
Erweiterung `az fabric` oder über `az rest` gegen die ARM-API läuft, und welche
`api-version` dort verwendet wird. Der bestehende, funktionierende Mechanismus
wird beibehalten und nicht ohne Not ausgetauscht.

---

## 8. Feature F5 — Auto-Pause nach Inaktivität

### 8.1 Begriffsklärung, bitte sorgfältig lesen

„Inaktivität" bedeutet in dieser Ausbaustufe ausschließlich:
**keine Bedienung des Cockpits durch den Nutzer.**

Es bedeutet **nicht**, dass auf der Kapazität keine Last liegt. Das Tool weiß
nichts über laufende Aktualisierungen, Pipelines, Notebooks oder Nutzerzugriffe
auf Berichte. Eine echte Lasterkennung erfordert Verbrauchsdaten (Capacity Metrics
bzw. entsprechende API) und ist ausdrücklich nicht Teil dieser Ausbaustufe.

Konsequenz für die Umsetzung: Die Funktion ist **standardmäßig ausgeschaltet**,
muss bewusst aktiviert werden, und die Oberfläche muss diese Einschränkung
benennen. Ein automatisches Pausieren, das eine laufende Aktualisierung abwürgt,
wäre schlimmer als vergessene Laufzeit.

### 8.2 Bedienung

In der Oberfläche eine Auswahl:

`Auto-Pause bei Inaktivität: [ Aus | 15 | 30 | 60 | 120 ] Minuten`

Voreinstellung `Aus`. Die Einstellung wird gespeichert und beim nächsten Start
wiederhergestellt. Daneben ein Info-Symbol mit dem Tooltip:

„Zählt die Zeit ohne Bedienung dieses Fensters. Last auf der Kapazität, etwa
laufende Aktualisierungen, wird dabei nicht erkannt."

### 8.3 Logik

- Der Timer läuft **nur**, wenn: Auto-Pause aktiv ist, Status `Active` ist, eine
  Kapazität gewählt ist und der Anmeldestatus gültig ist.
- **Zurückgesetzt** wird der Timer durch: Klick auf einen beliebigen Button,
  Wechsel der Kapazität, manuelles Refresh, Änderung einer Einstellung.
- **Nicht zurückgesetzt** wird er durch den automatischen Refresh alle 30 Sekunden.
  Sonst läuft er nie ab.
- Beim Wechsel der Kapazität startet der Timer neu.
- Während eines laufenden Pause- oder Resume-Pollings ist der Timer angehalten.
- Wechselt der Status auf `Paused`, wird der Timer gestoppt.

### 8.4 Ablauf beim Auslösen

Zwei Minuten vor Ablauf erscheint eine deutlich sichtbare Warnung im Fenster
(kein modaler Dialog, der könnte unbemerkt hinter anderen Fenstern liegen):

`Auto-Pause in 01:58  [ Jetzt pausieren ]  [ Verlängern ]  [ Für heute deaktivieren ]`

- **Verlängern** setzt den Timer auf den vollen Wert zurück.
- **Für heute deaktivieren** schaltet Auto-Pause bis zum Neustart der Anwendung ab.
- Ohne Reaktion wird nach Ablauf pausiert, **ohne** weiteren Bestätigungsdialog.
  Der Vorgang durchläuft dieselbe Fortschrittsanzeige wie F4 und wird mit
  Zeitstempel und Auslöser („Auto-Pause nach 60 Min. Inaktivität") ins Log
  geschrieben.

### 8.5 Bewusst nicht enthalten

- Pausieren beim Schließen des Fensters. Sinnvoll, aber ein eigener Fall mit
  eigenen Fallstricken (Abmelden, Neustart, abgebrochene Vorgänge). Getrennt
  betrachten.
- Zeitplanbasiertes Pausieren über die Aufgabenplanung. Gehört nicht in die GUI.
- Lasterkennung über Verbrauchsdaten. Siehe 8.1.

---

## 9. Querschnittsanforderungen

### 9.1 Konfiguration

Eine JSON-Datei unter `%APPDATA%\FabricCockpit\settings.json`:

```json
{
  "lastCapacity": { "subscriptionId": "", "resourceGroup": "", "name": "" },
  "autoRefreshSeconds": 30,
  "autoPauseMinutes": 0,
  "capacityCache": [],
  "capacityCacheUpdated": "2026-09-13T14:03:00Z"
}
```

Keine Secrets, keine Tokens. Fehlt die Datei oder ist sie unlesbar, wird mit
Standardwerten gestartet und eine neue geschrieben.

### 9.2 Logbereich

Die bestehende Statuszeile bleibt. Zusätzlich ein aufklappbarer Logbereich mit den
letzten Meldungen inklusive Zeitstempel und einem Button „Log kopieren". Jede
Aktion, jeder Fehler und jeder Statuswechsel wird dort protokolliert.

### 9.3 Fehlerbehandlung, allgemein

- Kein Azure-Aufruf darf die GUI einfrieren.
- Jeder fehlgeschlagene Aufruf schreibt Kommando (ohne Tokens), Exitcode und
  stderr ins Log.
- Der Nutzer bekommt eine verständliche Meldung, nicht den rohen Fehlertext.
- Zeitweise Fehler beim automatischen Refresh führen nicht zu Dialogfenstern,
  sondern nur zu einem Eintrag im Log und einem dezenten Hinweis in der
  Statuszeile.

### 9.4 Rückwirkung auf die VS-Code-Variante

Die PowerShell-Skripte bekommen Parameter für Subscription, Ressourcengruppe und
Kapazitätsname. Fehlen sie, greifen Standardwerte aus derselben
`settings.json`, damit die bestehenden Statusleisten-Buttons unverändert
weiterlaufen. Keine doppelte Azure-Logik.

---

## 10. Abnahmekriterien

1. Ohne gültige Anmeldung startet das Fenster, zeigt `✖ Nicht angemeldet`, alle
   Aktionen sind gesperrt, „Anmelden" führt durch `az login` und danach lädt die
   Kapazitätsliste selbsttätig.
2. Das Dropdown enthält Kapazitäten aus mindestens zwei verschiedenen
   Subscriptions, sofern vorhanden. Ein Wechsel aktualisiert alle Felder und alle
   Links.
3. Ein Resume zeigt eine laufende Fortschrittsanzeige mit Sekundenzähler und endet
   erst, wenn der Status `Active` gemeldet wird. Die Gesamtdauer steht im Log.
4. „Warten abbrechen" beendet nur die Anzeige, der Statuswert wird beim nächsten
   Refresh korrekt nachgeführt.
5. Auto-Pause auf 15 Minuten gestellt und das Fenster unberührt gelassen: nach 13
   Minuten erscheint die Warnung, nach 15 Minuten ist die Kapazität pausiert, das
   Log nennt den Auslöser.
6. „Verlängern" während der Warnung setzt den Timer nachweislich zurück.
7. Der Pay-as-you-go-Hinweis ist ohne Scrollen sichtbar.
8. Wird die Netzwerkverbindung während des Betriebs getrennt, friert nichts ein
   und es erscheint kein Stapel von Fehlerdialogen.

---

## 11. Sammelliste „Zu verifizieren"

| Punkt | Abschnitt |
|---|---|
| Listen-Kommando in der Erweiterung `az fabric`, Preview-Stand | 4.5 |
| Felder aus `az resource list` ausreichend oder `az resource show` nötig | 4.5 |
| Verfügbarkeit der Erweiterung `resource-graph` auf dem Zielrechner | 4.2 |
| Exakte Statuswerte inklusive Übergangszustände | 7.4 |
| Verwendeter Pause/Resume-Aufruf und dessen `api-version` | 7.4 |
| Tatsächliche Fehlertexte bei abgelaufenem Token | 6.4 |
| Verhalten unter Windows PowerShell 5.1 gegenüber PowerShell 7 | 3 |

Diese Punkte bitte durch Ausführen und Nachlesen klären, nicht durch Annahmen. Wo
sich eine Annahme nicht auflösen lässt, im Code kommentieren und hier vermerken.

### Ergebnisse (13.09.2026, az 2.90.0, Extension microsoft-fabric 1.0.0b1)

| Punkt | Befund | Konsequenz |
|---|---|---|
| Listen-Kommando `az fabric` | `az fabric capacity list` existiert (je Subscription) und liefert `state`, `sku.name`, `location`, `resourceGroup`, `provisioningState`. | Ersetzt `az resource list` und Resource Graph. Schleife über `az account list --all` (Enabled) → `az fabric capacity list --subscription`. Weg wird im Log vermerkt. |
| Felder `az resource list` | Liefert `properties: null`, d. h. **kein** `state`; `location` nur als Kurzform (`germanywestcentral`). | Nicht verwendet. |
| Erweiterung `resource-graph` | Auf dem Zielrechner nicht installiert. | Nicht benötigt (siehe oben). |
| Statuswerte | Beobachtet: `Paused` → `Resuming` → `Active` und `Active` → `Pausing` → `Paused`; während des Übergangs `provisioningState: Updating`, danach `Succeeded`. Resume ~8-35 s, Pause ~12-18 s. | Polling endet bei Zielzustand `Active`/`Paused`; andere Werte werden angezeigt und weitergepollt. |
| Pause/Resume-Aufruf | `az fabric capacity suspend/resume` (Extension, ARM `api-version=2023-11-01`). **Ohne** `--no-wait` blockiert die CLI selbst bis zum Zielzustand. | Aufruf mit `--no-wait`, Polling alle 5 s über `az fabric capacity show`. |
| Fehlertexte bei abgelaufenem Token | Nicht live provozierbar. Mustererkennung großzügig: `az login`, `AADSTS`, `ExpiredToken`, `ExpiredAuthenticationToken`, `InvalidAuthenticationToken`, `re-authenticate`, `Interactive authentication is needed`, `refresh token`, `AuthenticationFailed`, `not logged in`, `token has expired`, `Authorization failed`. | `Test-AuthError` in `lib/Fabric-Common.ps1`; abgemeldeter Zustand getestet über leeres `AZURE_CONFIG_DIR`. |
| PS 5.1 vs. PS 7 | Nur Windows PowerShell 5.1 getestet (Launcher nutzt `powershell.exe -STA`). Dateien sind bewusst ASCII-only, da PS 5.1 BOM-lose Dateien als ANSI liest. | Im Skript-Header vermerkt. |

### Abweichungen von der Spezifikation (mit dem Auftraggeber abgestimmt)

- **§1 / §9.4** entfallen: GUI und VS-Code-Variante sind seit der Repo-Trennung eigenständig; die GUI hat ihre Azure-Logik in `lib/`.
- **§4.4** Kosten: die bestehende Abfrage filtert bereits auf die `ResourceId` der Kapazität (nicht RG-Summe). Beschriftung bleibt „Cost (MTD)"; nur der Fallback nennt die RG-Summe ausdrücklich.
- **§9.1** `config.json` entfällt vollständig; `metricsAppUrl` liegt in `settings.json`. `costAnalysisUrl` entfällt, der Link führt auf die RG-Kostenanalyse der gewählten Kapazität.
- **§9.2** Es gibt eine neue einzeilige Statuszeile; der Log bleibt dauerhaft sichtbar (nicht aufklappbar), mit „Copy log".
- **§6.2** Kopfzeile zeigt Benutzer und Tenant; die Subscription steht in der Info-Karte der gewählten Kapazität.
- **Sprache** der Oberfläche: Englisch (wie Bestand).

