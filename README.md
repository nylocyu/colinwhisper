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

Lokale Builds werden wie Releases mit der Developer ID signiert (Team PW42RVY2HS). macOS bindet die Berechtigungen an die Signatur, so teilen sich Xcode-Builds und die installierte Version dieselben Freigaben.

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

Ein Eintrag ist entweder eine Korrektur („PayPal → Paperless“) oder nur ein Wort („QES-Addon“, *Erkannt als* leer). Die richtige Schreibweise jedes Eintrags wird durchgesetzt, auch wenn das Wort klein, mit Leerzeichen oder mit Bindestrichen ankommt: `qes add-on` → „QES-Addon“, `paper less` → „Paperless“. Bei reinen Wort-Einträgen ab 7 Zeichen wird auch ein Buchstabe Abweichung korrigiert: `Papeless`, `Paperess` → „Paperless“.

Zusätzlich bringt die App eine feste Liste bekannter Fehlformen mit (`Glossary.builtIn`): „Wis.per“, „US. Whisper“, „US Whisper“, „Whisper Flow“, „Whisperflow“ → „Wispr Flow“, „Colin Wis.per“, „Colin Visper“ → „Colin Whisper“ und „API K“ → „API-Key“. Sie gilt neben den eigenen Einträgen, steht aber nicht in `glossary.json`. Die Zielschreibweisen aller Einträge gehen außerdem als „genau so schreiben“-Liste in den Prompt des Formatierers.

## Claude (optional, eigener API-Key)

