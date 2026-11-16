// Pral – fælles opsætning for Edge Functions: adgang til databasen og tjek af hemmelig nøgle

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.45.4';
import type { StrengthModel } from './model.ts';

// SUPABASE_URL og SUPABASE_SERVICE_ROLE_KEY sætter Supabase selv i alle Edge Functions.
export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });
}

// Kun timeren (pg_cron) kender CRON_SECRET. Alle andre kald afvises.
export function authorized(req: Request): boolean {
  const secret = Deno.env.get('CRON_SECRET') ?? '';
  return secret.length >= 20 && req.headers.get('x-cron-secret') === secret;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

// Henter holdstyrke fra tabellerne teams og league_stats.
export async function loadModels(sb: SupabaseClient): Promise<(leagueId: number | null) => StrengthModel | null> {
  const [{ data: teams, error: e1 }, { data: leagues, error: e2 }] = await Promise.all([
    sb.from('teams').select('*'),
    sb.from('league_stats').select('*'),
  ]);
  if (e1 || e2) throw e1 || e2;
  const teamMap: StrengthModel['teams'] = {};
  for (const t of teams || []) {
    teamMap[t.id] = {
      attackHome: Number(t.attack_home), defenceHome: Number(t.defence_home),
      attackAway: Number(t.attack_away), defenceAway: Number(t.defence_away), games: t.games,
    };
  }
  const byLeague = new Map((leagues || []).map((l) => [Number(l.league_id), l]));
  return (leagueId) => {
    const l = (leagueId != null && byLeague.get(Number(leagueId))) || (leagues || [])[0];
    if (!l) return null;
    return { avgHome: Number(l.avg_home), avgAway: Number(l.avg_away), teams: teamMap, matches: l.matches };
  };
}
