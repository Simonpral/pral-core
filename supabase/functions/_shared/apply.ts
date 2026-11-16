// Pral – opdatér kampe ud fra nye data og regn odds ud
// Ren logik uden database, så den kan testes. Edge-funktionerne sørger for at læse og skrive.

import { expectedGoals, nextGoalProbs, probs, toOdds, type StrengthModel } from './model.ts';
import type { Normalized } from './sportmonks.ts';

export const LOCK_MS = 20_000;        // kald låses 20 sekunder efter mål og røde kort
export const NG_CONFIRM_MS = 120_000; // næste mål afgøres først, når målet har stået i 2 minutter (VAR)
export const LIVE_VOID_SECONDS = 40;  // live-kald lagt så kort før et mål eller rødt kort annulleres

export interface PendingGoal { side: 0 | 2; at: string; gh: number; ga: number }
export interface Result {
  rows: MatchRow[];
  settle: number[];                                       // kampe, der skal afregnes (slutfløjt)
  voids: number[];                                        // kampe, der er udsat eller aflyst
  events: number[];                                       // kampe med mål eller rødt kort lige nu
  ngSettle: { id: number; side: 0 | 2; before: string }[]; // bekræftede mål til næste mål
}

export interface FeedItem { minute: number; text: string }

// Rækken, som den ligger i tabellen public.matches
export interface MatchRow {
  id: number;
  league_id: number | null;
  starts_at: string | null;
  status: 'scheduled' | 'live' | 'finished' | 'void';
  home: string;
  away: string;
  home_id: number | null;
  away_id: number | null;
  minute: number;
  gh: number;
  ga: number;
  reds_home: number;
  reds_away: number;
  lh: number;
  la: number;
  round_key?: string | null;
  round_name?: string | null;
  ng_pending?: PendingGoal[];
  odds: number[];
  ng_odds?: number[] | null;
  history?: number[][];
  prev_odds: number[] | null;
  chance: number[] | null;
  lock_until: string | null;
  feed: FeedItem[];
  settled?: boolean;
  updated_at: string;
}

