// Pral – natlig opdatering
// Kører hver nat (pg_cron). Gør tre ting:
//   1. Regner holdenes styrke ud fra det seneste års resultater og gemmer den i teams og league_stats.
//   2. Henter kampene de næste 8 dage med runde og sætter odds før kampen.
//   3. Rydder op i kampe, der skulle være spillet, men stadig står som kommende (udsat, aflyst eller flyttet).
//
// Uden SPORTMONKS_TOKEN bruges en simuleret sæson, så demo-kampene får realistiske styrker.

import { adminClient, authorized, json, loadModels } from '../_shared/db.ts';
import { computeStrengths, type Result } from '../_shared/model.ts';
import { applyFixtures, preMatchRow, type MatchRow } from '../_shared/apply.ts';
import { FINISHED_STATES, NOT_STARTED, normalize, smGet } from '../_shared/sportmonks.ts';

const TOKEN = Deno.env.get('SPORTMONKS_TOKEN') ?? '';
const LEAGUES = Deno.env.get('LEAGUES') ?? '271';
const sb = adminClient();
const day = (d: Date) => d.toISOString().slice(0, 10);

Deno.serve(async (req: Request) => {
  if (!authorized(req)) return json({ error: 'forbidden' }, 403);
  try {
    const strength = await refreshStrength();
    const upcoming = TOKEN ? await refreshUpcoming() : { skipped: 'demo' };
    const stale = TOKEN ? await refreshStale() : { skipped: 'demo' };
    return json({ strength, upcoming, stale });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

async function refreshStrength() {
  // Resultater pr. liga, så hver liga får sit eget gennemsnit.
  const byLeague = new Map<number, Result[]>();
  const names = new Map<number, string>();
  if (TOKEN) {
    const to = new Date(), from = new Date(Date.now() - 365 * 864e5);
    const fixtures = await smGet(
      `fixtures/between/${day(from)}/${day(to)}?include=participants;scores&filters=fixtureLeagues:${LEAGUES}&per_page=50`,
      TOKEN, true,
    );
    for (const fx of fixtures) {
      if (!FINISHED_STATES.includes(fx.state_id)) continue;
      const n = normalize(fx);
      if (n.homeId == null || n.awayId == null) continue;
      names.set(n.homeId, n.home); names.set(n.awayId, n.away);
      const list = byLeague.get(n.leagueId ?? 0) ?? [];
      list.push({ homeId: n.homeId, awayId: n.awayId, gh: n.gh, ga: n.ga });
      byLeague.set(n.leagueId ?? 0, list);
    }
  } else {
    byLeague.set(0, mockSeason());
  }

  let teams = 0;
  for (const [leagueId, results] of byLeague) {
    const model = computeStrengths(results);
    const rows = Object.entries(model.teams).map(([id, t]) => ({
      id: Number(id), name: names.get(Number(id)) ?? null,
      attack_home: +t.attackHome.toFixed(4), defence_home: +t.defenceHome.toFixed(4),
      attack_away: +t.attackAway.toFixed(4), defence_away: +t.defenceAway.toFixed(4),
      games: t.games, updated_at: new Date().toISOString(),
    }));
    if (rows.length) {
      const { error } = await sb.from('teams').upsert(rows);
      if (error) throw error;
    }
    const { error } = await sb.from('league_stats').upsert({
      league_id: leagueId, avg_home: +model.avgHome.toFixed(4), avg_away: +model.avgAway.toFixed(4),
      matches: model.matches, updated_at: new Date().toISOString(),
    });
    if (error) throw error;
    teams += rows.length;
  }
  return { leagues: byLeague.size, teams };
}

async function refreshUpcoming() {
  const from = new Date(), to = new Date(Date.now() + 8 * 864e5);
  const fixtures = (await smGet(
    `fixtures/between/${day(from)}/${day(to)}?include=participants;state;round&filters=fixtureLeagues:${LEAGUES}&per_page=50`,
    TOKEN, true,
  )).filter((fx) => fx.state_id === NOT_STARTED).map(normalize);
  if (!fixtures.length) return { upcoming: 0 };

  // Rør ikke kampe, der allerede er i gang eller slut.
  const { data: known, error } = await sb.from('matches').select('id,status').in('id', fixtures.map((f) => f.id));
  if (error) throw error;
  const started = new Set((known || []).filter((k) => k.status !== 'scheduled').map((k) => Number(k.id)));

  const modelFor = await loadModels(sb);
  const rows = fixtures.filter((f) => !started.has(f.id)).map((f) => preMatchRow(f, modelFor(f.leagueId)));
  if (rows.length) {
    const { error: e } = await sb.from('matches').upsert(rows);
    if (e) throw e;
  }
  return { upcoming: rows.length };
}

// Simuleret sæson til demo-holdene 101–108 med forskellig styrke.
function mockSeason(): Result[] {
  const power: Record<number, number> = { 101: 1.0, 102: 0.9, 103: 1.35, 104: 1.1, 105: 1.3, 106: 1.0, 107: 0.95, 108: 1.05 };
  const pois = (l: number) => { let k = 0, p = Math.exp(-l), s = p; const u = Math.random(); while (u > s) { k++; p *= l / k; s += p; } return k; };
  const ids = Object.keys(power).map(Number), out: Result[] = [];
  for (let r = 0; r < 2; r++) for (const h of ids) for (const a of ids) if (h !== a) {
    out.push({ homeId: h, awayId: a, gh: pois(1.5 * power[h] / power[a]), ga: pois(1.2 * power[a] / power[h]) });
  }
  return out;
}

// Kampe, der stadig står som kommende, selvom de skulle være startet for over 3 timer siden.
// Udsat eller aflyst: kald annulleres. Flyttet: nyt tidspunkt. Spillet: afregnes.
async function refreshStale() {
  const { data, error } = await sb.from('matches').select('*').eq('status', 'scheduled')
    .lt('starts_at', new Date(Date.now() - 3 * 3600e3).toISOString()).gte('id', 0);
  if (error) throw error;
  const rows = (data || []) as MatchRow[];
  if (!rows.length) return { stale: 0 };
  const existing = new Map(rows.map((r) => [Number(r.id), r]));
  const fixtures: Record<string, unknown>[] = [];
  for (let i = 0; i < rows.length; i += 50) {
    const ids = rows.slice(i, i + 50).map((r) => r.id).join(',');
    fixtures.push(...(await smGet(`fixtures/multi/${ids}?include=participants;scores;events;periods;state;round`, TOKEN)));
  }
  const modelFor = await loadModels(sb);
  const r = applyFixtures(fixtures.map(normalize), existing, modelFor);
  if (r.rows.length) {
    const { error: e } = await sb.from('matches').upsert(r.rows);
    if (e) throw e;
  }
  for (const id of r.voids) { const { error: e } = await sb.rpc('settle_void_match', { p_match: id }); if (e) throw e; }
  for (const id of r.settle) { const { error: e } = await sb.rpc('settle_match', { p_match: id }); if (e) throw e; }
  return { stale: rows.length, voided: r.voids.length, settled: r.settle.length };
}
