-- Varredura de hora em hora em MODO SOMBRA (24/11/2026).
-- A IA analisa o lead vencido e grava fase, checklist, resumo, decisao e mensagem sugerida.
-- Nada e enviado ao lead nesta fase.

-- 1. Novo status para quem passou pelo F3 sem responder.
alter table public.followup_leads drop constraint if exists followup_leads_status_check;
alter table public.followup_leads add constraint followup_leads_status_check
  check (status in ('ativo','retorno_marcado','matriculado','perdido','optout','encerrado','repescagem'));

-- 2. Log de cada analise da varredura (retencao de 90 dias).
create table public.followup_analises (
  id bigint generated always as identity primary key,
  session_id text not null references public.followup_leads(session_id) on delete cascade,
  analisado_em timestamptz not null default now(),
  modo text not null default 'sombra' check (modo in ('sombra','envio')),
  etapa smallint,                 -- 1 = F1, 2 = F2, 3 = F3
  origem text not null check (origem in ('regra','ia')),
  decisao text not null check (decisao in ('enviar','agendar','avisar_vendedor','aguardar','optout')),
  motivo text,
  fase text check (fase in ('descoberta','encantamento','fechamento')),
  checklist jsonb,
  resumo text,
  mensagem_sugerida text,
  horarios_oferecidos jsonb,
  agendar_para timestamptz,
  alerta_vendedor text,
  dentro_janela_24h boolean,      -- false = so sai template aprovado
  ultima_nossa_lida boolean,
  proximo_followup_at timestamptz,
  aplicada boolean not null default true,  -- false = o lead mudou durante a analise (corrida)
  modelo text,
  tokens_entrada int,
  tokens_saida int,
  erro text
);
create index followup_analises_session_idx on public.followup_analises (session_id, analisado_em desc);
create index followup_analises_data_idx on public.followup_analises (analisado_em);
alter table public.followup_analises enable row level security;

-- 3. Base oficial de cursos (vazia ate a FAMESP enviar). A IA so cita o que estiver aqui ou na conversa.
create table public.cursos (
  id bigint generated always as identity primary key,
  nome text not null,
  modalidade text,          -- presencial, EaD, semipresencial
  periodos text,            -- ex.: manha, noite, sabado
  unidade text,
  carga_horaria text,
  observacoes text,
  ativo boolean not null default true
);
alter table public.cursos enable row level security;

-- 4. Configuracao da varredura.
insert into public.followup_config (chave, valor) values
  ('varredura_token', encode(extensions.gen_random_bytes(24), 'hex')),
  ('max_por_varredura', '30'),
  ('modelo_ia', 'claude-opus-5-5')
on conflict (chave) do nothing;

-- 5. Pega os leads vencidos e reserva por 30 min (evita duas varreduras no mesmo lead).
-- atualizado_em devolvido serve de "versao": se o webhook mexer no lead durante a analise, ela nao e aplicada.
create or replace function public.pegar_vencidos(p_limite int)
returns setof public.followup_leads language sql security definer set search_path = public as $$
  update public.followup_leads f
     set proximo_followup_at = now() + interval '30 minutes',
         atualizado_em = clock_timestamp()
   where f.session_id in (
     select session_id from public.followup_leads
      where status = 'ativo' and proximo_followup_at <= now()
      order by proximo_followup_at
      limit p_limite
      for update skip locked)
  returning f.*;
$$;

-- 6. Grava a analise e, se o lead nao mudou desde a reserva, aplica o resultado.
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
     horarios_oferecidos, agendar_para, alerta_vendedor, dentro_janela_24h, ultima_nossa_lida,
     proximo_followup_at, aplicada, modelo, tokens_entrada, tokens_saida, erro)
  values
    (p_session_id, coalesce(p->>'modo','sombra'),
     case when v_decisao = 'enviar' then v_etapa else v_lead.etapa_regua + 1 end,
     p->>'origem', v_decisao, p->>'motivo', p->>'fase', p->'checklist', left(p->>'resumo', 300),
     p->>'mensagem_sugerida', p->'horarios_oferecidos', (p->>'agendar_para')::timestamptz,
     p->>'alerta_vendedor', (p->>'dentro_janela_24h')::boolean, (p->>'ultima_nossa_lida')::boolean,
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

revoke execute on function public.pegar_vencidos(int) from public, anon, authenticated;
revoke execute on function public.registrar_analise(text, timestamptz, jsonb) from public, anon, authenticated;

-- 7. Retencao: analises e envios com mais de 90 dias.
create or replace function public.limpar_followup_antigo()
returns void language sql security definer set search_path = public as $$
  delete from public.followup_analises where analisado_em < now() - interval '90 days';
  delete from public.followup_envios where enviado_em < now() - interval '90 days';
$$;
revoke execute on function public.limpar_followup_antigo() from public, anon, authenticated;

-- 8. Lead em repescagem que volta a conversar (ele ou o vendedor) reativa a regua.
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
    status = case when f.status = 'repescagem'
                   and p_msg_at >= coalesce(greatest(f.ultima_msg_lead_at, f.ultima_msg_nossa_at), '-infinity'::timestamptz)
                  then 'ativo' else f.status end,
    atualizado_em = now();
end $$;

revoke execute on function public.registrar_mensagem(text, text, text, text, timestamptz, text) from public, anon, authenticated;