// Beregner de nye rækker. Returnerer rækker til upsert og de kampe, der skal afregnes.
export function applyFixtures(
  list: Normalized[],
  existing: Map<number, MatchRow>,
  modelFor: (leagueId: number | null) => StrengthModel | null,
  now = Date.now(),
): Result {
  const rows: MatchRow[] = [];
  const settle: number[] = [], voids: number[] = [], events: number[] = [];
  const ngSettle: Result['ngSettle'] = [];
  const nowIso = new Date(now).toISOString();

  for (const n of list) {
    const m = existing.get(n.id);
    if (m && (m.status === 'finished' || m.status === 'void')) {
      if (m.status === 'finished' && !m.settled) settle.push(n.id);
      continue; // færdig kamp: intet nyt at regne på
    }
    // Udsat eller aflyst: annullér alle kald
    if (n.voided) { if (m) voids.push(n.id); continue; }
    // Ikke startet alligevel (fx flyttet): opdatér kun tidspunktet
    if (n.notStarted) {
      if (m && m.status === 'scheduled' && n.startsAt && n.startsAt !== m.starts_at) rows.push({ ...m, starts_at: n.startsAt, updated_at: nowIso });
      continue;
    }

    // Holdenes styrke ligger fast fra kampstart. Ny kamp: slå den op.
    const xg = m ? { lh: Number(m.lh), la: Number(m.la) } : expectedGoals(modelFor(n.leagueId), n.homeId, n.awayId);
    let feed: FeedItem[] = m ? [...(m.feed || [])] : [];
    let lockUntil = m ? m.lock_until : null;
    let pending: PendingGoal[] = m ? [...(m.ng_pending || [])] : [];

    if (m) {
      const what =
        n.gh > m.gh ? `Mål til ${n.home}` :
        n.ga > m.ga ? `Mål til ${n.away}` :
        n.gh < m.gh || n.ga < m.ga ? 'Mål annulleret' :
        n.redsHome > m.reds_home ? `Rødt kort til ${n.home}` :
        n.redsAway > m.reds_away ? `Rødt kort til ${n.away}` : null;
      if (what && !what.startsWith('Mål annulleret')) events.push(n.id);
      // Et mål lægges i kø og afgør først næste mål, når det har stået i 2 minutter.
      if (n.gh > m.gh) pending.push({ side: 0, at: nowIso, gh: n.gh, ga: n.ga });
      else if (n.ga > m.ga) pending.push({ side: 2, at: nowIso, gh: n.gh, ga: n.ga });
      if (what) {
        lockUntil = new Date(now + LOCK_MS).toISOString();
        feed.unshift({ minute: n.minute, text: `${what}. Stillingen er ${n.gh}–${n.ga}` });
      }
    }
    if (n.finished) feed.unshift({ minute: Math.max(90, n.minute), text: `Slutfløjt. Kampen endte ${n.gh}–${n.ga}` });
    feed = feed.slice(0, 10);

    // Mål i køen: annulleret (stillingen er gået ned igen) → fjernes. Stået i 2 min. eller slutfløjt → afgøres.
    pending = pending.filter((g) => (g.side === 0 ? n.gh >= g.gh : n.ga >= g.ga));
    const ready = pending.filter((g) => n.finished || now - Date.parse(g.at) >= NG_CONFIRM_MS);
    for (const g of ready) ngSettle.push({ id: n.id, side: g.side, before: g.at });
    pending = pending.filter((g) => !ready.includes(g));

    const state = { lh: xg.lh, la: xg.la, minute: n.minute, gh: n.gh, ga: n.ga, redsHome: n.redsHome, redsAway: n.redsAway };
    const chance = probs(state);
    // Chancen minut for minut, så appen kan tegne grafen. Ét punkt pr. minut; sidste punkt i samme minut overskrives.
    const history = [...(m?.history || [])];
    const point = [Math.min(n.minute, 90), ...chance.map((x) => +x.toFixed(3))];
    if (history.length && history[history.length - 1][0] === point[0]) history[history.length - 1] = point;
    else history.push(point);
    rows.push({
      id: n.id,
      league_id: n.leagueId ?? m?.league_id ?? null,
      starts_at: n.startsAt ?? m?.starts_at ?? null,
      status: n.finished ? 'finished' : 'live',
      home: n.home,
      away: n.away,
      home_id: n.homeId,
      away_id: n.awayId,
      round_key: n.roundKey ?? m?.round_key ?? null,
      round_name: n.roundName ?? m?.round_name ?? null,
      ng_pending: pending,
      minute: n.minute,
      gh: n.gh,
      ga: n.ga,
      reds_home: n.redsHome,
      reds_away: n.redsAway,
      lh: xg.lh,
      la: xg.la,
      odds: toOdds(chance),
      ng_odds: n.finished ? null : toOdds(nextGoalProbs(state)),
      history: history.slice(-130),
      prev_odds: m ? m.odds.map(Number) : null,
      chance: chance.map((x) => +x.toFixed(4)),
      lock_until: lockUntil,
      feed,
      updated_at: nowIso,
    });
    if (n.finished) settle.push(n.id);
  }
  return { rows, settle, voids, events, ngSettle };
}

// Odds før kampen (bruges af nightly til kommende kampe)
export function preMatchRow(n: Normalized, model: StrengthModel | null, now = Date.now()): MatchRow {
  const xg = expectedGoals(model, n.homeId, n.awayId);
  const chance = probs({ ...xg, minute: 0, gh: 0, ga: 0 });
  return {
    id: n.id, league_id: n.leagueId, starts_at: n.startsAt, status: 'scheduled',
    round_key: n.roundKey, round_name: n.roundName, ng_pending: [],
    home: n.home, away: n.away, home_id: n.homeId, away_id: n.awayId,
    minute: 0, gh: 0, ga: 0, reds_home: 0, reds_away: 0,
    lh: xg.lh, la: xg.la, odds: toOdds(chance), prev_odds: null,
    chance: chance.map((x) => +x.toFixed(4)), ng_odds: null, history: [], lock_until: null, feed: [],
    updated_at: new Date(now).toISOString(),
  };
}
