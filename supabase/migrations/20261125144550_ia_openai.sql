-- A varredura passou a usar a OpenAI (Chat Completions com Structured Outputs).
update public.followup_config set valor = 'gpt-5.6' where chave = 'modelo_ia';
