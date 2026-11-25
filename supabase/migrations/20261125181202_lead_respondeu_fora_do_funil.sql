-- Ajustes da leitura da semana (25/11):
-- 1) Mensagem do lead agenda uma checagem 1h util depois: se ninguem respondeu, vira
--    "pendencia nossa" (etiqueta Responder lead). Antes, mensagem do lead nao gerava analise.
-- 2) Nova decisao 'encerrar' com situacoes ja_matriculado, fora_do_funil e lead_frio.
-- 3) Lead encerrado volta a ativo quando escreve de novo.
-- 4) Status da sessao no Front guardado para o card do painel esconder conversas encerradas.

alter table public.followup_analises drop constraint followup_analises_decisao_check;
alter table public.followup_analises add constraint followup_analises_decisao_check
  check (decisao in ('enviar', 'agendar', 'avisar_vendedor', 'aguardar', 'optout', 'encerrar'));

alter table public.followup_leads drop constraint followup_leads_situacao_check;
alter table public.followup_leads add constraint followup_leads_situacao_check
  check (situacao in ('em_andamento', 'pendencia_nossa', 'sem_turma', 'sem_conversa',
                      'ja_matriculado', 'fora_do_funil', 'lead_frio'));
alter table public.followup_analises drop constraint followup_analises_situacao_check;
alter table public.followup_analises add constraint followup_analises_situacao_check
  check (situacao in ('em_andamento', 'pendencia_nossa', 'sem_turma', 'sem_conversa',
                      'ja_matriculado', 'fora_do_funil', 'lead_frio'));

alter table public.followup_leads add column sessao_status text;

insert into public.followup_config (chave, valor) values
  ('dias_max_sem_lead', '60'),
  ('modelo_transcricao', 'gpt-4o-transcribe')
on conflict (chave) do nothing;

create or replace function public.registrar_mensagem(p_session_id text, p_telefone text, p_lead_nome text,
  p_autor text, p_msg_at timestamptz, p_vendedor_id text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_venc timestamptz;
begin
  -- Vendedor falou: vence em 2h uteis. Lead falou: checa em 1h util se alguem respondeu.
  v_venc := public.proximo_horario_comercial(
    p_msg_at + case when p_autor = 'vendedor' then interval '2 hours' else interval '1 hour' end);

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
    -- Lead em repescagem ou encerrado volta a ativo quando escreve de novo.
    status = case when f.status in ('repescagem', 'encerrado') and p_autor = 'lead'
                   and p_msg_at >= coalesce(greatest(f.ultima_msg_lead_at, f.ultima_msg_nossa_at), '-infinity'::timestamptz)
                  then 'ativo'
                  when f.status = 'repescagem'
                   and p_msg_at >= coalesce(greatest(f.ultima_msg_lead_at, f.ultima_msg_nossa_at), '-infinity'::timestamptz)
                  then 'ativo'
                  else f.status end,
    atualizado_em = now();
end $function$;

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
    v_prox := null;
  elsif v_decisao = 'optout' then
    v_prox := null;
    v_status := 'optout';
  elsif v_decisao = 'encerrar' then
    -- Ja matriculado vira 'matriculado'; fora do funil ou lead frio vira 'encerrado'.
    v_prox := null;
    v_status := case when p->>'situacao' = 'ja_matriculado' then 'matriculado' else 'encerrado' end;
  end if;

  v_fase := case
    when p->>'fase' is null then v_lead.fase
    when coalesce(array_position(v_ordem, p->>'fase'), 0) > coalesce(array_position(v_ordem, v_lead.fase), 0)
      then p->>'fase'
    else v_lead.fase end;

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
    ultimo_autor = case when (p->>'lead_falou_por_ultimo')::boolean then 'lead' else ultimo_autor end,
    atualizado_em = clock_timestamp()
  where session_id = p_session_id;
  return true;
end $function$;
