# Pral – arkitektur

Det her dokument beskriver, **hvad Pral skal kunne, hvilke sider der skal være, og hvad der skal være på hver side**.
Det er tegningen, som koden bygges efter. Koden selv bestemmer udvikleren.

> Ejer af dokumentet: Simon (arkitekt). Udvikler: partner.
> Ændringer i krav sker her først, og derefter i koden.

---

## 1. Hvad er Pral

Et socialt spil om fodbold for vennegrupper (klubber). Man afgiver **kald** (bets) på kampe med **pralepoint (PP)**.
PP kan ikke købes og kan ikke veksles til penge. Man spiller kun om retten til at prale.

**Grundregler**

| Regel | Værdi |
| --- | --- |
| Budget pr. runde (uge) | 1.000 PP |
| Indsats pr. kald | 10–300 PP |
| Deltagerbonus pr. runde | 50 PP (når man har afgivet mindst ét kald) |
| Kombikald | 2–5 kampe i ét kald, odds ganges sammen |
| Følg / Modspil en vens kald | Fast indsats, sat af klubben (standard 100 PP) |
| Live-kald lukker | 85. minut |
| Alder | Kun 18+ |

---

## 2. Sider

Hver side er én HTML-fil. Alle sider efter login har **samme top** og **samme bundmenu** (se afsnit 3).

| # | Fil | Formål | Status i dag |
| --- | --- | --- | --- |
| 1 | `login.html` | Log ind, opret profil, vælg eller opret klub | ✅ Findes |
| 2 | `index.html` | **Kampe**: kommende kampe og afgiv kald | ✅ Findes (indeholder også live) |
| 3 | `live.html` | **Live**: kampe i gang og live-kald | ❌ Mangler (linket fra `klub.html`) |
| 4 | `klub.html` | **Klubben**: stilling, rundens kald, følg/modspil, kåringer | ✅ Findes |
| 5 | `mine-kald.html` | **Mine kald**: egne kald og rundens resultat | ❌ Mangler (linket fra `klub.html`) |
| 6 | `badges.html` | **Badges**: klistermærker | ❌ Mangler (linket fra `klub.html`) |
| 7 | `klubadmin.html` | **Klubadmin**: indstillinger og medlemmer (kun admin) | ✅ Findes |

### 2.1 `login.html` – Log ind
**Skal indeholde**
- Opret profil: e-mail, adgangskode, kaldenavn, flueben "Jeg er fyldt 18 år" (påkrævet).
- Log ind: e-mail og adgangskode.
- Efter login: vælg klub med invitationskode **eller** opret ny klub (navn, motto). Den, der opretter, bliver admin.
- Er man allerede logget ind og med i en klub → send direkte videre til `index.html`.

**Mangler i dag:** 18+-flueben.

### 2.2 `index.html` – Kampe
**Skal indeholde**
- Rundenavn og **PP tilbage** af ugens 1.000.
- Liste over kommende kampe: liga, tidspunkt, hold, odds for **1 / X / 2**.
- Under hvert odds: hvor stor en del af klubben, der har valgt det (fx "40 % valgte").
- Kuponslip nederst, når man har valgt: valgte kampe, samlet odds, indsats (50 / 100 / 200 / 300), kommentar, knap "Afgiv kald, mulig gevinst X PP".
- Låste kampe (startet eller slut) kan ikke vælges.

**Bemærk:** Live-delen (Dine live-kald, Kampforløb, Chancen gennem kampen) ligger i dag i `index.html`. Den skal flyttes til `live.html`.

### 2.3 `live.html` – Live *(ny)*
**Skal indeholde**
- Kampe i gang: stilling, minut, live-markering.
- Live-odds 1 / X / 2, der skifter med stillingen. Låst efter 85. minut og kortvarigt efter mål.
- Afgiv live-kald: vælg udfald og indsats.
- **Dine live-kald** i kampen.
- **Hvis kampene slutter nu**: hvad dine kald giver.
- **Chancen gennem kampen**: graf over 1 / X / 2.
- **Kampforløb**: mål, kort, udskiftninger.

### 2.4 `klub.html` – Klubben
**Skal indeholde**
- Klubbens navn, motto, antal medlemmer, invitationskode med "Kopiér" og "Del link".
- **Før runden er spillet:** "Ugens odds før fløjtet" (mest og mindst sandsynlige kald).
- **Efter runden:** "Ugens kåringer" (profet, største brøler, konge) og mulighed for at dele dem som billede.
- **Rundens kald**: alle klubbens kald med kommentar, Følg / Modspil-knapper og hvor mange der følger/modspiller.
- **Stillingen**: rangliste for ugen og sæsonen.
- **Rivaler**: resultat af dine modspil-dueller mod hver ven.
- Skift klub, hvis man er med i flere.
- Link til Klubadmin, hvis man er admin.

### 2.5 `mine-kald.html` – Mine kald *(ny)*
**Skal indeholde**
- Rundens tal: indsat, gevinst, bonus, resultat (= gevinst − indsats + bonus), PP tilbage.
- Mine kald i denne runde: kampe, odds, indsats, status (afventer / ramte plet / forbi).
- Tidligere runder.
- Ret mit kaldenavn. Log ud.

