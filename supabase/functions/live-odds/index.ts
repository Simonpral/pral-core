// Pral – live-odds
// Kører hvert 20. sekund (pg_cron). Henter stilling, minut og røde kort fra Sportmonks,
// regner nye odds ud, gemmer dem i public.matches og afregner kampe.
// Appen får ændringerne med det samme gennem Supabase Realtime.
//
// Rækkefølgen i hver kørsel:
//   1. Gem nye stillinger og odds
//   2. Mål eller rødt kort: annullér live-kald lagt inden for de sidste 40 sekunder
//   3. Mål, der har stået i 2 minutter: afgør næste mål (kun kald lagt før målet)
//   4. Udsatte eller aflyste kampe: annullér alle kald, indsatsen gives tilbage
//   5. Slutfløjt: afregn kampen
//
// Uden SPORTMONKS_TOKEN kører funktionen i demo-tilstand med simulerede kampe,
// så I kan teste hele kæden, før I har rigtige data.

import { adminClient, authorized, json, loadModels } from '../_shared/db.ts';
import { applyFixtures, LIVE_VOID_SECONDS, preMatchRow, type MatchRow } from '../_shared/apply.ts';
import { normalize, smGet, type Normalized } from '../_shared/sportmonks.ts';

const TOKEN = Deno.env.get('SPORTMONKS_TOKEN') ?? '';
const LEAGUES = Deno.env.get('LEAGUES') ?? '271'; // Superligaens id hos Sportmonks – tjek det i ID Finder
const INCLUDE = 'participants;scores;events;periods;state;round';

const sb = adminClient();

