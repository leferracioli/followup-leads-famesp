-- Etiqueta no contato do Front indicando a acao pendente do vendedor ("FUP - ...").
-- Liga/desliga em followup_config.etiqueta_ligada. So uma etiqueta FUP por lead.

alter table public.followup_leads add column etiqueta_fup text;
alter table public.followup_analises add column etiqueta text;

insert into public.followup_config (chave, valor) values ('etiqueta_ligada', 'false')
on conflict (chave) do nothing;

-- p_etiqueta: nome da etiqueta aplicada, ou null quando foi removida.
-- p_status: 'aplicada' | 'removida' | 'desligada' | 'erro'.
create or replace function public.registrar_etiqueta(p_session_id text, p_etiqueta text, p_status text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.followup_analises
     set etiqueta = case p_status when 'aplicada' then p_etiqueta else p_status end
   where id = (select max(id) from public.followup_analises where session_id = p_session_id);

  if p_status in ('aplicada', 'removida') then
    update public.followup_leads set etiqueta_fup = p_etiqueta where session_id = p_session_id;
  end if;
end $function$;

revoke all on function public.registrar_etiqueta(text, text, text) from public, anon, authenticated;
