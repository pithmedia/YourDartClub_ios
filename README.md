# YourDartClub voor iPhone en iPad — eerste testversie

Universele SwiftUI-app, iOS/iPadOS 17+, met lokale oefenpartijen, SQLite-herstel, inloggen, veilige uploadwachtrij en een online teamoverzicht. De iPhone/iPad-app staat volledig in `ios/`; de bestaande Android TV-app blijft apart.

## Openen en bouwen

Open `ios/YourDartClub.xcodeproj` in Xcode 16.2 of nieuwer, kies scheme **YourDartClub** en een iPhone- of iPad-simulator, druk Run. Het project gebruikt alleen Apple-frameworks en SQLite, zonder externe packages. Het officiële bestaande appicoon is overgenomen uit `public_html/images/yourdartclub-app-icon-1024.png`.

```sh
xcodebuild -project ios/YourDartClub.xcodeproj -scheme YourDartClub \
  -sdk iphonesimulator -configuration Debug -derivedDataPath ios/build \
  CODE_SIGNING_ALLOWED=NO build
swift test --package-path ios
npm test
npm run build
```

Het uitgevoerde simulatorproduct staat in `ios/build/Build/Products/Debug-iphonesimulator/YourDartClub.app`. Voor een fysieke iPhone of iPad: selecteer je Apple Development Team bij Signing & Capabilities. Er is geen distributieprofiel of App Store-publicatie gemaakt. `python3 ios/generate-project.py` genereert het ingecheckte project opnieuw als bronbestanden worden toegevoegd; `python3 ios/localizations.py` genereert de vier vertaalbestanden.

Debug en Release gebruiken beide `https://www.yourdartclub.com`, uitsluitend via HTTPS. Er is geen zichtbaar serverveld en geen HTTP-uitzondering. De nieuwe backendroutes zijn **niet gedeployed** en de migratie is **niet op de bestaande database uitgevoerd**. Lokale partijen werken meteen; login en uploads via .com vragen eerst de afzonderlijke publicatie van deze backendwijzigingen. Oude wachtrijen blijven aan hun oorspronkelijke server gebonden en worden niet automatisch naar .com verplaatst. DartFlightClub blijft buiten scope.

## Wat is gebouwd

- Vrije lokale oefenpartij met twee, drie of vier namen, 301/501/701, single/double out, best of 1/3/5/7/9/11 en keuze van starter.
- Correcte bust, mogelijke darttotalen, checkout met expliciete bevestiging, wisselende legstarter, winnaar en undo als nieuw event.
- Scorebediening naar de website: vijfkoloms cijferblok met snelkeuzes aan beide zijkanten, CLR/backspace, Gegooid/Over, advies na 1–3 darts, aparte knoppen Score opslaan/Eindscore, bust en Geen score. Grote spelerskaarten tonen voorlopige resterende scores, gemiddelde en 180’s. De uitgooiroutes komen uit dezelfde voorkeurstabel als de website. Onmogelijke invoer wordt geweigerd zonder het invoerveld te wissen.
- Een zichtbare schakelaar voor direct opslaan. Bij eerste accountgebruik neemt de app de bestaande accountvoorkeur over; een expliciete apparaatkeuze blijft lokaal bewaard.
- SQLite met schema-versie, migratie, WAL en FULL-synchronisatie. Iedere bevestigde actie commit vóór het scherm verandert. Heropenen herstelt partijen én uploadwachtrij. Geen stille verwijdering of reset bij leesfouten.
- Bestaande captain- en teamlogin via nieuwe bearer-API. Token en apparaat-ID/geheim in Keychain, `ThisDeviceOnly`. Geen wachtwoordopslag of logging.
- Optionele, expliciet bevestigde upload naar geselecteerd team; apparaatgebonden, geordend en idempotent. Backoff van 15 seconden tot 5 minuten bij verbindingsproblemen; opnieuw proberen bij netwerkherstel, terugkeer naar de app en handmatige synchronisatie. Een lopende upload verliest geen ondertussen ingevoerde worpen.
- Lokale gastpartijen blijven gescheiden van teamdata. Uploads slaan naam, regels, worpen en correcties op als mobiele oefeningen; ze veranderen geen teamstatistieken.
- JSON-export via het iOS-deelmenu voor behoud/herstel. Uitloggen houdt lokale partijen en wachtrijen intact.
- Online alleen-lezen teamoverzicht met bestaande wedstrijden en scores, verversing elke 15 seconden. Standaard iOS-navigatie, VoiceOver-labels, grotere tekst en NL/EN/FR/DE via de systeemtaal.

