-- Modo leitura da varredura: analisa uma lista de sessoes (ex.: todas as da semana) com as
-- mesmas regras e a mesma IA, mas SO grava aqui. Nao mexe em followup_leads, nao poe nota nem
-- etiqueta no Front.
create table public.followup_leituras (
  id bigint generated always as identity primary key,
  lote text not null,
  session_id text not null,
  titulo text,
  status_sessao text,
  departamento text,
  origem text check (origem in ('regra', 'ia', 'erro')),
  decisao text,
  motivo text,
  fase text,
  situacao text,
  objecao text,
  resumo text,
  mensagem_sugerida text,
  alerta_vendedor text,
  checklist jsonb,
  dentro_janela_24h boolean,
  ultima_msg_lead_at timestamptz,
  ultima_msg_nossa_at timestamptz,
  modelo text,
  tokens_entrada int,
  tokens_saida int,
  erro text,
  lido_em timestamptz not null default now()
);
create index followup_leituras_lote on public.followup_leituras (lote);
alter table public.followup_leituras enable row level security;
