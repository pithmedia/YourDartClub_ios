# YourDartClub voor iPhone en iPad — eerste testversie

Universele SwiftUI-app, iOS/iPadOS 17+, met lokale oefenpartijen, SQLite-herstel, inloggen, veilige uploadwachtrij en een gekoppelde online teamomgeving. De iPhone/iPad-app staat volledig in `ios/`; de bestaande Android TV-app blijft apart.

## Openen en bouwen

Open `ios/YourDartClub.xcodeproj` in Xcode 16.2 of nieuwer, kies scheme **YourDartClub** en een iPhone- of iPad-simulator, druk Run. Voer bij een nieuwe checkout eerst `python3 ios/setup-cast.py` en `python3 ios/generate-project.py` uit. Het project gebruikt Apple-frameworks, SQLite en de vastgelegde Google Cast/Protobuf-dependencies. Het door jou aangeleverde appicoon staat in `ios/Artwork/appicon-yourdartclub-original.png`. De 1024×1024-versie wordt gebruikt voor het universele iPhone/iPad-appicoon en de logo-intro. De projectgenerator behoudt deze keuze.

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

- Lokaal potje darten met één, twee, drie of vier namen, 301/501/701, single/double out, best of 1/3/5/7/9/11 en keuze van starter.
- Correcte bust, mogelijke darttotalen, checkout met expliciete bevestiging, wisselende legstarter, winnaar en undo als nieuw event.
- Compacte scorebediening zonder scrollen: cijferblok met snelkeuzes, CLR/backspace, Gegooid/Over, uitgooiadvies, bust en Geen score. Instellingen en geschiedenis staan in een apart venster. De uitgooiroutes komen uit dezelfde voorkeurstabel als de website.
- Een zichtbare schakelaar voor direct opslaan. Bij eerste accountgebruik neemt de app de bestaande accountvoorkeur over; een expliciete apparaatkeuze blijft lokaal bewaard.
- SQLite met schema-versie, migratie, WAL en FULL-synchronisatie. Iedere bevestigde actie commit vóór het scherm verandert. Heropenen herstelt partijen én uploadwachtrij. Geen stille verwijdering of reset bij leesfouten.
- Bestaande beheerdersaccount- en teamlogin via nieuwe bearer-API. Token en apparaat-ID/geheim in Keychain, `ThisDeviceOnly`. Geen wachtwoordopslag of logging.
- Optionele, expliciet bevestigde upload naar geselecteerd team; apparaatgebonden, geordend en idempotent. Backoff van 15 seconden tot 5 minuten bij verbindingsproblemen; opnieuw proberen bij netwerkherstel, terugkeer naar de app en handmatige synchronisatie. Een lopende upload verliest geen ondertussen ingevoerde worpen.
- Lokale gastpartijen blijven gescheiden van teamdata. Uploads slaan naam, regels, worpen en correcties op als mobiele oefeningen; ze veranderen geen teamstatistieken.
- JSON-export via het iOS-deelmenu voor behoud/herstel. Uitloggen houdt lokale partijen en wachtrijen intact.
- Native teamtab met eventlijst, aanmaken, eventdetails, planning, poulestand, deelnemers, beheer en bordteller. Alle mutaties gebruiken dezelfde platformdatabase, rechten en tellerlogica als de website, via bearer-authenticatie.

## Bewuste grenzen van deze versie

Dit is de eerste werkende basis uit de opdracht, **geen volledige vervanging van de website**.

- Geen native registratie, betalingen, abonnementsbeheer of accountbeheer. De server controleert bestaande toegang bij elk teamverzoek.
- Geen offline officiële teamavonden of toernooimutaties. Er is geen nieuwe offline abonnementsregel verzonnen.
- Native bordtellers zijn gericht op handmatig tellen. Een automatisch door Autodarts bijgehouden bord kan niet handmatig worden overschreven; de bestaande serverbeveiliging blijft actief.
- Geen teamupload voor solo- of 3/4-persoonspartijen, apparaatwissel, automatische conflictmerge of download/herstel van serverpartijen in de iPhone-client. De API heeft wel een leesroute voor mobiele oefeningen; de iPhone uploadt eigen lokale oefeningen.
- Tv koppelen via het tv-icoon in lokale partijen en team-bordtellers. Chromecast vereist nog registratie en configuratie van de Receiver App ID. AirPlay en tv-codekoppeling zijn gebouwd; fysieke tv-validatie staat nog open.
- Geen achtergrondgarantie als iOS de app opschort of beëindigt. Geen BGTaskScheduler in deze versie. De duurzame wachtrij gaat bij openen verder.
- Geen pushnotificaties, publicatie, echte betaling, productie-migratie of wijziging aan DartFlightClub.

