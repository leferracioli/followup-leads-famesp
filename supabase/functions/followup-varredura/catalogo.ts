// Catálogo oficial de cursos, lido direto de https://admin.famesp.com.br/catalogo-cursos
// (página pública em Next.js). Nada é gravado no banco: a varredura lê uma vez por rodada.
//
// A página traz os cursos como dados no fluxo RSC do Next (self.__next_f.push). Objetos
// repetidos viram referências do tipo "$7:...:cursos:0:informacoesExtras:2", resolvidas aqui.
// Se a página mudar de formato, lerCatalogo() lança erro e a análise segue sem catálogo.

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

export type Curso = {
  nome: string;
  nivel: string;
  modalidade: string;
  sigla: string | null;
  ficha: string | null;
  pagina: string | null;
  texto: string; // resumo pronto para a IA
};

export const CATALOGO_URL = "https://admin.famesp.com.br/catalogo-cursos";

export async function lerCatalogo(url = CATALOGO_URL): Promise<Curso[]> {
  const r = await fetch(url, { headers: { Accept: "text/html" } });
  if (!r.ok) throw new Error(`catálogo respondeu ${r.status}`);
  return extrairCursos(await r.text());
}

export function extrairCursos(html: string): Curso[] {
  const partes = [...html.matchAll(/self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)/g)].map((m) => JSON.parse(m[1]));
  const rsc = partes.join("");
  const marca = '"cursos":[';
  const ini = rsc.indexOf(marca);
  if (ini < 0) throw new Error("catálogo sem a lista de cursos (formato da página mudou?)");
  const bruto: Obj[] = JSON.parse(fatiaJson(rsc, ini + marca.length - 1));
  const cursos = resolver(bruto, bruto, 0) as Obj[];
  if (!cursos.length) throw new Error("catálogo veio vazio");
  return cursos.map(resumir);
}

// Recorta o array JSON que começa em `ini`, respeitando strings e aninhamento.
function fatiaJson(s: string, ini: number): string {
  let prof = 0, emStr = false, esc = false;
  for (let i = ini; i < s.length; i++) {
    const c = s[i];
    if (emStr) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') emStr = false;
      continue;
    }
    if (c === '"') emStr = true;
    else if (c === "[" || c === "{") prof++;
    else if (c === "]" || c === "}") {
      if (--prof === 0) return s.slice(ini, i + 1);
    }
  }
  throw new Error("lista de cursos truncada");
}

function resolver(o: unknown, raiz: Obj[], prof: number): unknown {
  if (Array.isArray(o)) return o.map((v) => resolver(v, raiz, prof));
  if (o && typeof o === "object") {
    return Object.fromEntries(Object.entries(o as Obj).map(([k, v]) => [k, resolver(v, raiz, prof)]));
  }
  if (typeof o === "string") {
    if (o === "$undefined") return undefined;
    const m = o.match(/^\$[0-9a-f]+:(.*)$/);
    if (m && prof < 5) {
      const caminho = m[1].split(":");
      const i = caminho.indexOf("cursos");
      if (i >= 0) {
        // deno-lint-ignore no-explicit-any
        let alvo: any = raiz;
        for (const seg of caminho.slice(i + 1)) alvo = alvo?.[Array.isArray(alvo) ? Number(seg) : seg];
        return resolver(alvo, raiz, prof + 1);
      }
    }
  }
  return o;
}

const reais = (centavos: unknown) =>
  typeof centavos === "number"
    ? "R$ " + (centavos / 100).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
    : "?";
const data = (iso: unknown) => typeof iso === "string" && /^\d{4}-\d{2}-\d{2}/.test(iso)
  ? `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`
  : String(iso ?? "");
const VENC: Record<string, string> = { dia05: "pagando até o dia 5", util: "pagando até o 5º dia útil" };