## Bewuste grenzen van deze versie

Dit is de eerste werkende basis uit de opdracht, **geen volledige vervanging van de website**.

- Geen native registratie, betalingen, abonnementsbeheer of accountbeheer. De server controleert bestaande toegang bij elk teamverzoek.
- Geen offline officiële teamavonden of toernooimutaties. Er is geen nieuwe offline abonnementsregel verzonnen.
- Geen native beheer van spelers, borden, round-robin/finales/knock-out of zichtbaar toekomstig bracket. Het teamoverzicht toont bestaande wedstrijden; onbekende deelnemers verschijnen als `…`.
- Geen teamupload voor 3/4-persoonspartijen, apparaatwissel, automatische conflictmerge of download/herstel van serverpartijen in de iPhone-client. De API heeft wel een leesroute voor mobiele oefeningen; de iPhone uploadt eigen lokale oefeningen.
- Geen native tv-koppelproces of directe Autodarts-bediening. Het online teamoverzicht ontvangt bestaande backendstanden. Mobiele oefeningen worden niet op gekoppelde tv's gepubliceerd.
- Geen achtergrondgarantie als iOS de app opschort of beëindigt. Geen BGTaskScheduler of lokale-netwerksamenwerking in deze versie. De duurzame wachtrij gaat bij openen verder.
- Geen pushnotificaties, publicatie, echte betaling, productie-migratie of wijziging aan DartFlightClub.

## Tests en resterende controles

`YourDartClub/Tests` controleert bust/checkout/undo, onmogelijke worpen, herstel via heropende SQLite, mislukte opslag, identieke retry na verloren antwoord, nieuwe worp tijdens upload, ongeldige acknowledgements en batchlimiet. `flightclub/tests/Feature/MobileTest.php` controleert echte API-verzoeken tegen SQLite in memory: retries, JSON-keyvolgorde, eventvolgorde, rollback, twee apparaten, device-secret, teamgrenzen, betaaldetoegang, ingetrokken logins en tokens.

De simulatorbuild en het starten van de app zijn uitgevoerd. Visuele bediening, Dynamic Type/VoiceOver in de simulator en de volledige loginflow tegen een draaiende gemigreerde testbackend zijn **nog niet end-to-end gecontroleerd**: Computer Use heeft in deze sessie geen toestemming; er zijn geen live credentials gebruikt. Test voor distributie ook echte procesbeëindiging, vliegtuigmodus, volle opslag, keychain-toegang na reboot en een fysieke iPhone.

## App Store en abonnementen

De [actuele Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/uk/) zijn geraadpleegd op 25 september 2026. Onder 3.1.3(b) heeft toegang tot elders gekochte digitale functies voorwaarden; externe aankoopverwijzingen verschillen per storefront en overeenkomst. Daarom bevat deze testversie geen Mollie-checkout, koopknop of externe betaalverwijzing. Dat maakt deze login-versie niet automatisch App Store-goedgekeurd. Voor distributie moeten de toepasselijke categorie/storefronts en eventueel StoreKit/entitlements expliciet worden uitgewerkt. De bestaande prijzen, limieten en betaalregels zijn ongewijzigd.

Zie [API-CONTRACT.md](API-CONTRACT.md) voor alle requests, foutcodes en het nog te bouwen overdrachtsproces.

### Uitgevoerde verificatie op 25 september 2026

