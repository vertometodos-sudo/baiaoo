# MeuLink (meulink.blog)

Página de link na bio. Front-end em um único `index.html` e backend no Supabase (projeto `meulink-blog`).

## Arquivos

- `site/index.html`: o app inteiro (página pública, /admin, /master, /termos).
- `site/config.js`: URL do Supabase e chave **publishable**, que é pública por natureza. Nunca coloque a secret ou a service_role aqui.
- `supabase/migrations/20261126_metricas_confiaveis.sql`: **já aplicada** em produção em 26/11/2026.

## Como publicar o front-end

O primeiro commit desta pasta é uma cópia do HTML **como ele sai do servidor**. O servidor (Cloudflare) injeta `<title>`, `description` e as tags `og:` de cada página. Por isso:

1. Pegue o seu `index.html` original, o que você sobe para a Cloudflare.
2. Aplique nele o diff do segundo commit: `git diff HEAD~1 -- meulink/site/index.html`.
3. Suba normalmente.

Se o seu original não tiver a linha de `<meta ... og:...>` logo depois do `</style>`, não a copie daqui.

## O que mudou

**Banco (já está no ar, compatível com o site antigo)**
- Cliques não podem mais ser forjados. O navegador não escolhe data, id nem URL: a URL é a do botão salvo (`link_idx`). Índice inválido é ignorado.
- Clique repetido do mesmo aparelho em 30 s não conta. Visita repetida em 30 min não conta.
- Nova tabela `visitas`. Agora existe taxa de clique (cliques ÷ visitas).
- Nenhum IP é guardado. Fica só um hash com sal secreto que muda por dia e por perfil (`private.visitante_hash`).
- `stats_perfil(p_id, dias)`: estatísticas calculadas no servidor. Só o dono da página ou o master podem chamar.
- `master_lista()` agora também devolve `visitas_30d`.

**Site (precisa publicar)**
- Registra a visita e identifica a origem: `?utm_source=`, navegador interno do Instagram/Facebook/TikTok ou referrer.
- O painel mostra visitas, cliques, taxa, gráfico de 14 dias, cliques por botão e origem.
- O painel master mostra visitas por cliente.
- Ao salvar um link, remove `fbclid`, `utm_*` e `igsh` colados junto.
- Página inicial explica o produto em 3 passos.
- O aviso de "página inativa" tem botão de WhatsApp (se `WHATSAPP_CONTATO` estiver preenchido).
- Termos: o texto de privacidade agora descreve o que é registrado e cobre os dados do titular (LGPD).
- `supabase-js` com versão fixa (2.119.0).
- Se o CDN falhar, mostra "Tentar de novo" em vez de "Configuração pendente".
- Página não encontrada recebe `noindex`.
- Avatar vazio não aparece mais como círculo quebrado.

## Pendências que só você faz no painel

- `config.js`: preencha `WHATSAPP_CONTATO`. Sem ele não existe nenhum canal para o influenciador pedir liberação.
- Supabase > Authentication > Passwords: ligar "Leaked password protection".
- Cloudflare: fazer `/robots.txt` e `/sitemap.xml` (hoje devolvem o HTML) e fazer slug inexistente responder 404 de verdade.