In den Einstellungen unter „Formatierung“ wählt „Modell“ zwischen „Claude Haiku 5.5 (eigener Key)“ und „Lokales Modell auf dem Mac“. Für Claude wird ein Anthropic-API-Key hinterlegt ([console.anthropic.com](https://console.anthropic.com)). „Prüfen und speichern“ testet den Key mit einer kostenlosen Anfrage und legt ihn im Schlüsselbund ab, nicht in einer Datei. Beim Umschalten auf lokal bleibt er dort. Mit Claude als Auswahl formatiert Claude Haiku 5.5 jedes Diktat, das Menü zeigt das aktive Modell. Es bekommt dieselben Anweisungen, Beispiele und Glossar-Begriffe und liefert dieselbe Struktur (Anrede, Absätze, Listen, Grußformel) als JSON nach dem Muster der Beispiele, mit denselben Plausibilitätsprüfungen. Structured Outputs mit erzwungenem Schema wurden getestet und verworfen: Claude schrieb die Blöcke dann vor der Anrede und wählte leere Listen (4–12 von 14 Testdiktaten fehlerhaft, ohne Schema 0 von 14, und schneller). Ohne Netz, bei Fehlern oder nach 8 s formatiert das Modell auf dem Mac, danach greift wie bisher der unformatierte Text.

- **Datenschutz:** Mit Key geht der Diktattext (nach Glossar) an Anthropic, das Audio nie. Ohne Key bleibt alles auf dem Mac.
- **Kosten:** 0,10 $ / 0,50 $ pro Mio. Tokens. Anweisungen und Beispiele (~3.900 Tokens) liegen 5 Minuten im Prompt-Cache. Gemessen am Testfall: ~0,03 Cent pro Diktat, das erste nach einer Pause ~0,07 Cent. Mit hinterlegtem Key zeigen die Einstellungen, was bisher angefallen ist („Du hast Colin 1,24 Cent verursacht.“), berechnet aus den Tokens jeder Antwort, in Euro-Cent zum festen Kurs 0,86 € pro Dollar, dazu die entsprechende Arbeitszeit bei 19 € pro Stunde. Gezählt werden auch Antworten, die durch die Prüfung fallen, nicht aber Anfragen nach dem 8-s-Timeout. „Statistik zurücksetzen“ lässt den Betrag stehen.
- **Dauer (gemessen):** kurze Diktate ~1,1 s (lokal ~0,6 s), Testfall ~1,8 s (lokal ~4,8 s), langer Text mit 1.157 Zeichen ~2,5 s (lokal ~5,1 s).
- **Ein Claude-Abo (Pro/Max) geht nicht:** Anthropic erlaubt Drittanbieter-Apps den claude.ai-Login nicht, nur API-Keys.

Im Fenster „Pipeline testen“ lässt sich Claude ein- und ausschalten. Angezeigt wird, wer formatiert hat.

## Glossar-Lernen

Das Glossar füllt sich selbst: Korrigierst du im Korrekturfenster den eingefügten Text und klickst „Übernehmen", vergleicht die App deine Fassung mit dem Rohtranskript. Gefundene Kandidaten werden gemerkt und **ab dem zweiten Auftreten in einem anderen Diktat automatisch** ins Glossar übernommen – ohne Bestätigung. Einmalige Ausrutscher bleiben damit folgenlos.

Dafür muss das Korrekturfenster nach dem Diktat auf – am bequemsten über die Einstellung „Korrekturfenster nach jedem Diktat öffnen". Gemerkte, noch nicht übernommene Kandidaten stehen in `pending-candidates.json`.

## Pipeline testen

Nur in Debug-Builds (aus Xcode gestartet): Menü → „Pipeline testen…“. Das Fenster schickt einen Text durch die Stufen nach der Spracherkennung, also Segmente zusammenfügen, Glossar, Fragezeichen und Formatierer, und zeigt Rohtext, Zwischenstand und Ergebnis mit der Dauer der Nachbearbeitung. Jede Zeile der Eingabe gilt als ein Segment der Spracherkennung. Vorbelegt ist der Testfall aus dem Tester-Feedback (`Fixture.swift`). Es wird nichts eingefügt und nichts im Verlauf gespeichert.

## Statistik

Menü → „Statistik…“ zeigt Wörter pro Minute, diktierte Wörter, Korrekturen (Formatierer und Glossar), die Nutzung nach App, die Tage in Folge mit Kalender, das häufigste Wort (nur Substantive) und die Hauptzeit. Beim ersten Öffnen startet sie mit den Diktaten aus dem Verlauf, danach zählt jedes Diktat dazu. Zurücksetzen: Einstellungen → „Statistik zurücksetzen“.

## Daten

`~/Library/Application Support/ColinWhisper/`: `glossary.json` (von Hand bearbeitbar), `pending-candidates.json` (gemerkte Kandidaten), `history.json` (die letzten N Diktate) und `usage.json` (Statistik: pro Diktat Zeitpunkt, Wortzahl, Dauer, Ziel-App und Anzahl Korrekturen, dazu wie oft jedes Substantiv vorkam – kein Diktat-Text). Audio wird nie gespeichert.

## Abweichungen von der Spezifikation

- **Transkriber:** `SpeechTranscriber` statt `DictationTranscriber`. Er hat keine Interpunktions-Option, setzt aber immer Satzzeichen. `DictationTranscriber` hat im Test auf Deutsch Wörter verschluckt. `contextualStrings` (über `AnalysisContext`) werden übergeben, wirken laut Apple-Doku aber nur mit `DictationTranscriber` und haben auch in Tests nichts bewirkt. Die eigentliche Korrektur leisten das Glossar und der Formatierer-Prompt.
- **Segmente:** Der Transkriber liefert ein Ergebnis pro Segment. Bis 1.3 wurden sie ohne Trenner aneinandergehängt („WhisperFällt“, „DeployedLäuft“). Jetzt fügt die Pipeline sie mit Leerzeichen zusammen und bereinigt deterministisch: keine doppelten Leerzeichen, keins vor Satzzeichen, eins nach `.?!` vor einem Großbuchstaben („aufnehme.Ich“), außer nach Abkürzungen wie „z.B.“.
- **Formatierer mit Guided Generation:** Das Modell liefert keinen fertigen Text, sondern die Struktur `FormattedDictation` (Anrede, Blöcke aus Absätzen oder Listen, Grußformel). Den Text baut der Code daraus: Leerzeilen zwischen Absätzen, „- “ für Listenpunkte, die Liste direkt unter ihrem Einleitungssatz. Die Beispiele werden als echte Gesprächsrunden mit strukturierter Antwort übergeben, das Diktat steht in `<diktat>`-Tags, die Guardrails sind permissiv. Ohne diese Maßnahmen hat das On-Device-Modell diktierte Fragen beantwortet und aus „Schreib eine E-Mail an …“ ganze E-Mails verfasst. Das JSON-Schema steht **nicht** im Prompt (`includeSchemaInPrompt: false`): Mit Schema hat das Modell in 8 von 10 Testdiktaten Anreden und Grußformeln erfunden und Beispielsätze kopiert, bei 2,3-facher Dauer.
- **Struktur nur, wo sie sich lohnt:** Guided Generation kostet bei kurzen Diktaten rund 0,7 s mehr (Median 1,3 s statt 0,6 s) und schreibt bei langen Texten ganze Absätze klein. Deshalb fordert die App die Struktur nur an, wenn das Diktat höchstens 800 Zeichen hat und mit einer Anrede beginnt, mit einer Grußformel endet oder aufzählt („erstens …“, „Aufzählung“, „Milch, Eier, Brot und Butter“). Alles andere formatiert das Modell als Freitext, mit denselben Beispielen als Textantworten. Ein Fehlgriff kostet nur Zeit oder das feste Layout, nie Text. Im Fenster „Pipeline testen“ steht, welcher Modus gewählt wurde. Beim Drücken der Auslösetaste wird nur die Freitext-Session vorgewärmt: Das Modell hält nur einen vorgewärmten Prompt-Anfang, ein zweites Vorwärmen verdrängte den ersten. Kurze Freitext-Diktate brauchen so wieder ~0,5 s wie vor der Umstellung, kurze Briefe und Listen ~2–2,5 s.
- **Absätze bei Themenwechsel:** Bisher nur bei „neuer Absatz“, jetzt auch bei einem Themenwechsel. Listen ab drei aufgezählten Punkten, nummeriert („1.“, „2.“ …), wenn der Sprecher zählt (erstens, zweitens), sonst mit „- “. Zählwörter am Anfang eines Punkts entfernt der Code. Ein Fragezeichen der Spracherkennung darf wegfallen, wenn sein Satz zum Listenpunkt wurde. Selbstkorrekturen („nee, ich meine“, „X beziehungsweise Y“, „also eigentlich“) werden mit Few-Shot-Beispielen aufgelöst.
- **Plausibilitätsprüfung** zusätzlich zur 50-%-Längenregel: Die Ausgabe darf nur wenige neue Wörter enthalten (gezählt pro Vorkommen, damit auch Wiederholungen auffallen), kaum Inhaltswörter weglassen und kaum Wörter anders groß- oder kleinschreiben. Diktierte Fragen müssen Fragen bleiben. Anrede und Grußformel müssen mit einer echten Anrede bzw. Grußformel beginnen und aus diktierten Wörtern bestehen. Sonst wird der bereinigte Text ohne Formatierung eingefügt. Zwei Fehler repariert der Code vorher selbst: Eine Grußformel, die im letzten Absatz stehen geblieben ist, wird zur Grußformel. Eine Anrede oder Grußformel, von der kein Wort diktiert wurde, fällt weg.
- **Lange Diktate** laufen als Freitext in Stücken bis 1500 Zeichen. Fällt nur ein Stück durch die Plausibilitätsprüfung, bekommt nur dieses seinen unformatierten Text.
- **Glossar-Lernen ohne Bestätigung:** Die Spec verlangt eine Checkbox-Bestätigung pro Kandidat. Stattdessen zählt die App, in wie vielen verschiedenen Diktaten dieselbe Korrektur vorkam, und übernimmt sie ab dem zweiten Mal selbst.
- **Abbruch bei Tastenkürzeln:** Wird mit gehaltener Auslösetaste eine andere Taste gedrückt oder geklickt (z. B. ⌘C), wird die Aufnahme still verworfen.
- **Stille um die Aufnahme:** Vor und nach dem Audio hängt die App je 0,5 s Stille an. Ohne sie hat die Spracherkennung Wörter am Anfang und Ende verschluckt und den letzten Satz oft ohne Satzzeichen gelassen – auch Fragen ohne „?“.
- **Fragenerkennung aus der Syntax:** Nach dem Glossar setzt die App ein „?“, wenn der Satzbau eine Frage ist (W-Frage mit Verb, Verb vorne mit passendem Subjekt wie „Kannst du …“, „Haben Sie …“, Anhängsel wie „…, oder“). Imperative („Schicken Sie mir …“) und Bedingungssätze („Sollte das nicht klappen, …“) bleiben Aussagen. „Kann ich …“/„Machen wir …“ gelten nur als Frage, wenn die Spracherkennung keinen Punkt gesetzt hat. Es werden nur Fragezeichen ergänzt, nie entfernt.
- **Start-Timeout:** Kommt 3 s lang kein Audio-Buffer an, zeigt das Overlay einen Fehler statt ewig „Moment…“.