## Tests en resterende controles

`YourDartClub/Tests` controleert bust/checkout/undo, onmogelijke worpen, herstel via heropende SQLite, mislukte opslag, identieke retry na verloren antwoord, nieuwe worp tijdens upload, ongeldige acknowledgements en batchlimiet. `flightclub/tests/Feature/MobileTest.php` controleert echte API-verzoeken tegen SQLite in memory: retries, JSON-keyvolgorde, eventvolgorde, rollback, twee apparaten, device-secret, teamgrenzen, betaaldetoegang, ingetrokken logins en tokens.

De simulatorbuild en het starten van de app zijn uitgevoerd. Visuele bediening, Dynamic Type/VoiceOver in de simulator en de volledige loginflow tegen een draaiende gemigreerde testbackend zijn **nog niet end-to-end gecontroleerd**: Computer Use heeft in deze sessie geen toestemming; er zijn geen live credentials gebruikt. Test voor distributie ook echte procesbeëindiging, vliegtuigmodus, volle opslag, keychain-toegang na reboot en een fysieke iPhone.

## App Store en abonnementen

De [actuele Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/uk/) zijn geraadpleegd op 25 september 2026. Onder 3.1.3(b) heeft toegang tot elders gekochte digitale functies voorwaarden; externe aankoopverwijzingen verschillen per storefront en overeenkomst. Daarom bevat deze testversie geen Mollie-checkout, koopknop of externe betaalverwijzing. Dat maakt deze login-versie niet automatisch App Store-goedgekeurd. Voor distributie moeten de toepasselijke categorie/storefronts en eventueel StoreKit/entitlements expliciet worden uitgewerkt. De bestaande prijzen, limieten en betaalregels zijn ongewijzigd.

Zie [API-CONTRACT.md](API-CONTRACT.md) voor alle requests, foutcodes en het nog te bouwen overdrachtsproces.

### Uitgevoerde verificatie op 25 september 2026

- Xcode Debug en Release voor iPhone-simulator: geslaagd; simulatorstart geslaagd.
- Swift: 26 tests geslaagd (inclusief multiplayer, favorieten, schema-1-migratie en invoer zoals op de website).
- `npm test`: 150 PHP-tests (204.337 assertions) en 72 frontendtests geslaagd.
- `npm run build`: geslaagd, inclusief bestaande vertaal- en knopicooncontroles. Bestaande waarschuwingen over Imagick-versies en een grote frontendchunk blijven zichtbaar.
- iOS-vertalingen: dezelfde 154 sleutels in NL, EN, FR en DE.

## iPad-ondersteuning

Dezelfde app en hetzelfde Xcode-scheme werken op iPhone én iPad (`TARGETED_DEVICE_FAMILY = 1,2`). Kies je aangesloten iPad bovenaan Xcode en gebruik Run; de ondertekening werkt hetzelfde als bij iPhone.

- Native partijenlijst als zijbalk, met de geselecteerde partij ernaast. Op een smal scherm verandert dit automatisch in navigatie tussen lijst en partij.
- Het telscherm heeft een vaste stand en toetsenblok zonder ScrollView. Brede vensters gebruiken twee kolommen; op een liggende telefoon wordt het toetsenblok drie rijen. Geschiedenis, export, upload en voorkeuren staan in een apart instellingenvenster.
- `AnyLayout` behoudt dezelfde invoercontrols bij wisselen van indeling. Een andere partij selecteren begint bewust met een leeg invoerveld; bevestigde scores blijven in SQLite.
- Alle vier iPad-schermoriëntaties, Split View en resizable vensters zijn toegestaan. Meerdere vensters van dezelfde app zijn uitgeschakeld: één actieve appinstantie houdt de lokale uploadwachtrij bij.
- Uploadbevestiging is aan de actieknop gekoppeld, zodat iPad-popovers een correct anker hebben. Export gebruikt het native deelmenu.
- Apparaatneutrale teksten in NL/EN/FR/DE. De bestaande offline opslag, rechten en synchronisatie zijn gelijk aan die op iPhone.

