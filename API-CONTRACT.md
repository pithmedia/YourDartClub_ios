# YourDartClub Mobile API v1

Implementatie: `flightclub/routes/mobile.php`, `MobileController`, `MobileAccess`, migratie `2026_09_25_210000_create_mobile_tables.php`. Gedeeld met Android. Deze routes zijn nieuw gebouwd in dit project, niet op productie beschikbaar gesteld. Datum: 25 september 2026.

## Transport en authenticatie

Basis: `/api/mobile/v1`. HTTPS vereist; de iOS-app gebruikt in Debug en Release `https://www.yourdartclub.com`, zonder zichtbaar serverveld. JSON met `Accept: application/json` en voor POST `Content-Type: application/json`. Geen cookies, CSRF-sessies of redirects. Maximaal 20.000 bytes per POST door bestaande `ClubRequest`-middleware. Stuur een object met velden; `{}` en `[]` worden door de bestaande middleware afgewezen.

`POST /login`:

```json
{"login":"admin@example.test","password":"…","deviceId":"a UUID","deviceSecret":"64 lowercase hex characters"}
```

`login` is een e-mailadres voor een persoonlijk account of de gedeelde teamlogin. `deviceId` wordt één keer per installatie aangemaakt. `deviceSecret` is 32 cryptografisch willekeurige bytes, als 64 lowercase hextekens. Bewaar beide in Keychain/Keystore en hergebruik ze bij volgende logins. De server registreert alleen de hash van dit geheim. Een bestaand deviceId met een ander geheim levert 409 op. Het openbare deviceId uit een opgeslagen partij is dus onvoldoende om dat apparaat na te doen.

Antwoord: `{"token":"64 hex characters","userId":123}`. Bearer-token in Keychain, uitsluitend hash op de server. Geldig tot 30 dagen na uitgifte. Een wachtwoordwijziging, wijziging/intrekking van de gedeelde login of `POST /logout` trekt toegang in. Tokens verlenen geen toegang tot website-billing of beheeracties.

Alle volgende routes vereisen `Authorization: Bearer <token>`. Teamroutes vereisen bovendien `X-Team-Id: <integer>`. Membership, shared-teamgrens en actuele betaalde toegang worden bij ieder teamverzoek op de server gecontroleerd via `TeamContext`. Een lokale preview geldt alleen volgens de bestaande local-configuratie; er is geen nieuwe offline entitlement.

| Methode / route | Gedrag |
| --- | --- |
| GET `/me` | `userId`, `quickScoreAutoSubmit`, `teams`: id, name, owner, active, paidUntil |
| POST `/logout` | Body `{"revoke":true}`; trekt dit bearer-token in |
| GET `/club` | Bestaande `ClubStore.snapshot()`: spelers en avonden van dit team |
| GET `/games` | Mobiele oefenpartijen van dit team: id, deviceId, revision, config, events |
| POST `/sync` | Eén batch van één mobiele oefenpartij atomair synchroniseren |

Login: 10 verzoeken/minuut. Overige mobiele routes: 120/minuut. Geen wachtwoorden of deviceSecrets loggen. Bearer-authenticatie accepteert geen bestaande websessie als vervanging.

## Partijen en events

```json
{
  "id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "revision":0,
  "config":{"players":["Alex","Sam"],"game":501,"checkout":"double","bestOf":3,"starter":"A"},
  "events":[
    {"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","kind":"visit","score":60,"darts":3,"finish":false,"bust":false}
  ]
}
```

