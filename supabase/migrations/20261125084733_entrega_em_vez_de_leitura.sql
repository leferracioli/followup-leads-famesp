-- A confirmacao de leitura do WhatsApp nao e confiavel; a varredura passa a olhar a ENTREGA (25/11/2026).
alter table public.followup_analises rename column ultima_nossa_lida to ultima_nossa_entregue;

create or replace function public.registrar_analise(p_session_id text, p_versao timestamptz, p jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_lead public.followup_leads;
  v_decisao text := p->>'decisao';
  v_etapa smallint;
  v_prox timestamptz;
  v_status text;
  v_aplicar boolean;
begin
  select * into v_lead from public.followup_leads where session_id = p_session_id for update;
  if not found then return false; end if;
  v_aplicar := v_lead.atualizado_em = p_versao;
  v_etapa := v_lead.etapa_regua;
  v_status := v_lead.status;

  if v_decisao = 'enviar' then
    -- Regua: F1 -> F2 no dia util seguinte -> F3 tres dias depois -> repescagem.
    -- Em modo sombra a regua tambem anda ("regua fantasma"), para calibrar F2 e F3.
    v_etapa := v_lead.etapa_regua + 1;
    if v_etapa = 1 then
      v_prox := public.proximo_horario_comercial(now() + interval '1 day');
    elsif v_etapa = 2 then
      v_prox := public.proximo_horario_comercial(now() + interval '3 days');
    else
      v_prox := null;
      v_status := 'repescagem';
    end if;
  elsif v_decisao = 'agendar' then
    v_prox := public.proximo_horario_comercial(coalesce((p->>'agendar_para')::timestamptz, now() + interval '1 day'));
  elsif v_decisao = 'aguardar' then
    v_prox := case when p ? 'proximo_followup_at'
                   then (p->>'proximo_followup_at')::timestamptz
                   else public.proximo_horario_comercial(now() + interval '3 hours') end;
  elsif v_decisao = 'avisar_vendedor' then
    v_prox := null;   -- volta a contar quando o vendedor escrever de novo
  elsif v_decisao = 'optout' then
    v_prox := null;
    v_status := 'optout';
  end if;

  insert into public.followup_analises
    (session_id, modo, etapa, origem, decisao, motivo, fase, checklist, resumo, mensagem_sugerida,
     horarios_oferecidos, agendar_para, alerta_vendedor, dentro_janela_24h, ultima_nossa_entregue,
     proximo_followup_at, aplicada, modelo, tokens_entrada, tokens_saida, erro)
  values
    (p_session_id, coalesce(p->>'modo','sombra'),
     case when v_decisao = 'enviar' then v_etapa else v_lead.etapa_regua + 1 end,
     p->>'origem', v_decisao, p->>'motivo', p->>'fase', p->'checklist', left(p->>'resumo', 300),
     p->>'mensagem_sugerida', p->'horarios_oferecidos', (p->>'agendar_para')::timestamptz,
     p->>'alerta_vendedor', (p->>'dentro_janela_24h')::boolean, (p->>'ultima_nossa_entregue')::boolean,
     v_prox, v_aplicar, p->>'modelo', (p->>'tokens_entrada')::int, (p->>'tokens_saida')::int, p->>'erro');

  if not v_aplicar then return false; end if;

  update public.followup_leads set
    fase = coalesce(p->>'fase', fase),
    checklist = coalesce(p->'checklist', checklist),
    resumo = coalesce(left(p->>'resumo', 300), resumo),
    etapa_regua = v_etapa,
    status = v_status,
    proximo_followup_at = v_prox,
    -- Correcao de estado: o historico mostrou que o lead falou por ultimo.
    ultimo_autor = case when (p->>'lead_falou_por_ultimo')::boolean then 'lead' else ultimo_autor end,
    atualizado_em = clock_timestamp()
  where session_id = p_session_id;
  return true;
end $$;

revoke execute on function public.registrar_analise(text, timestamptz, jsonb) from public, anon, authenticated;