function resumir(c: Obj): Curso {
  const linhas = [`${c.nome} — ${c.nivel} · ${c.modalidade}${c.situacao ? ` · ${c.situacao}` : ""}`];
  const of: Obj | undefined = c.oferta && typeof c.oferta === "object" ? c.oferta : undefined;

  if (of?.planos?.length) {
    linhas.push("Condição da Black (campanha):");
    for (const p of of.planos as Obj[]) {
      const partes = [
        p.rotulo ? `${p.rotulo}:` : null,
        `${p.parcelas}x de ${reais(p.centavos)}`,
        p.valorCheioCentavos ? `(cheio ${reais(p.valorCheioCentavos)})` : null,
        p.vencimento ? VENC[p.vencimento] ?? p.vencimento : null,
        p.inicio ? `início ${data(p.inicio)}` : null,
        p.turma ? `turma ${p.turma}` : null,
        p.descricao ?? null,
      ].filter(Boolean);
      linhas.push("- " + partes.join(" "));
    }
    if (of.matriculaCheiaCentavos) {
      const final = of.matriculaCheiaCentavos - (of.economiaMatricula ?? 0);
      linhas.push(`Matrícula: de ${reais(of.matriculaCheiaCentavos)} por ${reais(final)}`);
    }
    for (const k of ["condicaoMatricula", "condicaoPrimeiraParcela"]) if (of[k]) linhas.push(String(of[k]));
    if (of.descontoPrimeiraMensalidadePercentual) {
      linhas.push(`${of.descontoPrimeiraMensalidadePercentual}% de desconto na primeira mensalidade`);
    }
    if (of.descontoPontualidadePercentual) linhas.push(`Desconto de pontualidade: ${of.descontoPontualidadePercentual}%`);
    if (of.cupomMensalidades?.codigo) {
      const cp = of.cupomMensalidades;
      linhas.push(
        `Cupom ${cp.codigo}: ${cp.descontoPercentual ?? "?"}% nas mensalidades${cp.idadeMinima ? ` (a partir de ${cp.idadeMinima} anos)` : ""}`,
      );
    }
  } else if (c.foraDaBlack) {
    linhas.push("Fora da campanha Black.");
  }

  // Condições e turmas fora da campanha: formato livre, vai compacto.
  for (const k of ["condicoesRegulares", "turmas"]) {
    if (c[k]) linhas.push(`${k === "turmas" ? "Turmas" : "Condições regulares"}: ${JSON.stringify(c[k]).slice(0, 700)}`);
  }
  for (const e of (c.informacoesExtras ?? []) as Obj[]) {
    if (e?.titulo || e?.descricao) linhas.push(`${e.titulo ?? ""}: ${e.descricao ?? ""}`.trim());
  }
  if (c.ficha) linhas.push(`Ficha de inscrição: ${c.ficha}`);

  return {
    nome: String(c.nome ?? ""),
    nivel: String(c.nivel ?? ""),
    modalidade: String(c.modalidade ?? ""),
    sigla: c.sigla ?? null,
    ficha: c.ficha ?? null,
    pagina: c.pagina ?? null,
    texto: linhas.join("\n"),
  };
}

// ---------- escolha dos cursos relevantes para uma conversa ----------

const norm = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
// Radicais de palavras que aparecem em muitos nomes (ou em qualquer conversa) e não
// identificam o curso sozinhos: valem 1 ponto em vez de 2.
const COMUNS = new Set([
  "tecnic", "tecnol", "gradua", "bachar", "gestao", "clinic", "medica", "medici", "animai", "pequen",
  "saude", "avanca", "enfase", "contro", "cirurg", "conven", "diagno", "imagem", "veteri", "esteti",
  "hospit", "geral", "famili", "public", "legal", "humana", "pratic",
]);
// Radical: as 6 primeiras letras ("enfermagem" e "enfermeira" -> "enferm").
const radical = (w: string) => w.slice(0, 6);

// Pontua cada curso pelos radicais do nome que aparecem na conversa. Nome completo vale mais.
export function cursosDaConversa(cursos: Curso[], conversa: string, max = 3): Curso[] {
  const t = norm(conversa);
  const pont = cursos.map((c) => {
    const nome = norm(c.nome);
    let p = t.includes(nome) ? 10 : 0;
    const radicais = new Set(nome.split(/[^a-z0-9]+/).filter((w) => w.length >= 5).map(radical));
    for (const r of radicais) if (t.includes(r)) p += COMUNS.has(r) ? 1 : 2;
    return { c, p };
  });
  return pont.filter((x) => x.p >= 2).sort((a, b) => b.p - a.p).slice(0, max).map((x) => x.c);
}

// Bloco <base_de_cursos> para a IA: detalhe dos cursos da conversa + lista de todos.
export function blocoCatalogo(cursos: Curso[], conversa: string): string {
  const relevantes = cursosDaConversa(cursos, conversa);
  const lista = cursos.map((c) => `- ${c.nome} (${c.nivel} · ${c.modalidade})`).join("\n");
  return [
    `Fonte: catálogo oficial (${CATALOGO_URL}), lido agora.`,
    relevantes.length
      ? "Cursos que aparecem na conversa (detalhe completo):\n\n" + relevantes.map((c) => c.texto).join("\n\n")
      : "Nenhum curso do catálogo foi identificado na conversa.",
    "Todos os cursos do catálogo (só nome; para detalhes de outro curso, peça ao vendedor):\n" + lista,
  ].join("\n\n");
}
