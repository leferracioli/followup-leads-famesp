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

Definidas com conversas reais de março e abril de 2026 (análise no doc vivo). A fase gravada é a **mais avançada** que o lead já atingiu e nunca volta atrás (`registrar_analise` garante isso). O checklist acumula.

- **Encaixe:** curso definido, turma aberta, pré-requisito atendido (o bot já coleta parte) e período e formato que cabem na rotina e na logística.
- **Apresentação:** ficha e preço ou condição enviados, e o lead reagiu. O lead costuma pedir o preço cedo.
- **Decisão:** o lead disse sim, ou a objeção foi tratada com uma alternativa concreta.
- **Inscrição:** dados, plano de parcelas, pix e comprovante.

O motivo do "agora" é só informativo (`motivo_conhecido`): perguntar ou não não mudou a conversão.

Estados que valem em qualquer fase: `objecao` (preco, horario_rotina, distancia_logistica, concorrente, terceiro_decide, pre_requisito, outra) e `situacao` (em_andamento, pendencia_nossa, sem_turma, sem_conversa). Pendência nossa, sem turma e sem conversa viram aviso ao vendedor, não mensagem ao lead.

Todo follow-up termina oferecendo **dois horários** para o retorno.

## Tabelas

- `followup_leads`: estado por sessão (fase, checklist, objecao, situacao, resumo de até 300 caracteres, timestamps, `proximo_followup_at`, `etapa_regua`, `status`, `vendedor_id`).
- `followup_envios`: log dos follow-ups enviados (retenção de 90 dias).
- `webhook_amostras`: os primeiros 30 payloads de mensagem, para mapear o formato.
- `followup_analises`: uma linha por análise da varredura (retenção de 90 dias).
- `cursos`: base oficial de cursos que a IA pode citar (vazia por enquanto).
- `followup_config`: `webhook_token`, `envio_ligado` (botão de desligar), `max_amostras`, `vendedores_permitidos` (opcional), `varredura_token`, `max_por_varredura`, `modelo_ia`, `aviso_nota_ligado`, `aviso_repetir_dias`, `etiqueta_ligada`.

RLS ligado em todas as tabelas, sem policies: só a service role acessa.

## Fatos aprendidos com payloads reais

- O payload traz `content.userId` (dono), `sessionId`, `direction`, `timestamp`, `templateId`, `status` e `details.from/to`.
- A Meta recusa template de **Marketing** para quem já recebeu muitos (erro 131049, limite por usuário): na régua automática do time, 4 de 5 mensagens falharam para um mesmo lead. O follow-up fora da janela de 24h precisa de template de **Utilidade**.
- Mensagem com `status` FAILED fica no histórico do Front; a varredura ignora.
- `options.senderId` no `send/text` **volta vazio**, então não serve para marcar mensagem do bot.
- Envio pela API (`send/text`) não gerou evento no webhook filtrado.
- O agendamento nativo do Front (`scheduled-message`) só aceita TEMPLATE ou CHATBOT.

## Varredura em modo sombra (no ar desde 24/11)

- pg_cron `followup-varredura` (`5 11-22 * * 1-6` UTC = 8h05 às 19h05 em SP) chama `disparar_varredura()`, que faz POST na Edge Function `followup-varredura` com o header `x-varredura-token` (valor em `followup_config.varredura_token`).
- `pegar_vencidos(limite)` reserva até `max_por_varredura` leads por 30 min; `registrar_analise(session, versao, jsonb)` grava em `followup_analises` e só aplica no lead se `atualizado_em` não mudou (senão `aplicada = false`).
- Origem das nossas mensagens no Front: `DEFAULT` = vendedor; `BOT` sem `templateId` = fluxo do chatbot; `CAMPAIGN`, ou `BOT` com `templateId` = campanha ou follow-up automático.
- Regras fixas antes da IA, nesta ordem:
  1. Lead falou por último (ignorando o fluxo do bot) → corrige o estado e espera o vendedor.
  2. Nossa última mensagem é campanha ou follow-up automático de menos de 24h → ainda não é lead parado; volta 24h depois dela.
  3. Lead que nunca escreveu e nunca falou com vendedor (só recebeu automação) → `situacao = sem_conversa`, avisa o vendedor para fazer o primeiro contato, sem chamar a IA.
  4. Última mensagem nossa só SENT (não entregue) → espera 3h, e depois de 3 dias avisa o vendedor.