Validatie: universele Debug- en Release-build, controle van beide apparaatfamilies, vier iPad-oriëntaties en vier complete vertalingen, 22 Swift-regressietests, installatie en starten op iPhone 16 Pro en iPad Pro 11-inch simulator. Visuele interactie, rotatie en Split View moeten nog handmatig worden gecontroleerd; Computer Use was eerder in deze sessie niet beschikbaar. De bestaande beperkingen voor backend-login, toernooien en overdracht gelden ook voor iPad.

## Vormgeving, favorieten en intro

De websitebestanden `resources/css/app.css`, `resources/js/components/darts/live-counter.tsx` en `resources/js/lib/counter.ts` zijn de referentie voor kleuren, spelerskaarten, toetsenbord, score-/restinvoer, voorbeelden en uitgooiadvies. De app gebruikt de bestaande officiële logo-assets, donkergroene achtergronden, lichtgroene acties en eigen native kaarten. Een korte logo-intro verschijnt één keer bij het starten van het app-proces, is overslaanbaar door te tikken en wordt overgeslagen bij Verminder beweging.

Favorieten staan in een eigen tab en zijn direct te kiezen bij de spelernaam tijdens het aanmaken. Een ster bij de naam slaat die lokaal op. SQLite-migratie 1 → 2 voegt de favorietentabel toe zonder bestaande partijen te wijzigen. Een favoriet verwijderen verandert geen namen of scores van opgeslagen partijen. Favorieten zijn lokale namen, geen nieuwe teamleden en geen verhoging van de commerciële spelerslimiet.

Drie- en vierpersoonspartijen spelen op één bord, in de opgegeven volgorde. De volgende leg begint telkens bij de volgende speler vanaf de oorspronkelijke starter. Bij voldoende gewonnen legs eindigt de partij. Undo herstelt ook de beurt over een leggrens heen. Deze partijen worden lokaal bewaard en kunnen als JSON worden geëxporteerd; de bestaande gedeelde mobiele API blijft expliciet beperkt tot twee spelers. De app toont die beperking voordat de partij begint en bij de partij zelf.

## Compact telscherm en solo

Kies 1–4 spelers bij Potje darten. Solo gebruikt dezelfde validatie, uitgooi, legs, undo en duurzame opslag; alleen tweepersoonspartijen kunnen naar een team worden geüpload. Bij twee spelers staan de standen naast elkaar; bij drie/vier spelers staat de actieve speler boven een compacte lijst. Tijdens het tellen is de tabbar verborgen. Uitgooien bevestig je in een dialoog. De rest-/scoremodus blijft beschikbaar boven het toetsenblok.

De compacte indeling is gebouwd, maar nog niet visueel op toestellen gecontroleerd. Controleer vóór distributie kleine schermen, rotatie, iPad Split View en grotere tekstinstellingen. De 22 coretests bevatten solo bust, undo, legwissel, winst, hervatten en weigering van solo-teamuploads.

## Taal en scorelettertype

De globe op het startscherm, Account → Taal en de partijinstellingen bieden Nederlands, Engels, Frans, Duits en de apparaattaal. De keuze wordt lokaal bewaard en werkt direct, ook voor dynamische teksten, zonder navigatie of score-invoer opnieuw aan te maken. Niet-ondersteunde apparaattalen vallen terug op Nederlands.

Scores, invoer en toetsen gebruiken Arial Bold (het ingebouwde iOS-lettertype Arial-BoldMT), overeenkomstig de Arial-fontstack van de website. De grote score blijft passend binnen het vaste telscherm. De accounttekst gebruikt beheerdersaccount in plaats van captainaccount, met dezelfde correctie in EN/FR/DE.

## Online events, toernooien en tellen in de app

Team gebruikt nu native SwiftUI-schermen voor events, borden, planning, standen, deelnemers en eventbeheer. De bordteller schrijft via de mobiele bearer-API naar de bestaande platformwedstrijden. De exclusieve tellerlease en revisiecontrole blijven leidend. De vroegere webbrug blijft voor compatibiliteit op de backend staan, maar de nieuwe app opent die niet meer voor events.

Zie [CASTEN-EN-NATIVE-EVENTS.md](CASTEN-EN-NATIVE-EVENTS.md) voor gebruik, publicatiebestanden, Chromecast-registratie en validatie. De tv-weergave staat los van de iPhone-invoer en volgt bij teamevents een bord door naar de volgende partij. Chromecast vereist nog de Receiver App ID; echte tv-verbindingen moeten nog op hardware worden getest.

