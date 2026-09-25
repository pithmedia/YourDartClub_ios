# YourDartClub Mobile API v1

Implementatie: `flightclub/routes/mobile.php`, `MobileController`, `MobileAccess`, migratie `2026_09_25_210000_create_mobile_tables.php`. Gedeeld met Android. Deze routes zijn nieuw gebouwd in dit project, niet op productie beschikbaar gesteld. Datum: 25 september 2026.

## Transport en authenticatie

Basis: `/api/mobile/v1`. HTTPS vereist; de iOS-app gebruikt in Debug en Release `https://www.yourdartclub.com`, zonder zichtbaar serverveld. JSON met `Accept: application/json` en voor POST `Content-Type: application/json`. Geen cookies, CSRF-sessies of redirects. Maximaal 20.000 bytes per POST door bestaande `ClubRequest`-middleware. Stuur een object met velden; `{}` en `[]` worden door de bestaande middleware afgewezen.

`POST /login`:

```json
{"login":"captain@example.test","password":"…","deviceId":"a UUID","deviceSecret":"64 lowercase hex characters"}
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

`LiveCounter`, `DartEngine` en wedstrijden zijn A/B-gebaseerd. Meerdere spelers in een avond zijn geen 3/4-persoonspartij op één bord. De iOS-app ondersteunt inmiddels lokale partijen met twee, drie of vier spelers, maar deze gedeelde API accepteert nog uitsluitend twee spelers. De app blokkeert uploads van drie- en vierpersoonspartijen, ook in de batchbouwer. Officiële avonden, schema's, statistieken en Autodarts worden door mobiele uploads niet gewijzigd.

Offline officiële teamavonden vragen nog een commerciële beslissing over toegangsduur en een duurzaam schrijf- en planningscontract. De huidige versie geeft daar geen offline schrijfbevoegdheid voor. Lokale oefeningen blijven lokaal speelbaar; serveruploads vragen actuele bestaande teamtoegang.