- `id`: UUID voor de partij. Blijft na crash en retry hetzelfde.
- `revision`: aantal events waarvan deze client de bevestiging duurzaam heeft opgeslagen; de batch begint op deze offset.
- `config`: onveranderlijk. Exact twee namen van 1–60 tekens, game 301/501/701, checkout single/double, bestOf 1/3/5/7/9/11, starter A/B. JSON-keyvolgorde is irrelevant.
- `events`: 0–50 events, maximaal 4.000 opgeslagen events per partij. Namen worden snapshots voor oefeningen; geen nieuwe teamspelers of teamstatistieken.
- Visit: UUID, kind `visit`, gehele score 0–180, darts 1–3, booleans finish/bust. Een optionele `target` is alleen relevant bij undo.
- Undo: nieuwe UUID, kind `undo`, target UUID van de laatste actieve visit, score 0, darts 3, finish false, bust false. De oorspronkelijke visit blijft in de auditgeschiedenis. Correcties zijn undo + nieuwe visit, geen wijziging van het oude event.
- Server valideert iedere nieuwe speltransitie met de bestaande `LiveCounter`, ook een worp die later in dezelfde batch wordt teruggenomen.
- Antwoord: `{"id":"…","revision":N}`. N is het totaal aantal duurzaam opgeslagen events.

De eerste geldige batch maakt de oefenpartij aan en bindt hem definitief aan het huidige team en apparaat. Alle verdere batches moeten deze identiteit en configuratie behouden. De server bewaart de hele batch in één database-transactie. Bestaande overlappende events moeten identiek zijn; identieke retries tellen niet opnieuw. Ander event op dezelfde offset, hergebruik van een event-ID, ontbrekende voorgangers en veranderde configuratie leveren 409 op. Een ander apparaat krijgt 423, ook na verlopen van zijn vorige token. Opnieuw inloggen met hetzelfde deviceId + secret herstelt de mogelijkheid om te uploaden.

Clientregels: schrijf eerst lokaal, toon pas daarna bevestiging. Geef dezelfde batch opnieuw door na timeout; verhoog de lokale revision uitsluitend na valide serverack. Bewaar lokale worpen die tijdens een request worden toegevoegd. Bind een upload blijvend aan server-origin, userId en teamId. Wisselen van account/team/server mag geen verplaatsing van een wachtrij veroorzaken. Zonder expliciete uploadkeuze blijven gastpartijen lokaal.

| Status | Clientactie |
| --- | --- |
| 400 / 422 | Invoerprobleem; behoud lokale geschiedenis en vraag aandacht |
| 401 | Opnieuw inloggen; geen lokale scores wissen |
| 402 | Actuele teamtoegang ontbreekt; bewaar wachtrij |
| 403 | Teamrecht ontbreekt; niet naar ander team omleiden |
| 409 | Geschiedenis/configuratie/apparaatregistratie conflicteert; niet overschrijven |
| 423 | Ander apparaat is eigenaar; geen automatische overname |
| 429 / 5xx / timeout | Bewaar batch en probeer met vertraging opnieuw |

## Overdracht en conflictherstel

Deze eerste versie staat geen apparaatoverdracht toe. Daardoor kan een offline eigenaar niet onopgemerkt worden ingehaald door een tweede schrijver. Bij conflict: exporteer de volledige lokale geschiedenis, bewaar de serverversie en vergelijk events voordat een operator herstel implementeert. De iPhone stopt automatische retries van een conflicterende partij; andere partijen kunnen verder synchroniseren. Er is geen reset-, force-, last-write-wins- of automatische merge-route.

Voor een volgende overdrachtsflow zijn nodig: huidige eigenaar volledig laten synchroniseren, zijn invoer duurzaam sluiten, online een expliciete overdracht met verwachte revision en nieuwe eigenaarsgeneratie bevestigen, en oude generaties blijvend afwijzen. Een offline of kwijtgeraakte eigenaar vereist een afzonderlijke gecontroleerde herstelprocedure met behoud van beide geschiedenissen. Dit proces is ontworpen, nog niet gebouwd.

## Bestaande backend en afgebakende hiaten

De website heeft `/api/club` met aanmaak, spelers, indeling, scoreteller en correcties; die gebruikt sessie/CSRF-authenticatie. `/api/counter-access` heeft een 30 seconden durende cachelease en is niet geschikt voor langdurige offline invoer. `/api/tv/*` en `/tv/pair` bestaan voor tv-koppeling; `/api/autodarts/ingest` gebruikt de bestaande extension-authenticatie. De mobiele v1 biedt hiervoor geen nieuwe mutatie- of koppelroutes.

