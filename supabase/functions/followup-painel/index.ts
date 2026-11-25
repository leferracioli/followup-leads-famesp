import { createClient } from "jsr:@supabase/supabase-js@2";

// Leitura para o card "Follow-up" do painel comercial (painel-comercial-famesp.vercel.app).
//
// GET ?vendedor=<nome no painel>  -> so os leads daquele vendedor
// GET ?todos=1                    -> todos os vendedores (visao de diretoria/admin)
// Header x-painel-key = followup_config.painel_key. O painel e publico, entao a chave so
// evita acesso casual: a resposta traz o MINIMO (primeiro nome, etiqueta, datas e link do
// Front, que exige login). Resumo, telefone e texto do aviso ficam na nota dentro do Front.

const FRONT_API = Deno.env.get("FRONT_API_BASE") ?? "https://api.wts.chat/chat";
const FRONT_TOKEN = Deno.env.get("FRONT_API_TOKEN") ?? "";
const LINK_FRONT = "https://frontcrm.wts.chat/redirect?type=SESSION&id=";
const SYNC_MIN = 15; // relê dono e nome da sessao no Front a cada 15 min, no maximo

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "x-painel-key, content-type, apikey, authorization",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

type Lead = {
  session_id: string;
  lead_nome: string | null;
  vendedor_id: string | null;
  etiqueta_fup: string;
  etiqueta_desde: string | null;
  ultima_msg_lead_at: string | null;
  ultima_msg_nossa_at: string | null;
  sessao_sync_em: string | null;
  sessao_status: string | null;
};

// Dono atual da sessao e nome do contato, lidos do Front (o webhook nem sempre traz).
async function sincronizar(lead: Lead) {
  if (!FRONT_TOKEN) return;
  const r = await fetch(`${FRONT_API}/v2/session/${lead.session_id}`, {
    headers: { Authorization: `Bearer ${FRONT_TOKEN}`, Accept: "application/json" },
  });
  if (!r.ok) return;
  const s = await r.json().catch(() => null);
  const sessao = s?.data ?? s;
  if (!sessao) return;
  lead.vendedor_id = sessao.userId ?? lead.vendedor_id;
  lead.lead_nome = sessao.title ?? lead.lead_nome;
  lead.sessao_status = sessao.status ?? lead.sessao_status;
  await db.from("followup_leads").update({
    vendedor_id: lead.vendedor_id,
    lead_nome: lead.lead_nome,
    sessao_status: lead.sessao_status,
    sessao_sync_em: new Date().toISOString(),
  }).eq("session_id", lead.session_id);
}

function primeiroNome(nome: string | null) {
  const n = (nome ?? "").trim().split(/\s+/)[0] ?? "";
  return n ? n.charAt(0).toUpperCase() + n.slice(1).toLowerCase() : "Lead sem nome";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "GET") return json({ erro: "metodo" }, 405);

  const { data: cfg } = await db.from("followup_config").select("valor").eq("chave", "painel_key").single();
  if (!cfg?.valor || req.headers.get("x-painel-key") !== cfg.valor) return json({ erro: "nao autorizado" }, 401);

  const url = new URL(req.url);
  const filtro = url.searchParams.get("vendedor");
  const todos = url.searchParams.get("todos") === "1";
  if (!filtro && !todos) return json({ erro: "informe vendedor ou todos=1" }, 400);

  const [{ data: leads, error }, { data: vendedores }] = await Promise.all([
    db.from("followup_leads")
      .select(
        "session_id, lead_nome, vendedor_id, etiqueta_fup, etiqueta_desde, ultima_msg_lead_at, ultima_msg_nossa_at, sessao_sync_em, sessao_status",
      )
      .not("etiqueta_fup", "is", null)
      .in("status", ["ativo", "repescagem"]),
    db.from("vendedores").select("front_user_id, nome_painel").eq("ativo", true),
  ]);
  if (error) return json({ erro: "falha ao ler leads" }, 500);

  // Atualiza dono/nome no Front quando faltam ou estao velhos (5 em paralelo).
  const lista = (leads ?? []) as Lead[];
  const limite = Date.now() - SYNC_MIN * 60_000;
  const velhos = lista.filter((l) => !l.sessao_sync_em || new Date(l.sessao_sync_em).getTime() < limite);
  for (let i = 0; i < velhos.length; i += 5) {
    await Promise.all(velhos.slice(i, i + 5).map((l) => sincronizar(l).catch(() => {})));
  }

  const nomePainel = new Map((vendedores ?? []).map((v) => [v.front_user_id, v.nome_painel]));
  const grupos = new Map<string, { nome: string; total: number; por_etiqueta: Record<string, number>; leads: unknown[] }>();
  for (const l of lista) {
    if (l.sessao_status === "COMPLETED") continue; // conversa encerrada no Front: sai do card
    const vendedor = (l.vendedor_id && nomePainel.get(l.vendedor_id)) || "Sem vendedor";
    if (filtro && vendedor !== filtro) continue;
    const g = grupos.get(vendedor) ?? { nome: vendedor, total: 0, por_etiqueta: {}, leads: [] };
    g.total++;
    g.por_etiqueta[l.etiqueta_fup] = (g.por_etiqueta[l.etiqueta_fup] ?? 0) + 1;
    const datas = [l.ultima_msg_lead_at, l.ultima_msg_nossa_at].filter(Boolean) as string[];
    g.leads.push({
      nome: primeiroNome(l.lead_nome),
      etiqueta: l.etiqueta_fup,
      desde: l.etiqueta_desde,
      ultimo_contato: datas.length ? datas.sort().at(-1) : null,
      link: LINK_FRONT + l.session_id,
    });
    grupos.set(vendedor, g);
  }

  const saida = [...grupos.values()].map((g) => ({
    ...g,
    // Mais antigos primeiro: quem esta parado ha mais tempo aparece no topo.
    leads: (g.leads as { desde: string | null }[]).sort((a, b) => (a.desde ?? "").localeCompare(b.desde ?? "")),
  })).sort((a, b) => b.total - a.total);

  if (filtro && !saida.length) saida.push({ nome: filtro, total: 0, por_etiqueta: {}, leads: [] });
  return json({ gerado_em: new Date().toISOString(), vendedores: saida });
});