## Compacte koppen en vectorlogo (26 september 2026)

De grote Spelen-paginatitel is verwijderd; de tabnaam blijft behouden. De bovenmarge van de lijst is verkleind en de taalknop is een compacte globe. Favorieten, Team, Account en partijinstellingen gebruiken inline navigatietitels. De introductiekaart heeft kleinere koptekst en minder tussenruimte. Het woordmerk gebruikt nu het bestaande website-SVG als schaalbaar asset met behoud van vectorgegevens; de generator bewaart dit. Deze wijziging vereist een nieuwe app-build, geen backendpublicatie.

## Mobiele teamindeling (26 september 2026)

De embedded platformpagina krijgt de bodyclass `mobile-platform`. `flightclub/resources/css/mobile-platform.css` wordt via de bestaande webbuild geladen en maakt alleen die omgeving compacter: geen dubbele branding of marketingkoppen, geen demolink, navigatie in twee kolommen op telefoons, volledig leesbare eventkeuzes en kleinere eventkaarten. Bedieningsdoelen blijven minimaal 44 pixels. De reguliere website en de scoreteller worden niet globaal verkleind.

Publiceer `flightclub/resources/views/club.blade.php` en de volledige huidige `public_html/build/` (manifest en assets als één versie), voer `php artisan view:clear` uit en sluit/open het teamvenster opnieuw. De webbuild en acht MobilePlatform-integratietests (76 assertions) slagen; visuele toestelcontrole is nog nodig. De oude native titel in de screenshot verdwijnt met de eerder aangepaste app-build.

## Archief, verwijderen en tv (26 september 2026)

Veeg een lokale partij naar links of houd deze ingedrukt voor Archiveren/Verwijderen. Het archief is een apart segment; Terugzetten maakt een partij weer zichtbaar. Archiveren bewaart worpen en eventuele uploadwachtrij en werkt ook voor oude opgeslagen partijen. Verwijderen vraagt bevestiging en verwijdert uitsluitend de lokale partij en resterende lokale wachtrij. Een eerder geüploade serverkopie blijft bestaan. Tijdens synchronisatie wordt verwijderen geblokkeerd, zodat een uploadantwoord de verwijderde partij niet kan terugplaatsen. Bestaande platformevents blijven onder de bestaande teamrechten en verwijderbevestiging vallen.

De tv-knop staat nu in de lokale partij en native team-bordteller. Ondersteuning voor AirPlay via een apart extern scherm, de YourDartClub TV-codekoppeling (ook lokale 1–4-persoonspartijen) en een voorbereide Chromecast-zender/receiver vervangt de oude webkoppeling. Zie [castinstructies](CASTEN-EN-NATIVE-EVENTS.md).

## Uitgooivakjes en terug tijdens invoer (26 september 2026)

Uitgooiadvies wordt in losse grotere vakjes getoond. Voorlopige invoer berekent advies met de resterende darts. Is uitgooien daarmee onmogelijk, maar wel met drie darts, dan tonen de vakjes expliciet Volgende beurt · 3 pijlen. Voorbeeld: 140 − 20 = 120 kan niet in twee darts; 101 − 20 = 81 wel. Bij geen beschikbare route verschijnt uitleg in plaats van een lege ruimte. Bust/uitgooi/winst houden hun eigen melding.

Het terugpijltje wist eerst de volledige onopgeslagen invoer (ook 0) en laat opgeslagen beurten ongemoeid. Alleen bij een leeg invoerveld wordt de vorige actieve beurt ongedaan gemaakt. Backspace blijft één cijfer verwijderen. Validatie: Debug-build en 26 Swift-tests geslaagd, inclusief beide invoervoorbeelden en de prioriteit van wissen boven undo. Alleen een nieuwe app-build nodig.

## Favorieten ordenen en verwijderen (26 september 2026)

Favorieten → Bewerken toont de sleepgrepen en verwijderknoppen. Veeg buiten de bewerkstand naar links om een favoriet te verwijderen. De volgorde wordt in SQLite (schema 3) opgeslagen en ook gebruikt in de spelerskeuze bij een nieuwe partij. Bestaande favorieten behouden bij de migratie hun eerdere alfabetische volgorde; nieuwe namen komen onderaan. Verwijderen van een favoriet laat opgeslagen partijen intact. Validatie: 30 Swift-tests geslaagd (inclusief migratie, heropenen, volgorde en verwijderen) en simulator Debug-build geslaagd. Alleen een nieuwe app-build nodig; geen backendwijziging.

