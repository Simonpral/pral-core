# Pral – app og Supabase

Pral-appen og alt, hvad Supabase skal bruge. Læg hele mappen i repositoriet `pral` på GitHub.

```
index.html                      Appen (Vercel viser den)
supabase/migrations/20261115000000_pral.sql      Database, regler og sikkerhed
supabase/migrations/20261116000000_pral_v2.sql   Kombikald, næste mål, følg og modspil, kåringer, rivaler og badges
supabase/migrations/20261117000000_pral_v3.sql   Superligaens runder, udsatte kampe, VAR og 40-sekunders-reglen
supabase/functions/live-odds/   Live-odds hvert 20. sekund
supabase/functions/nightly/     Holdstyrke og kommende kampe hver nat
supabase/functions/_shared/     Odds-model og Sportmonks-kode, som begge funktioner bruger
supabase/cron.sql               Timerne, der starter funktionerne
```

## Sådan hænger det sammen

1. Hver nat henter **nightly** det seneste års resultater og regner holdenes styrke ud. Derefter henter den kampene de næste 8 dage og sætter odds før kampen.
2. Hvert 20. sekund henter **live-odds** stilling, minut og røde kort, regner nye odds ud og gemmer dem i tabellen `matches`.
3. **Appen** læser `matches` og får ændringer med det samme gennem Supabase Realtime.
4. Når en bruger afgiver et kald, kalder appen funktionen `place_pick`. Det er databasen, der slår oddsene op, tjekker låsen og budgettet og gemmer kaldet. Appen sender aldrig odds.
5. Ved slutfløjt afregner **live-odds** alle kald på kampen.

## Opsætning, trin for trin

### 1. Database
1. Åbn Supabase → **SQL Editor**, og kør hele `supabase/migrations/20261115000000_pral.sql`. Kør derefter `20261116000000_pral_v2.sql` og til sidst `20261117000000_pral_v3.sql`. Rækkefølgen er vigtig.
2. Tjek under **Database → Publications**, at tabellerne `matches` og `picks` er med i `supabase_realtime`.

### 2. Login med kode
1. Gå til **Authentication → Sign In / Providers**, og sørg for, at Email er slået til.
2. Gå til **Authentication → Emails**, og tilføj koden i de to skabeloner **Confirm signup** og **Magic Link**, fx:
   `Din kode til Pral er {{ .Token }}`
   Nye brugere får den første, faste brugere den anden. Så kan alle skrive koden i appen. Det er nemmest på iPhone, når appen ligger på hjemmeskærmen.
3. Gå til **Authentication → URL Configuration**. Sæt **Site URL** til jeres Vercel-adresse, fx `https://pral.vercel.app`, og tilføj den under Redirect URLs.

### 3. Edge Functions
1. Gå til **Edge Functions → Secrets**, og tilføj:
   - `CRON_SECRET`: en lang, tilfældig tekst på mindst 20 tegn. Gem den i Bitwarden.
   - `SPORTMONKS_TOKEN`: Sportmonks-nøglen. **Vent med den**, til demoen virker (se trin 5).
   - `LEAGUES`: Superligaens id hos Sportmonks. Tjek det i Sportmonks' ID Finder. Er det ikke 271, så skriv det rigtige.
2. Læg de to funktioner op med Supabase CLI fra repositoriets mappe. `supabase init` laver en config-fil og rører ikke de eksisterende filer:
   ```
   supabase login
   supabase init
   supabase link --project-ref DIT-PROJEKT-ID
   supabase functions deploy live-odds --no-verify-jwt
   supabase functions deploy nightly --no-verify-jwt
   ```
   `--no-verify-jwt` er nødvendigt, fordi timeren ikke logger ind. Funktionerne afviser alle kald uden den rigtige `CRON_SECRET`.

### 4. Timere
1. Slå `pg_cron` og `pg_net` til under **Database → Extensions**.
2. Udfyld de to værdier øverst i `supabase/cron.sql`, og kør filen i SQL Editor.

### 5. Test med demo-kampe
Uden `SPORTMONKS_TOKEN` kører live-odds med tre simulerede kampe og én kommende kamp. Kampene starter forfra 5 minutter efter slutfløjt.
1. Kør `select public.pral_call('nightly');` én gang, så demo-holdene får styrker.
2. Vent et minut, og åbn appen. Kampene bør tikke frem, og oddsene skifte.
3. Når alt virker, tilføjer I `SPORTMONKS_TOKEN`. Så skifter funktionen selv til rigtige data. Ryd demo-kampene med `delete from picks where match_id between 9001 and 9004; delete from matches where id between 9001 and 9004;` og kør `select public.pral_call('nightly');`.

### 6. Appen på Vercel
1. Project URL og anon-nøgle står allerede øverst i scriptet i `index.html` (`SUPABASE_URL` og `SUPABASE_KEY`). Begge må gerne ligge på GitHub.
2. Importér repositoriet i Vercel. Vælg Framework Preset **Other**, og lad build-feltet stå tomt. Appen er én almindelig HTML-fil, så der skal ikke bruges Environment Variables i Vercel.
3. Tryk Deploy.

## Regler, som databasen håndhæver

| Regel | Værdi | Hvor den ændres |
| --- | --- | --- |
| Budget pr. runde | 1.000 PP | `pral_setting` i 20261115000000_pral.sql |
| Indsats pr. kald | 10–300 PP | `pral_setting` |
| Deltagerbonus | 50 PP | `pral_setting` |
| Live-kald lukker | 85. minut | `pral_setting` |
| Lås efter mål og rødt kort | 20 sekunder | `LOCK_MS` i `_shared/apply.ts` |
| Lås, når data er gamle | 90 sekunder | `pral_setting` |
| Runde | ISO-uge i dansk tid | `current_round` |

Ændres en regel i databasen, skal den samme værdi rettes i `RULES` øverst i scriptet i `index.html`, så appen viser det samme.

## Sikkerhed

- Appen bruger kun **publishable key**. Den kan læse kampe og odds, men kan ikke ændre dem.
- Kald kan kun oprettes gennem `place_pick`. Direkte skrivning i `picks` bliver afvist.
- Brugere kan kun se deres egne kald, og kun de klubber, de er med i.
- **Secret key** og **Sportmonks-nøglen** findes kun i Supabase. Læg dem aldrig i `index.html` eller på GitHub.

## Appens fem dele

| Del | Indhold |
| --- | --- |
| Log ind | Kode på mail og 18+-bekræftelse |
| Kampe | Kommende kampe, kuponslip med enkeltkald og kombikald på 2–5 kampe, andel af klubben pr. udfald |
| Live | Live-kampe, live-kald, næste mål, dine kald i kampen, "hvis kampene slutter nu", graf og kampforløb |
| Klubben | Kåringer med deling som billede, odds før fløjtet, ranglister, rundens kald med følg og modspil, rivaler |
| Badges | 11 badges, der regnes ud fra dine data |

Velkomst, mål-animation og konfetti er bygget ind. Tryk på pointsaldoen øverst for at se dine egne kald og rette dit navn.

## Ikke med endnu

Sikr kaldet, ugens boost, påmindelser før deadline og sæsonens trofæ mangler stadig.
