-- Fases revistas com as conversas reais (25/11):
--   encaixe -> apresentacao -> decisao -> inscricao
-- A fase gravada e a MAIS AVANCADA que o lead ja atingiu: nunca volta atras.
-- O checklist acumula (item que ja foi verdadeiro continua verdadeiro).
-- objecao e situacao valem em qualquer fase.

alter table public.followup_leads drop constraint followup_leads_fase_check;
alter table public.followup_analises drop constraint followup_analises_fase_check;

update public.followup_leads set fase = case fase
  when 'descoberta' then 'encaixe'
  when 'encantamento' then 'apresentacao'
  when 'fechamento' then 'decisao'
  else fase end;
update public.followup_analises set fase = case fase
  when 'descoberta' then 'encaixe'
  when 'encantamento' then 'apresentacao'
  when 'fechamento' then 'decisao'
  else fase end;

alter table public.followup_leads alter column fase set default 'encaixe';
alter table public.followup_leads add constraint followup_leads_fase_check
  check (fase in ('encaixe', 'apresentacao', 'decisao', 'inscricao'));
alter table public.followup_analises add constraint followup_analises_fase_check
  check (fase in ('encaixe', 'apresentacao', 'decisao', 'inscricao'));

alter table public.followup_leads
  add column objecao text check (objecao in
    ('preco', 'horario_rotina', 'distancia_logistica', 'concorrente', 'terceiro_decide', 'pre_requisito', 'outra')),
  add column situacao text not null default 'em_andamento' check (situacao in
    ('em_andamento', 'pendencia_nossa', 'sem_turma'));
alter table public.followup_analises
  add column objecao text check (objecao in
    ('preco', 'horario_rotina', 'distancia_logistica', 'concorrente', 'terceiro_decide', 'pre_requisito', 'outra')),
  add column situacao text check (situacao in ('em_andamento', 'pendencia_nossa', 'sem_turma'));

comment on column public.followup_leads.fase is
  'Ponto mais avançado que o lead já atingiu (encaixe, apresentacao, decisao, inscricao). Nunca volta atrás.';
comment on column public.followup_leads.objecao is 'Objeção aberta no momento, ou null.';
comment on column public.followup_leads.situacao is
  'em_andamento | pendencia_nossa (lead esperando resposta do time) | sem_turma (curso sem turma ou inexistente).';

create or replace function public.registrar_analise(p_session_id text, p_versao timestamptz, p jsonb)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_lead public.followup_leads;
  v_decisao text := p->>'decisao';
  v_etapa smallint;
  v_prox timestamptz;
  v_status text;
  v_aplicar boolean;
  v_ordem constant text[] := array['encaixe', 'apresentacao', 'decisao', 'inscricao'];
  v_fase text;
  v_checklist jsonb;
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

  -- Fase mais avancada: so troca se a nova estiver a frente da atual.
  v_fase := case
    when p->>'fase' is null then v_lead.fase
    when coalesce(array_position(v_ordem, p->>'fase'), 0) > coalesce(array_position(v_ordem, v_lead.fase), 0)
      then p->>'fase'
    else v_lead.fase end;

  -- Checklist acumulado: OU logico item a item.
  v_checklist := case
    when jsonb_typeof(p->'checklist') is distinct from 'object' then v_lead.checklist
    else (
      select coalesce(jsonb_object_agg(k, coalesce((v_lead.checklist->>k)::boolean, false)
                                          or coalesce((p->'checklist'->>k)::boolean, false)), '{}'::jsonb)
      from (select jsonb_object_keys(v_lead.checklist) k
            union select jsonb_object_keys(p->'checklist')) ks
    ) end;

  insert into public.followup_analises
    (session_id, modo, etapa, origem, decisao, motivo, fase, checklist, resumo, mensagem_sugerida,
     horarios_oferecidos, agendar_para, alerta_vendedor, dentro_janela_24h, ultima_nossa_entregue,
     proximo_followup_at, aplicada, modelo, tokens_entrada, tokens_saida, erro, objecao, situacao)
  values
    (p_session_id, coalesce(p->>'modo','sombra'),
     case when v_decisao = 'enviar' then v_etapa else v_lead.etapa_regua + 1 end,
     p->>'origem', v_decisao, p->>'motivo', p->>'fase', p->'checklist', left(p->>'resumo', 300),
     p->>'mensagem_sugerida', p->'horarios_oferecidos', (p->>'agendar_para')::timestamptz,
     p->>'alerta_vendedor', (p->>'dentro_janela_24h')::boolean, (p->>'ultima_nossa_entregue')::boolean,
     v_prox, v_aplicar, p->>'modelo', (p->>'tokens_entrada')::int, (p->>'tokens_saida')::int, p->>'erro',
     p->>'objecao', p->>'situacao');

  if not v_aplicar then return false; end if;

  update public.followup_leads set
    fase = v_fase,
    checklist = v_checklist,
    resumo = coalesce(left(p->>'resumo', 300), resumo),
    objecao = case when p ? 'objecao' then p->>'objecao' else objecao end,
    situacao = coalesce(p->>'situacao', situacao),
    etapa_regua = v_etapa,
    status = v_status,
    proximo_followup_at = v_prox,
    -- Correcao de estado: o historico mostrou que o lead falou por ultimo.
    ultimo_autor = case when (p->>'lead_falou_por_ultimo')::boolean then 'lead' else ultimo_autor end,
    atualizado_em = clock_timestamp()
  where session_id = p_session_id;
  return true;
end $function$;
