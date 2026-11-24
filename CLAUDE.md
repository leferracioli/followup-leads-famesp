# Follow-up automático de leads parados — FAMESP

Projeto da Letícia Ferracioli (supervisora comercial da FAMESP). O objetivo é recuperar leads com potencial de compra que ficaram sem resposta e levar cada um a um **retorno com data e hora marcada**.

Doc vivo com as decisões, o histórico e as pendências: https://claude.ai/artifact/2Cpcz7f5y3vQpgafeZF4Mt

## Contexto

- CRM: **Front** (FlowChat, API em `flwchat.readme.io`). WhatsApp pela **API oficial da Meta**: depois de 24h sem mensagem do lead, só sai template aprovado.
- Teste restrito ao usuário da Letícia e ao departamento "Supervisão Comercial". O filtro está configurado **na tela do webhook do Front**, não pela API.
- Volume: de 50 a 70 leads novos por dia no time.
- Supabase: projeto separado **Follow-up Leads FAMESP** (`tkcshzndaztfykkraprp`, sa-east-1). Não mexer nos projetos "FAMESP Comercial" e "Radar Comercial", que já estão com o disco pressionado.

## Arquitetura (decisões tomadas)

1. **Não copiar a conversa para o banco.** O histórico fica no Front e é lido pela API (`GET /chat/v1/session/{id}/message`) só na hora da análise.
2. **Uma linha por sessão** em `followup_leads`, atualizada via RPC `registrar_mensagem` (upsert que ignora evento fora de ordem).
3. **Webhook → Edge Function `followup-webhook`:** responde na hora e processa em segundo plano, porque o Front desliga webhook lento. Exige `?token=` na URL; o token fica em `followup_config.webhook_token` e nunca entra no repositório.
4. Eventos tratados: `MESSAGE_RECEIVED` com `direction = FROM_HUB` conta como lead; `MESSAGE_SENT` conta como vendedor. `MESSAGE_SENT` repetido com status DELIVERED ou READ é ignorado.
5. Quando o vendedor fala por último, o vencimento é de 2h, empurrado para o horário comercial (de segunda a sábado, das 8h às 20h, America/Sao_Paulo) por `proximo_horario_comercial()`.
6. IA só para lead vencido, numa varredura de hora em hora (próxima fase).

## Fases do funil (critério de saída)

- **Descoberta:** curso, motivo do "agora" e localização identificados.
- **Encantamento:** turma, período, horário, carga horária, disciplinas e cronograma apresentados, sem dúvida aberta.
- **Fechamento:** o lead quer se matricular. O follow-up tira o atrito.

Todo follow-up termina oferecendo **dois horários** para o retorno.

## Tabelas

- `followup_leads`: estado por sessão (fase, checklist, resumo de até 300 caracteres, timestamps, `proximo_followup_at`, `etapa_regua`, `status`, `vendedor_id`).
- `followup_envios`: log dos follow-ups enviados (retenção de 90 dias).
- `webhook_amostras`: os primeiros 30 payloads de mensagem, para mapear o formato.
- `followup_config`: `webhook_token`, `envio_ligado` (botão de desligar), `max_amostras`, `vendedores_permitidos` (opcional).

RLS ligado em todas as tabelas, sem policies: só a service role acessa.

## Fatos aprendidos com payloads reais

- O payload traz `content.userId` (dono), `sessionId`, `direction`, `timestamp`, `templateId`, `status` e `details.from/to`.
- `options.senderId` no `send/text` **volta vazio**, então não serve para marcar mensagem do bot.
- Envio pela API (`send/text`) não gerou evento no webhook filtrado.
- O agendamento nativo do Front (`scheduled-message`) só aceita TEMPLATE ou CHATBOT.

## Próxima fase: varredura em modo sombra

- Agendamento de hora em hora (pg_cron ou cron externo) que pega `proximo_followup_at <= now()` e `status = 'ativo'`.
- Para cada lead: ler o histórico no Front, chamar a IA, gravar fase, checklist, resumo e decisão (`enviar` | `agendar` | `avisar_vendedor`) e a mensagem sugerida, **sem enviar** enquanto `envio_ligado = false`.
- Regras: não empilhar mensagem se a última do vendedor não foi lida (`readContactAt` nulo); respeitar a janela de 24h (fora dela, só template); nunca prometer curso, modalidade, turma ou preço que não esteja na conversa ou na base de cursos.
- Dependências pendentes: chave de API de IA (secret) e base oficial de cursos (curso, modalidade, períodos, EaD).

## Convenções

- Respostas e textos em português do Brasil.
- Mensagens para leads: tom humano e acolhedor, nunca robótico; sempre terminam com pergunta ou CTA; nunca encerram o contato, sempre oferecem uma alternativa mais acessível.
- Documentar cada decisão no doc vivo.

## Deploy

```bash
supabase link --project-ref tkcshzndaztfykkraprp
supabase functions deploy followup-webhook --no-verify-jwt
```

As migrações em `supabase/migrations` **já foram aplicadas** no banco. Num link novo, marque-as como aplicadas com `supabase migration repair --status applied <versão>` em vez de rodá-las de novo.
