// Pral – odds-model og holdstyrke
// Samme matematik som i udviklerpakken (model.js og strength.js), bare skrevet til Supabase Edge Functions.

export type Probs = [number, number, number]; // chance for 1, X og 2

export interface MatchState {
  lh: number; // forventede mål hjemme på 90 minutter
  la: number; // forventede mål ude på 90 minutter
  minute: number;
  gh: number;
  ga: number;
  redsHome?: number;
  redsAway?: number;
}

function pois(k: number, l: number): number {
  let p = Math.exp(-l);
  for (let i = 1; i <= k; i++) p *= l / i;
  return p;
}

// Røde kort svækker holdet (×0,7) og styrker modstanderen (×1,15).
function effectiveStrength(m: MatchState) {
  const lh = m.lh * Math.pow(0.7, m.redsHome || 0) * Math.pow(1.15, m.redsAway || 0);
  const la = m.la * Math.pow(0.7, m.redsAway || 0) * Math.pow(1.15, m.redsHome || 0);
  return { lh, la };
}

// Chancen for 1, X og 2 ud fra stillingen og den tid, der er tilbage.
export function probs(m: MatchState): Probs {
  const { lh, la } = effectiveStrength(m);
  const left = Math.max(0, (90 - Math.min(m.minute || 0, 90)) / 90);
  const a = lh * left, b = la * left;
  let H = 0, D = 0, A = 0;
  for (let x = 0; x <= 10; x++) {
    const px = pois(x, a);
    for (let y = 0; y <= 10; y++) {
      const p = px * pois(y, b);
      const d = (m.gh + x) - (m.ga + y);
      if (d > 0) H += p; else if (d === 0) D += p; else A += p;
    }
  }
  const s = H + D + A;
  return [H / s, D / s, A / s];
}

// Næste mål: chancen for at hjemmeholdet scorer næste mål, at der ikke kommer flere mål, og at udeholdet scorer.
export function nextGoalProbs(m: MatchState): Probs {
  const { lh, la } = effectiveStrength(m);
  const left = Math.max(0, (90 - Math.min(m.minute || 0, 90)) / 90);
  const a = lh * left, b = la * left, l = a + b, none = Math.exp(-l);
  return l > 0 ? [a / l * (1 - none), none, b / l * (1 - none)] : [0, 1, 0];
}

// Odds = 1 ÷ chance. Ingen margin. Gulv 1,01 og loft 50.
export function toOdds(p: Probs): [number, number, number] {
  return p.map((x) => +Math.min(50, Math.max(1.01, 1 / Math.max(x, 0.0001))).toFixed(2)) as [number, number, number];
}

// ---------- Holdstyrke ----------
export interface Result { homeId: number; awayId: number; gh: number; ga: number }
export interface TeamStrength { attackHome: number; defenceHome: number; attackAway: number; defenceAway: number; games: number }
export interface StrengthModel { avgHome: number; avgAway: number; teams: Record<string, TeamStrength>; matches: number }

const PRIOR = 5; // hold med få kampe trækkes mod ligaens gennemsnit

export function computeStrengths(results: Result[]): StrengthModel {
  const n = results.length || 1;
  const avgHome = results.reduce((s, r) => s + r.gh, 0) / n || 1.5;
  const avgAway = results.reduce((s, r) => s + r.ga, 0) / n || 1.2;
  const t: Record<string, { hp: number; hs: number; hc: number; ap: number; as: number; ac: number }> = {};
  const get = (id: number) => (t[id] ||= { hp: 0, hs: 0, hc: 0, ap: 0, as: 0, ac: 0 });
  for (const r of results) {
    const h = get(r.homeId), a = get(r.awayId);
    h.hp++; h.hs += r.gh; h.hc += r.ga;
    a.ap++; a.as += r.ga; a.ac += r.gh;
  }
  const shrink = (goals: number, games: number, avg: number) => (goals + PRIOR * avg) / (games + PRIOR) / avg;
  const teams: Record<string, TeamStrength> = {};
  for (const [id, x] of Object.entries(t)) {
    teams[id] = {
      attackHome: shrink(x.hs, x.hp, avgHome),
      defenceHome: shrink(x.hc, x.hp, avgAway),
      attackAway: shrink(x.as, x.ap, avgAway),
      defenceAway: shrink(x.ac, x.ap, avgHome),
      games: x.hp + x.ap,
    };
  }
  return { avgHome, avgAway, teams, matches: results.length };
}

// Forventede mål på 90 minutter. Ukendte hold (fx nyoprykkere) får ligaens gennemsnit.
export function expectedGoals(model: StrengthModel | null, homeId?: number | null, awayId?: number | null) {
  const avg: TeamStrength = { attackHome: 1, defenceHome: 1, attackAway: 1, defenceAway: 1, games: 0 };
  const h = (model && homeId != null && model.teams[homeId]) || avg;
  const a = (model && awayId != null && model.teams[awayId]) || avg;
  const base = model || { avgHome: 1.5, avgAway: 1.2 };
  return {
    lh: +(base.avgHome * h.attackHome * a.defenceAway).toFixed(3),
    la: +(base.avgAway * a.attackAway * h.defenceHome).toFixed(3),
  };
}