`LiveCounter`, `DartEngine` en wedstrijden zijn A/B-gebaseerd. Meerdere spelers in een avond zijn geen 3/4-persoonspartij op één bord. De iOS-app ondersteunt inmiddels lokale partijen met één, twee, drie of vier spelers, maar deze gedeelde API accepteert nog uitsluitend twee spelers. De app blokkeert uploads van solo-, drie- en vierpersoonspartijen, ook in de batchbouwer. Officiële avonden, schema's, statistieken en Autodarts worden door mobiele uploads niet gewijzigd.

Offline officiële teamavonden vragen nog een commerciële beslissing over toegangsduur en een duurzaam schrijf- en planningscontract. De huidige versie geeft daar geen offline schrijfbevoegdheid voor. Lokale oefeningen blijven lokaal speelbaar; serveruploads vragen actuele bestaande teamtoegang.

## Online platformomgeving binnen iOS / Android

De app kan de bestaande, volledige teaminterface openen met een geïsoleerde WebView. Er is hiervoor geen tweede toernooimodel: mutaties gebruiken de bestaande `/api/club`, `/api/counter-access`, `/api/counter-preview` en `/api/autodarts` routes, inclusief TeamContext, CSRF, revisions, leases en beheerrechten.

1. Maak een niet-persistente WebView-sessie aan (niet delen met browser/accountsessies).
2. Laad **POST https://www.yourdartclub.com/mobile/team** met `Authorization: Bearer <mobile token>`, `X-Team-Id: <team>`, `Content-Type: application/json` en `Accept: text/html`.
3. Body: `{"locale":"nl"}`. Optioneel `"event":"<evening-id>"` om direct een eigen event te openen of `"create":true` om het aanmaakformulier te openen. Dit maakt nog geen event aan.
4. De server valideert token, actuele teamtoegang en eventeigendom, maakt een nieuwe sessiecookie en antwoordt met **303** naar `/mobile/team` (event/create als onschuldige queryparameters). Laat de WebView de cookie verwerken en dezelfde-origin redirect volgen.
5. De pagina bevat CSRF- en teammetadata. De bestaande websitecode verzorgt alle teamacties. Alleen de initialiserende POST is CSRF-vrij wegens verplichte bearer-authenticatie; latere mutaties houden normale CSRF-bescherming.
6. Token/geheim nooit in URL, JavaScript, localStorage of logs zetten. Sta alleen HTTPS-navigatie op de eigen origin naar `/mobile/team` en `/language` toe. Verwijder WebView-sessie bij sluiten, uitloggen of teamwissel. Herlaad nooit automatisch een onzekere scoreactie.

De websessie is aan het oorspronkelijke mobiele token en team gebonden. Intrekken, verlopen, wachtwoordwijziging en intrekken van de gedeelde login beëindigen toegang. Verzoeken voor andere teams en account-/billing-/adminroutes zijn geblokkeerd. Verwijderen vereist de bestaande eenmalige beheerderswachtwoordcontrole; genodigde accounts kunnen niet verwijderen.

Dit is online platformgebruik. De `/sync`-wachtrij blijft uitsluitend voor lokale tweepersoonsoefeningen; die mag geen officiële toernooiacties bevatten. Bij netwerkproblemen bewaart de bestaande teller zijn huidige invoer in het venster en controleert hij revisions/visit-id’s bij opslaan; sluit het venster niet zonder op te slaan. Na sluiten is onopgeslagen invoer niet gegarandeerd hersteld.

Backendpublicatie is nog niet uitgevoerd. Integratietests: MobilePlatformTest, naast de bestaande Club/Counter/Tournament-tests. Dezelfde bridge is bruikbaar voor Android mits WebView POST-headers, cookies en redirectgedrag daar expliciet worden getest.

### Tv openen vanuit de app

Voeg `"destination":"tv"` toe aan de JSON-body van POST `/mobile/team`. De server stuurt na dezelfde bearer-/teamcontrole een 303 naar `/tv/pair`. De geïsoleerde mobiele sessie mag `/tv/pair` en POST `/tv/displays/{id}/settings` en `/tv/displays/{id}/revoke` gebruiken. Die acties behouden CSRF, TeamContext, betaalde toegang, eigen-teamcontrole en eenmalige codeverzilvering. Sta deze exacte navigatiepaden ook toe in de WebView. Er komt geen brede toegang tot account- of abonnementsbeheer bij.

