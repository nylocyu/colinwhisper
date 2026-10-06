# ColinWhisper

Lokale Diktier-App für die macOS-Menüleiste: **rechte ⌘-Taste (in den Einstellungen änderbar) halten, sprechen, loslassen** – der Text landet formatiert an der Cursorposition. Transkription (`SpeechAnalyzer`) und Formatierung (Apple Foundation Models) laufen komplett auf dem Mac, ohne Netzwerk.

## Installieren

[Neueste Version herunterladen](https://github.com/nylocyu/colinwhisper/releases/latest), entpacken und `ColinWhisper.app` in den Programme-Ordner ziehen. Voraussetzungen: macOS 26, Apple Silicon, Apple Intelligence aktiviert (sonst wird der Text nur unformatiert eingefügt).

Updates kommen von selbst: Die App prüft täglich auf neue Versionen und fragt vor der Installation. Manuell geht es über „Nach Updates suchen…“ im Menü.

## Release veröffentlichen

```bash
./release.sh 1.1 "Was ist neu"
```

Das Skript setzt die Version, baut die App, signiert sie mit der Developer ID und lässt sie von Apple notarisieren. Danach signiert es das Update für Sparkle und legt Zip und `appcast.xml` als GitHub-Release ab.

Einmalig vorher nötig:
- Developer-ID-Zertifikat anlegen: Xcode → Einstellungen → Accounts → Zertifikate verwalten → „Developer ID Application“.
- Zugang für die Notarisierung speichern (Apple-ID und app-spezifisches Passwort von account.apple.com): `xcrun notarytool store-credentials ColinWhisper`
- Der private Sparkle-Schlüssel liegt im Schlüsselbund. Ohne ihn lassen sich keine Updates mehr ausliefern, deshalb ein Backup anlegen: `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-key-backup` und die Datei sicher ablegen, nicht ins Repo.

## Selbst bauen

Voraussetzungen: macOS 26, Apple Silicon, Xcode 26, `xcodegen` (`brew install xcodegen`).

```bash
xcodegen generate
xcodebuild -project ColinWhisper.xcodeproj -scheme ColinWhisper -configuration Release -derivedDataPath build/DerivedData build
cp -R build/DerivedData/Build/Products/Release/ColinWhisper.app /Applications/
```

Lokale Builds werden mit dem „Apple Development“-Zertifikat signiert (Team PW42RVY2HS), damit die Berechtigungen auch nach einem Neu-Build erhalten bleiben. Releases signiert `release.sh` mit der Developer ID. Wechselt man zwischen beiden, fragt macOS die Berechtigungen einmal neu ab.

## Erster Start

Die App braucht drei Berechtigungen. Fehlende stehen im Menü, jeweils mit direktem Link in die Systemeinstellungen:

- **Mikrofon** – Aufnahme
- **Eingabeüberwachung** – Erkennen der Auslösetaste
- **Bedienungshilfen** – Einfügen per ⌘V

Das deutsche Sprachmodell lädt beim ersten Start automatisch herunter (der Fortschritt steht im Menü).

## Tests

```bash
xcodebuild -project ColinWhisper.xcodeproj -scheme ColinWhisper -derivedDataPath build/DerivedData test
```

## Glossar

Ein Eintrag ist entweder eine Korrektur („PayPal → Paperless“) oder nur ein Wort („QES-Addon“, *Erkannt als* leer). Die richtige Schreibweise jedes Eintrags wird durchgesetzt, auch wenn das Wort klein, mit Leerzeichen oder mit Bindestrichen ankommt: `qes add-on` → „QES-Addon“, `paper less` → „Paperless“.

## Glossar-Lernen

Das Glossar füllt sich selbst: Korrigierst du im Korrekturfenster den eingefügten Text und klickst „Übernehmen", vergleicht die App deine Fassung mit dem Rohtranskript. Gefundene Kandidaten werden gemerkt und **ab dem zweiten Auftreten in einem anderen Diktat automatisch** ins Glossar übernommen – ohne Bestätigung. Einmalige Ausrutscher bleiben damit folgenlos.

Dafür muss das Korrekturfenster nach dem Diktat auf – am bequemsten über die Einstellung „Korrekturfenster nach jedem Diktat öffnen". Gemerkte, noch nicht übernommene Kandidaten stehen in `pending-candidates.json`.

## Daten

`~/Library/Application Support/ColinWhisper/`: `glossary.json` (von Hand bearbeitbar), `pending-candidates.json` (gemerkte Kandidaten) und `history.json` (die letzten N Diktate). Audio wird nie gespeichert.

## Abweichungen von der Spezifikation

- **Transkriber:** `SpeechTranscriber` statt `DictationTranscriber`. Er hat keine Interpunktions-Option, setzt aber immer Satzzeichen. `DictationTranscriber` hat im Test auf Deutsch Wörter verschluckt. `contextualStrings` werden übergeben, haben aber in Tests bei keinem der beiden Transkriber etwas bewirkt – die eigentliche Korrektur leistet das Glossar.
- **Formatierer:** Die Beispiele werden als echte Gesprächsrunden übergeben (Few-Shot-Transcript). Außerdem steht das Diktat in `<diktat>`-Tags und die Guardrails sind permissiv. Ohne diese Maßnahmen hat das On-Device-Modell diktierte Fragen beantwortet und aus „Schreib eine E-Mail an …“ ganze E-Mails verfasst.
- **Plausibilitätsprüfung** zusätzlich zur 50-%-Längenregel: Die Ausgabe darf nur wenige neue Wörter enthalten und kaum Inhaltswörter weglassen, und diktierte Fragen müssen Fragen bleiben. Sonst wird der unformatierte Text eingefügt.
- **Glossar-Lernen ohne Bestätigung:** Die Spec verlangt eine Checkbox-Bestätigung pro Kandidat. Stattdessen zählt die App, in wie vielen verschiedenen Diktaten dieselbe Korrektur vorkam, und übernimmt sie ab dem zweiten Mal selbst.
- **Abbruch bei Tastenkürzeln:** Wird mit gehaltener Auslösetaste eine andere Taste gedrückt oder geklickt (z. B. ⌘C), wird die Aufnahme still verworfen.
- **Start-Timeout:** Kommt 3 s lang kein Audio-Buffer an, zeigt das Overlay einen Fehler statt ewig „Moment…“.
