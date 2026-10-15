#!/bin/bash
# =============================================================================
#  SYNAPSE — PROVISIONAMENTO DE CLIENTE NOVO (script único, ponta-a-ponta)
#  Funde em um só fluxo:
#    - install_synapse_v6.sh   (VPS do zero: Docker/Traefik/Ritmo/Harmonia/
#                                Harpa/Eco/Acorde)
#    - 1_provisionar_ritmo.sh  (CORS/CSRF/roles/DocTypes/usuário de automação)
#    - 3_provisionar_harpa.sh  (conta/admin/token/inbox webchat)
#    - 4_atualizar_credenciais_harmonia.sh (grava .env do Harmonia)
#    - onboard-client.sh       (tenant na Lyra Central + injeta LYRA_API_KEY)
#    - 2_importar_workflows_harmonia.py (sobe os workflows W0-W4 + Lyra L1-L3)
#  Roda direto, como root, na VPS nova do cliente.
#
#  Uso local (script já baixado):
#    export LYRA_CENTRAL_URL=https://lyra.suaempresa.com
#    export LYRA_ADMIN_API_KEY=xxxxx
#    export GITHUB_TOKEN=ghp_xxxxx   # PAT com acesso de leitura aos repos nomen-me (privados)
#    sudo -E ./provisionar_cliente_synapse.sh <dominio-base> ["Nome da Loja"] [pasta-workflows] [arquivo-html-do-painel] [pasta-ou-arquivo-da-home]
#
#  Exemplo:
#    sudo -E ./provisionar_cliente_synapse.sh lojademo.com.br "Loja Demo" "" /root/synapse_painel.html /root/home-site
#
#  Uso via "curl | bash" (script hospedado no repo, sem baixar antes):
#    ⚠️ "curl ... | bash <dominio>" NÃO funciona — depois do "|", o bash lê o
#    SCRIPT do stdin, então qualquer coisa escrita depois de "bash" é
#    interpretada como argumento do PRÓPRIO bash, não do script. É preciso
#    "-s --" pra sinalizar "o resto da linha são argumentos do script".
#    E se github.com/nomen-me/synapse for um repo PRIVADO (como os outros
#    repos nomen-me citados abaixo), o "curl" no raw.githubusercontent
#    TAMBÉM precisa de autenticação própria — GITHUB_TOKEN usado dentro do
#    script é só pro "git clone" de dentro dele, não autentica esse curl:
#      export LYRA_CENTRAL_URL=https://lyra.suaempresa.com
#      export LYRA_ADMIN_API_KEY=xxxxx
#      export GITHUB_TOKEN=ghp_xxxxx
#      curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" \
#        https://raw.githubusercontent.com/nomen-me/synapse/main/provisionar_cliente_synapse.sh \
#        | sudo -E bash -s -- lojademo.com.br "Loja Demo"
#    (se o repo for Public, dá pra tirar o "-H Authorization" desse curl)
#
#  O 3º argumento (pasta-workflows) agora é OPCIONAL: se não for passado, o
#  script clona github.com/nomen-me/json (W0-W4 + Lyra L1-L3 + schema de
#  funções) e usa esses arquivos. Só informe esse argumento se quiser
#  apontar pra uma pasta local (ex: testando workflows ainda não commitados).
#
#  De onde vem cada coisa (nada mais depende de FileZilla/scp manual):
#    - Módulo fiscal Brazil NF   → github.com/nomen-me/brazil-nf
#    - Workflows do Harmonia     → github.com/nomen-me/json (raiz do repo)
#    - Painel/PDV (mesmo produto pra todo cliente, PWA offline-first) → um
#      CONJUNTO de 7 arquivos (index.html, sw.js, manifest.json, fflate.js,
#      icon-192.png, icon-512.png, icon-512-maskable.png), nunca só o HTML.
#      Ordem de prioridade (ver seção 9.5):
#        1) 4º argumento do script — pasta com os 7 arquivos, ou (modo
#           antigo) 1 arquivo HTML único + os outros 6 do lado dele
#        2) /root/painel_dist/ na VPS — pasta com os 7 arquivos
#        3) /root/synapse_painel.html (modo antigo) + os outros 6 em /root
#        4) clone de github.com/nomen-me/painel, travado no commit/tag de
#           SYNAPSE_PAINEL_REF (precisa ser exportado — não há valor-padrão
#           chutado; ver comentário na declaração da variável)
#      Sem um conjunto completo de alguma dessas 4 fontes, a instalação
#      FALHA de propósito (Painel é requisito obrigatório do PDV).
#    - Home/site da raiz (próprio da loja, diferente pra cada cliente,
#      sem repo padrão) → 5º argumento local, /root/home-site (pasta) ou
#      /root/index.html (arquivo) — ver seção 9.6 (esta, sim, é opcional)
#
#  Pré-requisitos antes de rodar:
#    - VPS Ubuntu 24.04 limpa, root/sudo
#    - 7 registros DNS tipo A apontando pro IP desta VPS:
#        ritmo. harmonia. harpa. acorde. eco. painel. <dominio-base>
#        + o próprio <dominio-base> (raiz/apex, sem subdomínio — é onde a
#        Home é publicada, seção 9.6)
#    - LYRA_CENTRAL_URL, LYRA_ADMIN_API_KEY e GITHUB_TOKEN exportados no
#      ambiente, e uma das 4 fontes do Painel acima disponível (os 7
#      arquivos em /root/painel_dist/ é a forma mais simples)
#
#  O QUE O SCRIPT NÃO FAZ DE PROPÓSITO (fica pro painel de operações ou
#  manual, ver resumo final):
#    - Credenciais de Melhor Envio / InfinitePay / 99 Empresas → cadastradas
#      pelo painel, direto no Ritmo (DocType "Synapse Credencial Externa")
#    - Inbox de WhatsApp no Harpa → depende de conta própria (Meta/Twilio/
#      360dialog) que só o cliente/vocês criam
#    - GEMINI_API_KEY → não existe mais por cliente; a Lyra Central já
#      centraliza isso
# =============================================================================
set -uo pipefail
# (sem -e de propósito: uma falha num passo não-crítico não deve abortar o
#  resto da instalação — cada passo crítico tem sua própria checagem/fatal)

# Todo o corpo do script fica dentro de main(), chamada só na ÚLTIMA linha
# do arquivo. Isso é o que garante rodar de forma segura via "curl | bash":
# bash precisa ler a função INTEIRA (até o "}" de fechamento) antes de poder
# executar qualquer parte dela — então, quando algum comando aqui dentro
# (docker exec, docker compose exec/run, etc.) tentar ler stdin, não sobra
# mais nada do script no mesmo cano pra ele roubar (o "curl" já entregou
# tudo, o bash já terminou de PARSEAR o arquivo inteiro nesse ponto). Sem
# isso, "curl | bash" pode morrer silenciosamente no meio — cada comando
# interno que lê stdin disputa os mesmos bytes que o bash ainda não leu.
main() {

# =============================================================================
# 0. ARGUMENTOS, VARIÁVEIS DERIVADAS E HELPERS
# =============================================================================
DOMINIO_BASE="${1:?Uso: sudo -E bash provisionar_cliente_synapse.sh <dominio-base> [\"Nome da Loja\"] [pasta-workflows-local-opcional] [arquivo-html-do-painel-opcional] [pasta-ou-arquivo-da-home-opcional]}"
NOME_LOJA="${2:-$DOMINIO_BASE}"
WORKFLOWS_DIR_OVERRIDE="${3:-}"   # se vazio, workflows vêm do clone de nomen-me/synapse (fase 12)
PAINEL_HTML_OVERRIDE="${4:-}"
HOME_SRC_OVERRIDE="${5:-}"

LYRA_CENTRAL_URL="${LYRA_CENTRAL_URL:?Exporte LYRA_CENTRAL_URL antes de rodar (ex: export LYRA_CENTRAL_URL=https://lyra.suaempresa.com)}"
LYRA_ADMIN_API_KEY="${LYRA_ADMIN_API_KEY:?Exporte LYRA_ADMIN_API_KEY antes de rodar}"
LYRA_CENTRAL_URL="${LYRA_CENTRAL_URL%/}"
GITHUB_TOKEN="${GITHUB_TOKEN:?Exporte GITHUB_TOKEN antes de rodar (PAT com acesso de leitura aos repos privados nomen-me)}"
GITHUB_ORG="nomen-me"

# =============================================================================
# SYNAPSE BASELINE — única fonte de verdade de versões. Nomen e Cliente usam
# exatamente os mesmos valores (exceto o que é exclusivo da Nomen, ex. Lyra).
# Toda mudança de versão passa por aqui, nunca solta pelo script.
# =============================================================================
SYNAPSE_UBUNTU_MAJOR="24.04"

SYNAPSE_ERPNEXT_VERSION="v15.121.4"
# frappe/erpnext:${SYNAPSE_ERPNEXT_VERSION} é a imagem oficial pré-construída do
# frappe_docker — ela já embute o Frappe correspondente (v15.121.1, o release
# v15 mais recente do Frappe na data do release do ERPNext v15.121.4). Não há
# bench/branch separado pra pinar aqui: o par Frappe/ERPNext vem fixado dentro
# da própria imagem publicada pelo frappe_docker.
SYNAPSE_FRAPPE_VERSION_REF="v15.121.1"  # só para o relatório — não usado em nenhum pull

SYNAPSE_N8N_VERSION="2.40.7"
SYNAPSE_CHATWOOT_VERSION="v4.18.0"
SYNAPSE_CHATWOOT_POSTGRES_VERSION="pg16"
# Escolha deliberada, não default de fallback: a linha 8.2 é documentada como
# uma das linhas "LTS" que o Redis mantém em paralelo à mais nova (8.10.x),
# validada contra Chatwoot/filas simples sem precisar do salto de major mais
# recente. O sufixo "-alpine" aqui é parte da tag testada e fixada — não é
# a tag "alpine" solta (sem versão) que a baseline proíbe.
SYNAPSE_CHATWOOT_REDIS_VERSION="8.2.10-alpine"

SYNAPSE_TRAEFIK_VERSION="v3.6.25"
SYNAPSE_UPTIME_KUMA_VERSION="2.5.5"
SYNAPSE_NETDATA_VERSION="v2.11.1"
SYNAPSE_SEMAPHORE_VERSION="v2.19.12"
# 1.30.5 corrige CVE-2026-90439 (heap buffer overflow em HTTP/3 com OpenSSL
# <=3.5.0) — release de segurança de 15/set/2026 na própria série "stable"
# que já estava em uso (não é salto de minor). Mesma lógica do Redis acima:
# "-alpine" é parte da tag fixada, não a tag solta.
SYNAPSE_NGINX_VERSION="1.30.5-alpine"

SYNAPSE_META_GRAPH_API_VERSION="v26.0"

SYNAPSE_GEMINI_MODEL="gemini-3.8-flash"

# brazil-nf é repositório público (github.com/${GITHUB_ORG}/brazil-nf), mas sem
# release/tag — só 3 commits na main. SHA confirmado via "git ls-remote" em
# 29/set/2026 (HEAD == refs/heads/main nesse momento). Continua sobrescrevível
# por variável de ambiente se a Nomen cortar um commit novo depois.
SYNAPSE_BRAZIL_NF_REF="${SYNAPSE_BRAZIL_NF_REF:-cd1efcac6b62e70f55c6ae9cb95a6d22d16678d4}"

# Painel: ao contrário do brazil-nf, este script NÃO tem como saber sozinho
# qual commit/tag de github.com/${GITHUB_ORG}/painel corresponde à versão
# validada (synapse_painel_18-09m.html + sw.js entregues junto desta tarefa)
# — isso só existe no repositório real, que este ambiente não acessa. Por
# isso, de propósito, NÃO HÁ um valor-padrão chutado aqui (seria exatamente
# o "HTML antigo sem controle de versão" que a seção 10 da instrução proíbe,
# só que disfarçado de commit). Se os passos (a)/(b)/(c) da seção 9.5 não
# acharem uma fonte local, o clone do repo oficial só é tentado quando
# SYNAPSE_PAINEL_REF for exportado com o commit/tag real e homologado.
SYNAPSE_PAINEL_REF="${SYNAPSE_PAINEL_REF:-}"

AUTO_REBOOT="${AUTO_REBOOT:-nao}"   # export AUTO_REBOOT=sim para pular a confirmação de reboot

DOMINIO_ERP="ritmo.${DOMINIO_BASE}"
DOMINIO_N8N="harmonia.${DOMINIO_BASE}"
DOMINIO_CHAT="harpa.${DOMINIO_BASE}"
DOMINIO_NETDATA="acorde.${DOMINIO_BASE}"
DOMINIO_UPTIME="eco.${DOMINIO_BASE}"
DOMINIO_PAINEL="painel.${DOMINIO_BASE}"
ORIGEM_PAINEL="https://${DOMINIO_PAINEL}"

EMAIL="admin@${DOMINIO_BASE}"
SENHA="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
SECRET_KEY="$(openssl rand -hex 64)"

# Basic Auth de infraestrutura para Eco (Uptime Kuma) e Acorde (Netdata) —
# essas duas ficam com Basic Auth em vez de 404, porque são ferramentas de
# operação que a própria equipe Synapse acessa, não algo pra esconder de
# quem já tem a senha certa.
BASICAUTH_USER="synapse-ops"
BASICAUTH_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
BASICAUTH_HASH="$(openssl passwd -apr1 "${BASICAUTH_PASS}")"
BASICAUTH_HASH_ESCAPED="$(echo "$BASICAUTH_HASH" | sed 's/\$/\$\$/g')"  # docker-compose exige $$ pra não tentar interpolar variável

# tenant_id derivado do domínio, no formato aceito pela Lyra Central (^[a-z0-9_-]{3,64}$)
TENANT_ID="${TENANT_ID:-$(echo "$DOMINIO_BASE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | sed 's/_\+/_/g; s/^_//; s/_$//')}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; cancao_registra_erro "$1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

# =============================================================================
# CANCAO DA LYRA  (parte do Synapse: "Synapse instalado" == "Synapse completo")
#  - INSTALL = FAIL: qualquer err()/falha critica derruba o veredito e o exit code.
#  - O payload (app do Ritmo, workflows, Painel, patch da Lyra) vai ANEXADO a este
#    script, com sha256 verificado. Nao existe instalacao manual complementar.
# =============================================================================
CANCAO_BUNDLE_SHA256="d455d1a95e5b7ed2c3f5a9657a9c3d308b1d755d9137054132fb3a33559de258"
CANCAO_ROLE="cliente"
CANCAO_DIR="/home/ubuntu/cancao_bundle"
INSTALL_ERROS=0
INSTALL_ERROS_LISTA=()
cancao_registra_erro() { INSTALL_ERROS=$((INSTALL_ERROS+1)); INSTALL_ERROS_LISTA+=("$1"); }

cancao_trap_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ] && { [ "${INSTALL_ERROS:-0}" -gt 0 ] || [ "${FALHA_CRITICA:-false}" = true ]; }; then
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}  INSTALL = FAIL  (${INSTALL_ERROS} erro(s) obrigatorio(s))${NC}"
    local e; for e in "${INSTALL_ERROS_LISTA[@]:-}"; do [ -n "$e" ] && echo -e "${RED}   - ${e}${NC}"; done
    echo -e "${RED}  A instalacao NAO esta concluida. Corrija e rode de novo.${NC}"
    echo -e "${RED}============================================================${NC}"
    exit 1
  fi
}
trap cancao_trap_exit EXIT

# resultado de um check da Cancao: usa relatorio() quando existe (Nomen) e SEMPRE conta como erro se FAIL
cancao_check() {
  local status="$1" nome="$2" detalhe="${3:-}"
  if declare -F relatorio >/dev/null 2>&1; then relatorio "$status" "Cancao: ${nome}" "$detalhe"; fi
  if [ "$status" = "PASS" ]; then ok "Cancao: ${nome} ${detalhe}"; else err "Cancao: ${nome} - ${detalhe}"; FALHA_CRITICA=true; fi
}

cancao_extrair_bundle() {
  local self="${BASH_SOURCE[0]:-$0}"
  [ -f "$self" ] || fatal "Nao achei o proprio script para extrair o payload da Cancao (nao rode via 'curl | bash': salve o arquivo e execute)."
  grep -q '^#__CANCAO_PAYLOAD__$' "$self" || fatal "Payload da Cancao ausente neste instalador."
  rm -rf "$CANCAO_DIR"; mkdir -p "$CANCAO_DIR"
  sed -n '/^#__CANCAO_PAYLOAD__$/,$p' "$self" | tail -n +2 | tr -d '\r\n ' | base64 -d > /tmp/cancao_bundle.tgz 2>/dev/null \
    || fatal "Payload da Cancao corrompido (base64)."
  local got; got="$(sha256sum /tmp/cancao_bundle.tgz | cut -d' ' -f1)"
  [ "$got" = "$CANCAO_BUNDLE_SHA256" ] || fatal "sha256 do payload da Cancao NAO confere (esperado ${CANCAO_BUNDLE_SHA256}, obtido ${got})."
  tar xzf /tmp/cancao_bundle.tgz -C "$CANCAO_DIR" || fatal "Falha ao extrair o payload da Cancao."
  local req="ritmo-app/pyproject.toml workflows/cancao_ingestao.json workflows/cancao_flush_heartbeat.json workflows/cancao_aprovacao_harpa.json workflows/synapse_provisionar_cliente.json painel_patch/patch_painel_aprovacoes.py painel_patch/patch_painel_harmonia.py"
  [ "$CANCAO_ROLE" = "nomen" ] && req="$req lyra/lyra.patch semaphore/configurar_semaphore_synapse.sh semaphore/provisionar_cliente_synapse2.sh semaphore/playbooks/provisionar_cliente.yml semaphore/playbooks/validar_integracao.yml semaphore/scripts/registrar_inventario_com_retry.sh"
  for f in $req; do
    [ -s "$CANCAO_DIR/$f" ] || fatal "Payload da Cancao incompleto: falta $f"
  done
  ok "Payload da Cancao extraido e verificado (sha256 ${got:0:12}...)"
}

# Ritmo: instala synapse_core (DocTypes, hooks, APIs, Outbox, execucao). Obrigatorio.
cancao_instalar_ritmo() {
  log "Cancao: instalando synapse_core no Ritmo..."
  [ -n "${ERP_API_KEY:-}" ] && [ -n "${ERP_API_SECRET:-}" ] || fatal "Cancao: ERP_API_KEY/SECRET do usuario de automacao ausentes - nao da para instalar/validar a Cancao."
  local C=ritmo-backend-1 B=/home/frappe/frappe-bench
  docker exec -u root $C rm -rf $B/apps/synapse_core || fatal "Cancao: nao consegui limpar apps/synapse_core"
  docker exec -u root $C mkdir -p $B/apps/synapse_core || fatal "Cancao: mkdir apps/synapse_core"
  docker cp "$CANCAO_DIR/ritmo-app/." $C:$B/apps/synapse_core/ || fatal "Cancao: docker cp do app falhou"
  docker exec -u root $C chown -R frappe:frappe $B/apps/synapse_core
  docker exec -u frappe $C bash -c "cd $B && ./env/bin/pip install -e apps/synapse_core && (grep -qxF synapse_core sites/apps.txt || echo synapse_core >> sites/apps.txt)" \
    || fatal "Cancao: pip install -e synapse_core falhou"
  docker exec -u frappe $C bash -c "cd $B && (bench --site ${DOMINIO_ERP} list-apps | grep -qx synapse_core || bench --site ${DOMINIO_ERP} install-app synapse_core) && bench --site ${DOMINIO_ERP} migrate" \
    || fatal "Cancao: install-app/migrate do synapse_core falhou"
  docker exec -u frappe $C bash -c "cd $B && bench --site ${DOMINIO_ERP} list-apps" | grep -qx synapse_core \
    || fatal "Cancao: synapse_core NAO aparece em 'bench list-apps'"
  # papel + configuracao (URL da Harmonia e usuario de automacao = dono da API key)
  local R
  R=$(ritmo_exec <<PYEOF
def main():
    import frappe
    u = frappe.db.get_value("User", {"api_key": "${ERP_API_KEY}"}, "name")
    if not u:
        print("CANCAO_ERRO usuario da API key nao encontrado"); return
    frappe.get_doc("User", u).add_roles("Synapse Automacao")
    frappe.db.set_single_value("Synapse Autonomia", "usuario_automacao", u)
    frappe.db.set_single_value("Synapse Autonomia", "harmonia_ingest_url", "https://${DOMINIO_N8N}/webhook/synapse-evento")
    frappe.db.commit()
    print("CANCAO_OK", u)
PYEOF
)
  echo "$R" | grep -q "CANCAO_OK" || fatal "Cancao: configuracao do Synapse Autonomia falhou: ${R}"
  docker exec -u frappe $C bash -c "cd $B && bench --site ${DOMINIO_ERP} enable-scheduler" >/dev/null 2>&1 || fatal "Cancao: nao consegui habilitar o scheduler (relay do Outbox depende dele)"
  ( cd /home/ubuntu/ritmo 2>/dev/null || true; docker compose --project-name ritmo restart backend queue-short queue-long scheduler >/dev/null 2>&1 ) || fatal "Cancao: restart do Ritmo falhou"
  sleep 8
  ok "Cancao: synapse_core instalado e configurado no Ritmo (${DOMINIO_ERP})"
}