## Opstartcrash na tv-koppeling verholpen (26 september 2026)

Het fysieke crashrapport meldde `Thread stack size exceeded due to excessive recursion` met herhaalde `AppSceneDelegate.responds(to:)`-aanroepen. In de simulator herhaalde `AppSceneDelegate.scene(_:willConnectTo:options:)` zich duizenden keren. De custom appdelegate retourneerde een kopie van de reeds door SwiftUI beheerde sceneconfiguratie, waardoor die delegate opnieuw in zichzelf werd verpakt.

De appdelegate-adaptor en de configuratie-override zijn verwijderd. Het tv-scherm gebruikt de bestaande expliciete externe-sceneconfiguratie in Info.plist; SwiftUI beheert het hoofdscherm zelf. Google Cast initialiseert eenmaal vanuit de root-task nadat de app gestart is. Simulator Debug en device Release bouwen; de nieuwe simulatorstart is met LLDB gecontroleerd en de hoofdthread staat normaal in de eventloop, zonder de recursie. Opnieuw uitvoeren op de fysieke iPhone via Xcode blijft de laatste toestelcontrole. Er is geen backendpublicatie nodig voor deze fix.

## Autodarts-bediening op afstand

De app heeft nu **Autodarts bedienen** bij het officiële bord. De beveiligde teamwebsite opent direct de gekozen partij. Vereist de aanvullende serverupdate en een verbonden laptop met een open YourDartClub-tab. Zie [instructies en uitrol](../AUTODARTS-MOBIEL.md). Geen storepublicatie of fysieke combinatieproef uitgevoerd.

## Compacte teamagenda (9 oktober 2026)

De app opent de gedeelde teamagenda in het privé-appvenster. Dezelfde lijst op datum, darticonen, aantallen aanwezigen/niet-gereageerd, opgeslagen spelerskeuze en aanwezigheidskeuze worden gebruikt als op de website. De mobiele stylesheet geeft knoppen minimaal 44 px hoogte; uitgebreide deelnemerslijsten en het volledige adres blijven onder Details en deelnemers.

Google Maps-locaties openen vanuit het appvenster in de externe kaartenapp/browser. De interne navigatie blijft beperkt tot de bestaande platformroutes. Het geselecteerde menu blijft bij verversen behouden via `view` op `/mobile/team`; de aparte agenda-ingang blijft `?agenda=1`.

Voor de weergave zijn de huidige webbuild en backend met locatieverrijking nodig. Voor het openen van Maps is ook een nieuwe native app-build nodig. Deze wijziging publiceert geen website of appwinkelversie. Native builds en core/unit-tests zijn gecontroleerd; controle op fysieke telefoons blijft nodig.

## Uitgooitabel (9 oktober 2026)

De uitgooitips zijn gelijkgetrokken met de aangeleverde checkoutfoto en worden vanuit één gedeelde tabel gegenereerd. Zie [UITGOOIADVIES.md](../docs/UITGOOIADVIES.md) voor de vergelijking, het aantal resterende pijlen en het bijwerken van alle platforms. Hiervoor is een nieuwe app-build nodig; er is niets gepubliceerd.

### Agenda zonder internet

Open de teamagenda eerst met internet. De app bewaart daarna de laatst succesvol opgehaalde wedstrijden en trainingen per login en team op het toestel. Zonder verbinding, of bij een onbereikbare teamomgeving, verschijnt een leesversie met datum, tijd, locatie, annuleringen en het ophaaltijdstip. Ook na opnieuw openen van de app kun je de opgeslagen teamagenda kiezen. Aanwezigheid, trainingswijzigingen en agenda-abonnementen vereisen internet. Bij herstel van de verbinding wordt de online agenda opnieuw geopend; vernieuwen kan ook handmatig.

Alleen agenda-afspraken worden opgeslagen: geen sessiecookies, agenda-abonnementstokens of aanwezigheidsreacties. Uitloggen verwijdert de agenda-opslag; een andere login of ander team kan deze niet uitlezen. Een mislukte bronaanvraag overschrijft de bestaande kopie niet. Er is geen websitewijziging nodig voor deze mobiele leesversie.