- Xcode Debug en Release voor iPhone-simulator: geslaagd; simulatorstart geslaagd.
- Swift: 20 tests geslaagd (inclusief multiplayer, favorieten, schema-1-migratie en invoer zoals op de website).
- `npm test`: 142 PHP-tests (204.262 assertions) en 72 frontendtests geslaagd.
- `npm run build`: geslaagd, inclusief bestaande vertaal- en knopicooncontroles. Bestaande waarschuwingen over Imagick-versies en een grote frontendchunk blijven zichtbaar.
- iOS-vertalingen: dezelfde 116 sleutels in NL, EN, FR en DE.

## iPad-ondersteuning

Dezelfde app en hetzelfde Xcode-scheme werken op iPhone én iPad (`TARGETED_DEVICE_FAMILY = 1,2`). Kies je aangesloten iPad bovenaan Xcode en gebruik Run; de ondertekening werkt hetzelfde als bij iPhone.

- Native partijenlijst als zijbalk, met de geselecteerde partij ernaast. Op een smal scherm verandert dit automatisch in navigatie tussen lijst en partij.
- Bij minimaal 820 punten beschikbare detailbreedte staan scorebord en bediening naast elkaar. Smallere vensters en toegankelijkheidsformaten gebruiken één kolom; de inhoud blijft scrollbaar.
- `AnyLayout` behoudt dezelfde invoercontrols bij wisselen van indeling. Een andere partij selecteren begint bewust met een leeg invoerveld; bevestigde scores blijven in SQLite.
- Alle vier iPad-schermoriëntaties, Split View en resizable vensters zijn toegestaan. Meerdere vensters van dezelfde app zijn uitgeschakeld: één actieve appinstantie houdt de lokale uploadwachtrij bij.
- Undo- en uploaddialogen zijn aan hun actieknop gekoppeld, zodat iPad-popovers een correct anker hebben. Export gebruikt het native deelmenu.
- Apparaatneutrale teksten in NL/EN/FR/DE. De bestaande offline opslag, rechten en synchronisatie zijn gelijk aan die op iPhone.

Validatie: universele Debug- en Release-build, controle van beide apparaatfamilies, vier iPad-oriëntaties en vier complete vertalingen, twintig Swift-regressietests, installatie en starten op iPhone 16 Pro en iPad Pro 11-inch simulator. Visuele interactie, rotatie en Split View moeten nog handmatig worden gecontroleerd; Computer Use was eerder in deze sessie niet beschikbaar. De bestaande beperkingen voor backend-login, toernooien en overdracht gelden ook voor iPad.

## Vormgeving, favorieten en intro

De websitebestanden `resources/css/app.css`, `resources/js/components/darts/live-counter.tsx` en `resources/js/lib/counter.ts` zijn de referentie voor kleuren, spelerskaarten, toetsenbord, score-/restinvoer, voorbeelden en uitgooiadvies. De app gebruikt de bestaande officiële logo-assets, donkergroene achtergronden, lichtgroene acties en eigen native kaarten. Een korte logo-intro verschijnt één keer bij het starten van het app-proces, is overslaanbaar door te tikken en wordt overgeslagen bij Verminder beweging.

Favorieten staan in een eigen tab en zijn direct te kiezen bij de spelernaam tijdens het aanmaken. Een ster bij de naam slaat die lokaal op. SQLite-migratie 1 → 2 voegt de favorietentabel toe zonder bestaande partijen te wijzigen. Een favoriet verwijderen verandert geen namen of scores van opgeslagen partijen. Favorieten zijn lokale namen, geen nieuwe teamleden en geen verhoging van de commerciële spelerslimiet.

Drie- en vierpersoonspartijen spelen op één bord, in de opgegeven volgorde. De volgende leg begint telkens bij de volgende speler vanaf de oorspronkelijke starter. Bij voldoende gewonnen legs eindigt de partij. Undo herstelt ook de beurt over een leggrens heen. Deze partijen worden lokaal bewaard en kunnen als JSON worden geëxporteerd; de bestaande gedeelde mobiele API blijft expliciet beperkt tot twee spelers. De app toont die beperking voordat de partij begint en bij de partij zelf.
