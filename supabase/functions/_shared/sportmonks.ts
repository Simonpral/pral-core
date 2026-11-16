// Pral – hent og oversæt data fra Sportmonks API v3
// Feltnavnene følger Sportmonks v3. Tjek dem mod deres dokumentation, før I går live.

export const GOAL = 14, RED = 20, YELLOW_RED = 21;
export const FINISHED_STATES = [5, 7, 8]; // fuld tid, efter forlænget, efter straffe
export const NOT_STARTED = 1;
// Kampe, der er udsat, aflyst eller afbrudt for altid. Kald på dem annulleres.
// Navnene kommer med include=state. Tjek id'erne mod Sportmonks' liste over states, før I går live.
export const VOID_STATE_NAMES = ['POSTPONED', 'CANCELLED', 'ABANDONED', 'DELETED', 'WO', 'AWARDED'];
export const VOID_STATE_IDS = [10, 12, 14, 15, 17, 20];

export interface Normalized {
  id: number;
  leagueId: number | null;
  startsAt: string | null;
  stateId: number | null;
  homeId: number | null;
  awayId: number | null;
  home: string;
  away: string;
  gh: number;
  ga: number;
  minute: number;
  finished: boolean;
  voided: boolean;     // udsat eller aflyst
  notStarted: boolean; // ikke startet endnu (fx flyttet til senere)
  roundKey: string | null;
  roundName: string | null;
  redsHome: number;
  redsAway: number;
}

// deno-lint-ignore no-explicit-any
type Fixture = any;

export function normalize(fx: Fixture): Normalized {
  const parts = fx.participants || [];
  // deno-lint-ignore no-explicit-any
  const home = parts.find((p: any) => p.meta && p.meta.location === 'home') || parts[0] || {};
  // deno-lint-ignore no-explicit-any
  const away = parts.find((p: any) => p.meta && p.meta.location === 'away') || parts[1] || {};
  // deno-lint-ignore no-explicit-any
  const current = (fx.scores || []).filter((s: any) => s.description === 'CURRENT');
  const goals = (side: string) => {
    // deno-lint-ignore no-explicit-any
    const s = current.find((x: any) => x.score && x.score.participant === side);
    return s ? s.score.goals : 0;
  };
  const periods = fx.periods || [];
  // deno-lint-ignore no-explicit-any
  const period = periods.find((p: any) => p.ticking) || periods[periods.length - 1];
  // deno-lint-ignore no-explicit-any
  const reds = (fx.events || []).filter((e: any) => e.type_id === RED || e.type_id === YELLOW_RED);
  const startsAt = fx.starting_at_timestamp
    ? new Date(fx.starting_at_timestamp * 1000).toISOString()
    : fx.starting_at ? new Date(fx.starting_at.replace(' ', 'T') + 'Z').toISOString() : null;
  return {
    id: fx.id,
    leagueId: fx.league_id ?? null,
    startsAt,
    stateId: fx.state_id ?? null,
    homeId: home.id ?? null,
    awayId: away.id ?? null,
    home: home.name ?? 'Hjemmehold',
    away: away.name ?? 'Udehold',
    gh: goals('home'),
    ga: goals('away'),
    minute: period && period.minutes != null ? period.minutes : 0,
    finished: FINISHED_STATES.includes(fx.state_id),
    voided: VOID_STATE_NAMES.includes(fx.state?.developer_name ?? fx.state?.state ?? '') || (!fx.state && VOID_STATE_IDS.includes(fx.state_id)),
    notStarted: fx.state_id === NOT_STARTED,
    roundKey: fx.round_id ? `R${fx.round_id}` : null,
    roundName: fx.round?.name ? `Runde ${fx.round.name}` : null,
    // deno-lint-ignore no-explicit-any
    redsHome: reds.filter((e: any) => e.participant_id === home.id).length,
    // deno-lint-ignore no-explicit-any
    redsAway: reds.filter((e: any) => e.participant_id === away.id).length,
  };
}

// Henter én side eller alle sider (følger pagination) fra Sportmonks.
export async function smGet(path: string, token: string, allPages = false): Promise<Fixture[]> {
  const out: Fixture[] = [];
  let url: string | null = `https://api.sportmonks.com/v3/football/${path}${path.includes('?') ? '&' : '?'}api_token=${token}`;
  while (url) {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Sportmonks svarede ${res.status} på ${path}`);
    const json = await res.json();
    const data = json.data;
    if (Array.isArray(data)) out.push(...data); else if (data) out.push(data);
    const p = json.pagination;
    url = allPages && p && p.has_more && p.next_page
      ? p.next_page + (p.next_page.includes('api_token') ? '' : `&api_token=${token}`)
      : null;
  }
  return out;
}