### 2.6 `badges.html` – Badges *(ny)*
**Skal indeholde**
- Gitter med alle badges. Opnåede er farvede, ikke-opnåede er grå med beskrivelse af, hvordan man får dem.
- Badges: Ny i klubben, Første kald, Ramte plet, Kombimager, Langskud, Live-kalder, Sidste øjeblik, Modspilleren, På stribe, Profeten, Brølerkongen.

### 2.7 `klubadmin.html` – Klubadmin
**Skal indeholde**
- Kun adgang for klubbens admins. Andre sendes til `klub.html`.
- Klubindstillinger: navn, motto, invitationskode, rundebonus, duel-indsats, slå Modspil og Live til/fra.
- Medlemmer: rolle (admin/medlem), smid ud, bonus og bøde (bødekasse).

**Skal ændres:** Afregning af kampe og "Start næste runde" må **ikke** ligge her (se afsnit 5).

---

## 3. Fælles på alle sider efter login

- **Top:** Pral-logo, klubnavn, streak 🔥, PP tilbage.
- **Bundmenu:** Kampe · Live · Klubben · Mine kald · Badges.
- **Ikke logget ind** → send til `login.html`.
- **Velkomst** første gang, og små beskeder (toast) ved handlinger.
- Tekst nederst: "PP kan ikke købes for penge og kan ikke veksles til penge."
- Supabase-forbindelsen (URL og anon-nøgle) er den samme på alle sider.

---

## 4. Data (Supabase)

Tabellerne, som siderne bruger i dag. Der findes endnu **ingen SQL**, der opretter dem. Det er første opgave.

| Tabel | Indhold | Kolonner, koden bruger |
| --- | --- | --- |
| `profiles` | Én pr. bruger | `id`, `display_name`, `email`, `pp`, `streak`, `badges`, `email_verified`, `updated_at` |
| `clubs` | Klubber | `id`, `name`, `motto`, `invite_code`, `created_by`, `current_round`, `round_bonus`, `duel_stake`, `allow_fades`, `allow_live`, `bodekasse` |
| `club_members` | Hvem er med i hvilken klub | `club_id`, `user_id`, `role` (`admin` / `member`) |
| `matches` | Kampe og odds | `id`, `home_team`, `away_team`, `league`, `kickoff_label`, `odds`, `status`, `result`, `round` |
| `calls` | Kald | `id`, `club_id`, `user_id`, `round`, `picks`, `stake`, `odds`, `comment`, `status`, `payout`, `created_at` |
| `call_reactions` | Følg / Modspil | `call_id`, `user_id`, `action` (`follow` / `fade`), `stake`, `status`, `payout` |
| `pp_transactions` | Log over alle PP-bevægelser | `user_id`, `amount`, `reason` |
| `round_awards` | Ugens kåringer | `club_id`, `round`, `best_user_id`, `best_odds`, `best_win`, `burnt_user_id`, `burnt_odds` |

**Sikkerhed (Row Level Security)** skal være slået til på alle tabeller:
- Man ser kun klubber, man er med i, og kun profiler i sine klubber.
- Man kan kun ændre sit eget kaldenavn.
- Kampe kan alle læse, men ingen bruger kan ændre dem.

---

## 5. Regler, der skal flyttes ind i databasen

I dag regner browseren point ud og skriver dem direkte i databasen. Det betyder, at **enhver bruger kan give sig selv point eller ændre resultater**. Derfor skal disse handlinger være **databasefunktioner** (`sb.rpc(...)`), der selv tjekker reglerne:

| Handling | Funktion | Tjekker |
| --- | --- | --- |
| Afgiv kald | `place_call` | Logget ind, medlem af klubben, kampen ikke startet, indsats 10–300, budget. Odds slås op i databasen, ikke sendt fra browseren. |
| Følg / Modspil | `react_call` | Medlem, ikke sit eget kald, klubben tillader modspil. |
| Bonus / bøde | `admin_adjust_pp` | Den, der kalder, er admin i klubben. Skrives i `pp_transactions`. |
| Afregn kamp | `settle_match` | Kun systemet (ikke klubadmin). Afregner alle klubbers kald på kampen. |
| Ny runde | `start_round` | Kun systemet. Runde = uge. |

**Kampe er fælles for alle klubber.** Derfor må en klubadmin ikke sætte resultater eller nulstille kampe, for det rammer alle klubber. Resultater kommer fra systemet (senere fra en data-leverandør, indtil da fra Pral-admin).

---

## 6. Rækkefølge

1. [ ] **Database:** SQL, der opretter tabellerne i afsnit 4 med sikkerhed. Gem den i `supabase/` i repoet.
2. [ ] **Databasefunktioner** fra afsnit 5. Siderne skifter fra direkte skrivning til `sb.rpc(...)`.
3. [ ] **De tre manglende sider:** `live.html`, `mine-kald.html`, `badges.html`.
4. [ ] **Fælles top og bundmenu** på alle sider.
5. [ ] **18+-flueben** ved oprettelse.
6. [ ] Flyt afregning og "næste runde" ud af `klubadmin.html`.
7. [ ] Lås Supabase-biblioteket til en fast version (fx `supabase-js@2.45.4` i stedet for `@2`).

---

## 7. Aftaler

- Udvikleren ejer koden. Kravændringer skrives her først.
- Claude tilføjer kun **nye filer** (fx dette dokument, SQL eller nye sider) og retter ikke i eksisterende filer uden aftale.
- Hemmelige nøgler (secret key, service_role, database-adgangskode) må aldrig ligge i repoet.
