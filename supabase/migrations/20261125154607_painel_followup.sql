-- Card de follow-up no painel comercial (painel-comercial-famesp.vercel.app).
-- O painel le pela Edge Function followup-painel, que devolve so o minimo (primeiro nome,
-- etiqueta, datas e link do Front): o painel e publico.

-- De-para entre o usuario do Front e o nome usado no painel.
create table public.vendedores (
  front_user_id text primary key,
  nome_front text not null,
  nome_painel text not null,
  ativo boolean not null default true
);
alter table public.vendedores enable row level security;

insert into public.vendedores (front_user_id, nome_front, nome_painel) values
  ('2e2413bb-6825-43e5-8567-4d11cb64b964', 'Ana Paula Ribeiro', 'Ana P.'),
  ('426b70dd-01bb-4060-8418-e4932d23b1a3', 'Robson Soares Ferreira', 'Robson'),
  ('c1db8b6c-8dc8-49b1-b81a-8b4af3c53282', 'Samantha Soares Couto', 'Samantha'),
  ('feddbde3-1a26-46c3-8c4c-0611b332d684', 'Sara Humenhuk', 'Sara'),
  ('1c534fda-749a-475a-afbf-214de46dd108', 'Leticia Ferracioli', 'Letícia');

-- Quando a etiqueta FUP entrou (para "parado ha X") e quando o dono/nome foram lidos do Front.
alter table public.followup_leads
  add column etiqueta_desde timestamptz,
  add column sessao_sync_em timestamptz;

update public.followup_leads set etiqueta_desde = coalesce(ultimo_aviso_at, now()) where etiqueta_fup is not null;

-- Chave que o painel manda no header x-painel-key (fica no HTML publico: so evita acesso casual).
insert into public.followup_config (chave, valor)
values ('painel_key', encode(extensions.gen_random_bytes(12), 'hex'))
on conflict (chave) do nothing;

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

  if p_status = 'aplicada' then
    update public.followup_leads set etiqueta_fup = p_etiqueta, etiqueta_desde = now() where session_id = p_session_id;
  elsif p_status = 'removida' then
    update public.followup_leads set etiqueta_fup = null, etiqueta_desde = null where session_id = p_session_id;
  end if;
end $function$;
