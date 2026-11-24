-- Upsert do estado do lead a cada mensagem (aplicada em 24/11/2026).
-- Ignora evento que chega fora de ordem e grava o vendedor dono da mensagem.

drop function if exists public.registrar_mensagem(text, text, text, text, timestamptz);

create or replace function public.registrar_mensagem(
  p_session_id text, p_telefone text, p_lead_nome text, p_autor text, p_msg_at timestamptz, p_vendedor_id text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_venc timestamptz;
begin
  if p_autor = 'vendedor' then
    v_venc := public.proximo_horario_comercial(p_msg_at + interval '2 hours');
  end if;

  insert into public.followup_leads as f
    (session_id, telefone, lead_nome, vendedor_id, ultimo_autor, ultima_msg_lead_at, ultima_msg_nossa_at, proximo_followup_at)
  values
    (p_session_id, p_telefone, p_lead_nome, p_vendedor_id, p_autor,
     case when p_autor = 'lead' then p_msg_at end,
     case when p_autor = 'vendedor' then p_msg_at end,
     v_venc)
  on conflict (session_id) do update set
    telefone = coalesce(f.telefone, excluded.telefone),
    lead_nome = coalesce(f.lead_nome, excluded.lead_nome),
    vendedor_id = coalesce(excluded.vendedor_id, f.vendedor_id),
    ultima_msg_lead_at = greatest(f.ultima_msg_lead_at, excluded.ultima_msg_lead_at),
    ultima_msg_nossa_at = greatest(f.ultima_msg_nossa_at, excluded.ultima_msg_nossa_at),
    ultimo_autor = case when p_msg_at >= coalesce(greatest(f.ultima_msg_lead_at, f.ultima_msg_nossa_at), '-infinity'::timestamptz)
                        then excluded.ultimo_autor else f.ultimo_autor end,
    proximo_followup_at = case when p_msg_at >= coalesce(greatest(f.ultima_msg_lead_at, f.ultima_msg_nossa_at), '-infinity'::timestamptz)
                        then excluded.proximo_followup_at else f.proximo_followup_at end,
    etapa_regua = case when p_autor = 'lead' and p_msg_at >= coalesce(greatest(f.ultima_msg_lead_at, f.ultima_msg_nossa_at), '-infinity'::timestamptz)
                        then 0 else f.etapa_regua end,
    atualizado_em = now();
end $$;

revoke execute on function public.registrar_mensagem(text, text, text, text, timestamptz, text) from public, anon, authenticated;
