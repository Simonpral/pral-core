-- Pral – timere (pg_cron)
-- Kør denne fil i Supabase → SQL Editor, EFTER at de to Edge Functions er lagt op.
--
-- Før I kører den:
--   1. Slå udvidelserne pg_cron og pg_net til under Database → Extensions.
--   2. Erstat de to værdier herunder:
--        DIT-PROJEKT-ID  → står i Project URL, fx https://abcdefgh.supabase.co → abcdefgh
--        DIN-CRON-NØGLE  → den samme lange tilfældige tekst, som I har gemt som CRON_SECRET
--                          under Edge Functions → Secrets (mindst 20 tegn, gem den i Bitwarden)
--   Værdierne gemmes krypteret i Supabase Vault, så de ikke står i klartekst i timerne.

select vault.create_secret('https://DIT-PROJEKT-ID.supabase.co', 'pral_project_url');
select vault.create_secret('DIN-CRON-NØGLE', 'pral_cron_secret');

-- Hjælper, der kalder en Edge Function med den hemmelige nøgle
create or replace function public.pral_call(fn text)
returns bigint language sql security definer set search_path = '' as $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'pral_project_url') || '/functions/v1/' || fn,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'pral_cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 20000
  )
$$;
revoke execute on function public.pral_call(text) from public, anon, authenticated;

-- Live-odds hvert 20. sekund. Uden kampe i gang spørger funktionen ikke Sportmonks,
-- så den bruger kun af Sportmonks-kvoten (180 kald i timen på gratisplanen), når der spilles.
select cron.schedule('pral-live-odds', '20 seconds', $$ select public.pral_call('live-odds') $$);

-- Holdstyrke og kommende kampe hver nat kl. 03:15 UTC (04:15 dansk vintertid)
select cron.schedule('pral-nightly', '15 3 * * *', $$ select public.pral_call('nightly') $$);

-- Nyttigt:
--   select * from cron.job;                                   -- se timerne
--   select * from cron.job_run_details order by start_time desc limit 20;  -- se de seneste kørsler
--   select * from net._http_response order by created desc limit 20;       -- se svarene fra funktionerne
--   select cron.unschedule('pral-live-odds');                 -- stop live-odds