Deno.serve(async (req: Request) => {
  if (!authorized(req)) return json({ error: 'forbidden' }, 403);
  try {
    return json(TOKEN ? await runLive() : await runDemo());
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

async function existingRows(ids: number[]): Promise<Map<number, MatchRow>> {
  if (!ids.length) return new Map();
  const { data, error } = await sb.from('matches').select('*').in('id', ids);
  if (error) throw error;
  return new Map((data as MatchRow[]).map((r) => [Number(r.id), r]));
}

async function rpc(fn: string, args: Record<string, unknown>): Promise<number> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return Number(data ?? 0);
}

// Gemmer og afregner i den rigtige rækkefølge (se toppen af filen)
async function save(list: Normalized[], existing: Map<number, MatchRow>, now = Date.now()) {
  const modelFor = await loadModels(sb);
  const r = applyFixtures(list, existing, modelFor, now);
  if (r.rows.length) {
    const { error } = await sb.from('matches').upsert(r.rows);
    if (error) throw error;
  }
  let voidedLive = 0, settled = 0;
  for (const id of r.events) voidedLive += await rpc('void_recent_live', { p_match: id, p_seconds: LIVE_VOID_SECONDS });
  for (const g of r.ngSettle) settled += await rpc('settle_next_goal', { p_match: g.id, p_side: g.side, p_before: g.before });
  for (const id of r.voids) settled += await rpc('settle_void_match', { p_match: id });
  for (const id of r.settle) settled += await rpc('settle_match', { p_match: id });
  return { updated: r.rows.length, voidedLive, settledPicks: settled, voidedMatches: r.voids.length };
}

// ---------- Rigtige data ----------
async function runLive() {
  // Spar kald til Sportmonks: spørg kun, når der er en kamp i gang eller lige ved at starte.
  const now = Date.now();
  const soon = new Date(now + 10 * 60e3).toISOString();
  const recent = new Date(now - 3 * 3600e3).toISOString();
  const { data: active, error } = await sb
    .from('matches')
    .select('id,status,starts_at')
    .or(`status.eq.live,and(status.eq.scheduled,starts_at.lte."${soon}",starts_at.gte."${recent}")`);
  if (error) throw error;
  if (!active?.length) return { skipped: 'ingen kampe i gang' };

  const inplay = await smGet(`livescores/inplay?include=${INCLUDE}&filters=fixtureLeagues:${LEAGUES}`, TOKEN);
  const seen = new Set(inplay.map((f) => f.id));
  // Hent direkte: kampe, der var live, men ikke længere er i inplay (typisk slut),
  // og kampe, der skulle være startet for 10 minutter siden, men ikke er i gang (typisk udsat).
  const late = now - 10 * 60e3;
  const gone = active
    .filter((m) => !seen.has(Number(m.id)) && (m.status === 'live' || Date.parse(m.starts_at) < late))
    .map((m) => m.id);
  const extra = gone.length ? await smGet(`fixtures/multi/${gone.join(',')}?include=${INCLUDE}`, TOKEN) : [];
  const list = [...inplay, ...extra].map(normalize);
  return save(list, await existingRows(list.map((n) => n.id)), now);
}

// ---------- Demo-tilstand ----------
const DEMO = [
  { id: 9001, home: [101, 'OB'], away: [102, 'Randers FC'], offset: 0 },
  { id: 9002, home: [103, 'FC København'], away: [104, 'Brøndby IF'], offset: 30 },
  { id: 9003, home: [105, 'FC Midtjylland'], away: [106, 'AGF'], offset: 60 },
] as const;
const DEMO_UPCOMING = { id: 9004, home: [107, 'Viborg FF'], away: [108, 'Silkeborg IF'] } as const;
const demoBase = (id: number, home: readonly [number, string], away: readonly [number, string]) => ({
  id, leagueId: null, startsAt: null, stateId: null, homeId: home[0], awayId: away[0], home: home[1], away: away[1],
  voided: false, notStarted: false, roundKey: null, roundName: null,
});

async function runDemo() {
  const now = Date.now();
  const existing = await existingRows([...DEMO.map((d) => d.id), DEMO_UPCOMING.id]);
  const modelFor = await loadModels(sb);
  const list: Normalized[] = [];

  for (const d of DEMO) {
    const m = existing.get(d.id);
    const base = demoBase(d.id, d.home, d.away);
    // Ny eller færdig i mere end 5 minutter: start kampen forfra.
    if (!m || (m.status === 'finished' && Date.parse(m.updated_at) < now - 5 * 60e3)) {
      existing.delete(d.id);
      const row = preMatchRow({ ...base, gh: 0, ga: 0, minute: 0, finished: false, redsHome: 0, redsAway: 0 }, modelFor(null), now);
      const { error } = await sb.from('matches').upsert({ ...row, status: 'live', minute: d.offset, settled: false, starts_at: new Date(now - d.offset * 60e3).toISOString() });
      if (error) throw error;
      continue;
    }
    if (m.status === 'finished') continue;
    // Spil ét minut: mål og røde kort trækkes tilfældigt ud fra holdenes styrke.
    const minute = m.minute + 1;
    let { gh, ga, reds_home: rh, reds_away: ra } = m;
    if (Math.random() < Number(m.lh) / 90) gh++;
    else if (Math.random() < Number(m.la) / 90) ga++;
    else if (Math.random() < 0.004) Math.random() < 0.5 ? rh++ : ra++;
    list.push({ ...base, gh, ga, minute, finished: minute >= 90, redsHome: rh, redsAway: ra });
  }

  // En kommende kamp i morgen, så man også kan afgive kald før kampen.
  const up = existing.get(DEMO_UPCOMING.id);
  if (!up || up.status !== 'scheduled' || !up.starts_at || Date.parse(up.starts_at) < now + 3600e3) {
    const n: Normalized = {
      ...demoBase(DEMO_UPCOMING.id, DEMO_UPCOMING.home, DEMO_UPCOMING.away),
      startsAt: new Date(now + 864e5).toISOString(), stateId: 1,
      gh: 0, ga: 0, minute: 0, finished: false, redsHome: 0, redsAway: 0,
    };
    const { error } = await sb.from('matches').upsert({ ...preMatchRow(n, modelFor(null), now), settled: false });
    if (error) throw error;
  }

  existing.delete(DEMO_UPCOMING.id);
  return { demo: true, ...(await save(list, existing, now)) };
}