- **Leitura não conta**: a confirmação de leitura não é confiável.
- IA: **OpenAI** (Chat Completions com Structured Outputs `strict`, chamada por `fetch`), modelo em `followup_config.modelo_ia` (padrão `gpt-5.6`), `reasoning_effort` medium. Trocada da Anthropic em 25/11 por escolha da Letícia. Decisões: `enviar` | `agendar` | `avisar_vendedor` | `optout` (+ `aguardar` só por regra).
- Régua fantasma: `enviar` avança `etapa_regua` (F2 no dia seguinte, F3 três dias depois, depois `repescagem`). Lead em repescagem volta a `ativo` quando alguém escreve.
- **Nada é enviado ao lead**, mesmo com `envio_ligado = true`: o envio ainda não foi implementado.
- **Aviso ao vendedor (no ar desde 25/11):** quando a decisão é `avisar_vendedor` e a análise foi aplicada, a varredura posta uma **nota interna** na conversa do Front (`POST /v1/session/{id}/note`; o lead não vê). A nota sai no nome do dono do token da API. Chave `followup_config.aviso_nota_ligado`. Não repete antes de `aviso_repetir_dias` (3), a não ser que o lead tenha escrito depois do último aviso. O resultado fica em `followup_analises.aviso_nota` (postada, repetida, desligada, erro) e em `followup_leads.ultimo_aviso_at/ultimo_aviso_texto`. A nota não aparece na lista de mensagens nem dispara o webhook.
- **Etiqueta no contato (no ar desde 25/11):** cada lead tem no máximo uma etiqueta `FUP - …` no contato do Front (API core: `POST https://api.wts.chat/core/v1/contact/{contactId}/tags` com `InsertIfNotExists` / `DeleteIfExists`, **nunca `ReplaceAll`**: as réguas do time dependem das próprias etiquetas, como `ABANDONO_ROBO`). Os nomes são: `FUP - Responder lead` (pendencia_nossa), `FUP - Primeiro contato` (sem_conversa), `FUP - Sem turma` e `FUP - Ver conversa` (outros avisos). Sai quando a IA decide enviar, agendar ou optout, ou quando o lead fala por último. Esperas de regra não mexem nela. A varredura cria a etiqueta no Front se ela faltar. Chave `followup_config.etiqueta_ligada`. Estado em `followup_leads.etiqueta_fup` e `followup_analises.etiqueta`.
- **Card no painel comercial (no ar desde 25/11):** o painel `painel-comercial-famesp.vercel.app` é outro projeto (pasta `Treinamento Comercial - Famesp`, HTML estático no Vercel, sem remoto git). Ele lê do FAMESP Comercial, mas o card de follow-up lê da Edge Function **`followup-painel`** deste projeto (`GET ?vendedor=<nome no painel>` ou `?todos=1`, header `x-painel-key` = `followup_config.painel_key`). Como o painel é público, a função devolve só primeiro nome, etiqueta, datas e o link do Front. A tabela `vendedores` faz o de-para entre usuário do Front e nome no painel. O dono e o nome da sessão são relidos do Front a cada 15 min (`sessao_sync_em`). Deploy: `supabase functions deploy followup-painel --no-verify-jwt`.
- Secrets `FRONT_API_TOKEN` e `OPENAI_API_KEY` cadastrados em 25/11 (sem eles a função responde 503). Primeiro teste real no mesmo dia: 24 leads, sem erro.
- Pendente: a base oficial na tabela `cursos` (vazia).
- Teste manual: `select public.disparar_varredura();` e depois `net._http_response`. Fora do horário comercial, a função só roda com `?forcar=1`.

## Convenções

- Respostas e textos em português do Brasil.
- Mensagens para leads: tom humano e acolhedor, nunca robótico; sempre terminam com pergunta ou CTA; nunca encerram o contato, sempre oferecem uma alternativa mais acessível.
- Documentar cada decisão no doc vivo.

## Deploy

```bash
supabase link --project-ref tkcshzndaztfykkraprp
supabase functions deploy followup-webhook --no-verify-jwt
supabase functions deploy followup-varredura --no-verify-jwt
supabase functions deploy followup-painel --no-verify-jwt
```

As migrações em `supabase/migrations` **já foram aplicadas** no banco. Num link novo, marque-as como aplicadas com `supabase migration repair --status applied <versão>` em vez de rodá-las de novo.
