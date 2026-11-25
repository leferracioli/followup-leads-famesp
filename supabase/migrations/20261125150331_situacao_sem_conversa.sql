-- Lead que so recebeu automacao (campanha, regua do bot) e nunca conversou com ninguem:
-- falta o primeiro contato humano, nao uma resposta atrasada.
alter table public.followup_leads drop constraint followup_leads_situacao_check;
alter table public.followup_leads add constraint followup_leads_situacao_check
  check (situacao in ('em_andamento', 'pendencia_nossa', 'sem_turma', 'sem_conversa'));
alter table public.followup_analises drop constraint followup_analises_situacao_check;
alter table public.followup_analises add constraint followup_analises_situacao_check
  check (situacao in ('em_andamento', 'pendencia_nossa', 'sem_turma', 'sem_conversa'));
comment on column public.followup_leads.situacao is
  'em_andamento | pendencia_nossa (lead esperando resposta do time) | sem_turma (curso sem turma ou inexistente) | sem_conversa (só recebeu automação, nunca conversou).';