# Workflows: sobrepoe os 12 arquivos da Cancao em WORKFLOWS_DIR (3 novos + 9 existentes com dominio corrigido).
cancao_workflows_overlay() {
  [ -n "${WORKFLOWS_DIR:-}" ] && [ -d "$WORKFLOWS_DIR" ] || fatal "Cancao: pasta de workflows indisponivel (clone do repo json falhou) - INSTALL=FAIL."
  cp "$CANCAO_DIR"/workflows/*.json "$WORKFLOWS_DIR"/ || fatal "Cancao: nao consegui copiar os workflows para ${WORKFLOWS_DIR}"
  # regra: *_DOMAIN no .env e so o host; todo consumidor prefixa https://. Nenhum 'https://https://' nem URL sem esquema.
  if grep -rlE 'https://https://' "$WORKFLOWS_DIR"/*.json >/dev/null 2>&1; then fatal "Cancao: 'https://https://' encontrado nos workflows"; fi
  if grep -rEq '"=\{\{\$env\.(ERPNEXT|HARMONIA|CHATWOOT)_DOMAIN' "$WORKFLOWS_DIR"/*.json; then fatal "Cancao: workflow com *_DOMAIN sem esquema https://"; fi
  # n8n 2.40.7: em httpRequest typeVersion>=3 o parametro e `method`; `requestMethod` e IGNORADO e o no envia GET (verificado). Reprova.
  python3 - "$WORKFLOWS_DIR" <<'PYEOF' || fatal "Cancao: workflow(s) com httpRequest usando 'requestMethod' (vira GET no n8n 2.x). Corrija para 'method'."
import json, glob, sys
bad = []
for f in glob.glob(sys.argv[1] + "/*.json"):
    for n in json.load(open(f, encoding="utf-8")).get("nodes", []):
        if n.get("type", "").endswith(".httpRequest") and n.get("typeVersion", 0) >= 3 and "requestMethod" in n.get("parameters", {}):
            bad.append(f.split("/")[-1] + " :: " + n.get("name", "?"))
if bad:
    print("requestMethod em:", *bad[:10], sep="\n  "); sys.exit(1)
PYEOF
  cancao_cors_workflows "$WORKFLOWS_DIR" "https://${DOMINIO_PAINEL}"
  ok "Cancao: workflows da Cancao + dominios normalizados + CORS restrito ao Painel em ${WORKFLOWS_DIR}"
}

# ---------------------------------------------------------------------------------------------------------
# Painel (Aprovar/Rejeitar): a fonte do Painel e a que o instalador JA resolve (arquivo, pasta de 7 arquivos ou repo pinado).
# Sobre o index.html resultante aplica-se, no site/, o patch de Aprovacoes (ancoras verificadas; "ja aplicado" e idempotente;
# ancora ausente = FATAL: nao publica um Painel sem o ciclo humano). Roda ANTES do docker compose e das provas de SHA.
cancao_painel_aprovacoes_aplicar() {
  local idx="$1"
  [ -f "$idx" ] || fatal "Cancao: index.html do Painel ausente em ${idx}"
  command -v python3 >/dev/null 2>&1 || fatal "Cancao: python3 ausente (necessario para o patch de Aprovacoes do Painel)"
  python3 "$CANCAO_DIR/painel_patch/patch_painel_aprovacoes.py" "$idx" "${idx}.cancao.tmp" || { rm -f "${idx}.cancao.tmp"; fatal "Cancao: o patch de Aprovacoes NAO casou com este Painel (index.html mudou). INSTALL=FAIL: atualize o patcher, nao publique sem Aprovar/Rejeitar."; }
  mv "${idx}.cancao.tmp" "$idx"
  grep -q 'page-aprovacoes' "$idx" || fatal "Cancao: Painel sem a aba Aprovacoes apos o patch"
  # Harmonia: credentials omit (CORS), multipart e ligacao do anexo ao workflow existente atendimento/enviar-anexo
  python3 "$CANCAO_DIR/painel_patch/patch_painel_harmonia.py" "$idx" "${idx}.cancao.tmp" || { rm -f "${idx}.cancao.tmp"; fatal "Cancao: o patch Painel->Harmonia (anexo/CORS) NAO casou com este Painel. INSTALL=FAIL."; }
  mv "${idx}.cancao.tmp" "$idx"
  grep -q "Harmonia.chamarMultipart('atendimento/enviar-anexo'" "$idx" || fatal "Cancao: Painel sem a ligacao do anexo ao Harmonia apos o patch"
  ok "Cancao: Painel com Aprovar/Rejeitar (sha256 $(sha256sum "$idx" | cut -c1-12)...)"
}

# Migracao de instalacao existente (publicacao por DIRETORIO, nao por bind mount de arquivo): preserva backup do compose e do
# default.conf antes de qualquer reescrita.
cancao_backup_painel_config() {
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  local f
  for f in /home/ubuntu/painel/docker-compose.yml /home/ubuntu/painel/conf/default.conf; do
    if [ -f "$f" ] && ! [ -f "${f}.bak.cancao" ]; then cp -p "$f" "${f}.bak.${ts}" && ok "Cancao: backup de ${f} -> ${f}.bak.${ts}"; fi
  done
  mkdir -p /home/ubuntu/painel/site /home/ubuntu/painel/conf
  if docker inspect painel >/dev/null 2>&1; then
    if docker inspect painel --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' | grep -q '/index.html:/usr/share/nginx/html/index.html'; then
      warn "Cancao: instalacao ANTIGA detectada (bind mount de arquivo unico). Sera migrada para diretorio com --force-recreate."
    fi
  fi
}

# Prova de que o container usa o DIRETORIO (e nunca o arquivo unico) apos o --force-recreate.
cancao_painel_verifica_mount() {
  local m; m="$(docker inspect painel --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' 2>/dev/null)"
  if echo "$m" | grep -q '/home/ubuntu/painel/site:/usr/share/nginx/html' && ! echo "$m" | grep -q 'index.html:/usr/share/nginx/html/index.html'; then
    ok "Cancao: Painel monta o DIRETORIO /home/ubuntu/painel/site em /usr/share/nginx/html (mounts: ${m})"
  else
    err "Cancao: o container painel NAO usa o diretorio site/ (mounts: ${m:-vazio}). Bind mount de arquivo unico e proibido."; FALHA_CRITICA=true
  fi
}

# CORS da Harmonia: SO os webhooks que o Painel chama pelo navegador recebem allowedOrigins = origem do Painel. Webhooks
# servidor-a-servidor (Ritmo, Chatwoot, InfinitePay, Lyra interna, Cancao, provisionamento) ficam sem CORS. Nunca '*'.
cancao_cors_workflows() {
  local dir="$1" origem="$2"
  [ -n "${DOMINIO_PAINEL:-}" ] || fatal "Cancao: DOMINIO_PAINEL ausente (CORS precisa da origem real do Painel)"
  python3 - "$dir" "$origem" <<'PYEOF' || fatal "Cancao: falha ao aplicar CORS nos workflows"
import json, glob, sys
d, origem = sys.argv[1], sys.argv[2]
PREFIXOS = ("fiscal/", "lyra/", "integracoes/", "marketing/", "consumo/", "envio/", "atendimento/", "endereco/", "monitoramento/", "pagamentos/")
assert origem.startswith("https://") and "*" not in origem, "origem invalida: " + origem
n = 0
for f in glob.glob(d + "/*.json"):
    wf = json.load(open(f, encoding="utf-8"))
    ch = False
    for node in wf.get("nodes", []):
        if node["type"].endswith(".webhook") and node["parameters"].get("path", "").startswith(PREFIXOS):
            opt = node["parameters"].setdefault("options", {})
            if opt.get("allowedOrigins") != origem:
                opt["allowedOrigins"] = origem; ch = True; n += 1
    if ch: json.dump(wf, open(f, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("CORS aplicado em", n, "webhook(s) ->", origem)
PYEOF
}

# Lyra Central (somente Nomen): aplica o patch sobre o codigo clonado. Idempotente; falha = FATAL.
cancao_aplicar_patch_lyra() {
  log "Cancao: aplicando patch da Lyra Central em ${LYRA_APP_DIR}..."
  if grep -q 'decideOnce' "${LYRA_APP_DIR}/src/services/geminiService.js" 2>/dev/null && [ -f "${LYRA_APP_DIR}/src/routes/decide.js" ]; then
    ok "Cancao: patch da Lyra ja aplicado"; return 0
  fi
  command -v patch >/dev/null 2>&1 || apt-get install -y patch >/dev/null 2>&1 || fatal "Cancao: 'patch' indisponivel"
  ( cd "$LYRA_APP_DIR" && patch -p2 --dry-run < "$CANCAO_DIR/lyra/lyra.patch" >/dev/null ) \
    || fatal "Cancao: o patch da Lyra NAO aplica no codigo clonado (upstream mudou?). INSTALL=FAIL."
  ( cd "$LYRA_APP_DIR" && patch -p2 < "$CANCAO_DIR/lyra/lyra.patch" >/dev/null ) || fatal "Cancao: falha ao aplicar o patch da Lyra"
  grep -q '^GEMINI_MODEL=.\+' "${LYRA_APP_DIR}/.env" 2>/dev/null || fatal "Cancao: GEMINI_MODEL ausente no .env da Lyra (sem fallback por design)"
  ok "Cancao: patch da Lyra aplicado (/v1/decide, autonomia, sem fallback de modelo)"
}

# Validacao funcional: o ciclo real, nao so "o servico responde".
cancao_validar() {
  log "Cancao: validacao funcional (Ritmo -> Outbox -> Harmonia -> gate -> PROCESSED)..."
  local AUTH="Authorization: token ${ERP_API_KEY}:${ERP_API_SECRET}" R
  local RIT="https://${DOMINIO_ERP}/api/method/synapse_core.api"
  # 1) workflows da Cancao existem e estao ativos
  if [ -n "${N8N_API_KEY:-}" ]; then
    R=$(curl -s -m 30 -H "X-N8N-API-KEY: ${N8N_API_KEY}" "https://${DOMINIO_N8N}/api/v1/workflows?limit=250" | python3 -c "
import sys,json
try: d=json.load(sys.stdin).get('data',[])
except Exception: d=[]
need=['Synapse — Canção — Ingestão de Eventos (Harmonia)','Synapse — Canção — Flush, Heartbeat e Reconciliação (Harmonia)','Synapse — Canção — Aprovação Humana (Harpa)']
ativos={w['name'] for w in d if w.get('active')}
print('ok' if all(n in ativos for n in need) else 'faltando:'+','.join(n for n in need if n not in ativos))")
    [ "$R" = "ok" ] && cancao_check PASS "workflows ativos" "(ingestao, flush/heartbeat, aprovacao)" || cancao_check FAIL "workflows ativos" "$R"
  else
    cancao_check FAIL "workflows ativos" "sem N8N_API_KEY - nao foi possivel confirmar"
  fi
  # 2) Ritmo: synapse_core responde e o estado operacional e HEALTHY
  R=$(curl -s -m 30 -H "$AUTH" "${RIT}.state" | python3 -c "import sys,json
try: print(json.load(sys.stdin)['message']['estado_operacional'])
except Exception: print('erro')")
  [ "$R" = "HEALTHY" ] && cancao_check PASS "Ritmo estado operacional" "HEALTHY" || cancao_check FAIL "Ritmo estado operacional" "esperado HEALTHY, obtido ${R}"
  # 3) ciclo real: altera o Ritmo e espera o evento chegar a PROCESSED pela Harmonia
  local CODE="SYNAPSE-SMOKE-$(date +%s)" GRP
  GRP=$(curl -s -m 30 -H "$AUTH" -G "https://${DOMINIO_ERP}/api/resource/Item%20Group" --data-urlencode 'filters=[["is_group","=",0]]' --data-urlencode 'limit_page_length=1' | python3 -c "import sys,json
try: print(json.load(sys.stdin)['data'][0]['name'])
except Exception: print('')")
  if [ -z "$GRP" ]; then cancao_check FAIL "ciclo Ritmo->Harmonia" "nenhum Item Group folha para o teste"; else
    curl -s -m 30 -o /dev/null -H "$AUTH" -H 'Content-Type: application/json' -X POST "https://${DOMINIO_ERP}/api/resource/Item" \
      -d "{\"item_code\":\"${CODE}\",\"item_name\":\"${CODE}\",\"item_group\":\"${GRP}\",\"stock_uom\":\"Nos\",\"is_stock_item\":0}"
    local i ST="" GA=""
    for i in $(seq 1 40); do
      R=$(curl -s -m 30 -H "$AUTH" -G "https://${DOMINIO_ERP}/api/resource/Synapse%20Outbox" --data-urlencode "filters=[[\"entity_id\",\"=\",\"${CODE}\"]]" --data-urlencode 'fields=["status","gate_action","event_type"]' | python3 -c "import sys,json
try:
  d=json.load(sys.stdin)['data']; print((d[0]['status']+'|'+str(d[0].get('gate_action'))) if d else '')
except Exception: print('')")
      ST="${R%%|*}"; GA="${R##*|}"
      [ "$ST" = "PROCESSED" ] && break
      sleep 6
    done
    if [ "$ST" = "PROCESSED" ]; then cancao_check PASS "ciclo Ritmo->Outbox->Harmonia->gate" "evento de ${CODE} PROCESSED (gate=${GA})"
    else cancao_check FAIL "ciclo Ritmo->Outbox->Harmonia->gate" "evento de ${CODE} terminou em '${ST:-ausente}' apos ~4 min (relay do Outbox, webhook da Harmonia ou ACK falhou)"; fi
    curl -s -m 30 -o /dev/null -H "$AUTH" -X DELETE "https://${DOMINIO_ERP}/api/resource/Item/${CODE}"
  fi
  # 4) Lyra Central: rota /v1/decide instalada e autenticada (evento de controle - nao depende do Gemini)
  local LK="${LYRA_API_KEY:-${LYRA_TENANT_API_KEY:-}}" LT="${LYRA_TENANT_ID:-${TENANT_ID:-}}" LU="${LYRA_CENTRAL_URL:-}"
  if [ -n "$LK" ] && [ -n "$LT" ] && [ -n "$LU" ]; then
    R=$(curl -s -m 30 -X POST "${LU}/v1/decide" -H "Authorization: Bearer ${LK}" -H "X-Tenant-ID: ${LT}" -H 'Content-Type: application/json' \
      -d '{"event":{"event_id":"smoke","event_type":"intent_expired","entity_type":"Item","entity_id":"X","state_version":1,"payload":{"operation_id":"smoke","conversa_id":"0"}}}' | python3 -c "import sys,json
try:
  d=json.load(sys.stdin); print('ok' if d.get('notifications') and d['notifications'][0]['kind']=='reconfirm_intent' else 'resposta inesperada')
except Exception: print('sem JSON (rota /v1/decide ausente?)')")
    [ "$R" = "ok" ] && cancao_check PASS "Lyra /v1/decide" "rota ativa e autenticada" || cancao_check FAIL "Lyra /v1/decide" "$R"
  else
    cancao_check FAIL "Lyra /v1/decide" "credenciais/URL da Lyra Central ausentes para o teste"
  fi
  # 5) Painel publicado com Aprovar/Rejeitar
  if [ -n "${DOMINIO_PAINEL:-}" ]; then
    curl -s -m 30 "https://${DOMINIO_PAINEL}/" | grep -q 'page-aprovacoes' && cancao_check PASS "Painel Aprovar/Rejeitar" "publicado em https://${DOMINIO_PAINEL}" \
      || cancao_check FAIL "Painel Aprovar/Rejeitar" "a pagina publicada nao contem a aba Aprovacoes"
  fi
}
# n8n <-> Semaphore (so Nomen): grava no .env do Harmonia o contrato da Integration (token/paths gerados pelo script do
# Semaphore), recria o Harmonia e PROVA o ciclo real n8n -> Integration -> Task -> Ansible com o template "Validar Integracao"
# (localhost; nao toca VPS de cliente). Nada manual. Conferimos a TASK (o endpoint de disparo responde 204 mesmo com token errado).
cancao_integrar_n8n_semaphore() {
  log "Cancao: integrando n8n <-> Semaphore (contrato vps_ip/dominio/nome_loja)..."
  local ENVF="/root/.semaphore_synapse/integracao_n8n.env" CREDF="/root/.semaphore_synapse/credenciais.env"
  if [ "${SEMA_RC:-1}" -ne 0 ]; then cancao_check FAIL "Semaphore sem pendencias" "o script de configuracao saiu com ${SEMA_RC} (FAIL - AUTOMATIZACAO INCOMPLETA) - ver ${SEMA_LOG:-log}"; return; fi
  [ "${SEMA_CONFIG_OK:-false}" = true ] || { cancao_check FAIL "integracao n8n-Semaphore" "Semaphore nao configurado"; return; }
  [ -s "$ENVF" ] || { cancao_check FAIL "integracao n8n-Semaphore" "arquivo ${ENVF} ausente"; return; }
  local k v
  while IFS='=' read -r k v; do case "$k" in SEMAPHORE_INTEGRACAO_*) grava_env_n8n "$k" "$v";; esac; done < "$ENVF"
  grava_env_n8n "SEMAPHORE_INTERNAL_URL" "http://semaphore:3000"
  local PTOK; PTOK="$(grep '^SYNAPSE_PROVISION_TOKEN=' "$N8N_ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  [ -n "$PTOK" ] || PTOK="$(head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  grava_env_n8n "SYNAPSE_PROVISION_TOKEN" "$PTOK"; salvar_credencial "SYNAPSE_PROVISION_TOKEN" "$PTOK"
  ( cd /home/ubuntu/n8n && docker compose up -d --force-recreate >/dev/null 2>&1 ) || { cancao_check FAIL "Harmonia recriado com a integracao" "docker compose up falhou"; return; }
  local i; for i in $(seq 1 60); do curl -s -m 4 -o /dev/null -w '%{http_code}' "https://${DOMINIO_N8N}/healthz" 2>/dev/null | grep -q 200 && break; sleep 4; done
  local TOKEN_SEMA PROJ TPL N0 CODE ST="" PAYLOAD
  TOKEN_SEMA="$(grep '^SEMAPHORE_API_TOKEN=' "$CREDF" | cut -d= -f2-)"
  PROJ="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/projects" | jq -r '.[] | select(.name=="Synapse") | .id' | head -n1)"
  TPL="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${PROJ}/templates" | jq -r '.[] | select(.name=="Validar Integracao") | .id' | head -n1)"
  [ -n "$PROJ" ] && [ -n "$TPL" ] || { cancao_check FAIL "integracao n8n-Semaphore" "projeto/template Validar Integracao nao encontrados via API"; return; }
  N0="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${PROJ}/tasks" | jq 'length')"
  PAYLOAD="$(jq -nc --arg d "validacao.${DOMINIO_BASE}" '{operacao:"validar", vps_ip:"203.0.113.10", dominio:$d, nome_loja:"Validacao Synapse"}')"
  # o webhook so existe alguns segundos DEPOIS do healthz (verificado no n8n 2.40.7): retentativas
  for i in $(seq 1 25); do
    CODE="$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST "https://${DOMINIO_N8N}/webhook/synapse-provisionar-cliente" -H 'Content-Type: application/json' -H "X-Synapse-Provision-Token: ${PTOK}" -d "$PAYLOAD")"
    [ "$CODE" = "202" ] && break; sleep 6
  done
  [ "$CODE" = "202" ] || { cancao_check FAIL "n8n -> webhook de provisionamento" "HTTP ${CODE:-sem resposta} (esperado 202)"; return; }
  for i in $(seq 1 40); do
    ST="$(curl -s -H "Authorization: Bearer ${TOKEN_SEMA}" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${PROJ}/tasks" | jq -r --argjson n "${N0:-0}" --argjson t "$TPL" 'if length>$n then ([.[]|select(.template_id==$t)]|.[0].status) else "sem-task" end')"
    case "$ST" in success|error) break;; esac; sleep 3
  done
  if [ "$ST" = "success" ]; then cancao_check PASS "n8n -> Semaphore -> Ansible" "task 'Validar Integracao' success (webhook 202; contrato vps_ip/dominio/nome_loja)"
  else cancao_check FAIL "n8n -> Semaphore -> Ansible" "task terminou em '${ST:-sem-task}' (token/Integration/playbook?)"; fi
}



# Baseline §2: a instalação só é reprodutível em cima do Ubuntu homologado.
# Falha explícita e imediata em qualquer outra versão — nada de seguir e
# descobrir problema de compatibilidade no meio do provisionamento.
UBUNTU_VERSAO_HOST="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-desconhecida}")"
if [ "$UBUNTU_VERSAO_HOST" != "$SYNAPSE_UBUNTU_MAJOR" ]; then
  fatal "Ubuntu incompatível (detectado: ${UBUNTU_VERSAO_HOST}). Synapse exige Ubuntu ${SYNAPSE_UBUNTU_MAJOR} LTS."
fi
ok "Ubuntu ${UBUNTU_VERSAO_HOST} confirmado"

CRED_FILE="/root/synapse_credentials.txt"
salvar_credencial() {
  # upsert de UMA chave no arquivo de credenciais — idempotente, reaproveitado
  # também para o .env do Harmonia (ver grava_env abaixo)
  local chave="$1" valor="$2"
  [ -z "$valor" ] && return 0
  touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
  if grep -q "^${chave}=" "$CRED_FILE" 2>/dev/null; then
    sed -i "s|^${chave}=.*|${chave}=${valor}|" "$CRED_FILE"
  else
    echo "${chave}=${valor}" >> "$CRED_FILE"
  fi
}

N8N_ENV_FILE="/home/ubuntu/n8n/.env"
grava_env_n8n() {
  local chave="$1" valor="$2"
  [ -z "$valor" ] && return 0
  touch "$N8N_ENV_FILE"; chmod 600 "$N8N_ENV_FILE"
  if grep -q "^${chave}=" "$N8N_ENV_FILE" 2>/dev/null; then
    sed -i "s|^${chave}=.*|${chave}=${valor}|" "$N8N_ENV_FILE"
  else
    echo "${chave}=${valor}" >> "$N8N_ENV_FILE"
  fi
}

# Executa um snippet Python dentro do backend do ERPNext via "bench execute"
# (nunca "bench console" interativo — não funciona de forma confiável dentro
# de um script não-interativo). Uso:
#   RESULTADO=$(ritmo_exec <<PYEOF
#   def main():
#       import frappe
#       ...
#   PYEOF
#   )
ritmo_exec() {
  # bench execute <mod>.main exige que "mod" resolva como <app_instalado>.<...> —
  # colocar o .py solto na raiz do bench faz "mod" virar o "app_name" que ele
  # checa contra frappe.get_installed_apps(), e falha com AppNotInstalledError
  # (nome do arquivo não é um app). "frappe" é sempre um app instalado, então
  # colocamos dentro do pacote dele e executamos como frappe.<mod>.main.
  local tmp="/tmp/synapse_ritmo_$$_${RANDOM}.py"
  cat > "$tmp"
  local mod; mod="$(basename "$tmp" .py)"
  docker cp "$tmp" "ritmo-backend-1:/home/frappe/frappe-bench/apps/frappe/frappe/${mod}.py" 2>/dev/null
  docker exec -u frappe ritmo-backend-1 bash -c "cd /home/frappe/frappe-bench && bench --site ${DOMINIO_ERP} execute frappe.${mod}.main" 2>&1
  docker exec -u frappe ritmo-backend-1 rm -f "/home/frappe/frappe-bench/apps/frappe/frappe/${mod}.py" 2>/dev/null || true
  rm -f "$tmp"
}

# Clona um repo privado nomen-me via HTTPS usando GITHUB_TOKEN. Não é fatal
# por padrão — quem chama decide o que fazer se vier vazio/falhar (o site
# fiscal, por exemplo, segue sem o módulo em vez de abortar tudo).
clonar_repo_nomen() {
  local repo="$1" destino="$2"
  rm -rf "$destino"
  local saida
  if saida=$(git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo}.git" "$destino" 2>&1); then
    return 0
  else
    # redige o token antes de mostrar qualquer coisa (git às vezes ecoa a URL no erro)
    echo "$saida" | sed "s|${GITHUB_TOKEN}|***|g" >&2
    return 1
  fi
}

# Igual a clonar_repo_nomen, mas fixa um commit/tag em vez de pegar o HEAD do
# momento. Usado onde a baseline exige um ref exato e reproduzível (ex.:
# brazil-nf, que não tem release pública — só o commit homologado manualmente).
clonar_repo_nomen_pinned() {
  local repo="$1" destino="$2" ref="$3"
  rm -rf "$destino"
  local saida
  if ! saida=$(git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo}.git" "$destino" 2>&1); then
    echo "$saida" | sed "s|${GITHUB_TOKEN}|***|g" >&2
    return 1
  fi
  if ! saida=$(cd "$destino" && git checkout --quiet "$ref" 2>&1); then
    echo "$saida" >&2
    err "Ref '${ref}' não encontrado em ${GITHUB_ORG}/${repo} — confira SYNAPSE_BRAZIL_NF_REF."
    return 1
  fi
  return 0
}

cancao_extrair_bundle
# =============================================================================
# 1. PRÉ-VERIFICAÇÕES
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
  fatal "Este script precisa correr como root. Corre com 'sudo -E'."
fi

if ! [[ "$TENANT_ID" =~ ^[a-z0-9_-]{3,64}$ ]]; then
  fatal "tenant_id derivado de '${DOMINIO_BASE}' ficou inválido ('${TENANT_ID}'). Exporte TENANT_ID=algo_valido manualmente e rode de novo."
fi

if [ -n "$WORKFLOWS_DIR_OVERRIDE" ] && [ ! -d "$WORKFLOWS_DIR_OVERRIDE" ]; then
  fatal "Pasta de workflows local informada não existe: ${WORKFLOWS_DIR_OVERRIDE}"
fi

if [ -n "$PAINEL_HTML_OVERRIDE" ] && [ ! -f "$PAINEL_HTML_OVERRIDE" ] && [ ! -d "$PAINEL_HTML_OVERRIDE" ]; then
  fatal "Pasta/arquivo do Painel informado como 4º argumento não existe: ${PAINEL_HTML_OVERRIDE}"
fi

if [ -n "$HOME_SRC_OVERRIDE" ] && [ ! -f "$HOME_SRC_OVERRIDE" ] && [ ! -d "$HOME_SRC_OVERRIDE" ]; then
  fatal "Pasta/arquivo da Home informado como 5º argumento não existe: ${HOME_SRC_OVERRIDE}"
fi

mkdir -p /root
: > "$CRED_FILE"; chmod 600 "$CRED_FILE"
salvar_credencial "DOMINIO_BASE" "$DOMINIO_BASE"
salvar_credencial "TENANT_ID" "$TENANT_ID"
salvar_credencial "EMAIL" "$EMAIL"
salvar_credencial "SENHA" "$SENHA"
salvar_credencial "BASICAUTH_USER" "$BASICAUTH_USER"
salvar_credencial "BASICAUTH_PASS" "$BASICAUTH_PASS"
ok "Password gerada e guardada em ${CRED_FILE} (permissões 600)"

echo "======================================================"
echo " Synapse — provisionando cliente novo"
echo "   domínio base : ${DOMINIO_BASE}"
echo "   loja         : ${NOME_LOJA}"
echo "   tenant Lyra  : ${TENANT_ID}"
echo "======================================================"

# =============================================================================
# 2. SISTEMA BASE + CVE-2026-53359 (kernel) + FIREWALL + DOCKER
# =============================================================================
# Numa VPS recém-criada o unattended-upgrades pode segurar o lock do
# dpkg/apt por um bom tempo. Paramos a instância atual dele (não desativa
# permanentemente, só interrompe a execução em andamento — volta a rodar no
# próximo agendamento/boot) e, como rede de segurança extra, esperamos o
# lock liberar antes de qualquer apt/docker install.
parar_unattended_upgrades() {
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
}
esperar_apt_livre() {
  local tentativas=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    tentativas=$((tentativas+1))
    if [ $tentativas -ge 60 ]; then
      warn "dpkg/apt ainda ocupado por outro processo depois de 5min — seguindo mesmo assim (pode falhar)."
      break
    fi
    log "apt/dpkg ocupado por outro processo (provavelmente unattended-upgrades) — aguardando... (${tentativas}/60)"
    sleep 5
  done
}
parar_unattended_upgrades

log "Actualizando sistema..."
esperar_apt_livre
apt update && apt upgrade -y || fatal "Falha ao actualizar o sistema."
esperar_apt_livre
apt install -y curl git nano ufw jq python3 unzip || fatal "Falha ao instalar pacotes base."

log "Verificando estado do kernel face à CVE-2026-53359 (Januscape)..."
KERNEL_A_CORRER="$(uname -r)"
KERNEL_MAIS_RECENTE="$(dpkg -l 2>/dev/null | awk '/^ii  linux-image-[0-9]/{print $2}' | sed 's/linux-image-//' | sort -V | tail -1)"
if [ -n "$KERNEL_MAIS_RECENTE" ] && [ "$KERNEL_A_CORRER" != "$KERNEL_MAIS_RECENTE" ]; then
  REINICIO_NECESSARIO=true
  warn "Kernel mais recente instalado (${KERNEL_MAIS_RECENTE}) mas a correr ${KERNEL_A_CORRER}. Reinício necessário no fim."
else
  REINICIO_NECESSARIO=false
  ok "Kernel a correr (${KERNEL_A_CORRER}) já é o mais recente disponível."
fi
warn "CVE-2026-53359 (Januscape): falha KVM/x86 com escape de VM para o host. A correção do HYPERVISOR é responsabilidade do provedor da VPS — este script só mantém o kernel do guest atualizado e reinicia quando necessário."

log "Configurando firewall..."
ufw allow OpenSSH; ufw allow 80; ufw allow 443; ufw --force enable
ok "Firewall configurado"

if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker..."
  esperar_apt_livre
  curl -fsSL https://get.docker.com | sh || fatal "Falha ao instalar Docker."
  systemctl enable --now docker
fi
ok "Docker disponível: $(docker --version)"

# =============================================================================
# 3. REDE UNIFICADA + TRAEFIK
# =============================================================================
log "Criando rede unificada stack-network..."
docker network create stack-network 2>/dev/null || true

log "Instalando Traefik standalone..."
mkdir -p /home/ubuntu/traefik
cat > /home/ubuntu/traefik/docker-compose.yml << EOF
services:
  traefik:
    image: traefik:${SYNAPSE_TRAEFIK_VERSION}
    container_name: traefik
    restart: always
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=stack-network"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesResolvers.myresolver.acme.httpChallenge=true"
      - "--certificatesResolvers.myresolver.acme.httpChallenge.entrypoint=web"
      - "--certificatesResolvers.myresolver.acme.email=${EMAIL}"
      - "--certificatesResolvers.myresolver.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_certs:/letsencrypt
    networks:
      - stack-network
volumes:
  traefik_certs:
networks:
  stack-network:
    external: true
EOF
cd /home/ubuntu/traefik && docker compose up -d
ok "Traefik standalone activo"

# =============================================================================
# 3.5 BLACKHOLE 404 — backend genérico que só devolve 404
#    É vital que os clientes da Synapse jamais vejam as GUIs internas
#    (ERPNext/N8N/Chatwoot) nem saibam de que peças a stack é composta.
#    Este container serve de destino para os routers "*-deny" criados nas
#    fases seguintes: qualquer rota não-API/não-webhook cai aqui e recebe
#    404, enquanto as chamadas de API/webhook continuam passando direto
#    para o serviço real (routers "*-allow" com prioridade maior).
# =============================================================================
log "Instalando backend blackhole404 (404 genérico para rotas de GUI)..."
mkdir -p /home/ubuntu/blackhole404
cat > /home/ubuntu/blackhole404/nginx.conf << 'EOF'
server {
    listen 80 default_server;
    location / {
        return 404;
    }
}
EOF

cat > /home/ubuntu/blackhole404/docker-compose.yml << EOF
services:
  blackhole404:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: blackhole404
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - stack-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.blackhole404.loadbalancer.server.port=80"

      # ---- Ritmo (ERPNext): tudo que não começa com /api cai aqui ----
      - "traefik.http.routers.ritmo-deny.rule=Host(\`${DOMINIO_ERP}\`)"
      - "traefik.http.routers.ritmo-deny.entrypoints=websecure"
      - "traefik.http.routers.ritmo-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.ritmo-deny.priority=1"
      - "traefik.http.routers.ritmo-deny.service=blackhole404"

      # ---- Harmonia (N8N): editor/telas caem aqui; webhooks/API não ----
      - "traefik.http.routers.harmonia-deny.rule=Host(\`${DOMINIO_N8N}\`)"
      - "traefik.http.routers.harmonia-deny.entrypoints=websecure"
      - "traefik.http.routers.harmonia-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.harmonia-deny.priority=1"
      - "traefik.http.routers.harmonia-deny.service=blackhole404"

      # ---- Harpa (Chatwoot): login/painel de atendimento caem aqui ----
      - "traefik.http.routers.harpa-deny.rule=Host(\`${DOMINIO_CHAT}\`)"
      - "traefik.http.routers.harpa-deny.entrypoints=websecure"
      - "traefik.http.routers.harpa-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.harpa-deny.priority=1"
      - "traefik.http.routers.harpa-deny.service=blackhole404"
networks:
  stack-network:
    external: true
EOF

cd /home/ubuntu/blackhole404 && docker compose up -d
ok "blackhole404 activo — GUIs de Ritmo/Harmonia/Harpa vão responder 404 a partir de agora (os routers *-allow, criados junto de cada serviço, têm prioridade maior e liberam só API/webhook)"

# =============================================================================
# 4. ERPNEXT 15 (RITMO)
# =============================================================================
log "Instalando ERPNext 15 (Ritmo)..."
cd /home/ubuntu
[ -d frappe_docker ] || git clone https://github.com/frappe/frappe_docker || fatal "Falha ao clonar frappe_docker."
cd frappe_docker

cat > .env << EOF
ERPNEXT_VERSION=${SYNAPSE_ERPNEXT_VERSION}
DB_PASSWORD=${SENHA}
SITES=${DOMINIO_ERP}
FRAPPE_SITE_NAME_HEADER=${DOMINIO_ERP}
LETSENCRYPT_EMAIL=${EMAIL}
SITES_RULE=Host(\`${DOMINIO_ERP}\`)
EOF

cat > overrides/compose.stack-network.yaml << EOF
services:
  frontend:
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ritmo.rule=Host(\`${DOMINIO_ERP}\`) && PathPrefix(\`/api\`)"
      - "traefik.http.routers.ritmo.entrypoints=websecure"
      - "traefik.http.routers.ritmo.tls.certresolver=myresolver"
      - "traefik.http.routers.ritmo.priority=10"
      - "traefik.http.services.ritmo.loadbalancer.server.port=8080"
  backend: { networks: [stack-network] }
  db: { networks: [stack-network] }
  redis-cache: { networks: [stack-network] }
  redis-queue: { networks: [stack-network] }
  queue-short: { networks: [stack-network] }
  queue-long: { networks: [stack-network] }
  scheduler: { networks: [stack-network] }
  websocket: { networks: [stack-network] }
networks:
  stack-network:
    external: true
EOF

docker compose --project-name ritmo -f compose.yaml \
  -f overrides/compose.mariadb.yaml -f overrides/compose.redis.yaml \
  -f overrides/compose.stack-network.yaml up -d

log "Aguardando MariaDB ficar saudável..."
TENTATIVAS=0
until docker exec ritmo-db-1 mariadb-admin ping -h localhost --silent 2>/dev/null; do
  TENTATIVAS=$((TENTATIVAS+1))
  if [ $TENTATIVAS -ge 30 ]; then
    err "MariaDB não respondeu em 60s. Saída de 'docker logs ritmo-db-1 --tail 50':"
    docker logs ritmo-db-1 --tail 50 2>&1
    fatal "MariaDB não ficou saudável — ver logs acima."
  fi
  sleep 2
done
ok "MariaDB saudável"
log "Aguardando backend ERPNext (15s de margem)..."; sleep 15

if docker exec ritmo-backend-1 test -d "/home/frappe/frappe-bench/sites/${DOMINIO_ERP}" 2>/dev/null; then
  ok "Site ERPNext já existia — reaproveitando"
else
  log "Criando site ERPNext..."
  if docker compose --project-name ritmo exec -T backend bench new-site "${DOMINIO_ERP}" \
    --db-root-password "${SENHA}" --admin-password "${SENHA}" --db-host db --install-app erpnext; then
    ok "Site ERPNext criado"
  else
    fatal "Falha ao criar o site ERPNext. Verifica 'docker logs ritmo-backend-1'. Instalação interrompida de propósito."
  fi
  docker compose --project-name ritmo exec -T backend bench --site "${DOMINIO_ERP}" enable-scheduler
fi

log "Liberando utilizador da base de dados para qualquer host da rede..."
DB_USER=$(docker compose --project-name ritmo exec -T backend bash -c "
  cd /home/frappe/frappe-bench &&
  grep -o '\"db_name\": \"[^\"]*\"' sites/${DOMINIO_ERP}/site_config.json | cut -d'\"' -f4
" | tr -d '\r')
if [ -n "$DB_USER" ]; then
  CURRENT_HOST=$(docker exec ritmo-db-1 mariadb -u root -p"${SENHA}" -N -e "
    SELECT host FROM mysql.user WHERE user='${DB_USER}' AND host != '%' LIMIT 1;" 2>/dev/null | tr -d '\r')
  if [ -n "$CURRENT_HOST" ]; then
    docker exec ritmo-db-1 mariadb -u root -p"${SENHA}" -e "
      RENAME USER '${DB_USER}'@'${CURRENT_HOST}' TO '${DB_USER}'@'%'; FLUSH PRIVILEGES;" 2>/dev/null \
      && ok "Utilizador da BD liberado para qualquer host." \
      || warn "Não foi possível liberar o host do utilizador automaticamente."
  fi
fi
ok "ERPNext instalado em https://${DOMINIO_ERP}"

log "Reiniciando workers do ERPNext..."
docker compose --project-name ritmo restart queue-short queue-long websocket scheduler
sleep 5

log "Instalando módulo fiscal Brazil NF (github.com/${GITHUB_ORG}/brazil-nf)..."
if clonar_repo_nomen_pinned "brazil-nf" "/home/ubuntu/brazil_nf_src" "${SYNAPSE_BRAZIL_NF_REF}"; then
  # O repo hoje (29/set/2026, commit cd1efcac) não traz o app aberto — traz só
  # um brazil_nf.zip na raiz (extrai pra brazil_nf/brazil_nf/hooks.py +
  # brazil_nf/pyproject.toml, layout normal de app Frappe UMA VEZ
  # descompactado). O próprio INSTALL.md do app assume repo aberto (bench
  # get-app direto). Descompacta primeiro se achar zip solto na raiz; se um
  # dia o repo passar a versionar o app aberto (sem zip), o find já resolve
  # sem precisar mexer aqui de novo.
  ZIP_BRAZIL_NF="$(find /home/ubuntu/brazil_nf_src -maxdepth 1 -name '*.zip' | head -1)"
  if [ -n "$ZIP_BRAZIL_NF" ]; then
    command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null 2>&1
    unzip -o "$ZIP_BRAZIL_NF" -d /home/ubuntu/brazil_nf_src >/dev/null 2>&1
  fi
  APP_DIR="$(find /home/ubuntu/brazil_nf_src -maxdepth 4 \( -name 'pyproject.toml' -o -name 'setup.py' \) -exec dirname {} \; | head -1)"
  if [ -z "$APP_DIR" ]; then
    warn "Não achei pyproject.toml/setup.py no repositório brazil-nf — tentando pelo diretório do hooks.py (layout sem packaging próprio)."
    APP_DIR="$(find /home/ubuntu/brazil_nf_src -maxdepth 6 -name 'hooks.py' -exec dirname {} \; | head -1)"
  fi
  if [ -z "$APP_DIR" ]; then
    err "Não encontrei hooks.py nem pyproject.toml/setup.py no repositório brazil-nf — instalação segue sem o módulo fiscal."
  else
    docker exec -u root ritmo-backend-1 rm -rf /home/frappe/frappe-bench/apps/brazil_nf 2>/dev/null || true
    docker exec -u root ritmo-backend-1 mkdir -p /home/frappe/frappe-bench/apps/brazil_nf
    docker cp "${APP_DIR}/." ritmo-backend-1:/home/frappe/frappe-bench/apps/brazil_nf/
    docker exec -u root ritmo-backend-1 chown -R frappe:frappe /home/frappe/frappe-bench/apps/brazil_nf
    if docker exec -u frappe ritmo-backend-1 bash -c "
      cd /home/frappe/frappe-bench && ./env/bin/pip install -e apps/brazil_nf &&
      grep -qxF 'brazil_nf' sites/apps.txt || echo 'brazil_nf' >> sites/apps.txt &&
      bench --site ${DOMINIO_ERP} install-app brazil_nf &&
      bench --site ${DOMINIO_ERP} migrate && bench --site ${DOMINIO_ERP} clear-cache"; then
      docker compose --project-name ritmo restart
      sleep 5
      # O bloco acima só prova que os comandos saíram com exit 0 — não prova
      # que o Frappe realmente registrou o app como instalado no site. Só
      # confia depois de perguntar pro próprio Frappe (list-apps), não pelo
      # exit code da cadeia anterior.
      if docker exec -u frappe ritmo-backend-1 bash -c "cd /home/frappe/frappe-bench && bench --site ${DOMINIO_ERP} list-apps" 2>/dev/null | grep -qx "brazil_nf"; then
        ok "Brazil NF instalado e confirmado em 'bench list-apps' do site ${DOMINIO_ERP}"
        BRAZIL_NF_CONFIRMADO="sim"
      else
        err "bench install-app terminou sem erro, mas brazil_nf NÃO aparece em 'bench list-apps' do site ${DOMINIO_ERP} — instalação do módulo fiscal não confirmada."
      fi
    else
      err "Falha ao instalar Brazil NF — corre 'docker logs ritmo-backend-1 --tail 100' depois."
    fi
  fi
else
  err "Falha ao clonar github.com/${GITHUB_ORG}/brazil-nf — confirma se GITHUB_TOKEN tem acesso ao repositório. Instalação segue sem o módulo fiscal."
fi

# =============================================================================
# 5. RITMO — PROVISIONAMENTO (CORS/CSRF/roles/DocTypes/usuário de automação)
#    (fusão do antigo 1_provisionar_ritmo.sh — agora com domínio dinâmico e
#    sem "bench console"; tudo via "bench execute")
# =============================================================================
log "Provisionando Ritmo (CORS, CSRF, roles, DocTypes, usuário de automação)..."

docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" set-config allow_cors "${ORIGEM_PAINEL}"
docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" set-config session_cookie_samesite "Lax"
ok "CORS liberado para ${ORIGEM_PAINEL} e session_cookie_samesite=Lax"

ritmo_exec > /tmp/synapse_csrf.log <<PYEOF
def main():
    import frappe
    if not frappe.db.exists("Server Script", "synapse_csrf_token"):
        frappe.get_doc({
            "doctype": "Server Script", "name": "synapse_csrf_token",
            "script_type": "API", "api_method": "synapse_csrf_token", "allow_guest": 0,
            "script": "frappe.response['message'] = frappe.local.session.data.csrf_token"
        }).insert(ignore_permissions=True)
        print("Server Script 'synapse_csrf_token' criado -> GET /api/method/synapse_csrf_token")
    else:
        print("Server Script 'synapse_csrf_token' já existia")
    frappe.db.commit()
PYEOF
ok "Endpoint de CSRF token pronto (se 'Server Script' estiver desabilitado no site, habilite em Configurações do Sistema)"

ritmo_exec > /tmp/synapse_caixa_offline.log <<PYEOF
def main():
    import frappe
    # Corpo real dos dois endpoints do Caixa offline. Executam dentro do
    # sandbox do Server Script do Frappe (mesmo mecanismo do
    # synapse_csrf_token acima) — por isso não têm "import frappe": lá
    # dentro "frappe" já vem pronto no escopo, e só o que a whitelist do
    # safe_exec permite (frappe.*, builtins comuns) está disponível.
    SCRIPT_SINCRONIZAR = """
pos_profile = frappe.form_dict.get('pos_profile')
if not pos_profile:
    frappe.throw('Parametro pos_profile e obrigatorio')
if not frappe.db.exists('POS Profile', pos_profile):
    frappe.throw('POS Profile nao encontrado: ' + pos_profile)

linhas_autorizadas = frappe.get_all(
    'POS Profile User',
    filters={'parent': pos_profile, 'parenttype': 'POS Profile'},
    fields=['user']
)
restricao_configurada = len(linhas_autorizadas) > 0
usuarios_ids = [r.user for r in linhas_autorizadas]

usuarios = []
funcionarios = []
if restricao_configurada:
    solicitante = frappe.session.user
    pode_solicitar = (
        solicitante in usuarios_ids
        or 'System Manager' in frappe.get_roles(solicitante)
        or 'Synapse Administrador' in frappe.get_roles(solicitante)
    )
    if not pode_solicitar:
        frappe.throw(
            'Voce nao esta na lista de usuarios autorizados deste POS Profile',
            frappe.PermissionError
        )
    funcionarios = frappe.get_all(
        'Employee',
        filters={'user_id': ['in', usuarios_ids], 'status': 'Active'},
        fields=['name', 'employee_name', 'user_id', 'modified',
                'synapse_pin_hash', 'synapse_pin_salt', 'synapse_pin_kdf_iteracoes']
    )
    for f in funcionarios:
        usuarios.append({
            'user_id': f.user_id,
            'employee': f.name,
            'nome_exibicao': f.employee_name,
            'roles': frappe.get_roles(f.user_id),
            'pin_definido': bool(f.synapse_pin_hash),
            'pin_hash': f.synapse_pin_hash or None,
            'pin_salt': f.synapse_pin_salt or None,
            'pin_kdf_iteracoes': int(f.synapse_pin_kdf_iteracoes) if f.synapse_pin_kdf_iteracoes else None,
        })

pos_profile_modified = frappe.db.get_value('POS Profile', pos_profile, 'modified')
carimbos = [str(pos_profile_modified)] + [str(f.modified) for f in funcionarios]
versao = max(carimbos)

frappe.response['message'] = {
    'pos_profile': pos_profile,
    'sincronizado_em': frappe.utils.now(),
    'versao': versao,
    'restricao_configurada': restricao_configurada,
    'usuarios_autorizados': usuarios,
}
"""
    SCRIPT_DEFINIR_PIN = """
pin_hash = frappe.form_dict.get('pin_hash')
pin_salt = frappe.form_dict.get('pin_salt')
pin_kdf = frappe.form_dict.get('pin_kdf_iteracoes')

if not pin_hash or not pin_salt or not pin_kdf:
    frappe.throw('pin_hash, pin_salt e pin_kdf_iteracoes sao obrigatorios')

if len(pin_hash) < 32 or pin_hash.isdigit():
    frappe.throw('pin_hash nao parece ser um hash valido — operacao recusada por seguranca')

try:
    iteracoes = int(pin_kdf)
except (TypeError, ValueError):
    frappe.throw('pin_kdf_iteracoes precisa ser um numero inteiro')

emp = frappe.get_all('Employee', filters={'user_id': frappe.session.user}, fields=['name'], limit_page_length=1)
if not emp:
    frappe.throw('Nenhum funcionario do Ritmo esta vinculado a este usuario — nao e possivel definir PIN offline')

doc = frappe.get_doc('Employee', emp[0].name)
doc.synapse_pin_hash = pin_hash
doc.synapse_pin_salt = pin_salt
doc.synapse_pin_kdf_iteracoes = iteracoes
doc.synapse_pin_definido_em = frappe.utils.now()
doc.save(ignore_permissions=True)
frappe.db.commit()

frappe.response['message'] = {'ok': True, 'employee': doc.name, 'definido_em': str(doc.synapse_pin_definido_em)}
"""
    scripts = {
        "synapse_sincronizar_caixa": SCRIPT_SINCRONIZAR,
        "synapse_definir_pin": SCRIPT_DEFINIR_PIN,
    }
    for nome, corpo in scripts.items():
        if frappe.db.exists("Server Script", nome):
            doc = frappe.get_doc("Server Script", nome)
            doc.script = corpo
            doc.save(ignore_permissions=True)
            print(f"Server Script '{nome}' atualizado")
        else:
            frappe.get_doc({
                "doctype": "Server Script", "name": nome,
                "script_type": "API", "api_method": nome, "allow_guest": 0,
                "script": corpo
            }).insert(ignore_permissions=True)
            print(f"Server Script '{nome}' criado -> /api/method/{nome}")
    frappe.db.commit()
PYEOF
ok "Endpoints do Caixa offline prontos: /api/method/synapse_sincronizar_caixa (GET) e /api/method/synapse_definir_pin (POST)"

ritmo_exec > /tmp/synapse_roles.log <<PYEOF
def main():
    import frappe
    for role in ["Synapse Administrador", "Synapse Lojista", "Synapse Funcionário"]:
        if not frappe.db.exists("Role", role):
            frappe.get_doc({"doctype": "Role", "role_name": role, "desk_access": 0}).insert(ignore_permissions=True)
            print(f"criada: {role}")
        else:
            print(f"já existia: {role}")
    frappe.db.commit()
PYEOF
ok "Roles Synapse garantidas"

# =============================================================================
# 8.5 USUÁRIO DE LOGIN DO PAINEL (mesmo EMAIL/SENHA de /root/synapse_credentials.txt)
#    O "bench new-site --admin-password" (seção anterior) só define a senha
#    do usuário especial "Administrator" do Frappe — que não tem esse e-mail.
#    O Painel faz login chamando /api/method/login com o EMAIL/SENHA salvos
#    nas credenciais (ver synapse_painel.html: Ritmo.login()), então sem
#    criar explicitamente um User com esse e-mail, login nenhum funciona —
#    é exatamente essa a conta que faltava.
# =============================================================================
log "Criando usuário de login do Painel (${EMAIL})..."
ritmo_exec > /tmp/synapse_admin_user.log <<PYEOF
def main():
    import frappe
    email = "${EMAIL}"
    roles_necessarias = ["System Manager", "Synapse Administrador"]
    if not frappe.db.exists("User", email):
        user = frappe.get_doc({
            "doctype": "User", "email": email, "first_name": "${NOME_LOJA}",
            "user_type": "System User", "send_welcome_email": 0,
            "new_password": "${SENHA}",
            "roles": [{"role": r} for r in roles_necessarias]
        })
        user.insert(ignore_permissions=True)
        print(f"Usuário {email} criado com roles {roles_necessarias}")
    else:
        user = frappe.get_doc("User", email)
        ja_tem = {r.role for r in user.roles}
        for role in roles_necessarias:
            if role not in ja_tem:
                user.append("roles", {"role": role})
        user.new_password = "${SENHA}"
        user.save(ignore_permissions=True)
        print(f"Usuário {email} já existia — roles/senha confirmadas")
    frappe.db.commit()
PYEOF
if grep -qE "criad|confirmadas" /tmp/synapse_admin_user.log; then
  ok "Usuário ${EMAIL} pronto no Ritmo com System Manager + Synapse Administrador — é essa a conta que loga no Painel"
else
  # FATAL, não aviso: sem este usuário, login nenhum funciona no Painel —
  # nem o login online inicial que sincroniza a lista de operadores
  # autorizados do Caixa, nem nada do PDV depende disso (seção 13/17 da
  # instrução obrigatória). Seguir "parcialmente instalado" aqui deixaria
  # o cliente com um PDV que não abre.
  fatal "Não consegui confirmar a criação do usuário ${EMAIL} no Ritmo — veja /tmp/synapse_admin_user.log. Sem isso, o login no Painel (e portanto o PDV) não funciona."
fi

ritmo_exec > /tmp/synapse_tema.log <<PYEOF
def main():
    import frappe
    if not frappe.db.exists("DocType", "Synapse Tema Loja"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Tema Loja", "module": "Custom", "custom": 1,
            "autoname": "field:nome_tema",
            "fields": [
                {"fieldname": "nome_tema", "label": "Nome do Tema", "fieldtype": "Data", "reqd": 1, "unique": 1},
                {"fieldname": "ativo", "label": "Ativo", "fieldtype": "Check", "default": "0"},
                {"fieldname": "configuracoes_json", "label": "Configurações (JSON)", "fieldtype": "Code", "options": "JSON"}
            ],
            "permissions": [
                {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1},
                {"role": "Synapse Lojista", "read": 1, "write": 1, "create": 1}
            ]
        }).insert(ignore_permissions=True)
        print("DocType 'Synapse Tema Loja' criado")
    else:
        print("DocType 'Synapse Tema Loja' já existia")
    frappe.db.commit()
PYEOF
ok "DocType 'Synapse Tema Loja' garantido"

ritmo_exec > /tmp/synapse_cred.log <<PYEOF
def main():
    import frappe, json
    schema = json.loads(r'''
{
  "doctype": "DocType",
  "name": "Synapse Credencial Externa",
  "module": "Synapse",
  "custom": 1,
  "istable": 0,
  "issingle": 0,
  "track_changes": 1,
  "autoname": "field:credencial_id",
  "sort_field": "modified",
  "sort_order": "DESC",
  "fields": [
    {
      "fieldname": "credencial_id",
      "fieldtype": "Data",
      "label": "ID",
      "unique": 1,
      "reqd": 1,
      "description": "Ex.: melhorenvio, infinitepay, gmc, gads, msads, meta, whatsapp, telegram, sms — um registro por provedor conectado."
    },
    {
      "fieldname": "provedor",
      "fieldtype": "Data",
      "label": "Provedor",
      "reqd": 1,
      "description": "Chave usada pelo painel (plataforma). Ex.: 'gmc', 'melhorenvio', 'whatsapp'."
    },
    {
      "fieldname": "categoria",
      "fieldtype": "Select",
      "label": "Categoria",
      "reqd": 1,
      "options": "marketing\nenvio\npagamento\natendimento"
    },
    {
      "fieldname": "status",
      "fieldtype": "Select",
      "label": "Status",
      "default": "desconectado",
      "options": "desconectado\nconectado\nexpirado\nerro"
    },
    {
      "fieldname": "conta_conectada",
      "fieldtype": "Data",
      "label": "Conta Conectada",
      "description": "Nome/handle exibido ao lojista (nunca um ID técnico). Ex.: 'joao@gmail.com', '@minhaloja'."
    },
    {
      "fieldname": "sec_credenciais",
      "fieldtype": "Section Break",
      "label": "Credenciais (nunca lidas pelo painel)"
    },
    {
      "fieldname": "access_token",
      "fieldtype": "Password",
      "label": "Access Token"
    },
    {
      "fieldname": "refresh_token",
      "fieldtype": "Password",
      "label": "Refresh Token"
    },
    {
      "fieldname": "expira_em",
      "fieldtype": "Datetime",
      "label": "Token Expira Em",
      "description": "Usado pelo workflow de renovação automática pra saber quando reautenticar."
    },
    {
      "fieldname": "metadados",
      "fieldtype": "Long Text",
      "label": "Metadados (JSON)",
      "description": "Qualquer campo específico do provedor que não mereça virar coluna própria."
    },
    {
      "fieldname": "sec_cache",
      "fieldtype": "Section Break",
      "label": "Cache de leitura (o painel lê só isto)"
    },
    {
      "fieldname": "saldo",
      "fieldtype": "Data",
      "label": "Saldo / Crédito"
    },
    {
      "fieldname": "consumo_diario",
      "fieldtype": "Data",
      "label": "Consumo Diário"
    },
    {
      "fieldname": "roas",
      "fieldtype": "Data",
      "label": "ROAS Geral"
    },
    {
      "fieldname": "cache_atualizado_em",
      "fieldtype": "Datetime",
      "label": "Cache Atualizado Em"
    }
  ],
  "permissions": [
    {
      "role": "System Manager",
      "read": 1,
      "write": 1,
      "create": 1,
      "delete": 1
    },
    {
      "role": "Synapse Automação",
      "read": 1,
      "write": 1,
      "create": 1,
      "if_owner": 0,
      "print": 0,
      "email": 0,
      "export": 0,
      "report": 0,
      "description": "Papel de serviço usado só pela API key do Harmonia — não deve existir papel que dê acesso de leitura direta a access_token/refresh_token pra usuário humano nenhum, nem admin da loja."
    }
  ]
}
''')
    if not frappe.db.exists("Module Def", schema["module"]):
        frappe.get_doc({"doctype": "Module Def", "module_name": schema["module"], "app_name": "frappe", "custom": 1}).insert(ignore_permissions=True)
    if frappe.db.exists("DocType", schema["name"]):
        frappe.delete_doc("DocType", schema["name"], force=True, ignore_permissions=True)
        print("DocType '" + schema["name"] + "' existia com schema antigo — recriado com o schema oficial")
    else:
        print("DocType '" + schema["name"] + "' criado com o schema oficial")
    frappe.get_doc(schema).insert(ignore_permissions=True)
    frappe.db.commit()
PYEOF
ok "DocType 'Synapse Credencial Externa' garantido com o schema oficial (é aqui que o painel grava Melhor Envio/InfinitePay/99)"

ritmo_exec > /tmp/synapse_fields.log <<PYEOF
def main():
    import frappe
    from frappe.custom.doctype.custom_field.custom_field import create_custom_fields
    create_custom_fields({
        "Company": [
            {"fieldname": "synapse_certificado_a1", "label": "Certificado A1 (arquivo)", "fieldtype": "Attach", "insert_after": "company_name"},
            {"fieldname": "synapse_certificado_senha", "label": "Senha do Certificado A1", "fieldtype": "Password", "insert_after": "synapse_certificado_a1"},
            # Campos do formulário de Empresa (aba Fiscal). CNPJ NÃO tem campo
            # novo aqui — usa o "tax_id" nativo do Company, que já existe pra
            # isso (confirmado no schema real do ERPNext v15). Existe também
            # um "cnpj"/"inscricao_estadual" em NF Company Settings (doctype
            # do app brazil_nf, escopo diferente — configuração específica do
            # importador de NF-e). Não sincronizamos os dois automaticamente
            # aqui; é uma decisão em aberto, não uma omissão silenciosa.
            {"fieldname": "synapse_nome_fantasia", "label": "Nome Fantasia", "fieldtype": "Data", "insert_after": "synapse_certificado_senha"},
            {"fieldname": "synapse_endereco", "label": "Endereço", "fieldtype": "Data", "insert_after": "synapse_nome_fantasia"},
            {"fieldname": "synapse_cnae", "label": "CNAE Principal", "fieldtype": "Data", "insert_after": "synapse_endereco"},
            {"fieldname": "synapse_ie", "label": "Inscrição Estadual", "fieldtype": "Data", "insert_after": "synapse_cnae"},
            {"fieldname": "synapse_regime_tributario", "label": "Regime Tributário", "fieldtype": "Select",
             "options": "\\nsimples\\nsimples-excesso\\nnormal", "insert_after": "synapse_ie"},
            {"fieldname": "synapse_email_contador", "label": "E-mail do Contador", "fieldtype": "Data", "insert_after": "synapse_regime_tributario"},
        ],
        "Bank Account": [
            {"fieldname": "synapse_codigo_banco", "label": "Código do Banco", "fieldtype": "Data", "insert_after": "bank"},
            {"fieldname": "synapse_tipo_conta", "label": "Tipo de Conta", "fieldtype": "Select", "options": "corrente\\npoupanca", "insert_after": "synapse_codigo_banco"},
            {"fieldname": "synapse_chave_pix", "label": "Chave PIX", "fieldtype": "Data", "insert_after": "synapse_tipo_conta"},
        ],
        "Employee": [
            # PIN do Caixa offline — nunca a senha do Ritmo. Fieldtype "Data"
            # de propósito, não "Password": o endpoint synapse_sincronizar_caixa
            # precisa devolver hash+salt pro terminal guardar localmente e
            # comparar ali; o fieldtype "Password" do Frappe criptografa e
            # NUNCA devolve o valor por API (nem pro dono do próprio registro),
            # o que quebraria exatamente o mecanismo que este campo existe pra
            # viabilizar. A proteção real destes dados é a mesma do resto do
            # Ritmo (acesso ao banco), não uma camada extra — ver proposta de
            # segurança: PIN curto + storage local copiado é força-bruta
            # viável, isto não é apresentado como garantia diferente disso.
            {"fieldname": "synapse_pin_hash", "label": "Synapse — Hash do PIN (Caixa offline)", "fieldtype": "Data", "insert_after": "user_id", "read_only": 1},
            {"fieldname": "synapse_pin_salt", "label": "Synapse — Salt do PIN", "fieldtype": "Data", "insert_after": "synapse_pin_hash", "read_only": 1},
            {"fieldname": "synapse_pin_kdf_iteracoes", "label": "Synapse — Iterações PBKDF2", "fieldtype": "Int", "insert_after": "synapse_pin_salt", "read_only": 1},
            {"fieldname": "synapse_pin_definido_em", "label": "Synapse — PIN definido em", "fieldtype": "Datetime", "insert_after": "synapse_pin_kdf_iteracoes", "read_only": 1},
            # Endereço do funcionário: o Painel (salvarEnderecoFuncionario) grava estes 3
            # campos direto no Employee. Nunca tinham sido provisionados em lugar nenhum.
            {"fieldname": "synapse_cep", "label": "Synapse — CEP", "fieldtype": "Data", "insert_after": "synapse_pin_definido_em"},
            {"fieldname": "synapse_cidade_uf", "label": "Synapse — Cidade/UF", "fieldtype": "Data", "insert_after": "synapse_cep"},
            {"fieldname": "synapse_endereco", "label": "Synapse — Endereço", "fieldtype": "Data", "insert_after": "synapse_cidade_uf"},
        ],
        "POS Opening Entry": [
            # Chave de idempotência da abertura de caixa: o Painel consulta por ela antes de
            # gravar (jaExiste), então uma retentativa da fila offline nunca duplica a abertura.
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "pos_profile", "unique": 1, "read_only": 1},
        ],
        "POS Closing Entry": [
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "pos_profile", "unique": 1, "read_only": 1},
        ],
        "POS Invoice": [
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "pos_profile", "unique": 1, "read_only": 1},
            # Quem realmente registrou a venda no terminal — não necessariamente
            # quem está com sessão aberta no Ritmo no momento em que a fila
            # sincroniza (pode ser outra pessoa, ou pode ter sido offline).
            # Não usamos o campo nativo "owner" do Frappe pra isso: nunca
            # verificamos se um POST autenticado comum consegue sobrescrevê-lo
            # (é campo de sistema, comportamento não documentado o bastante pra
            # apostar). Um campo próprio é gravável por definição — nós que o
            # criamos.
            {"fieldname": "synapse_operador_real", "label": "Synapse — Operador real (Caixa offline)", "fieldtype": "Data", "insert_after": "synapse_op_id", "read_only": 1},
            # Item 6 (Fase 1) — mesa/comanda/senha. Não existe campo nativo
            # equivalente no ERPNext; opcional, só preenchido quando a venda
            # tem atendimento identificado. Contrato idêntico ao já usado no
            # instalador central (instalar_nomen_completo.sh) — mesmo nome,
            # mesmo fieldtype, mesma posição relativa.
            {"fieldname": "synapse_identificacao_atendimento", "label": "Synapse — Mesa/Comanda/Senha", "fieldtype": "Data", "insert_after": "synapse_operador_real"},
        ],
        "Sales Order": [
            # Pedido de Venda offline — mesmo par de campos do POS Invoice,
            # pelo mesmo motivo: idempotência (synapse_op_id, Sales Order
            # também autonomeia por naming_series) e identidade real de quem
            # criou o pedido, que pode ser diferente de quem sincroniza.
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "customer", "unique": 1, "read_only": 1},
            {"fieldname": "synapse_operador_real", "label": "Synapse — Operador real (Pedido offline)", "fieldtype": "Data", "insert_after": "synapse_op_id", "read_only": 1},
            {"fieldname": "synapse_identificacao_atendimento", "label": "Synapse — Mesa/Comanda/Senha", "fieldtype": "Data", "insert_after": "synapse_operador_real"},
        ],
        "POS Invoice Item": [
            # Item 2.3 (Fase 1) — item genérico: nunca cria um Item novo no
            # catálogo por venda (ver ITEM_GENERICO_CODE no cliente); estes
            # campos só marcam a linha como genérica e guardam quem autorizou.
            # Faltavam neste provisionador — confirmados existentes no
            # instalador central, nunca transportados pra cá até agora.
            {"fieldname": "synapse_item_generico", "label": "Synapse — Item genérico", "fieldtype": "Check", "insert_after": "rate"},
            {"fieldname": "synapse_preco_autorizado_por", "label": "Synapse — Preço autorizado por", "fieldtype": "Data", "insert_after": "synapse_item_generico", "read_only": 1},
            {"fieldname": "synapse_preco_motivo", "label": "Synapse — Motivo do preço autorizado", "fieldtype": "Data", "insert_after": "synapse_preco_autorizado_por", "read_only": 1},
        ],
        "Sales Order Item": [
            {"fieldname": "synapse_item_generico", "label": "Synapse — Item genérico", "fieldtype": "Check", "insert_after": "rate"},
            {"fieldname": "synapse_preco_autorizado_por", "label": "Synapse — Preço autorizado por", "fieldtype": "Data", "insert_after": "synapse_item_generico", "read_only": 1},
            {"fieldname": "synapse_preco_motivo", "label": "Synapse — Motivo do preço autorizado", "fieldtype": "Data", "insert_after": "synapse_preco_autorizado_por", "read_only": 1},
        ],
        "POS Profile": [
            # Item 4.2 (Fase 1) — acréscimos (frete/embalagem/taxa de serviço)
            # viram linhas reais em Sales Taxes and Charges, que exige uma
            # Account. Configurada uma vez aqui; sem isso, sincronizar uma
            # venda/pedido com acréscimo falha com mensagem clara (ver
            # pdvMapearAjustesDocParaRitmo no painel) em vez de adivinhar
            # uma conta contábil que pode não existir nesse plano de contas.
            {"fieldname": "synapse_conta_acrescimos", "label": "Synapse — Conta contábil para acréscimos", "fieldtype": "Link", "options": "Account", "insert_after": "selling_price_list"},
        ],
        "Customer": [
            # Fecha uma lacuna real de idempotência: buscar Customer por
            # tax_id não ajuda quando o pedido não tem CPF/CNPJ (cliente sem
            # documento) — nesse caso não havia NENHUMA chave estável pra uma
            # retentativa achar o Customer que uma tentativa anterior já
            # criou, e cada retry criava um Customer novo. Este campo guarda
            # o op_id do Pedido que criou o Customer, e passa a ser a SEGUNDA
            # busca (depois de tax_id) antes de decidir criar — cobre
            # justamente o caso sem documento, e reforça o caso com
            # documento contra a própria retentativa da mesma operação.
            # NÃO resolve duas operações DIFERENTES com o mesmo tax_id
            # correndo ao mesmo tempo em terminais diferentes — isso exigiria
            # uma constraint de unicidade em tax_id no banco, que não aplico
            # às cegas aqui sem saber se já existem tax_id duplicados/vazios
            # nos dados reais de vocês. Ver nota na entrega.
            {"fieldname": "synapse_pedido_op_id", "label": "Synapse — Pedido que criou este cliente", "fieldtype": "Data", "insert_after": "customer_name", "read_only": 1},
        ]
    }, ignore_validate=True)
    frappe.db.commit()
    print("Campos customizados garantidos")
PYEOF
ok "Campos customizados (Company, Bank Account, Employee, POS Opening/Closing/Invoice, Sales Order, POS Invoice Item, Sales Order Item, POS Profile, Customer) garantidos"

ritmo_exec > /tmp/synapse_warehouse_type.log <<PYEOF
def main():
    import frappe
    # Unidades e Filiais filtram Warehouse por warehouse_type 'Loja' e 'Deposito' (sem acento,
    # exatamente como o Painel usa). Os dois tipos precisam existir antes da primeira filial.
    for nome in ["Loja", "Deposito"]:
        if not frappe.db.exists("Warehouse Type", nome):
            frappe.get_doc({"doctype": "Warehouse Type", "name": nome}).insert(ignore_permissions=True)
            print(f"Warehouse Type '{nome}' criado")
        else:
            print(f"Warehouse Type '{nome}' já existia")
    frappe.db.commit()
PYEOF
ok "Warehouse Type 'Loja' e 'Deposito' garantidos (Unidades e Filiais dependem dos dois)"

# =============================================================================
# 8.4 ITEM GENÉRICO — item coringa usado pelo PDV pra vendas de itens
#    excepcionais não cadastrados no catálogo (ver ITEM_GENERICO_CODE no
#    painel). Contrato idêntico ao instalador central: um único Item
#    criado uma vez na instalação (infraestrutura), nunca um Item novo por
#    venda. Seção 6 da instrução obrigatória: isto é requisito do novo PDV,
#    não pode depender de criação manual depois — por isso, diferente do
#    instalador central (que só avisava e seguia), aqui a ausência de
#    Item Group/UOM é FATAL: sem este item, a operação "item genérico" do
#    PDV (seção 13 da instrução) fica inoperante em qualquer cliente novo.
# =============================================================================
RESULT_ITEM_GENERICO=$(ritmo_exec <<'PYEOF'
def main():
    import frappe
    if frappe.db.exists("Item", "ITEM-GENERICO"):
        print("SYNAPSE_KV|status|ja_existia")
        return
    grupo = "All Item Groups" if frappe.db.exists("Item Group", "All Item Groups") else frappe.db.get_value("Item Group", {}, "name")
    uom = frappe.db.get_value("UOM", {}, "name")
    if not grupo or not uom:
        print("SYNAPSE_KV|status|sem_dependencia")
        return
    frappe.get_doc({
        "doctype": "Item", "item_code": "ITEM-GENERICO", "item_name": "Item genérico (preço livre)",
        "item_group": grupo, "stock_uom": uom,
        "is_stock_item": 0,  # não é produto físico rastreável em estoque — só um veículo pra descrição/preço livres
        "description": "Item coringa usado pelo PDV para vendas de itens excepcionais não cadastrados no catálogo. Não vender fisicamente por este código — a descrição real vem da linha da venda.",
    }).insert(ignore_permissions=True)
    frappe.db.commit()
    print(f"SYNAPSE_KV|status|criado")
    print(f"SYNAPSE_KV|grupo|{grupo}")
    print(f"SYNAPSE_KV|uom|{uom}")
PYEOF
)
ITEM_GENERICO_STATUS=$(echo "$RESULT_ITEM_GENERICO" | grep '^SYNAPSE_KV|status|' | cut -d'|' -f3)
case "$ITEM_GENERICO_STATUS" in
  criado)
    ITEM_GENERICO_GRUPO=$(echo "$RESULT_ITEM_GENERICO" | grep '^SYNAPSE_KV|grupo|' | cut -d'|' -f3)
    ITEM_GENERICO_UOM=$(echo "$RESULT_ITEM_GENERICO" | grep '^SYNAPSE_KV|uom|' | cut -d'|' -f3)
    ok "Item 'ITEM-GENERICO' criado (grupo: ${ITEM_GENERICO_GRUPO} | uom: ${ITEM_GENERICO_UOM})"
    ;;
  ja_existia) ok "Item 'ITEM-GENERICO' já existia — mantido como está" ;;
  *) fatal "Não foi possível criar o Item 'ITEM-GENERICO' — nenhum Item Group nem UOM existe ainda neste site (${DOMINIO_ERP}). Isto não pode acontecer num ERPNext recém-instalado com app 'erpnext' presente (ele semeia Item Group/UOM padrão); confira 'bench --site ${DOMINIO_ERP} list-apps' antes de rodar de novo. Saída: ${RESULT_ITEM_GENERICO}. A operação 'item genérico' do PDV (seção 13) não funciona sem isto, por isso a instalação foi interrompida em vez de seguir parcialmente funcional." ;;
esac

log "Criando usuário de automação para o Harmonia..."
RESULT_AUTOMACAO=$(ritmo_exec <<PYEOF
def main():
    import frappe
    role_name = "Synapse Automação"
    if not frappe.db.exists("Role", role_name):
        frappe.get_doc({"doctype": "Role", "role_name": role_name, "desk_access": 0}).insert(ignore_permissions=True)

    user_email = "auto@nomen.me"
    if not frappe.db.exists("User", user_email):
        user = frappe.get_doc({
            "doctype": "User", "email": user_email, "first_name": "Harmonia (Automação)",
            "user_type": "System User", "send_welcome_email": 0,
            "roles": [{"role": role_name}, {"role": "System Manager"}]
        })
        user.insert(ignore_permissions=True)
    else:
        user = frappe.get_doc("User", user_email)

    user.api_key = frappe.generate_hash(length=15)
    if not user.get_password("api_secret", raise_exception=False):
        user.api_secret = frappe.generate_hash(length=15)
    user.save(ignore_permissions=True)
    frappe.db.commit()

    print(f"SYNAPSE_KV|api_key|{user.api_key}")
    print(f"SYNAPSE_KV|api_secret|{user.get_password('api_secret')}")
PYEOF
)
ERP_API_KEY=$(echo "$RESULT_AUTOMACAO" | grep '^SYNAPSE_KV|api_key|' | cut -d'|' -f3)
ERP_API_SECRET=$(echo "$RESULT_AUTOMACAO" | grep '^SYNAPSE_KV|api_secret|' | cut -d'|' -f3)
if [ -n "$ERP_API_KEY" ] && [ -n "$ERP_API_SECRET" ]; then
  salvar_credencial "ERP_API_KEY" "$ERP_API_KEY"
  salvar_credencial "ERP_API_SECRET" "$ERP_API_SECRET"
  ok "Usuário de automação auto@nomen.me pronto — chave capturada"
else
  err "Não consegui capturar api_key/api_secret do usuário de automação. Saída: ${RESULT_AUTOMACAO}"
fi

docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" clear-cache

log "Criando Empresa Padrão e aplicando Plano de Contas BR..."
RESULT_COMPANY=$(ritmo_exec <<PYEOF
def main():
    import frappe

    nome_empresa = "${NOME_LOJA}"

    if not frappe.db.exists("Company", nome_empresa):
        # Não chutamos um nome fixo de plano de contas — "Standard" é o
        # genérico do Frappe, não o brasileiro. Perguntamos ao próprio
        # ERPNext (mesma função que o Setup Wizard usa) quais planos
        # existem pra "Brazil" nos apps instalados, e usamos o primeiro.
        # Se nenhum vier (nenhuma localização BR instalada), caímos pro
        # genérico mas avisamos de forma explícita — nunca em silêncio.
        coa = "Standard"
        coa_e_brasileiro = False
        try:
            from erpnext.accounts.doctype.account.chart_of_accounts.chart_of_accounts import get_charts_for_country
            opcoes = get_charts_for_country("Brazil") or []
            if opcoes:
                coa = opcoes[0]
                coa_e_brasileiro = True
        except Exception as e:
            print(f"SYNAPSE_KV|coa_erro|{e}")

        try:
            doc = frappe.get_doc({
                "doctype": "Company",
                "company_name": nome_empresa,
                "default_currency": "BRL",
                "country": "Brazil",
                "chart_of_accounts": coa,
            })
            doc.insert(ignore_permissions=True)
            frappe.db.commit()
            print(f"SYNAPSE_KV|company_status|criada")
            print(f"SYNAPSE_KV|coa_usado|{coa}")
            print(f"SYNAPSE_KV|coa_brasileiro|{coa_e_brasileiro}")
        except Exception as e:
            frappe.db.rollback()
            print(f"SYNAPSE_KV|company_status|falhou")
            print(f"SYNAPSE_KV|company_erro|{e}")
            return
    else:
        print(f"SYNAPSE_KV|company_status|ja_existia")

    frappe.db.set_single_value("Global Defaults", "default_company", nome_empresa)
    frappe.db.set_single_value("Global Defaults", "default_currency", "BRL")
    frappe.db.set_single_value("Global Defaults", "country", "Brazil")
    frappe.db.commit()
PYEOF
)
COMPANY_STATUS=$(echo "$RESULT_COMPANY" | grep '^SYNAPSE_KV|company_status|' | cut -d'|' -f3)
COA_USADO=$(echo "$RESULT_COMPANY" | grep '^SYNAPSE_KV|coa_usado|' | cut -d'|' -f3)
COA_BRASILEIRO=$(echo "$RESULT_COMPANY" | grep '^SYNAPSE_KV|coa_brasileiro|' | cut -d'|' -f3)
case "$COMPANY_STATUS" in
  criada)
    if [ "$COA_BRASILEIRO" = "True" ]; then
      ok "Empresa '${NOME_LOJA}' criada com Plano de Contas BR real: '${COA_USADO}'"
    else
      warn "Empresa '${NOME_LOJA}' criada, mas NENHUM plano de contas brasileiro foi encontrado instalado — usou o genérico '${COA_USADO}'. Confirme manualmente se algum app de localização BR precisa ser instalado."
    fi
    ;;
  ja_existia) ok "Empresa '${NOME_LOJA}' já existia — mantida como está" ;;
  # FATAL, não aviso: Company é a raiz de praticamente todo doctype de
  # venda do ERPNext (POS Profile, Warehouse, Sales Order, POS Invoice...).
  # Sem ela, abertura de caixa e venda (seção 13) não têm onde existir —
  # não é um estado "parcialmente funcional", é "não funciona".
  *) fatal "Falha ao criar a Empresa '${NOME_LOJA}'. Saída: ${RESULT_COMPANY}" ;;
esac

# =============================================================================
# 5.5 RITMO — MOTOR DE COMPOSIÇÃO (itens compostos / "montador" do PDV +
#     rastreamento de produção)
#     (o Painel do PDV assume "Synapse Composicao" / "Synapse Producao Item" como existentes)
# =============================================================================
log "Provisionando Motor de Composição (itens compostos + produção)..."

RESULT_COMPOSICAO=$(ritmo_exec <<'PYEOF'
def main():
    import frappe

    if not frappe.db.exists("Module Def", "Synapse"):
        frappe.get_doc({"doctype": "Module Def", "module_name": "Synapse", "app_name": "frappe", "custom": 1}).insert(ignore_permissions=True)

    # ---- 1) Synapse Composicao Opcao (child table, sem dependência) ----
    if not frappe.db.exists("DocType", "Synapse Composicao Opcao"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Composicao Opcao", "module": "Synapse",
            "custom": 1, "istable": 1,
            "fields": [
                {"fieldname": "nome", "label": "Nome", "fieldtype": "Data", "reqd": 1, "in_list_view": 1},
                {"fieldname": "preco", "label": "Ajuste de Preço", "fieldtype": "Currency", "default": "0", "in_list_view": 1},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Composicao Opcao")
    else:
        print("ja existia: Synapse Composicao Opcao")

    # ---- 2) Synapse Composicao Grupo (child table; composicao_filha vem depois, quebra de dependência circular) ----
    if not frappe.db.exists("DocType", "Synapse Composicao Grupo"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Composicao Grupo", "module": "Synapse",
            "custom": 1, "istable": 1,
            "fields": [
                {"fieldname": "nome", "label": "Nome", "fieldtype": "Data", "reqd": 1, "in_list_view": 1},
                {"fieldname": "min", "label": "Mínimo", "fieldtype": "Int", "default": "0", "in_list_view": 1},
                {"fieldname": "max", "label": "Máximo", "fieldtype": "Int", "default": "1", "in_list_view": 1},
                {"fieldname": "regra", "label": "Regra", "fieldtype": "Select", "options": "soma\nproporcional", "default": "soma"},
                {"fieldname": "opcoes", "label": "Opções", "fieldtype": "Table", "options": "Synapse Composicao Opcao"},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Composicao Grupo")
    else:
        print("ja existia: Synapse Composicao Grupo")

    # ---- 3) Synapse Composicao (pai) ----
    if not frappe.db.exists("DocType", "Synapse Composicao"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Composicao", "module": "Synapse",
            "custom": 1, "istable": 0, "autoname": "field:titulo",
            "fields": [
                {"fieldname": "titulo", "label": "Título", "fieldtype": "Data", "reqd": 1, "unique": 1, "in_list_view": 1},
                {"fieldname": "grupos", "label": "Grupos", "fieldtype": "Table", "options": "Synapse Composicao Grupo"},
            ],
            "permissions": [
                {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1},
                {"role": "Synapse Lojista", "read": 1, "write": 1, "create": 1},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Composicao")
    else:
        print("ja existia: Synapse Composicao")

    # ---- 4) fecha a recursão: adiciona composicao_filha no Grupo agora que Composicao existe ----
    grupo_doc = frappe.get_doc("DocType", "Synapse Composicao Grupo")
    if not any(f.fieldname == "composicao_filha" for f in grupo_doc.fields):
        grupo_doc.append("fields", {
            "fieldname": "composicao_filha", "label": "Composição Filha (recursão)",
            "fieldtype": "Link", "options": "Synapse Composicao",
            "insert_after": "regra"
        })
        grupo_doc.save(ignore_permissions=True)
        print("campo composicao_filha adicionado em Synapse Composicao Grupo")
    else:
        print("composicao_filha ja existia em Synapse Composicao Grupo")

    # ---- 5) Custom Field no Item ----
    from frappe.custom.doctype.custom_field.custom_field import create_custom_fields
    create_custom_fields({
        "Item": [
            {"fieldname": "custom_composicao", "label": "Composição (Motor)", "fieldtype": "Link",
             "options": "Synapse Composicao", "insert_after": "item_group"},
        ]
    }, ignore_validate=True)
    print("custom_composicao garantido em Item")

    # ---- 6) Synapse Producao Item ----
    if not frappe.db.exists("DocType", "Synapse Producao Item"):
        frappe.get_doc({
            "doctype": "DocType", "name": "Synapse Producao Item", "module": "Synapse",
            "custom": 1, "istable": 0, "autoname": "field:synapse_op_id",
            "track_changes": 1,
            "fields": [
                {"fieldname": "synapse_op_id", "label": "Op ID (idempotência)", "fieldtype": "Data", "reqd": 1, "unique": 1},
                {"fieldname": "pos_invoice", "label": "POS Invoice", "fieldtype": "Link", "options": "POS Invoice", "in_list_view": 1},
                {"fieldname": "item_code", "label": "Item", "fieldtype": "Link", "options": "Item", "in_list_view": 1},
                {"fieldname": "frase", "label": "Descrição", "fieldtype": "Data", "in_list_view": 1},
                {"fieldname": "preenchimentos_json", "label": "Escolhas (JSON)", "fieldtype": "Long Text"},
                {"fieldname": "alerta", "label": "Alerta Cozinha", "fieldtype": "Check", "default": "0"},
                {"fieldname": "status_producao", "label": "Status", "fieldtype": "Select",
                 "options": "Pendente\nEm Preparo\nPronto\nEnviado\nEntregue\nCancelado",
                 "default": "Pendente", "in_list_view": 1},
            ],
            "permissions": [
                {"role": "System Manager", "read": 1, "write": 1, "create": 1, "delete": 1},
                {"role": "Synapse Lojista", "read": 1, "write": 1, "create": 1},
                {"role": "Synapse Funcionário", "read": 1, "write": 1},
                {"role": "Synapse Automação", "read": 1, "write": 1, "create": 1},
            ]
        }).insert(ignore_permissions=True)
        print("criado: Synapse Producao Item")
    else:
        print("ja existia: Synapse Producao Item")

    frappe.db.commit()
PYEOF
)
echo "$RESULT_COMPOSICAO" > /tmp/synapse_composicao.log

if echo "$RESULT_COMPOSICAO" | grep -qiE "Traceback|Error|Exception"; then
  err "Motor de Composição: a execução no Ritmo devolveu erro — ver /tmp/synapse_composicao.log. O restante do provisionamento continua, mas o 'montador' do PDV vai ficar quebrado até isto ser corrigido (rode este script de novo depois — é idempotente)."
else
  docker exec ritmo-backend-1 bench --site "${DOMINIO_ERP}" clear-cache

  # Verificação real (não confia só em não ter dado erro acima) — consulta o
  # próprio Ritmo pra confirmar que cada DocType/campo existe de fato.
  VERIFICACAO_COMPOSICAO=$(ritmo_exec <<'PYEOF'
def main():
    import frappe
    esperado = [
        "Synapse Composicao Opcao",
        "Synapse Composicao Grupo",
        "Synapse Composicao",
        "Synapse Producao Item",
    ]
    for nome in esperado:
        print(f"SYNAPSE_CHECK|{nome}|{1 if frappe.db.exists('DocType', nome) else 0}")
    tem_campo = frappe.db.exists("Custom Field", {"dt": "Item", "fieldname": "custom_composicao"})
    print(f"SYNAPSE_CHECK|Item.custom_composicao|{1 if tem_campo else 0}")
PYEOF
)
  FALHOU_COMPOSICAO=0
  while IFS='|' read -r _ nome existe; do
    [ -z "$nome" ] && continue
    if [ "$existe" = "1" ]; then
      ok "Motor de Composição: confirmado '${nome}'"
    else
      err "Motor de Composição: NÃO encontrado '${nome}' — ver /tmp/synapse_composicao.log"
      FALHOU_COMPOSICAO=1
    fi
  done < <(echo "$VERIFICACAO_COMPOSICAO" | grep '^SYNAPSE_CHECK|')

  if [ "$FALHOU_COMPOSICAO" -eq 0 ]; then
    ok "Motor de Composição garantido e confirmado (itens compostos + Kanban de produção prontos para uso no painel)"
  fi
fi

cancao_instalar_ritmo
# =============================================================================
# 6. N8N (HARMONIA)
#    docker-compose usa "env_file: .env" (não valores fixos) — assim as
#    fases seguintes só escrevem no .env e reiniciam, sem tocar no compose.
# =============================================================================
log "Instalando N8N (Harmonia)..."
mkdir -p /home/ubuntu/n8n
cat > /home/ubuntu/n8n/docker-compose.yml << EOF
services:
  n8n:
    image: n8nio/n8n:${SYNAPSE_N8N_VERSION}
    container_name: harmonia
    restart: always
    env_file: .env
    volumes:
      - harmonia_data:/home/node/.n8n
    networks:
      - stack-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.harmonia.rule=Host(\`${DOMINIO_N8N}\`) && (PathPrefix(\`/webhook\`) || PathPrefix(\`/webhook-test\`) || PathPrefix(\`/api/v1\`) || PathPrefix(\`/healthz\`))"
      - "traefik.http.routers.harmonia.entrypoints=websecure"
      - "traefik.http.routers.harmonia.tls.certresolver=myresolver"
      - "traefik.http.routers.harmonia.priority=10"
      - "traefik.http.services.harmonia.loadbalancer.server.port=5678"
volumes:
  harmonia_data:
networks:
  stack-network:
    external: true
EOF

touch "$N8N_ENV_FILE"; chmod 600 "$N8N_ENV_FILE"
grava_env_n8n "N8N_HOST" "${DOMINIO_N8N}"
grava_env_n8n "N8N_PORT" "5678"
grava_env_n8n "N8N_PROTOCOL" "https"
grava_env_n8n "WEBHOOK_URL" "https://${DOMINIO_N8N}/"
grava_env_n8n "N8N_BASIC_AUTH_ACTIVE" "true"
grava_env_n8n "N8N_BASIC_AUTH_USER" "admin"
grava_env_n8n "N8N_BASIC_AUTH_PASSWORD" "${SENHA}"
grava_env_n8n "CHATWOOT_WHATSAPP_INBOX_ID" "1"

cd /home/ubuntu/n8n && docker compose up -d
ok "N8N instalado em https://${DOMINIO_N8N}"

# =============================================================================
# 7. CHATWOOT (HARPA)
# =============================================================================
log "Instalando Chatwoot (Harpa)..."
mkdir -p /home/ubuntu/chatwoot
cat > /home/ubuntu/chatwoot/docker-compose.yml << EOF
services:
  base: &base
    image: chatwoot/chatwoot:${SYNAPSE_CHATWOOT_VERSION}
    env_file: .env
    volumes:
      - harpa_storage:/app/storage
  rails:
    <<: *base
    container_name: harpa-rails
    restart: always
    command: bundle exec rails s -p 3000 -b 0.0.0.0
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.harpa.rule=Host(\`${DOMINIO_CHAT}\`) && (PathPrefix(\`/packs\`) || PathPrefix(\`/widget\`) || PathPrefix(\`/api/v1\`) || PathPrefix(\`/webhooks\`) || PathPrefix(\`/cable\`))"
      - "traefik.http.routers.harpa.entrypoints=websecure"
      - "traefik.http.routers.harpa.tls.certresolver=myresolver"
      - "traefik.http.routers.harpa.priority=10"
      - "traefik.http.services.harpa.loadbalancer.server.port=3000"
  sidekiq:
    <<: *base
    container_name: harpa-sidekiq
    restart: always
    command: bundle exec sidekiq -C config/sidekiq.yml
    networks: [stack-network]
  postgres:
    container_name: harpa-postgres
    # pg16 é o Postgres oficial do docker-compose.production.yaml upstream do
    # Chatwoot para a 4.18.0. Assume volume novo (reinstalação limpa) — se
    # algum dia isso rodar sobre um volume pg15 já existente, precisa de
    # pg_upgrade/dump-restore antes, não é troca direta de tag.
    image: pgvector/pgvector:${SYNAPSE_CHATWOOT_POSTGRES_VERSION}
    restart: always
    environment:
      POSTGRES_DB: harpa
      POSTGRES_USER: harpa
      POSTGRES_PASSWORD: ${SENHA}
    volumes: [harpa_postgres_data:/var/lib/postgresql/data]
    networks: [stack-network]
  redis:
    container_name: harpa-redis
    image: redis:${SYNAPSE_CHATWOOT_REDIS_VERSION}
    restart: always
    volumes: [harpa_redis:/data]
    networks: [stack-network]
volumes:
  harpa_storage:
  harpa_postgres_data:
  harpa_redis:
networks:
  stack-network:
    external: true
EOF

cat > /home/ubuntu/chatwoot/.env << EOF
SECRET_KEY_BASE=${SECRET_KEY}
FRONTEND_URL=https://${DOMINIO_CHAT}
DEFAULT_LOCALE=pt_BR
FORCE_SSL=true
ENABLE_ACCOUNT_SIGNUP=false
REDIS_URL=redis://harpa-redis:6379
POSTGRES_HOST=harpa-postgres
POSTGRES_USERNAME=harpa
POSTGRES_PASSWORD=${SENHA}
POSTGRES_DATABASE=harpa
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
EOF

cd /home/ubuntu/chatwoot
docker compose up -d postgres redis
log "Aguardando PostgreSQL do Chatwoot ficar saudável..."
TENTATIVAS=0
until docker compose exec -T postgres pg_isready -U harpa 2>/dev/null | grep -q "accepting connections"; do
  TENTATIVAS=$((TENTATIVAS+1))
  if [ $TENTATIVAS -ge 30 ]; then err "PostgreSQL do Chatwoot não respondeu a tempo. Seguindo mesmo assim."; break; fi
  sleep 2
done

docker compose stop rails sidekiq 2>/dev/null || true
if docker compose run --rm -T rails bundle exec rails db:chatwoot_prepare; then
  docker compose start rails sidekiq
  ok "Chatwoot instalado em https://${DOMINIO_CHAT}"
else
  err "Falha ao preparar a BD do Chatwoot. Rode depois: cd /home/ubuntu/chatwoot && docker compose run --rm -T rails bundle exec rails db:chatwoot_prepare"
fi
log "Aguardando Chatwoot subir de vez (20s)..."; sleep 20

# =============================================================================
# 8. HARPA — PROVISIONAMENTO (conta, admin, token, inbox webchat)
#    (fusão do antigo 3_provisionar_harpa.sh — domínio do widget dinâmico)
# =============================================================================
log "Provisionando Harpa (conta, admin, token de API)..."
RESULT_HARPA=$(docker exec -i harpa-rails bundle exec rails runner "
account = Account.find_by(name: '${NOME_LOJA}') || Account.create!(name: '${NOME_LOJA}')

user = User.find_by(email: '${EMAIL}')
if user.nil?
  user = User.new(name: 'Administrador Synapse', email: '${EMAIL}', password: '${SENHA}', password_confirmation: '${SENHA}')
  user.skip_confirmation!
  user.save!
end

unless AccountUser.exists?(account: account, user: user)
  AccountUser.create!(account: account, user: user, role: :administrator)
end

token = user.access_token&.token || AccessToken.create!(owner: user).token

inbox = account.inboxes.find_by(name: 'Site Synapse')
if inbox.nil?
  channel = Channel::WebWidget.create!(website_url: 'https://${DOMINIO_PAINEL}', account: account)
  inbox = account.inboxes.create!(name: 'Site Synapse', channel: channel)
end

puts \"SYNAPSE_KV|account_id|#{account.id}\"
puts \"SYNAPSE_KV|api_token|#{token}\"
puts \"SYNAPSE_KV|inbox_id|#{inbox.id}\"
" 2>&1)

CW_ACCOUNT_ID=$(echo "$RESULT_HARPA" | grep '^SYNAPSE_KV|account_id|' | cut -d'|' -f3)
CW_API_TOKEN=$(echo "$RESULT_HARPA" | grep '^SYNAPSE_KV|api_token|' | cut -d'|' -f3)
if [ -n "$CW_ACCOUNT_ID" ] && [ -n "$CW_API_TOKEN" ]; then
  salvar_credencial "CHATWOOT_ACCOUNT_ID" "$CW_ACCOUNT_ID"
  salvar_credencial "CHATWOOT_API_TOKEN" "$CW_API_TOKEN"
  ok "Conta '${NOME_LOJA}' provisionada no Harpa (account_id=${CW_ACCOUNT_ID}) — chave capturada"
else
  err "Não consegui capturar account_id/api_token do Harpa. Saída: ${RESULT_HARPA}"
fi
warn "Inbox de WhatsApp e de E-mail NÃO são criados aqui de propósito (dependem de credenciais de terceiros). WhatsApp: 1 chamada em POST /api/v1/accounts/{id}/inboxes assim que tiver o provider_config."

# =============================================================================
# 9. GRAVA CREDENCIAIS DE INFRA NO .env DO HARMONIA
#    (substitui o antigo 4_atualizar_credenciais_harmonia.sh — sem prompt
#    manual: só as chaves que o próprio provisionamento acabou de gerar.
#    Melhor Envio/InfinitePay/99 ficam fora — o painel grava no Ritmo.
#    GEMINI_API_KEY fica fora — centralizada só na Lyra Central.)
# =============================================================================
log "Gravando credenciais de infra no .env do Harmonia..."
grava_env_n8n "ERPNEXT_DOMAIN" "${DOMINIO_ERP}"   # so o host: todo consumidor prefixa https://
grava_env_n8n "ERPNEXT_API_KEY" "${ERP_API_KEY:-}"
grava_env_n8n "ERPNEXT_API_SECRET" "${ERP_API_SECRET:-}"
grava_env_n8n "CHATWOOT_DOMAIN" "${DOMINIO_CHAT}"   # so o host: todo consumidor prefixa https://
grava_env_n8n "CHATWOOT_API_TOKEN" "${CW_API_TOKEN:-}"
grava_env_n8n "CHATWOOT_ACCOUNT_ID" "${CW_ACCOUNT_ID:-}"
grava_env_n8n "HARMONIA_DOMAIN" "${DOMINIO_N8N}"   # so o host: todo consumidor prefixa https://
grava_env_n8n "N8N_BLOCK_ENV_ACCESS_IN_NODE" "false"   # n8n 2.x bloqueia $env por padrao ("access to env vars denied", verificado no 2.40.7); os workflows leem credenciais via $env

cd /home/ubuntu/n8n && docker compose up -d
ok ".env do Harmonia atualizado e N8N reiniciado"

# =============================================================================
# 9.5 PAINEL — deploy do frontend estático (painel.${DOMINIO_BASE})
#    É o mesmo produto (Painel de operações + PDV) pra todo cliente, sem
#    build: em runtime, ele resolve os domínios de Ritmo/Harmonia/Harpa/Eco
#    a partir do próprio hostname (ver resolverAmbienteSynapse() dentro do
#    arquivo) — nenhum valor precisa ser injetado no HTML por este script
#    (SYNAPSE_CONFIG não tem mais placeholder nenhum pra preencher; o antigo
#    "empresa: null"/"chatwootContaId: null" não existe na versão atual do
#    Painel — nomeEmpresa é resolvido em runtime, lendo o Ritmo).
#
#    O que precisa ser publicado NÃO é mais um arquivo único: desde a
#    implementação offline-first, o Painel é um conjunto coerente de 7
#    arquivos (seção 11/12 da instrução obrigatória — publicar só o HTML e
#    deixar um sw.js antigo preso no servidor é FAIL):
#      index.html  sw.js  manifest.json  fflate.js
#      icon-192.png  icon-512.png  icon-512-maskable.png
#    Todos lidos pelo navegador por caminho relativo (ver <script
#    src="fflate.js">, <link rel="manifest" href="manifest.json">,
#    navigator.serviceWorker.register('sw.js') dentro do próprio Painel) —
#    por isso os 7 têm que ficar juntos, no mesmo diretório servido.
#
#    Fonte, em ordem de prioridade (a função resolver_painel_de() abaixo
#    procura os 7 nomes dentro da pasta informada, até 1 nível abaixo):
#      (a) 4º argumento do script (PAINEL_HTML_OVERRIDE): se for uma PASTA,
#          ela já deve conter os 7 arquivos; se for um ARQUIVO único
#          (compatibilidade com o uso antigo), ele vira o index.html e os
#          outros 6 são procurados do lado dele, na mesma pasta.
#      (b) /root/painel_dist/ na própria VPS — convenção nova, pasta única
#          com os 7 arquivos (mesmo padrão já usado por /root/home-site/
#          na seção 9.6 — não é mecanismo novo, é o mesmo composto aqui).
#      (c) /root/synapse_painel.html (compatibilidade com o uso antigo) +
#          os outros 6 arquivos soltos direto em /root/.
#      (d) github.com/nomen-me/painel, num commit/tag FIXO — nunca o HEAD
#          do momento, que é exatamente o "sem controle de versão" que a
#          seção 10 da instrução proíbe. Só é tentado se SYNAPSE_PAINEL_REF
#          estiver exportado (ver comentário na declaração da variável, no
#          topo do script, sobre por que não há um valor-padrão aqui).
#    Diferente da versão anterior deste script, a ausência de uma fonte
#    completa (os 7 arquivos) é FATAL — seção 13/17/22 da instrução: o
#    Painel/Service Worker são requisitos do PDV, não podem virar uma
#    pendência "best effort" no resumo final.
# =============================================================================
# Procura, dentro da pasta $1 (até 1 nível abaixo), cada um dos 7 arquivos
# do Painel. Preenche PAINEL_SRC_<NOME> com o caminho encontrado (vazio se
# não achou) e PAINEL_FALTANDO com a lista dos que faltaram. Devolve 0 só
# se os 7 foram encontrados.
resolver_painel_de() {
  local pasta="$1"
  PAINEL_SRC_INDEX="$(find "$pasta" -maxdepth 2 -iname 'index.html' 2>/dev/null | head -1)"
  PAINEL_SRC_SW="$(find "$pasta" -maxdepth 2 -iname 'sw.js' 2>/dev/null | head -1)"
  PAINEL_SRC_MANIFEST="$(find "$pasta" -maxdepth 2 -iname 'manifest.json' 2>/dev/null | head -1)"
  PAINEL_SRC_FFLATE="$(find "$pasta" -maxdepth 2 -iname 'fflate.js' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON192="$(find "$pasta" -maxdepth 2 -iname 'icon-192.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512="$(find "$pasta" -maxdepth 2 -iname 'icon-512.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512M="$(find "$pasta" -maxdepth 2 -iname 'icon-512-maskable.png' 2>/dev/null | head -1)"
  PAINEL_FALTANDO=""
  [ -z "$PAINEL_SRC_INDEX" ]    && PAINEL_FALTANDO="${PAINEL_FALTANDO}index.html "
  [ -z "$PAINEL_SRC_SW" ]       && PAINEL_FALTANDO="${PAINEL_FALTANDO}sw.js "
  [ -z "$PAINEL_SRC_MANIFEST" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}manifest.json "
  [ -z "$PAINEL_SRC_FFLATE" ]   && PAINEL_FALTANDO="${PAINEL_FALTANDO}fflate.js "
  [ -z "$PAINEL_SRC_ICON192" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-192.png "
  [ -z "$PAINEL_SRC_ICON512" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512.png "
  [ -z "$PAINEL_SRC_ICON512M" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512-maskable.png "
  [ -z "$PAINEL_FALTANDO" ]
}

log "Instalando o Painel (frontend estático + PWA em https://${DOMINIO_PAINEL})..."
mkdir -p /home/ubuntu/painel/site
PAINEL_FONTE_USADA=""
PAINEL_TENTATIVAS_LOG=""

if [ -n "$PAINEL_HTML_OVERRIDE" ]; then
  if [ -d "$PAINEL_HTML_OVERRIDE" ]; then
    if resolver_painel_de "$PAINEL_HTML_OVERRIDE"; then
      PAINEL_FONTE_USADA="pasta informada no 4º argumento (${PAINEL_HTML_OVERRIDE})"
    else
      PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- 4º argumento (pasta ${PAINEL_HTML_OVERRIDE}): faltou ${PAINEL_FALTANDO}\n"
    fi
  else
    # Compatibilidade com o uso antigo (1 arquivo só): ele é o index.html;
    # os outros 6 são procurados do lado dele, na mesma pasta (maxdepth 1 —
    # não desce em subpastas de quem passou um arquivo solto).
    PAINEL_SRC_INDEX="$PAINEL_HTML_OVERRIDE"
    local_dir_override="$(dirname "$PAINEL_HTML_OVERRIDE")"
    PAINEL_SRC_SW="$(find "$local_dir_override" -maxdepth 1 -iname 'sw.js' 2>/dev/null | head -1)"
    PAINEL_SRC_MANIFEST="$(find "$local_dir_override" -maxdepth 1 -iname 'manifest.json' 2>/dev/null | head -1)"
    PAINEL_SRC_FFLATE="$(find "$local_dir_override" -maxdepth 1 -iname 'fflate.js' 2>/dev/null | head -1)"
    PAINEL_SRC_ICON192="$(find "$local_dir_override" -maxdepth 1 -iname 'icon-192.png' 2>/dev/null | head -1)"
    PAINEL_SRC_ICON512="$(find "$local_dir_override" -maxdepth 1 -iname 'icon-512.png' 2>/dev/null | head -1)"
    PAINEL_SRC_ICON512M="$(find "$local_dir_override" -maxdepth 1 -iname 'icon-512-maskable.png' 2>/dev/null | head -1)"
    PAINEL_FALTANDO=""
    [ -z "$PAINEL_SRC_SW" ]       && PAINEL_FALTANDO="${PAINEL_FALTANDO}sw.js "
    [ -z "$PAINEL_SRC_MANIFEST" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}manifest.json "
    [ -z "$PAINEL_SRC_FFLATE" ]   && PAINEL_FALTANDO="${PAINEL_FALTANDO}fflate.js "
    [ -z "$PAINEL_SRC_ICON192" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-192.png "
    [ -z "$PAINEL_SRC_ICON512" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512.png "
    [ -z "$PAINEL_SRC_ICON512M" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512-maskable.png "
    if [ -z "$PAINEL_FALTANDO" ]; then
      PAINEL_FONTE_USADA="arquivo informado no 4º argumento (${PAINEL_HTML_OVERRIDE}) + 6 arquivos irmãos em ${local_dir_override}"
    else
      PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- 4º argumento (arquivo ${PAINEL_HTML_OVERRIDE}, irmãos em ${local_dir_override}): faltou ${PAINEL_FALTANDO}\n"
    fi
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ] && [ -d /root/painel_dist ]; then
  if resolver_painel_de /root/painel_dist; then
    PAINEL_FONTE_USADA="/root/painel_dist/ (default, sem precisar passar argumento)"
  else
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- /root/painel_dist/: faltou ${PAINEL_FALTANDO}\n"
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ] && [ -f /root/synapse_painel.html ]; then
  PAINEL_SRC_INDEX="/root/synapse_painel.html"
  PAINEL_SRC_SW="$(find /root -maxdepth 1 -iname 'sw.js' 2>/dev/null | head -1)"
  PAINEL_SRC_MANIFEST="$(find /root -maxdepth 1 -iname 'manifest.json' 2>/dev/null | head -1)"
  PAINEL_SRC_FFLATE="$(find /root -maxdepth 1 -iname 'fflate.js' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON192="$(find /root -maxdepth 1 -iname 'icon-192.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512="$(find /root -maxdepth 1 -iname 'icon-512.png' 2>/dev/null | head -1)"
  PAINEL_SRC_ICON512M="$(find /root -maxdepth 1 -iname 'icon-512-maskable.png' 2>/dev/null | head -1)"
  PAINEL_FALTANDO=""
  [ -z "$PAINEL_SRC_SW" ]       && PAINEL_FALTANDO="${PAINEL_FALTANDO}sw.js "
  [ -z "$PAINEL_SRC_MANIFEST" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}manifest.json "
  [ -z "$PAINEL_SRC_FFLATE" ]   && PAINEL_FALTANDO="${PAINEL_FALTANDO}fflate.js "
  [ -z "$PAINEL_SRC_ICON192" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-192.png "
  [ -z "$PAINEL_SRC_ICON512" ]  && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512.png "
  [ -z "$PAINEL_SRC_ICON512M" ] && PAINEL_FALTANDO="${PAINEL_FALTANDO}icon-512-maskable.png "
  if [ -z "$PAINEL_FALTANDO" ]; then
    PAINEL_FONTE_USADA="/root/synapse_painel.html (default antigo) + 6 arquivos irmãos em /root"
  else
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- /root/synapse_painel.html + irmãos em /root: faltou ${PAINEL_FALTANDO}\n"
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ]; then
  if [ -z "$SYNAPSE_PAINEL_REF" ]; then
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- github.com/${GITHUB_ORG}/painel: não tentado (SYNAPSE_PAINEL_REF não foi exportado — ver comentário na declaração da variável)\n"
  elif clonar_repo_nomen_pinned "painel" "/home/ubuntu/painel_src" "${SYNAPSE_PAINEL_REF}"; then
    if resolver_painel_de /home/ubuntu/painel_src; then
      PAINEL_FONTE_USADA="github.com/${GITHUB_ORG}/painel @ ${SYNAPSE_PAINEL_REF}"
    else
      PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- github.com/${GITHUB_ORG}/painel @ ${SYNAPSE_PAINEL_REF}: faltou ${PAINEL_FALTANDO}\n"
    fi
  else
    PAINEL_TENTATIVAS_LOG="${PAINEL_TENTATIVAS_LOG}- github.com/${GITHUB_ORG}/painel @ ${SYNAPSE_PAINEL_REF}: não consegui clonar/checkout (repo ou ref podem não existir, ou GITHUB_TOKEN sem acesso)\n"
  fi
fi

if [ -z "$PAINEL_FONTE_USADA" ]; then
  fatal "Painel não publicado — nenhuma das fontes possíveis tinha os 7 arquivos completos (index.html, sw.js, manifest.json, fflate.js, icon-192.png, icon-512.png, icon-512-maskable.png). Tentativas:\n$(echo -e "$PAINEL_TENTATIVAS_LOG")Forneça a pasta completa como 4º argumento, copie-a para /root/painel_dist/, ou exporte SYNAPSE_PAINEL_REF com o commit/tag homologado de github.com/${GITHUB_ORG}/painel. O Painel/PDV é requisito obrigatório (seção 13 da instrução) — a instalação não pode seguir sem ele."
fi

ok "Fonte do Painel: ${PAINEL_FONTE_USADA}"
cp "$PAINEL_SRC_INDEX"    /home/ubuntu/painel/site/index.html
cp "$PAINEL_SRC_SW"       /home/ubuntu/painel/site/sw.js
cp "$PAINEL_SRC_MANIFEST" /home/ubuntu/painel/site/manifest.json
cp "$PAINEL_SRC_FFLATE"   /home/ubuntu/painel/site/fflate.js
cp "$PAINEL_SRC_ICON192"  /home/ubuntu/painel/site/icon-192.png
cp "$PAINEL_SRC_ICON512"  /home/ubuntu/painel/site/icon-512.png
cp "$PAINEL_SRC_ICON512M" /home/ubuntu/painel/site/icon-512-maskable.png

# Mount de PASTA, não de arquivo único: um bind mount de arquivo único
# resolve o inode no momento do "docker compose up" e nunca mais acompanha
# uma troca de arquivo no host sem recriar o container (é exatamente o bug
# de cache/build-antiga já corrigido no instalador central e no
# corrigir_painel.sh — reproduzir aqui a mesma causa seria reintroduzir o
# mesmo defeito num lugar novo).
cancao_backup_painel_config
cat > /home/ubuntu/painel/docker-compose.yml << EOF
services:
  painel:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: painel
    restart: always
    volumes:
      - ./site:/usr/share/nginx/html:ro
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.painel.rule=Host(\`${DOMINIO_PAINEL}\`)"
      - "traefik.http.routers.painel.entrypoints=websecure"
      - "traefik.http.routers.painel.tls.certresolver=myresolver"
      - "traefik.http.routers.painel.priority=10"
      - "traefik.http.services.painel.loadbalancer.server.port=80"
networks:
  stack-network:
    external: true
EOF
# --force-recreate: numa reexecução o compose não mudou (mesma imagem, mesmo
# mount), e sem isso o container antigo seguiria no ar — o mount de pasta
# evita o bug do inode, mas só troca o que o container ENXERGA se ele for
# recriado pelo menos uma vez depois do novo conteúdo estar no host.
cancao_painel_aprovacoes_aplicar /home/ubuntu/painel/site/index.html
cd /home/ubuntu/painel && docker compose up -d --force-recreate
cancao_painel_verifica_mount

# Verificação contra a realidade, não contra a intenção: não basta o
# container ter sido recriado nem o HTTPS responder 200 — HTTP 200 só prova
# que ALGUMA coisa respondeu, não que é o conteúdo certo. Publicar só o
# index.html novo e deixar um sw.js antigo preso no ar é exatamente o tipo
# de falha que essa checagem existe pra pegar (o sw.js é o mais perigoso dos
# 7: é ele quem decide se o navegador vai servir o PWA do cache ou buscar a
# versão nova). Confere os 7, não só o index.html.
#
# HTTPS logo após um docker compose up pode falhar por timing de emissão de
# certificado (Traefik/ACME), não por bug de publicação — por isso tenta
# algumas vezes com espera antes de declarar falha de verdade.
PAINEL_ARQUIVOS=(index.html sw.js manifest.json fflate.js icon-192.png icon-512.png icon-512-maskable.png)
PAINEL_VALIDADO="sim"
PAINEL_DEPLOY_LOG=""
for arq in "${PAINEL_ARQUIVOS[@]}"; do
  h_host="$(sha256sum "/home/ubuntu/painel/site/${arq}" 2>/dev/null | awk '{print $1}')"
  h_cont=""
  h_https=""
  for tentativa in 1 2 3 4 5; do
    h_cont="$(docker exec painel sha256sum "/usr/share/nginx/html/${arq}" 2>/dev/null | awk '{print $1}')"
    h_https="$(curl -fsSL --max-time 5 "https://${DOMINIO_PAINEL}/${arq}" 2>/dev/null | sha256sum | awk '{print $1}')"
    [ -n "$h_host" ] && [ "$h_host" = "$h_cont" ] && [ "$h_host" = "$h_https" ] && break
    sleep 3
  done
  PAINEL_DEPLOY_LOG="${PAINEL_DEPLOY_LOG}${arq}: host=${h_host:-vazio} container=${h_cont:-vazio} https=${h_https:-vazio}\n"
  if [ -z "$h_host" ] || [ "$h_host" != "$h_cont" ] || [ "$h_host" != "$h_https" ]; then
    PAINEL_VALIDADO="nao"
  fi
done
log "PANEL_DEPLOY_OK candidato (7 arquivos, até 5 tentativas/15s cada por causa de emissão de certificado):\n$(echo -e "$PAINEL_DEPLOY_LOG")"
if [ "$PAINEL_VALIDADO" = "sim" ]; then
  ok "Painel publicado e validado em https://${DOMINIO_PAINEL} — os 7 arquivos batem byte a byte entre host, container e HTTPS (fonte: ${PAINEL_FONTE_USADA})"
else
  err "Painel publicado, mas a validação host=container=HTTPS FALHOU em pelo menos 1 dos 7 arquivos — ver PANEL_DEPLOY_OK acima. NÃO declarando o Painel como corretamente instalado. Rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate, espere o certificado, e reexecute só esta seção."
fi

# =============================================================================
# 9.6 HOME — deploy do frontend estático da raiz (https://${DOMINIO_BASE})
#    Diferente do Painel, a Home É a própria loja/site do cliente — sem repo
#    padrão (cada cliente tem a sua). Também pode ser mais que um arquivo
#    (index.html + páginas irmãs + subpasta assets/), então este passo serve
#    uma PASTA inteira via nginx, não só um arquivo único. Fonte, em ordem
#    de prioridade:
#      (a) pasta ou arquivo local passado como 5º argumento do script
#          (HOME_SRC_OVERRIDE) — se for pasta, copia tudo que tiver dentro;
#          se for um arquivo único, vira só o index.html (páginas irmãs
#          eventuais vão dar 404 até serem colocadas na pasta manualmente)
#      (b) /root/home-site na própria VPS (pasta — default, sem argumento)
#      (c) /root/index.html na própria VPS (arquivo único — default)
#    Se nenhuma existir, o passo é pulado (não-fatal, mesmo padrão do
#    Painel).
# =============================================================================
log "Instalando a página inicial (frontend estático em https://${DOMINIO_BASE})..."
mkdir -p /home/ubuntu/home-site/public
HOME_SRC_ORIGEM=""
HOME_SRC_E_PASTA="nao"
if [ -n "$HOME_SRC_OVERRIDE" ]; then
  HOME_SRC_ORIGEM="$HOME_SRC_OVERRIDE"
  if [ -d "$HOME_SRC_OVERRIDE" ]; then
    HOME_SRC_E_PASTA="sim"
    ok "Usando pasta local informada para a Home: ${HOME_SRC_ORIGEM}"
  else
    ok "Usando arquivo local informado para a Home: ${HOME_SRC_ORIGEM}"
  fi
elif [ -d /root/home-site ]; then
  HOME_SRC_ORIGEM="/root/home-site"
  HOME_SRC_E_PASTA="sim"
  ok "Usando /root/home-site (pasta, default, sem precisar passar argumento)"
elif [ -f /root/index.html ]; then
  HOME_SRC_ORIGEM="/root/index.html"
  ok "Usando /root/index.html (arquivo único, default, sem precisar passar argumento)"
else
  warn "Nenhuma fonte de HTML pra Home nesta execução (nem 5º argumento, nem /root/home-site, nem /root/index.html)."
fi

HOME_INSTALADO="nao"
if [ -n "$HOME_SRC_ORIGEM" ]; then
  if [ "$HOME_SRC_E_PASTA" = "sim" ]; then
    cp -r "${HOME_SRC_ORIGEM}/." /home/ubuntu/home-site/public/
  else
    cp "$HOME_SRC_ORIGEM" /home/ubuntu/home-site/public/index.html
  fi

  if [ -f /home/ubuntu/home-site/public/index.html ]; then
    # Avisa (não trava) se o index.html referenciar páginas irmãs que não
    # vieram junto — comum quando só o index.html foi passado sem o resto
    # do site, ou quando a pasta ainda está incompleta.
    PAGINAS_FALTANDO=""
    for pagina in $(grep -oE 'href="[A-Za-z0-9_.-]+\.html"' /home/ubuntu/home-site/public/index.html 2>/dev/null | sed -E 's/href="([^"]+)"/\1/' | sort -u); do
      [ -f "/home/ubuntu/home-site/public/${pagina}" ] || PAGINAS_FALTANDO="${PAGINAS_FALTANDO} ${pagina}"
    done
    if [ -n "$PAGINAS_FALTANDO" ]; then
      warn "index.html da Home referencia páginas que ainda não estão em /home/ubuntu/home-site/public/:${PAGINAS_FALTANDO} — esses links vão dar 404 até você colocar os arquivos lá (mesma pasta) e rodar 'cd /home/ubuntu/home-site && docker compose restart' (não precisa reinstalar tudo)."
    fi

    cat > /home/ubuntu/home-site/docker-compose.yml << EOF
services:
  home-site:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: home-site
    restart: always
    volumes:
      - ./public:/usr/share/nginx/html:ro
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.home-site.rule=Host(\`${DOMINIO_BASE}\`)"
      - "traefik.http.routers.home-site.entrypoints=websecure"
      - "traefik.http.routers.home-site.tls.certresolver=myresolver"
      - "traefik.http.routers.home-site.priority=10"
      - "traefik.http.services.home-site.loadbalancer.server.port=80"
networks:
  stack-network:
    external: true
EOF
    cd /home/ubuntu/home-site && docker compose up -d
    ok "Página inicial publicada em https://${DOMINIO_BASE}"
    HOME_INSTALADO="sim"
  else
    warn "Copiei ${HOME_SRC_ORIGEM} pra /home/ubuntu/home-site/public/ mas não achei um index.html lá dentro — a Home não foi publicada."
  fi
else
  warn "Página inicial NÃO foi publicada — nenhuma fonte de HTML disponível nesta execução. Rode de novo passando a pasta/arquivo local como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo) (o script é idempotente)."
fi

# =============================================================================
# 10. UPTIME KUMA (ECO) + NETDATA (ACORDE)
# =============================================================================
log "Instalando Uptime Kuma (Eco)..."
mkdir -p /home/ubuntu/uptime
cat > /home/ubuntu/uptime/docker-compose.yml << EOF
services:
  uptime-kuma:
    image: louislam/uptime-kuma:${SYNAPSE_UPTIME_KUMA_VERSION}
    container_name: eco
    restart: always
    volumes: [eco_data:/app/data]
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.eco.rule=Host(\`${DOMINIO_UPTIME}\`)"
      - "traefik.http.routers.eco.entrypoints=websecure"
      - "traefik.http.routers.eco.tls.certresolver=myresolver"
      - "traefik.http.routers.eco.priority=1"
      - "traefik.http.routers.eco.middlewares=synapse-infra-auth@docker"
      - "traefik.http.services.eco.loadbalancer.server.port=3001"
      # Status page pública: é feita pra ser lida sem login (é o que o painel
      # do cliente consulta) — fica de fora do Basic Auth, o resto do Eco não.
      - "traefik.http.routers.eco-status-publico.rule=Host(\`${DOMINIO_UPTIME}\`) && PathPrefix(\`/api/status-page\`)"
      - "traefik.http.routers.eco-status-publico.entrypoints=websecure"
      - "traefik.http.routers.eco-status-publico.tls.certresolver=myresolver"
      - "traefik.http.routers.eco-status-publico.priority=10"
      - "traefik.http.routers.eco-status-publico.service=eco"
      - "traefik.http.middlewares.synapse-infra-auth.basicauth.users=${BASICAUTH_USER}:${BASICAUTH_HASH_ESCAPED}"
volumes:
  eco_data:
networks:
  stack-network:
    external: true
EOF
cd /home/ubuntu/uptime && docker compose up -d
ok "Uptime Kuma instalado em https://${DOMINIO_UPTIME} (atrás de Basic Auth; monitores/alertas: configurar manualmente pela UI)"

log "Instalando Netdata (Acorde)..."
mkdir -p /home/ubuntu/netdata
cat > /home/ubuntu/netdata/docker-compose.yml << EOF
services:
  netdata:
    image: netdata/netdata:${SYNAPSE_NETDATA_VERSION}
    container_name: acorde
    restart: always
    cap_add: [SYS_PTRACE, SYS_ADMIN]
    security_opt: [apparmor:unconfined]
    volumes:
      - acorde_config:/etc/netdata
      - acorde_lib:/var/lib/netdata
      - acorde_cache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
    networks: [stack-network]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.acorde.rule=Host(\`${DOMINIO_NETDATA}\`)"
      - "traefik.http.routers.acorde.entrypoints=websecure"
      - "traefik.http.routers.acorde.tls.certresolver=myresolver"
      - "traefik.http.routers.acorde.middlewares=synapse-infra-auth@docker"
      - "traefik.http.services.acorde.loadbalancer.server.port=19999"
volumes:
  acorde_config:
  acorde_lib:
  acorde_cache:
networks:
  stack-network:
    external: true
EOF
cd /home/ubuntu/netdata && docker compose up -d
ok "Netdata instalado em https://${DOMINIO_NETDATA}"

# =============================================================================
# 11. ONBOARDING NA LYRA CENTRAL
#    (fusão do antigo onboard-client.sh — chama /admin/tenants e já injeta
#    LYRA_API_KEY no .env do Harmonia, fechando o ciclo sozinho)
# =============================================================================
log "Provisionando tenant '${TENANT_ID}' na Lyra Central (${LYRA_CENTRAL_URL})..."
HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${LYRA_CENTRAL_URL}/admin/tenants" \
  -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"tenant_id\": \"${TENANT_ID}\"}")
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" = "409" ]; then
  warn "Tenant '${TENANT_ID}' já existia na Lyra Central — girando (rotate) a chave para reaproveitar neste provisionamento."
  HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "${LYRA_CENTRAL_URL}/admin/tenants/${TENANT_ID}/rotate" \
    -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}")
  HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
  HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
fi

LYRA_API_KEY=""
if [ "$HTTP_STATUS" = "201" ] || [ "$HTTP_STATUS" = "200" ]; then
  LYRA_API_KEY=$(echo "$HTTP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null)
fi

if [ -n "$LYRA_API_KEY" ]; then
  salvar_credencial "LYRA_CENTRAL_URL" "$LYRA_CENTRAL_URL"
  salvar_credencial "LYRA_TENANT_ID" "$TENANT_ID"
  salvar_credencial "LYRA_API_KEY" "$LYRA_API_KEY"
  grava_env_n8n "LYRA_CENTRAL_URL" "$LYRA_CENTRAL_URL"
  grava_env_n8n "LYRA_TENANT_ID" "$TENANT_ID"
  grava_env_n8n "LYRA_API_KEY" "$LYRA_API_KEY"
  cd /home/ubuntu/n8n && docker compose up -d
  ok "Tenant Lyra provisionado e injetado no .env do Harmonia (ciclo fechado sozinho)"
else
  err "Falha ao provisionar/rotacionar tenant na Lyra Central (HTTP ${HTTP_STATUS}): ${HTTP_BODY}. Corrija e rode de novo — o script é idempotente."
fi

# =============================================================================
# 12. WORKFLOWS DO HARMONIA + API KEY PÚBLICA DO N8N (best-effort)
#    ⚠️ Validar antes de confiar em produção: os endpoints REST internos do
#    n8n usados aqui (/rest/owner/setup, /rest/login, /rest/api-keys) não são
#    API pública documentada e podem mudar de formato entre versões — este
#    ambiente de geração de código não teve como testar contra uma instância
#    real. Se falhar, a importação abaixo é pulada e fica só o caminho manual
#    (gerar a chave em Configurações > API na UI do Harmonia e rodar o passo
#    de importação à parte).
# =============================================================================
if [ -n "$WORKFLOWS_DIR_OVERRIDE" ]; then
  WORKFLOWS_DIR="$WORKFLOWS_DIR_OVERRIDE"
  ok "Usando pasta de workflows local informada: ${WORKFLOWS_DIR}"
else
  log "Clonando github.com/${GITHUB_ORG}/json pra pegar os workflows (W0-W4 + Lyra L1-L3 + schema de funções)..."
  if clonar_repo_nomen "json" "/home/ubuntu/json_src"; then
    WORKFLOWS_DIR="/home/ubuntu/json_src"
    ok "Workflows encontrados em ${WORKFLOWS_DIR} (o lyra_functions.json de lá é ignorado na importação — não é workflow, é o schema de tools consumido pela Lyra Central, não pelo Harmonia)"
  else
    fatal "Falha ao clonar github.com/${GITHUB_ORG}/json (confirma GITHUB_TOKEN) - workflows sao obrigatorios: INSTALL=FAIL."
    WORKFLOWS_DIR=""
  fi
fi

cancao_workflows_overlay
N8N_API_KEY=""
if [ -n "$WORKFLOWS_DIR" ] && [ -d "$WORKFLOWS_DIR" ]; then
  log "Tentando gerar API key pública do N8N automaticamente..."
  N8N_BASE="https://${DOMINIO_N8N}"
  N8N_AUTOMACAO_EMAIL="automacao@${DOMINIO_BASE}"
  COOKIEJAR="/tmp/synapse_n8n_cookie_$$"

  HTTP_SETUP=$(curl -s -o /tmp/synapse_n8n_setup.json -w '%{http_code}' -c "$COOKIEJAR" \
    -X POST "${N8N_BASE}/rest/owner/setup" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"firstName\":\"Synapse\",\"lastName\":\"Automacao\",\"password\":\"${SENHA}\"}")

  if [ "$HTTP_SETUP" != "200" ]; then
    curl -s -o /dev/null -w '%{http_code}' -c "$COOKIEJAR" \
      -X POST "${N8N_BASE}/rest/login" -H 'Content-Type: application/json' \
      -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"password\":\"${SENHA}\"}" > /tmp/synapse_n8n_login_code || true
  fi

  N8N_KEY_BODY=$(curl -s -b "$COOKIEJAR" -X POST "${N8N_BASE}/rest/api-keys" \
    -H 'Content-Type: application/json' -d '{"label":"synapse-provisionamento"}' || true)
  rm -f "$COOKIEJAR"

  N8N_API_KEY=$(echo "$N8N_KEY_BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k in ('rawApiKey', 'apiKey', 'key'):
        v = d.get(k) or (d.get('data') or {}).get(k)
        if v:
            print(v); break
except Exception:
    pass
" 2>/dev/null)

  if [ -n "$N8N_API_KEY" ]; then
    salvar_credencial "N8N_API_KEY" "$N8N_API_KEY"
    ok "API key pública do N8N gerada automaticamente"

    log "Importando workflows de ${WORKFLOWS_DIR}..."
    N8N_URL="$N8N_BASE" N8N_API_KEY="$N8N_API_KEY" python3 - "$WORKFLOWS_DIR" <<'PYEOF'
import os, sys, json, glob, urllib.request, urllib.error

N8N_URL = os.environ.get("N8N_URL", "").rstrip("/")
N8N_API_KEY = os.environ.get("N8N_API_KEY", "")
PASTA = sys.argv[1] if len(sys.argv) > 1 else "."

def chamar(metodo, caminho, corpo=None):
    req = urllib.request.Request(
        N8N_URL + caminho, method=metodo,
        headers={"X-N8N-API-KEY": N8N_API_KEY, "Content-Type": "application/json"},
        data=json.dumps(corpo).encode() if corpo is not None else None,
    )
    try:
        with urllib.request.urlopen(req) as resp:
            corpo_resp = resp.read()
            return json.loads(corpo_resp) if corpo_resp else {}
    except urllib.error.HTTPError as e:
        print(f"   erro HTTP {e.code}: {e.read().decode()[:300]}")
        return None

def existente_por_nome(nome):
    dados = chamar("GET", "/api/v1/workflows?limit=250")
    if not dados:
        return None
    for wf in dados.get("data", []):
        if wf["name"] == nome:
            return wf["id"]
    return None

def limpar_para_import(wf):
    for chave in ("id", "createdAt", "updatedAt", "versionId", "active", "tags"):
        wf.pop(chave, None)
    return wf

arquivos = sorted(glob.glob(os.path.join(PASTA, "*.json")))
if not arquivos:
    sys.exit(f"Nenhum .json encontrado em {PASTA}")

print(f"== Synapse — importando workflows reais em {N8N_URL} ==")
for caminho in arquivos:
    with open(caminho, encoding="utf-8") as f:
        conteudo = json.load(f)
    if "nodes" not in conteudo:
        print(f"   pulado (não é workflow): {os.path.basename(caminho)}")
        continue
    wf = limpar_para_import(conteudo)
    nome = wf["name"]
    existente_id = existente_por_nome(nome)
    if existente_id:
        resultado = chamar("PUT", f"/api/v1/workflows/{existente_id}", wf)
        acao, wf_id = "atualizado", existente_id
    else:
        resultado = chamar("POST", "/api/v1/workflows", wf)
        acao = "criado"
        wf_id = resultado["id"] if resultado else None
    if resultado and wf_id:
        chamar("POST", f"/api/v1/workflows/{wf_id}/activate")
        print(f"   {acao} e ativado: {nome}")
    else:
        print(f"   FALHOU: {nome} — revise o erro acima")
print("Pronto. Confira no editor do n8n se os webhooks path batem com o que os outros serviços chamam.")
PYEOF
  else
    err "Não consegui gerar a API key pública do N8N automaticamente (endpoint interno pode ter mudado). Importação de workflows pulada. A UI do Harmonia não responde mais publicamente (GUI escondida de propósito) e a porta 5678 não é publicada no host — pra gerar a chave manualmente: (1) adicione 'ports: [\"127.0.0.1:5678:5678\"]' ao serviço n8n em /home/ubuntu/n8n/docker-compose.yml, (2) 'docker compose up -d', (3) na sua máquina: 'ssh -L 5678:localhost:5678 <usuario>@<ip-da-vps>' e abra http://localhost:5678 (Configurações > API), (4) remova a linha 'ports:' e rode 'docker compose up -d' de novo pra fechar o acesso. Depois: N8N_URL=https://${DOMINIO_N8N} N8N_API_KEY=<chave> python3 2_importar_workflows_harmonia.py ${WORKFLOWS_DIR}"
  fi
fi

cancao_validar
# =============================================================================
# 13. VALIDAÇÃO FINAL
# =============================================================================
log "Validando serviços instalados..."
sleep 10
# nota: N8N/Chatwoot já não respondem 200 na raiz de propósito (GUI escondida
# atrás do blackhole404) — cada checagem abaixo aponta pra uma rota que
# continua liberada. Eco/Acorde ficam atrás de Basic Auth, então a checagem
# usa a credencial gerada nesta mesma execução.
check_service() {
  local nome=$1 url=$2 auth="${3:-}"
  local code
  if [ -n "$auth" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -u "$auth" "$url" 2>/dev/null)
  else
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  fi
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    ok "$nome respondeu HTTP $code"
  else
    err "$nome não respondeu correctamente (HTTP $code) — verifica DNS e logs do container"
  fi
}
check_service "ERPNext (Ritmo) — API"        "https://${DOMINIO_ERP}/api/method/ping"
check_service "N8N (Harmonia) — healthz"     "https://${DOMINIO_N8N}/healthz"
check_service "Chatwoot (Harpa) — widget"    "https://${DOMINIO_CHAT}/packs/js/sdk.js"
check_service "Uptime (Eco) — Basic Auth"    "https://${DOMINIO_UPTIME}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"
CODE_STATUS_PUBLICA=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://${DOMINIO_UPTIME}/api/status-page/synapse" 2>/dev/null)
if [ "$CODE_STATUS_PUBLICA" = "401" ]; then
  err "Status page pública do Eco está pedindo Basic Auth (HTTP 401) — a exceção de Traefik não pegou. Revise o router 'eco-status-publico'."
else
  ok "Status page pública do Eco não exige Basic Auth (HTTP ${CODE_STATUS_PUBLICA} — 404 aqui é normal até a status page 'synapse' ser criada manualmente, passo 4 do resumo final)"
fi
check_service "Netdata (Acorde) — Basic Auth" "https://${DOMINIO_NETDATA}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"
check_service "Lyra Central"                 "${LYRA_CENTRAL_URL}/healthz"
# Painel não entra condicionado a uma variável "instalado sim/não" — a
# seção 9.5 já aborta a instalação com fatal() se o conjunto completo não
# tiver sido publicado, então, se chegamos até aqui, ele está publicado.
check_service "Painel"                       "https://${DOMINIO_PAINEL}"
if [ "$PAINEL_VALIDADO" != "sim" ]; then
  err "Painel respondeu HTTP, mas a validação host=container=HTTPS da publicação (seção 9.5) tinha falhado — HTTP 200 aqui não significa que é a versão certa. Ver PANEL_DEPLOY_OK mais acima."
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  check_service "Home (raiz)"                "https://${DOMINIO_BASE}"
fi

log "Confirmando que as GUIs internas estão de fato bloqueadas (deve dar 404)..."
for par in "ERPNext (Ritmo)|https://${DOMINIO_ERP}/app" "N8N (Harmonia)|https://${DOMINIO_N8N}/" "Chatwoot (Harpa)|https://${DOMINIO_CHAT}/app/login"; do
  nome="${par%%|*}"; url="${par##*|}"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  if [ "$code" == "404" ]; then
    ok "$nome bloqueado corretamente (GET nessa rota devolveu 404)"
  else
    err "$nome deveria devolver 404 nessa rota e devolveu HTTP $code — revise as labels do Traefik antes de considerar a instalação segura"
  fi
done

# =============================================================================
# 13.5 VALIDAÇÃO DO CONTRATO PDV (seção 19 da instrução obrigatória)
#    "O script deve verificar explicitamente, antes de declarar sucesso,
#    que as estruturas críticas existem." Tudo abaixo já devia ter sido
#    criado pelas seções 8/9 acima — isto não tenta corrigir nada, só
#    confirma, e FALHA a instalação se alguma coisa não bateu (nunca
#    declara sucesso com uma estrutura crítica faltando).
# =============================================================================
log "Confirmando que o Ritmo tem todas as estruturas que o novo PDV exige..."
RESULT_VALIDACAO_PDV=$(ritmo_exec <<'PYEOF'
def main():
    import frappe
    faltando = []

    campos_esperados = {
        "Employee": ["synapse_pin_hash", "synapse_pin_salt", "synapse_pin_kdf_iteracoes", "synapse_pin_definido_em"],
        "POS Opening Entry": ["synapse_op_id"],
        "POS Closing Entry": ["synapse_op_id"],
        "POS Invoice": ["synapse_op_id", "synapse_operador_real", "synapse_identificacao_atendimento"],
        "Sales Order": ["synapse_op_id", "synapse_operador_real", "synapse_identificacao_atendimento"],
        "POS Invoice Item": ["synapse_item_generico", "synapse_preco_autorizado_por", "synapse_preco_motivo"],
        "Sales Order Item": ["synapse_item_generico", "synapse_preco_autorizado_por", "synapse_preco_motivo"],
        "POS Profile": ["synapse_conta_acrescimos"],
        "Customer": ["synapse_pedido_op_id"],
    }
    for doctype, campos in campos_esperados.items():
        for campo in campos:
            if not frappe.db.exists("Custom Field", f"{doctype}-{campo}"):
                faltando.append(f"Custom Field {doctype}.{campo}")

    for script in ["synapse_sincronizar_caixa", "synapse_definir_pin", "synapse_csrf_token"]:
        if not frappe.db.exists("Server Script", script):
            faltando.append(f"Server Script {script}")

    if not frappe.db.exists("Item", "ITEM-GENERICO"):
        faltando.append("Item ITEM-GENERICO")

    for wt in ["Loja", "Deposito"]:
        if not frappe.db.exists("Warehouse Type", wt):
            faltando.append(f"Warehouse Type {wt}")

    if faltando:
        for item in faltando:
            print(f"SYNAPSE_KV|faltando|{item}")
    else:
        print("SYNAPSE_KV|status|completo")
PYEOF
)
FALTANDO_PDV=$(echo "$RESULT_VALIDACAO_PDV" | grep '^SYNAPSE_KV|faltando|' | cut -d'|' -f3)
if [ -n "$FALTANDO_PDV" ]; then
  fatal "Validação final do contrato PDV (seção 19 da instrução obrigatória) encontrou estruturas faltando no Ritmo, mesmo depois dos passos de provisionamento acima:\n$(echo "$FALTANDO_PDV" | sed 's/^/  - /')\nA instalação NÃO pode ser declarada concluída com isso faltando — revise os logs das seções 8/9 acima e rode o script de novo (é idempotente)."
else
  ok "Contrato PDV confirmado no Ritmo: todos os campos de operador/PIN, POS Opening/Closing/Invoice, Sales Order, item genérico, POS Profile, endpoints do Caixa Offline e estruturas de apoio existem"
fi

log "Confirmando que os endpoints do Caixa Offline respondem como 'existem' (não como 'método inexistente')..."
# allow_guest=0 nos dois: uma chamada sem sessão tem que ser recusada por
# PERMISSÃO (prova que o Server Script existe e está registrado), nunca
# por "método não encontrado" (que provaria o contrário). Mesmo critério
# já usado no testar_endpoint_caixa_b.sh (item 9) — não é um mecanismo
# novo, é o mesmo teste aplicado aqui dentro do provisionador.
verificar_endpoint_caixa_existe() {
  local nome="$1"
  local corpo
  corpo=$(curl -s --max-time 10 "https://${DOMINIO_ERP}/api/method/${nome}" 2>/dev/null)
  if echo "$corpo" | grep -qiE "permission|not permitted|login|authentication|csrf"; then
    ok "/api/method/${nome} existe e está protegido (recusou chamada sem sessão, como esperado)"
  elif echo "$corpo" | grep -qiE "not found|não encontrado|does not exist|method not found|app methods"; then
    fatal "/api/method/${nome} respondeu como se NÃO existisse: ${corpo}"
  else
    fatal "/api/method/${nome} devolveu uma resposta que não bate com 'existe e está protegido' nem com 'não existe' — confirme manualmente antes de liberar o cliente: ${corpo}"
  fi
}
verificar_endpoint_caixa_existe "synapse_sincronizar_caixa"
verificar_endpoint_caixa_existe "synapse_definir_pin"

log "Confirmando que o Painel está servindo o conjunto novo (index.html + sw.js + manifest.json)..."
verificar_arquivo_painel_servido() {
  local nome="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://${DOMINIO_PAINEL}/${nome}" 2>/dev/null)
  if [ "$code" = "200" ]; then
    ok "https://${DOMINIO_PAINEL}/${nome} respondeu HTTP 200"
  else
    fatal "https://${DOMINIO_PAINEL}/${nome} não respondeu HTTP 200 (HTTP ${code}) — o Painel/PDV não funciona sem este arquivo (seção 11/19 da instrução)."
  fi
}
verificar_arquivo_painel_servido "index.html"
verificar_arquivo_painel_servido "sw.js"
verificar_arquivo_painel_servido "manifest.json"

# =============================================================================
# 14. REINÍCIO (SE NECESSÁRIO PARA O PATCH DE KERNEL)
# =============================================================================
if [ "$REINICIO_NECESSARIO" = true ]; then
  if [ "$AUTO_REBOOT" = "sim" ]; then
    log "AUTO_REBOOT=sim — reiniciando em 5s (Ctrl+C pra cancelar)..."
    sleep 5
    reboot
  else
    echo -e "${YELLOW}Há um patch de kernel pendente (CVE-2026-53359). Reiniciar agora? Digite 'sim' pra continuar:${NC}"
    read -r CONFIRMACAO
    if [ "$CONFIRMACAO" = "sim" ]; then
      log "Reiniciando em 5s (Ctrl+C pra cancelar)..."
      sleep 5
      reboot
    else
      warn "Reinício adiado — os containers têm restart:always e voltam sozinhos quando você reiniciar manualmente (sudo reboot)."
    fi
  fi
fi

# =============================================================================
# RESUMO FINAL
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
if [ "${INSTALL_ERROS:-0}" -gt 0 ] || [ "${FALHA_CRITICA:-false}" = true ]; then echo -e "${RED}   SYNAPSE - INSTALL = FAIL: ${DOMINIO_BASE}${NC}"; else echo -e "${GREEN}   SYNAPSE - INSTALL = PASS: ${DOMINIO_BASE}${NC}"; fi
echo -e "${GREEN}============================================================${NC}"
echo -e "  Ritmo (ERPNext)   → https://${DOMINIO_ERP}"
echo -e "  Harmonia (N8N)    → https://${DOMINIO_N8N}"
echo -e "  Harpa (Chatwoot)  → https://${DOMINIO_CHAT}"
echo -e "  Eco (Uptime)      → https://${DOMINIO_UPTIME}"
echo -e "  Acorde (Netdata)  → https://${DOMINIO_NETDATA}"
if [ "$PAINEL_VALIDADO" = "sim" ]; then
  echo -e "  Painel (PDV)      → https://${DOMINIO_PAINEL} (fonte: ${PAINEL_FONTE_USADA}, validado host=container=https)"
else
  echo -e "  Painel (PDV)      → ${RED}https://${DOMINIO_PAINEL} — PUBLICADO MAS NÃO VALIDADO${NC} (fonte: ${PAINEL_FONTE_USADA}) — ver PANEL_DEPLOY_OK acima antes de liberar pro cliente"
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  echo -e "  Home (raiz)       → https://${DOMINIO_BASE}"
else
  echo -e "  Home (raiz)       → ${RED}NÃO publicada nesta execução${NC} (ver pendência 9 abaixo)"
fi
echo -e "  Tenant Lyra       → ${TENANT_ID}"
echo -e "  Credenciais       → ${CRED_FILE} (chmod 600)"
echo ""
echo -e "  Basic Auth (Eco/Acorde) → usuário: ${BASICAUTH_USER}  senha: ver ${CRED_FILE}"
echo -e "  GUIs de Ritmo/Harmonia/Harpa → escondidas (404 em qualquer rota que não seja API/webhook/widget)"
echo ""
echo -e "${YELLOW}PRÓXIMOS PASSOS (fora do alcance de script):${NC}"
echo -e "  1. No painel de operações, cadastrar Melhor Envio / InfinitePay / 99 Empresas para '${NOME_LOJA}'."
echo -e "  2. Inbox de WhatsApp no Harpa: precisa de credenciais de um provedor (Meta Cloud API/Twilio/360dialog)."
echo -e "  3. Confirmar Plano de Contas BR no Setup Wizard do ERPNext, se o passo automático não achou o nome certo."
echo -e "  4. Configurar monitores/alertas no Uptime Kuma (Eco) pela interface web (Basic Auth: ${BASICAUTH_USER}) — crie a Status Page com slug 'synapse' (é o que o painel consulta, sem login, em /api/status-page/synapse)."
echo -e "  5. Se a importação de workflows (fase 12) foi pulada, gerar a API key do N8N via túnel SSH (ver aviso da fase 12) e rodar manualmente."
echo -e "  6. Confirmar que os 7 registros DNS (ritmo/harmonia/harpa/acorde/eco/painel + a raiz/apex ${DOMINIO_BASE}) apontam pro IP desta VPS."
echo -e "  7. Validar manualmente em outro navegador que https://${DOMINIO_ERP}/app, https://${DOMINIO_N8N}/ e https://${DOMINIO_CHAT}/app/login realmente devolvem 404 antes de liberar acesso ao cliente."
if [ "$PAINEL_VALIDADO" != "sim" ]; then
  echo -e "  8. ${RED}Painel publicado mas NÃO validado${NC} — host/container/HTTPS não bateram em algum dos 7 arquivos (ver PANEL_DEPLOY_OK). Rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate, espere o certificado, e confira https://${DOMINIO_PAINEL}/sw.js manualmente antes de liberar pro cliente — NÃO declare o PDV pronto sem isso."
fi
if [ -z "$LYRA_API_KEY" ]; then
  echo -e "  8. ${RED}Onboarding da Lyra falhou — rode o script de novo (é idempotente) depois de corrigir LYRA_CENTRAL_URL/LYRA_ADMIN_API_KEY.${NC}"
fi
if [ "$HOME_INSTALADO" != "sim" ]; then
  echo -e "  9. ${RED}Home não publicada${NC} — rode de novo com a pasta/arquivo como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo)."
fi
if [ "$BRAZIL_NF_CONFIRMADO" != "sim" ]; then
  echo -e "  10. ${RED}Brazil NF não confirmado${NC} — bench install-app rodou sem erro mas o app não aparece em 'bench list-apps'. Investigar antes de liberar nota fiscal pro cliente."
fi
echo -e "${GREEN}============================================================${NC}"

}

# Chamada única, na última linha do arquivo — só a partir daqui o bash
# executa qualquer coisa (ver comentário no início da função main acima).
main "$@"
exit $?
#__CANCAO_PAYLOAD__
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
