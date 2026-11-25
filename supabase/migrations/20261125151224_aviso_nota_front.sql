-- Aviso ao vendedor por nota interna na conversa do Front (o lead nao ve).
-- Liga/desliga em followup_config.aviso_nota_ligado; nao repete o aviso antes de
-- aviso_repetir_dias, a nao ser que o lead tenha escrito algo depois do ultimo aviso.

alter table public.followup_leads
  add column ultimo_aviso_at timestamptz,
  add column ultimo_aviso_texto text;

alter table public.followup_analises
  add column aviso_nota text check (aviso_nota in ('postada', 'repetida', 'desligada', 'erro'));

insert into public.followup_config (chave, valor) values
  ('aviso_nota_ligado', 'false'),
  ('aviso_repetir_dias', '3')
on conflict (chave) do nothing;

-- Marca o resultado do aviso na analise mais recente da sessao e, se postado, no lead.
create or replace function public.registrar_aviso(p_session_id text, p_status text, p_texto text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.followup_analises set aviso_nota = p_status
  where id = (select max(id) from public.followup_analises where session_id = p_session_id);

  if p_status = 'postada' then
    update public.followup_leads
       set ultimo_aviso_at = now(), ultimo_aviso_texto = left(p_texto, 1000)
     where session_id = p_session_id;
  end if;
end $function$;

revoke all on function public.registrar_aviso(text, text, text) from public, anon, authenticated;
