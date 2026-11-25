-- Agenda a varredura de hora em hora e a limpeza diaria (24/11/2026).
-- O token da varredura e lido de followup_config na hora da chamada: nao fica no repositorio nem no cron.

create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function public.disparar_varredura()
returns bigint language sql security definer set search_path = public as $$
  select net.http_post(
    url := 'https://tkcshzndaztfykkraprp.supabase.co/functions/v1/followup-varredura',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-varredura-token', (select valor from public.followup_config where chave = 'varredura_token')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  );
$$;
revoke execute on function public.disparar_varredura() from public, anon, authenticated;

-- Seg a sab, das 8h05 as 19h05 de Sao Paulo (UTC-3 => 11h05 a 22h05 UTC).
select cron.schedule('followup-varredura', '5 11-22 * * 1-6', $$select public.disparar_varredura()$$);

-- Limpeza diaria as 3h de Sao Paulo (6h UTC).
select cron.schedule('followup-limpeza', '0 6 * * *', $$select public.limpar_followup_antigo()$$);
