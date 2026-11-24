-- Estrutura base do follow-up de leads parados (aplicada em 24/11/2026).
-- O token do webhook NAO fica no repositorio: no banco ele esta em followup_config.webhook_token.

create table public.followup_leads (
  session_id text primary key,
  telefone text,
  lead_nome text,
  vendedor_id text,
  fase text not null default 'descoberta' check (fase in ('descoberta','encantamento','fechamento')),
  checklist jsonb not null default '{}'::jsonb,
  resumo text check (char_length(resumo) <= 300),
  ultimo_autor text check (ultimo_autor in ('lead','vendedor')),
  ultima_msg_lead_at timestamptz,
  ultima_msg_nossa_at timestamptz,
  proximo_followup_at timestamptz,
  etapa_regua smallint not null default 0,
  retorno_marcado_at timestamptz,
  status text not null default 'ativo' check (status in ('ativo','retorno_marcado','matriculado','perdido','optout','encerrado')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index followup_leads_vencidos_idx on public.followup_leads (proximo_followup_at) where status = 'ativo';

create table public.followup_envios (
  id bigint generated always as identity primary key,
  session_id text not null references public.followup_leads(session_id) on delete cascade,
  enviado_em timestamptz not null default now(),
  fase text,
  etapa smallint,
  mensagem text,
  respondeu_em timestamptz
);
create index followup_envios_session_idx on public.followup_envios (session_id);

create table public.webhook_amostras (
  id bigint generated always as identity primary key,
  recebido_em timestamptz not null default now(),
  event_type text,
  payload jsonb
);

create table public.followup_config (
  chave text primary key,
  valor text not null
);
-- Valores iniciais. Defina o token real direto no banco:
-- insert into public.followup_config (chave, valor) values ('webhook_token', '<TOKEN>');
insert into public.followup_config (chave, valor) values
  ('envio_ligado', 'false'),
  ('max_amostras', '30');

alter table public.followup_leads enable row level security;
alter table public.followup_envios enable row level security;
alter table public.webhook_amostras enable row level security;
alter table public.followup_config enable row level security;

-- Empurra um horario para o proximo horario comercial: seg a sab, 8h-20h, America/Sao_Paulo.
create or replace function public.proximo_horario_comercial(p timestamptz)
returns timestamptz language plpgsql stable set search_path = public as $$
declare l timestamp := p at time zone 'America/Sao_Paulo';
begin
  loop
    if extract(isodow from l) = 7 then
      l := date_trunc('day', l) + interval '1 day 8 hours';
      continue;
    end if;
    if l::time < time '08:00' then
      l := date_trunc('day', l) + interval '8 hours';
    end if;
    if l::time >= time '20:00' then
      l := date_trunc('day', l) + interval '1 day 8 hours';
      continue;
    end if;
    exit;
  end loop;
  return l at time zone 'America/Sao_Paulo';
end $$;