Dezelfde bestaande TV-app/tv-browser blijft alleen-lezen; castcodes geven op zichzelf geen leestoegang. Dit ondersteunt team-events, niet lokale oefeningen. Directe AirPlay-/Chromecast-integratie is niet onderdeel van deze route.


## Native event- en bordbediening (26 september 2026)

De nieuwe iPhone-app gebruikt voor events de onderstaande JSON-routes in plaats van `/mobile/team`. De webbrug blijft compatibel met oudere builds. Alle officiële acties vereisen bearer-authenticatie, `X-Team-Id`, actuele teamtoegang en de bestaande TeamContext-grenzen.

| Route | Gebruik |
| --- | --- |
| POST `/club` | Dezelfde whitelist en validatie als `ClubController.update`: create, add-player, add-board, pair, join, finish, delete, start-match, score en counter-acties. Antwoord is de complete teamsnapshot. Create voegt `createdId` toe; add-player `addedPlayerId`. |
| GET `/club` | Complete teamsnapshot; events bevatten nu ook serverberekende `standings` (bij playoffs alleen leaguefase). |
| POST `/counter-access` | `{action: acquire/renew/release, id, matchId, counterToken}`. Token: 64 hextekens. Lease 30 seconden; de iPhone vernieuwt iedere 8 seconden. |
| POST `/tv/pair` | `{code,name,evening_id,board,page_size:1,rotation_seconds:10,locale}`. Eenmalige code, bestaand bord in eigen team. Antwoord `{paired:true,displayId}`. Geen cookie/sessie nodig. |
| POST `/tv/revoke` | `{displayId}`. Alleen gekoppelde tv van dit team; antwoord `{revoked:true}`. |

Counter-start vereist `id`, `revision`, `matchId`, `counterToken`, `starter` (A/B), `initialA`, `initialB`. Counter-visit vereist daarnaast `counterRevision` en `visit:{id,score,darts,finish,bust}`. Undo/finish gebruiken eveneens de actuele `counterRevision`. De client selecteert de live match op `(team,event,board)` opnieuw na iedere snapshot. Counter-finish schrijft het officiële resultaat en laat de bestaande engine de volgende beschikbare match plannen.

Officiële counter-writes zijn geen offline uploadbatch. Bij een verloren antwoord niet automatisch een nieuwe visit verzenden: herlees de snapshot en zoek de oorspronkelijke visit-ID. Als dat niet kan, blokkeer verdere invoer tot de actuele stand bekend is. Controleer altijd opnieuw de tellerlease.

### Tijdelijke lokale tv-relay

`POST /local-cast/pair` is apart van teamrechten: `{code,frame}` mag uitsluitend een nog ongekoppelde tv met een geldige code koppelen. Het antwoord geeft een willekeurig `writer`-token dat alleen deze tijdelijke schermkopie kan verversen. Het leest of wijzigt nooit spelers, events of officiële scores. `POST /local-cast/frame` gebruikt dit writer-token als bearer en `{frame}`. `POST /local-cast/stop` met hetzelfde token en `{stop:true}` ontkoppelt de tijdelijke tv en trekt het schrijftoken in. Maximaal vier spelers, begrensde strings/getallen, geen HTML. Pairing 10/minuut, frames 90/minuut. De tv leest via zijn bestaande HttpOnly-cookie `/api/tv/state`, met `localFrame` en `localUpdatedAt`. Koppeling maximaal vier uur, eenmalige code, ontkoppelen op de tv maakt het writer-token onbruikbaar. Laravel-cache moet over webservers gedeeld zijn.

Frame: `title`, `subtitle`, `message`, `legsLabel`, optioneel `stale`/`staleMessage`, en `players:[{name,remaining,legs,active,advice:[String]}]`. Dezelfde display-only framevorm gaat via Google Cast naar `urn:x-cast:com.yourdartclub.board`. De native AirPlay-weergave gebruikt dezelfde gegevens direct in geheugen.
