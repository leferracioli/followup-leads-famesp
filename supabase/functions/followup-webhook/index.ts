import { createClient } from "jsr:@supabase/supabase-js@2";

// Recebe o webhook do Front (FlowChat) e registra o ESTADO do lead.
// Nao guarda a conversa: 1 linha por sessao, atualizada via RPC registrar_mensagem.
// Responde na hora e processa em segundo plano (o Front desliga webhook lento).

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ATENCAO: o Front devolve senderId vazio em send/text, entao esta marca nao funciona.
// Na fase de envio, o controle passa a ser pelo id da mensagem em followup_envios.
const SENDER_FOLLOWUP = "followup-bot";
// MESSAGE_SENT chega de novo a cada mudanca de status; so o primeiro interessa.
const STATUS_IGNORADOS = new Set(["DELIVERED", "READ", "FAILED", "ERROR"]);

let config: Record<string, string> | null = null;
let configEm = 0;

async function getConfig(): Promise<Record<string, string>> {
  if (config && Date.now() - configEm < 5 * 60 * 1000) return config;
  const { data } = await db.from("followup_config").select("chave, valor");
  config = Object.fromEntries((data ?? []).map((r) => [r.chave, r.valor]));
  configEm = Date.now();
  return config;
}

// Guarda as primeiras N cargas brutas de MENSAGEM para mapear o formato real do payload.
async function guardarAmostra(body: Record<string, unknown>, max: number) {
  if (max <= 0) return;
  if (!String(body.eventType ?? "").startsWith("MESSAGE")) return;
  const { count } = await db
    .from("webhook_amostras")
    .select("id", { count: "exact", head: true });
  if ((count ?? 0) >= max) return;
  await db.from("webhook_amostras").insert({
    event_type: String(body.eventType ?? ""),
    payload: body,
  });
}

function dataValida(v: unknown): string {
  if (typeof v === "string" || typeof v === "number") {
    const d = new Date(v);
    if (!isNaN(d.getTime())) return d.toISOString();
  }
  return new Date().toISOString();
}

async function processar(body: Record<string, unknown>) {
  const ev = body.eventType;
  if (ev !== "MESSAGE_RECEIVED" && ev !== "MESSAGE_SENT") return;

  const cfg = await getConfig();
  await guardarAmostra(body, Number(cfg.max_amostras ?? 0));

  // deno-lint-ignore no-explicit-any
  const c = (body.content ?? {}) as Record<string, any>;
  const sessionId = c.sessionId as string | undefined;
  if (!sessionId) return;

  let autor: "lead" | "vendedor";
  if (ev === "MESSAGE_SENT") {
    if (STATUS_IGNORADOS.has(String(c.status ?? ""))) return;
    if (c.senderId === SENDER_FOLLOWUP) return;
    autor = "vendedor";
  } else if (c.direction === "FROM_HUB") {
    autor = "lead";
  } else {
    return;
  }

  // Cinto de seguranca: se houver lista de vendedores e o payload trouxer o dono, filtra.
  const permitidos = (cfg.vendedores_permitidos ?? "")
    .split(",").map((s) => s.trim()).filter(Boolean);
  const dono = c.userId ?? null;
  if (permitidos.length && dono && !permitidos.includes(String(dono))) return;

  const telefone = autor === "lead" ? (c.details?.from ?? null) : (c.details?.to ?? null);
  const nome = autor === "lead"
    ? (c.details?.name ?? c.details?.contactName ?? c.contact?.name ?? null)
    : null;
  const msgAt = dataValida(c.timestamp ?? c.createdAt ?? body.date);

  const { error } = await db.rpc("registrar_mensagem", {
    p_session_id: sessionId,
    p_telefone: telefone,
    p_lead_nome: nome,
    p_autor: autor,
    p_msg_at: msgAt,
    p_vendedor_id: autor === "vendedor" ? dono : null,
  });
  if (error) console.error("Erro em registrar_mensagem:", error);
}

function emSegundoPlano(p: Promise<unknown>) {
  const seguro = p.catch((e) => console.error("Erro no processamento:", e));
  try {
    if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) {
      EdgeRuntime.waitUntil(seguro);
    }
  } catch (_) { /* sem waitUntil: o catch acima segura */ }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "HEAD" || req.method === "GET") return json({ ok: true });
  if (req.method !== "POST") return json({ erro: "metodo" }, 405);

  const token = new URL(req.url).searchParams.get("token");
  const cfg = await getConfig();
  if (!token || token !== cfg.webhook_token) return json({ erro: "nao autorizado" }, 401);

  emSegundoPlano((async () => {
    const body = await req.json().catch(() => null);
    if (body) await processar(body as Record<string, unknown>);
  })());

  return json({ ok: true, queued: true });
});
