#!/bin/bash
# =============================================================================
#  SYNAPSE + LYRA CENTRAL + SEMAPHORE — INSTALAÇÃO COMPLETA NA VPS DA NOMEN
#  Script único: sobe, numa VPS só, TODO o ecossistema (Ritmo/Harmonia/Harpa/
#  Eco/Acorde) + a Lyra Central (multi-tenant) + a Lyra "atendente" da
#  própria Nomen (tenant onboardado automaticamente, sem copiar/colar chave
#  nenhuma entre passos) + Semaphore (Ansible) + o módulo fiscal Brazil NF.
#
#  Uso:
#    export GITHUB_TOKEN=ghp_xxxxx     # PAT com acesso de leitura aos repos privados nomen-me
#    export GEMINI_API_KEY=xxxxx       # chave real do Google AI Studio / Vertex AI
#    sudo -E bash -c "$(curl -fsSL -H "Authorization: token $GITHUB_TOKEN" \
#      https://raw.githubusercontent.com/nomen-me/synapse/main/instalar_nomen_completo.sh)" \
#      -- nomen.me "Nomen" "" /root/synapse_painel.html /root/home-site
#
#  Argumentos: <dominio-base> ["Nome da Loja"] [pasta-workflows-opcional] [arquivo-html-do-painel-opcional] [pasta-ou-arquivo-da-home-opcional]
#  O 4º argumento é o caminho LOCAL (já copiado pra VPS) do index.html do
#  Painel — arquivo único, sem assets (ver seção 9.5). Se omitido, o script
#  procura /root/synapse_painel.html e, por último, tenta clonar
#  github.com/nomen-me/painel; se nenhuma das três fontes existir, o passo
#  do Painel é pulado (não-fatal) e some do resumo final, sem travar o resto.
#
#  O 5º argumento é a Home (raiz do domínio — ex: nomen.me, sem subdomínio) —
#  ver seção 9.6. Pode ser uma PASTA (index.html + páginas irmãs tipo
#  como-funciona.html + subpasta assets/, tudo copiado como está) ou um
#  arquivo único. Se omitido, o script procura /root/home-site (pasta) e
#  depois /root/index.html (arquivo). Sem nenhuma das duas, o passo da Home
#  é pulado (não-fatal, mesmo padrão do Painel).
#
#  (dominio-base "nomen.me" vira: nomen.me (raiz), lyra.nomen.me,
#   ritmo.nomen.me, harmonia.nomen.me, harpa.nomen.me, eco.nomen.me,
#   acorde.nomen.me, painel.nomen.me — os 8 registros DNS tipo A precisam
#   existir antes, incluindo o apex/raiz)
#
#  Depois de rodar, você tem: Lyra Central (multi-tenant) + a própria Nomen
#  já como tenant dela (LYRA_ATENDENTE_TENANT_ID no resumo final) + o
#  ecossistema Synapse rodando com Brazil NF instalado + o Painel de
#  operações já publicado (se a fonte do HTML estava disponível) + Semaphore
#  acessível só via túnel SSH. Tudo numa credencial só: /root/nomen_credentials.txt
#
#  ⚠️ Recomendado rodar dentro de tmux/screen (script de 20-30min):
#    apt install -y tmux && tmux new -s instalacao
#    (depois cole o comando acima dentro da sessão)
# =============================================================================
set -uo pipefail
# (sem -e de propósito: uma falha num passo não-crítico não deve abortar o
#  resto da instalação — cada passo crítico tem sua própria checagem/fatal)

# Todo o corpo do script fica dentro de main(), chamada só na ÚLTIMA linha
# do arquivo — necessário pra rodar via "curl | bash" sem risco de um
# comando interno (docker exec, docker compose exec/run) roubar bytes do
# restante do script ainda não lido pelo bash (bug real, já reproduzido e
# corrigido nos scripts individuais; ver histórico).
main() {

# =============================================================================
# 0. ARGUMENTOS, VARIÁVEIS DERIVADAS E HELPERS
# =============================================================================
DOMINIO_BASE="${1:?Uso: sudo -E bash instalar_nomen_completo.sh <dominio-base> [\"Nome\"] [pasta-workflows-opcional] [arquivo-html-do-painel-opcional] [pasta-ou-arquivo-da-home-opcional]}"
NOME_LOJA="${2:-Nomen}"
WORKFLOWS_DIR_OVERRIDE="${3:-}"
PAINEL_HTML_OVERRIDE="${4:-}"
HOME_SRC_OVERRIDE="${5:-}"

GITHUB_TOKEN="${GITHUB_TOKEN:?Exporte GITHUB_TOKEN antes de rodar (PAT com acesso de leitura aos repos privados nomen-me)}"
GEMINI_API_KEY="${GEMINI_API_KEY:?Exporte GEMINI_API_KEY antes de rodar (chave real do Google AI Studio / Vertex AI)}"
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

GEMINI_MODEL="${GEMINI_MODEL:-${SYNAPSE_GEMINI_MODEL}}"
GITHUB_ORG="nomen-me"


AUTO_REBOOT="${AUTO_REBOOT:-nao}"
APP_USER="${APP_USER:-ubuntu}"
LYRA_APP_DIR="${LYRA_APP_DIR:-/home/${APP_USER}/lyra-central-api}"
SEMAPHORE_PORT="${SEMAPHORE_PORT:-3001}"
SEMAPHORE_ADMIN_USER="${SEMAPHORE_ADMIN_USER:-synapse-ops}"
SEMAPHORE_ADMIN_EMAIL="${SEMAPHORE_ADMIN_EMAIL:-ops@${DOMINIO_BASE}}"

DOMINIO_LYRA="lyra.${DOMINIO_BASE}"
DOMINIO_ERP="ritmo.${DOMINIO_BASE}"
DOMINIO_N8N="harmonia.${DOMINIO_BASE}"
DOMINIO_CHAT="harpa.${DOMINIO_BASE}"
DOMINIO_NETDATA="acorde.${DOMINIO_BASE}"
DOMINIO_UPTIME="eco.${DOMINIO_BASE}"
DOMINIO_PAINEL="painel.${DOMINIO_BASE}"
ORIGEM_PAINEL="https://${DOMINIO_PAINEL}"

CRED_FILE="/root/nomen_credentials.txt"
ler_credencial_existente() {
  # Lê uma chave de uma instalação anterior, se o arquivo já existir — usado
  # abaixo pra NÃO regenerar senha/segredo que já está em uso de verdade
  # (ver comentário junto de SENHA/SECRET_KEY logo abaixo).
  local chave="$1"
  [ -f "$CRED_FILE" ] && grep "^${chave}=" "$CRED_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-
}

EMAIL="admin@${DOMINIO_BASE}"
# Reaproveita SENHA/SECRET_KEY de uma instalação anterior, se existirem, em
# vez de gerar valores novos a cada rerun. MariaDB root, admin do ERPNext e
# Postgres do Chatwoot só usam SENHA no momento em que o container/site é
# CRIADO (num rerun eles continuam existindo, com a senha ORIGINAL) — gerar
# uma SENHA nova em todo rerun deixava o arquivo de credenciais mostrando
# uma senha que já não abria mais nada, sem nenhum erro visível na hora
# (mesma categoria de bug do TENANT_ID, só que silenciosa). SECRET_KEY é
# ainda mais sensível: é o SECRET_KEY_BASE do Rails/Chatwoot — trocá-lo
# depois que o Chatwoot já está de pé invalida sessões e pode quebrar a
# leitura de colunas criptografadas no banco dele.
SENHA="$(ler_credencial_existente SENHA)"
SENHA="${SENHA:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)}"
SECRET_KEY="$(ler_credencial_existente SECRET_KEY)"
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 64)}"

BASICAUTH_USER="synapse-ops"
# BASICAUTH_PASS também é reaproveitada — do contrário a senha do Basic Auth
# de Eco/Netdata muda a cada rerun (o docker compose recria o Traefik com o
# hash novo), obrigando a redescobrir a senha depois de qualquer manutenção.
BASICAUTH_PASS="$(ler_credencial_existente BASICAUTH_PASS)"
BASICAUTH_PASS="${BASICAUTH_PASS:-$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)}"
BASICAUTH_HASH="$(openssl passwd -apr1 "${BASICAUTH_PASS}")"
BASICAUTH_HASH_ESCAPED="$(echo "$BASICAUTH_HASH" | sed 's/\$/\$\$/g')"

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
CANCAO_BUNDLE_SHA256="a89007881a4a544560f8f306258175a18b2964a34e8b2c160edcd342fd0877b3"
CANCAO_ROLE="nomen"
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
# descobrir problema de compatibilidade no meio da instalação.
UBUNTU_VERSAO_HOST="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-desconhecida}")"
if [ "$UBUNTU_VERSAO_HOST" != "$SYNAPSE_UBUNTU_MAJOR" ]; then
  fatal "Ubuntu incompatível (detectado: ${UBUNTU_VERSAO_HOST}). Synapse exige Ubuntu ${SYNAPSE_UBUNTU_MAJOR} LTS."
fi
ok "Ubuntu ${UBUNTU_VERSAO_HOST} confirmado"

# Movido pra cá (era definido só na seção 9B) porque checks mais cedo no
# script (brazil-nf, e potencialmente outros) também precisam alimentar o
# mesmo relatório final — relatorio() precisa existir antes do primeiro uso.
RELATORIO_LINHAS=()
FALHA_CRITICA=false
relatorio() {
  local status="$1" nome="$2" detalhe="${3:-}"
  if [ -n "$detalhe" ]; then
    RELATORIO_LINHAS+=("[${status}] ${nome}
      ${detalhe}")
  else
    RELATORIO_LINHAS+=("[${status}] ${nome}")
  fi
  [ "$status" = "FAIL" ] && FALHA_CRITICA=true
}

salvar_credencial() {
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

clonar_repo_nomen() {
  local repo="$1" destino="$2"
  rm -rf "$destino"
  local saida
  if saida=$(git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${repo}.git" "$destino" 2>&1); then
    return 0
  else
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
parar_unattended_upgrades() {
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
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

if [ -n "$PAINEL_HTML_OVERRIDE" ] && [ ! -f "$PAINEL_HTML_OVERRIDE" ]; then
  fatal "Arquivo do Painel informado como 4º argumento não existe: ${PAINEL_HTML_OVERRIDE}"
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
salvar_credencial "SECRET_KEY" "$SECRET_KEY"
salvar_credencial "BASICAUTH_USER" "$BASICAUTH_USER"
salvar_credencial "BASICAUTH_PASS" "$BASICAUTH_PASS"
ok "Credenciais base geradas e guardadas em ${CRED_FILE} (permissões 600)"

echo "======================================================"
echo " Nomen — instalação completa (ecossistema + Lyra Central + Semaphore)"
echo "   domínio base   : ${DOMINIO_BASE}"
echo "   Lyra Central   : https://${DOMINIO_LYRA}"
echo "   tenant Lyra    : ${TENANT_ID} (a própria Nomen, atendente interna)"
echo "======================================================"

# =============================================================================
# 2. SISTEMA BASE — apt/kernel/firewall/Docker/Node.js/Redis
#    (Node+Redis são pra Lyra Central rodar via systemd; Docker é pra
#    Traefik + o ecossistema + Semaphore)
# =============================================================================
parar_unattended_upgrades

log "Actualizando sistema..."
esperar_apt_livre
apt update && apt upgrade -y || fatal "Falha ao actualizar o sistema."
esperar_apt_livre
apt install -y curl git nano ufw jq python3 unzip redis-server || fatal "Falha ao instalar pacotes base."

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
ok "Firewall configurado (só 22/80/443 públicos — Lyra Central em 127.0.0.1:8080 e Semaphore em 127.0.0.1:${SEMAPHORE_PORT} não são expostos diretamente)"

if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker..."
  esperar_apt_livre
  curl -fsSL https://get.docker.com | sh || fatal "Falha ao instalar Docker."
  systemctl enable --now docker
fi
ok "Docker disponível: $(docker --version)"

if ! command -v node >/dev/null 2>&1 || [ "$(node -v | sed 's/^v//' | cut -d. -f1)" -lt 20 ]; then
  log "Instalando Node.js 20 (NodeSource, pra Lyra Central)..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || fatal "Falha ao configurar o repositório NodeSource."
  esperar_apt_livre
  apt install -y nodejs || fatal "Falha ao instalar Node.js."
fi
ok "Node.js $(node -v) OK"

systemctl enable --now redis-server
if redis-cli ping >/dev/null 2>&1; then
  ok "Redis respondendo (usado pela Lyra Central e pelo rate limiter do ecossistema)"
else
  fatal "Redis não respondeu a PING local — verifique 'systemctl status redis-server'."
fi

# =============================================================================
# 3. REDE + TRAEFIK ÚNICO
#    UM SÓ Traefik pra tudo nesta VPS — docker provider (descobre Ritmo/
#    Harmonia/Harpa/Eco/Acorde/blackhole404 via labels, como antes) + file
#    provider (rota estática pra Lyra Central, que roda via systemd, fora
#    do Docker). "extra_hosts: host.docker.internal:host-gateway" é o que
#    deixa o Traefik (dentro do Docker) alcançar a Lyra Central (no host).
# =============================================================================
log "Criando rede unificada stack-network..."
docker network create stack-network 2>/dev/null || true

log "Instalando Traefik (único, docker + file provider)..."
mkdir -p /home/ubuntu/traefik/dynamic
cat > /home/ubuntu/traefik/docker-compose.yml << EOF
services:
  traefik:
    image: traefik:${SYNAPSE_TRAEFIK_VERSION}
    container_name: traefik
    restart: always
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=stack-network"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
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
      - ./dynamic:/etc/traefik/dynamic:ro
      - traefik_certs:/letsencrypt
    networks:
      - stack-network
volumes:
  traefik_certs:
networks:
  stack-network:
    external: true
EOF

# Rota estática da Lyra Central (systemd, fora do Docker). O arquivo já
# existe ANTES da Lyra estar de pé — Traefik só devolve 502 até ela subir,
# sem problema (o "--providers.file.watch=true" pega mudanças sem restart).
cat > /home/ubuntu/traefik/dynamic/lyra.yml << EOF
http:
  routers:
    lyra:
      rule: "Host(\`${DOMINIO_LYRA}\`)"
      entrypoints:
        - websecure
      tls:
        certResolver: myresolver
      service: lyra
  services:
    lyra:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:8080"
EOF

cd /home/ubuntu/traefik && docker compose up -d
ok "Traefik único activo (docker + file provider) — HTTPS pra tudo nesta VPS"

# =============================================================================
# 3.5 BLACKHOLE 404 — backend genérico que só devolve 404
#    GUIs de Ritmo/Harmonia/Harpa ficam escondidas atrás disso (a Lyra
#    Central NÃO passa por aqui — ela é só API, sem GUI pra esconder).
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
      - "traefik.http.routers.ritmo-deny.rule=Host(\`${DOMINIO_ERP}\`)"
      - "traefik.http.routers.ritmo-deny.entrypoints=websecure"
      - "traefik.http.routers.ritmo-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.ritmo-deny.priority=1"
      - "traefik.http.routers.ritmo-deny.service=blackhole404"
      - "traefik.http.routers.harmonia-deny.rule=Host(\`${DOMINIO_N8N}\`)"
      - "traefik.http.routers.harmonia-deny.entrypoints=websecure"
      - "traefik.http.routers.harmonia-deny.tls.certresolver=myresolver"
      - "traefik.http.routers.harmonia-deny.priority=1"
      - "traefik.http.routers.harmonia-deny.service=blackhole404"
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
ok "blackhole404 activo"

# =============================================================================
# 4. LYRA CENTRAL — deploy (systemd + Redis local, já instalados na fase 2)
#    Clona github.com/nomen-me/lyra, delega pro scripts/install.sh do
#    próprio repo, e conecta na rota do Traefik já criada na fase 3.
# =============================================================================
log "Instalando a Lyra Central (github.com/${GITHUB_ORG}/lyra)..."
# 2. CLONAR / ATUALIZAR github.com/nomen-me/lyra
# =============================================================================
if [ -d "${LYRA_APP_DIR}/.git" ]; then
  log "Repositório já existe em ${LYRA_APP_DIR} — atualizando (git pull --ff-only)..."
  if ! (cd "$LYRA_APP_DIR" && sudo -u "$APP_USER" git pull --ff-only 2>&1 | sed "s|${GITHUB_TOKEN}|***|g"); then
    err "git pull falhou — verifique conflitos manualmente em ${LYRA_APP_DIR}. Seguindo com o código já presente."
  fi
elif [ -f "${LYRA_APP_DIR}/scripts/install.sh" ]; then
  # Já tem o código de uma execução anterior (o achatamento abaixo troca o
  # clone por uma cópia sem .git, então não tem como dar "git pull" aqui —
  # e não tem problema, porque o clone original já é sempre --depth 1, e
  # atualizações de código são feitas via scripts/deploy.sh, não por este
  # script). Rodar "git clone" de novo aqui só ia falhar (pasta não-vazia).
  ok "Código da Lyra Central já está em ${LYRA_APP_DIR} de uma execução anterior — mantendo. Pra atualizar o código, use scripts/deploy.sh (ver resumo final)."
else
  log "Clonando github.com/${GITHUB_ORG}/lyra em ${LYRA_APP_DIR}..."
  mkdir -p "$(dirname "$LYRA_APP_DIR")"
  saida=$(git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/lyra.git" "$LYRA_APP_DIR" 2>&1) \
    || { echo "$saida" | sed "s|${GITHUB_TOKEN}|***|g" >&2; fatal "Falha ao clonar github.com/${GITHUB_ORG}/lyra. Confirma se GITHUB_TOKEN tem acesso ao repositório."; }
  id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$LYRA_APP_DIR"
fi
ok "Código da Lyra Central em ${LYRA_APP_DIR}"

# O repo pode ter uma pasta extra por dentro (ex: se o clone local que virou
# o repo já nasceu com um subdiretório "lyra-central-api/" e isso foi
# commitado assim). Em vez de assumir "scripts/install.sh" direto na raiz,
# procuramos de verdade e corrigimos LYRA_APP_DIR se precisar — mesma lógica
# usada pra achar o pyproject.toml do brazil-nf.
if [ ! -f "${LYRA_APP_DIR}/scripts/install.sh" ]; then
  warn "scripts/install.sh não está direto em ${LYRA_APP_DIR} — procurando dentro do repositório..."
  CANDIDATO="$(find "$LYRA_APP_DIR" -maxdepth 4 -path '*/scripts/install.sh' 2>/dev/null | head -1)"

  # Fallback: o repo às vezes tem só um .zip cru subido ("Add files via
  # upload"), sem o código extraído/commitado de verdade. Se for o caso,
  # extrai aqui mesmo em vez de travar a operação — mas isso é só uma
  # muleta; o certo é a Nomen commitar os arquivos extraídos no repo.
  if [ -z "$CANDIDATO" ]; then
    ZIP_ENCONTRADO="$(find "$LYRA_APP_DIR" -maxdepth 2 -name '*.zip' -not -path '*/.git/*' 2>/dev/null | head -1)"
    if [ -n "$ZIP_ENCONTRADO" ]; then
      warn "Não achei código extraído, mas achei '${ZIP_ENCONTRADO}' — o repo parece ter só o .zip cru subido, sem commit dos arquivos de verdade. Extraindo automaticamente (isso é uma muleta; o certo é vocês commitarem os arquivos extraídos no repo, não o .zip)."
      if command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null 2>&1; then
        EXTRACT_TMP="$(mktemp -d)"
        unzip -o "$ZIP_ENCONTRADO" -d "$EXTRACT_TMP" >/dev/null 2>&1
        CANDIDATO="$(find "$EXTRACT_TMP" -maxdepth 4 -path '*/scripts/install.sh' 2>/dev/null | head -1)"
        if [ -n "$CANDIDATO" ]; then
          RAIZ_REAL="$(dirname "$(dirname "$CANDIDATO")")"
          rm -rf "$LYRA_APP_DIR"; mkdir -p "$LYRA_APP_DIR"
          cp -a "${RAIZ_REAL}/." "$LYRA_APP_DIR/"
          CANDIDATO="$LYRA_APP_DIR/scripts/install.sh"  # já achatado, path final
        fi
        rm -rf "$EXTRACT_TMP"
      fi
    fi
  fi

  # ACHATAMENTO UNIVERSAL: não importa se o scripts/install.sh apareceu
  # aninhado dentro do próprio "git clone" (ex: o repo tem uma pasta
  # "lyra-central-api/" commitada dentro da raiz, em vez de flat) ou veio
  # do fallback do zip acima — sempre convergimos pra
  # ${LYRA_APP_DIR}/scripts/install.sh, um nível só, sem exceção. Isso
  # elimina o "path duplicado" de vez, seja qual for a origem da bagunça.
  if [ -n "$CANDIDATO" ]; then
    RAIZ_REAL="$(dirname "$(dirname "$CANDIDATO")")"
    if [ "$RAIZ_REAL" != "$LYRA_APP_DIR" ]; then
      warn "scripts/install.sh está aninhado em '${RAIZ_REAL}' — achatando pra '${LYRA_APP_DIR}' direto."
      FLAT_TMP="$(mktemp -d)"
      cp -a "${RAIZ_REAL}/." "$FLAT_TMP/"
      rm -rf "$LYRA_APP_DIR"; mkdir -p "$LYRA_APP_DIR"
      cp -a "${FLAT_TMP}/." "$LYRA_APP_DIR/"
      rm -rf "$FLAT_TMP"
    fi
  fi

  FOUND_INSTALL="$([ -f "${LYRA_APP_DIR}/scripts/install.sh" ] && echo "${LYRA_APP_DIR}/scripts/install.sh")"

  if [ -n "$FOUND_INSTALL" ]; then
    ok "scripts/install.sh confirmado em ${LYRA_APP_DIR}/scripts/install.sh (achatado, sem aninhamento)"
  else
    err "Não encontrei scripts/install.sh em nenhum lugar dentro de ${LYRA_APP_DIR} (nem dentro de um .zip). Isto é o que o clone realmente trouxe:"
    echo "----------------------------------------------------------------"
    find "$LYRA_APP_DIR" -maxdepth 2 -not -path '*/.git*' 2>/dev/null
    echo "----------------------------------------------------------------"
    echo "Total de arquivos (fora .git): $(find "$LYRA_APP_DIR" -type f -not -path '*/.git/*' 2>/dev/null | wc -l)"
    (cd "$LYRA_APP_DIR" && echo "Último commit: $(git log -1 --oneline 2>/dev/null || echo 'não foi possível ler')")
    fatal "Confirma no navegador se github.com/${GITHUB_ORG}/lyra realmente tem 'scripts/', 'src/' e 'package.json' commitados na raiz do branch padrão (não só um .zip solto) — a listagem acima é exatamente o que o clone trouxe."
  fi
fi

# Garante o dono certo em TODO o LYRA_APP_DIR, sempre — não só no clone novo.
# O fallback de extração de .zip acima roda como root e faz "cp -a" (que
# preserva o dono de quem copiou, ou seja, root), então sem isso a pasta
# data/ fica sem permissão de escrita pro usuário que o systemd realmente
# usa (APP_USER) — e a API quebra com EACCES ao tentar gravar
# data/tenants.dev.json em modo SECRETS_PROVIDER=env.
id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$LYRA_APP_DIR"

# =============================================================================
# 3. .env — só na primeira vez (reruns preservam o que já existe, ADMIN_API_KEY
#    nunca é trocada sozinha: trocar invalidaria os tenants já provisionados)
# =============================================================================
if [ ! -f "${LYRA_APP_DIR}/.env" ]; then
  log "Gerando .env pela primeira vez..."
  ADMIN_API_KEY="${ADMIN_API_KEY:-$(openssl rand -hex 32)}"
  cat > "${LYRA_APP_DIR}/.env" << EOF
PORT=8080
NODE_ENV=development
LOG_LEVEL=info

GEMINI_API_KEY=${GEMINI_API_KEY}
GEMINI_MODEL=${GEMINI_MODEL}

SECRETS_PROVIDER=env

ADMIN_API_KEY=${ADMIN_API_KEY}

REDIS_URL=redis://localhost:6379

TOKENS_PER_ATTENDANCE=1000
RECARGAS_MAXIMAS_MES=3

RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=60

TIMEOUT_CONSULTAR_FRETE_MS=5000
TIMEOUT_CONSULTAR_SALDO_MS=4000
TIMEOUT_CONSULTAR_ESTOQUE_MS=4000
EOF
  chmod 600 "${LYRA_APP_DIR}/.env"
  id -u "$APP_USER" >/dev/null 2>&1 && chown "${APP_USER}:${APP_USER}" "${LYRA_APP_DIR}/.env"

  # NÃO trunca de novo aqui — o arquivo já foi criado (e populado com
  # DOMINIO_BASE/TENANT_ID/EMAIL/SENHA/BASICAUTH_*) na seção 1. Truncar de
  # novo apagava justamente o TENANT_ID, quebrando o onboarding automático
  # do passo 11 e qualquer tentativa manual de retomá-lo depois (bug real,
  # já reproduzido: TENANT_ID ficava vazio em /root/nomen_credentials.txt).
  touch "$CRED_FILE"; chmod 600 "$CRED_FILE"
  cat >> "$CRED_FILE" << EOF
LYRA_CENTRAL_URL=https://${DOMINIO_LYRA}
ADMIN_API_KEY=${ADMIN_API_KEY}
EOF
  ok ".env criado — ADMIN_API_KEY gerada e salva em ${CRED_FILE} (chmod 600)"

  warn "NODE_ENV=development + SECRETS_PROVIDER=env: as API Keys de cada tenant"
  warn "ficam num arquivo local (data/tenants.dev.json), não criptografado."
  warn "O próprio scripts/install.sh do repo BLOQUEIA subir com NODE_ENV=production"
  warn "nesse modo — de propósito. Pra produção de verdade, primeiro implemente"
  warn "gcp_secret_manager ou vault em src/services/secrets.js (ainda são stubs,"
  warn "conforme o README do repo), troque SECRETS_PROVIDER e NODE_ENV no .env,"
  warn "e rode este script de novo (ele não sobrescreve o .env que já existe —"
  warn "edite manualmente antes de rerodar)."
else
  ok ".env já existe em ${LYRA_APP_DIR} — mantido como está (mesmo comportamento do install.sh do repo)"
fi

# =============================================================================
# 4. DELEGAR PRO scripts/install.sh DO PRÓPRIO REPO
#    (systemd, npm ci, checagens de segurança — não duplicamos essa lógica)
# =============================================================================
cancao_aplicar_patch_lyra
log "Rodando scripts/install.sh do repo (systemd + npm ci)..."
if APP_USER="$APP_USER" APP_DIR="$LYRA_APP_DIR" bash "${LYRA_APP_DIR}/scripts/install.sh"; then
  ok "lyra-central-api ativo via systemd"
else
  fatal "install.sh do repo falhou — veja a saída acima (ex: NODE_ENV=production com SECRETS_PROVIDER=env é bloqueado de propósito)."
fi

# O scripts/install.sh acima roda DENTRO deste script — ou seja, como root
# (todo este script exige root), não como ${APP_USER}. Se ele criar a pasta
# data/ nesse meio-tempo (ex: durante "npm ci" ou no primeiro boot da API pra
# preparar tenants.dev.json em SECRETS_PROVIDER=env), essa pasta nasce dona
# de root — por cima do chown que já fizemos na Seção 2 (que rodou ANTES de
# data/ existir, então não pegou essa pasta). Sem repetir o chown aqui, o
# serviço systemd (que roda como ${APP_USER}) recebe EACCES ao tentar abrir
# data/tenants.dev.json em qualquer chamada a /admin/tenants.
mkdir -p "${LYRA_APP_DIR}/data"
id -u "$APP_USER" >/dev/null 2>&1 && chown -R "${APP_USER}:${APP_USER}" "$LYRA_APP_DIR"
systemctl restart lyra-central-api 2>/dev/null || err "Não consegui reiniciar lyra-central-api agora — reinicie manualmente se necessário."

# =============================================================================

# Captura a chave gerada, direto do .env — nada de copiar/colar manual.
LYRA_ADMIN_API_KEY="$(grep '^ADMIN_API_KEY=' "${LYRA_APP_DIR}/.env" | cut -d'=' -f2-)"
LYRA_CENTRAL_URL="https://${DOMINIO_LYRA}"
salvar_credencial "LYRA_CENTRAL_URL" "$LYRA_CENTRAL_URL"
salvar_credencial "LYRA_ADMIN_API_KEY" "$LYRA_ADMIN_API_KEY"
ok "Lyra Central no ar — chave capturada automaticamente, sem precisar copiar nada"

# 4. ERPNEXT 15 (RITMO)
# =============================================================================
log "Instalando ERPNext 15 (Ritmo)..."
cd /home/ubuntu
[ -d frappe_docker ] || git clone https://github.com/frappe/frappe_docker || fatal "Falha ao clonar frappe_docker."
cd frappe_docker

ERPNEXT_VERSION="${SYNAPSE_ERPNEXT_VERSION}"
ok "ERPNext: usando ${ERPNEXT_VERSION} (fixo na baseline — sem resolução dinâmica)"
cat > .env << EOF
ERPNEXT_VERSION=${ERPNEXT_VERSION}
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
        relatorio "PASS" "Brazil NF" "instalado e confirmado em 'bench list-apps' do site ${DOMINIO_ERP}"
      else
        relatorio "FAIL" "Brazil NF" "bench install-app terminou sem erro, mas brazil_nf NÃO aparece em 'bench list-apps' do site ${DOMINIO_ERP} — instalação do módulo fiscal não confirmada."
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
# 8.5 USUÁRIO DE LOGIN DO PAINEL (mesmo EMAIL/SENHA de /root/nomen_credentials.txt)
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
  err "Não consegui confirmar a criação do usuário ${EMAIL} no Ritmo — veja /tmp/synapse_admin_user.log. Sem isso, o login no Painel não vai funcionar."
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
        ],
        "Sales Order": [
            # Pedido de Venda offline — mesmo par de campos do POS Invoice,
            # pelo mesmo motivo: idempotência (synapse_op_id, Sales Order
            # também autonomeia por naming_series) e identidade real de quem
            # criou o pedido, que pode ser diferente de quem sincroniza.
            {"fieldname": "synapse_op_id", "label": "Synapse — ID da operação (idempotência)", "fieldtype": "Data", "insert_after": "customer", "unique": 1, "read_only": 1},
            {"fieldname": "synapse_operador_real", "label": "Synapse — Operador real (Pedido offline)", "fieldtype": "Data", "insert_after": "synapse_op_id", "read_only": 1},
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
ok "Campos customizados (Company, Bank Account, Employee, POS Opening/Closing/Invoice, Sales Order, Customer) garantidos"

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
  *) err "Falha ao criar a Empresa '${NOME_LOJA}'. Saída: ${RESULT_COMPANY}" ;;
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
# CHATWOOT_WHATSAPP_INBOX_ID não é gravado aqui — nesse ponto do script a
# conta do Harpa ainda nem existe, então "1" era só um chute sem base
# nenhuma. O valor real (ou a ausência honesta dele) é resolvido mais
# adiante, na seção 9, depois que a conta do Chatwoot já existe de verdade.

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
log "Inbox de WhatsApp: verificado/criado mais adiante nesta mesma execução, na seção que já tem CHATWOOT_ACCOUNT_ID/CHATWOOT_API_TOKEN e os secrets da Meta disponíveis."

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

# =============================================================================
# 9B. RELATÓRIO PASS/FAIL + SECRETS DA META + WHATSAPP REAL + WEBHOOK
#     A partir daqui o script vira provisionador: cada elo é validado contra
#     a API real, nunca assumido por um HTTP 200 isolado, e tudo entra num
#     relatório final que decide se a instalação terminou com SUCCESS ou
#     PARCIAL. Nada disso imprime segredo em texto puro — só os 4 últimos
#     dígitos, e nunca em arquivo versionado.
# =============================================================================
mascarar() {
  local v="$1"
  [ -z "$v" ] && { echo "(vazio)"; return; }
  echo "***${v: -4}"
}

if [[ "$CW_ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
  relatorio "PASS" "Chatwoot" "conta '${NOME_LOJA}' (account_id=${CW_ACCOUNT_ID}) provisionada"
else
  relatorio "FAIL" "Chatwoot" "account_id não capturado — ver seção 8 acima"
fi
CODE_CW_API=$(curl -s -o /dev/null -w '%{http_code}' -H "api_access_token: ${CW_API_TOKEN}" \
  "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}" 2>/dev/null)
if [ "$CODE_CW_API" = "200" ]; then
  relatorio "PASS" "Chatwoot API" "autenticação com o token confirmada (HTTP 200)"
else
  relatorio "FAIL" "Chatwoot API" "HTTP ${CODE_CW_API} ao autenticar com CHATWOOT_API_TOKEN"
fi

# --- Secrets da Meta: só de mecanismo externo protegido. NUNCA por
#     argumento de linha de comando (fica no histórico do shell e em `ps`).
META_SECRETS_FILE="${META_SECRETS_FILE:-/root/.synapse_meta_secrets.env}"
if [ -f "$META_SECRETS_FILE" ]; then
  PERM_SECRETS=$(stat -c '%a' "$META_SECRETS_FILE" 2>/dev/null)
  if [ "$PERM_SECRETS" != "600" ]; then
    warn "Corrigindo permissão de ${META_SECRETS_FILE} para 600 (estava ${PERM_SECRETS})."
    chmod 600 "$META_SECRETS_FILE"
  fi
  set -a
  # shellcheck disable=SC1090
  source "$META_SECRETS_FILE"
  set +a
  ok "Secrets da Meta carregados de ${META_SECRETS_FILE} (permissão 600, fora do repo clonado)"
else
  warn "${META_SECRETS_FILE} não encontrado — também aceito por variável de ambiente já exportada antes de rodar este script."
fi
: "${META_APP_ID:=}"
: "${META_APP_SECRET:=}"
: "${META_WA_PHONE_NUMBER_ID:=}"
: "${META_WA_BUSINESS_ACCOUNT_ID:=}"
: "${META_SYSTEM_USER_TOKEN:=}"
: "${META_WEBHOOK_VERIFY_TOKEN:=}"
: "${META_GRAPH_API_VERSION:=${SYNAPSE_META_GRAPH_API_VERSION}}"

META_SECRETS_OK=true
for _v in META_APP_ID META_WA_PHONE_NUMBER_ID META_WA_BUSINESS_ACCOUNT_ID META_SYSTEM_USER_TOKEN; do
  [ -z "${!_v}" ] && META_SECRETS_OK=false
done

CW_WHATSAPP_INBOX_ID=""
if [ "$META_SECRETS_OK" = false ]; then
  relatorio "FAIL" "WhatsApp credentials" "faltando um ou mais de META_APP_ID/META_WA_PHONE_NUMBER_ID/META_WA_BUSINESS_ACCOUNT_ID/META_SYSTEM_USER_TOKEN em ${META_SECRETS_FILE} ou variável de ambiente — exceção real, não dá pra inventar valor"
  relatorio "FAIL" "WhatsApp inbox" "pulado — sem credenciais Meta válidas"
  relatorio "FAIL" "Chatwoot webhook" "pulado — depende do inbox de WhatsApp existir"
else
  relatorio "PASS" "WhatsApp credentials" "presentes (token $(mascarar "$META_SYSTEM_USER_TOKEN"))"

  GRAPH="https://graph.facebook.com/${META_GRAPH_API_VERSION}"

  HTTP_TOKEN=$(curl -s -o /tmp/synapse_meta_token.json -w '%{http_code}' \
    "${GRAPH}/me?access_token=${META_SYSTEM_USER_TOKEN}")
  if [ "$HTTP_TOKEN" = "200" ]; then
    relatorio "PASS" "Meta token válido"
  else
    ERRO_META=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_meta_token.json')).get('error', {}).get('message', 'sem detalhe'))
except Exception:
    print('resposta não-JSON')
" 2>/dev/null)
    relatorio "FAIL" "Meta token válido" "HTTP ${HTTP_TOKEN} — ${ERRO_META}"
  fi

  HTTP_WABA=$(curl -s -o /tmp/synapse_meta_waba.json -w '%{http_code}' \
    "${GRAPH}/${META_WA_BUSINESS_ACCOUNT_ID}?access_token=${META_SYSTEM_USER_TOKEN}")
  if [ "$HTTP_WABA" = "200" ]; then
    relatorio "PASS" "WhatsApp Business Account" "id=${META_WA_BUSINESS_ACCOUNT_ID} acessível"
  else
    ERRO_WABA=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_meta_waba.json')).get('error', {}).get('message', 'sem detalhe'))
except Exception:
    print('resposta não-JSON')
" 2>/dev/null)
    relatorio "FAIL" "WhatsApp Business Account" "HTTP ${HTTP_WABA} — ${ERRO_WABA}"
  fi

  HTTP_TEL=$(curl -s -o /tmp/synapse_meta_tel.json -w '%{http_code}' \
    "${GRAPH}/${META_WA_PHONE_NUMBER_ID}?fields=display_phone_number,verified_name&access_token=${META_SYSTEM_USER_TOKEN}")
  META_DISPLAY_PHONE=""
  if [ "$HTTP_TEL" = "200" ]; then
    META_DISPLAY_PHONE=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_meta_tel.json')).get('display_phone_number',''))
except Exception:
    pass
" 2>/dev/null)
    relatorio "PASS" "Phone Number válido" "id=${META_WA_PHONE_NUMBER_ID} (${META_DISPLAY_PHONE:-sem display_phone_number})"
  else
    relatorio "FAIL" "Phone Number válido" "HTTP ${HTTP_TEL} — phone_number_id inacessível com este token"
  fi

  # A API do Graph pagina phone_numbers (default ~25/página) — sem seguir
  # o cursor, um WABA com mais de uma página podia dar falso-negativo aqui
  # mesmo com o número certo cadastrado. Segue paging.next até achar ou
  # esgotar (com teto de segurança pra nunca ficar em loop infinito).
  PERTENCE="nao"
  PROXIMA_URL="${GRAPH}/${META_WA_BUSINESS_ACCOUNT_ID}/phone_numbers?access_token=${META_SYSTEM_USER_TOKEN}"
  HTTP_WABA_NUMS="000"
  for _pagina in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$PROXIMA_URL" ] && break
    HTTP_WABA_NUMS=$(curl -s -o /tmp/synapse_meta_waba_nums.json -w '%{http_code}' "$PROXIMA_URL")
    [ "$HTTP_WABA_NUMS" != "200" ] && break
    RESULTADO_PAGINA=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/synapse_meta_waba_nums.json'))
    ids = [n.get('id') for n in d.get('data', [])]
    achou = '${META_WA_PHONE_NUMBER_ID}' in ids
    prox = (d.get('paging') or {}).get('next', '')
    print(f\"{'sim' if achou else 'nao'}|{prox}\")
except Exception:
    print('nao|')
" 2>/dev/null)
    IFS='|' read -r ACHOU_NESSA_PAGINA PROXIMA_URL <<< "$RESULTADO_PAGINA"
    if [ "$ACHOU_NESSA_PAGINA" = "sim" ]; then
      PERTENCE="sim"
      break
    fi
  done
  if [ "$PERTENCE" = "sim" ]; then
    relatorio "PASS" "Phone Number pertence ao WABA"
  else
    relatorio "FAIL" "Phone Number pertence ao WABA" "phone_number_id ${META_WA_PHONE_NUMBER_ID} não está na lista de números do WABA ${META_WA_BUSINESS_ACCOUNT_ID} (HTTP ${HTTP_WABA_NUMS})"
  fi

  # --- Inbox de WhatsApp no Chatwoot: procura, reutiliza se existir,
  #     cria via API oficial se não existir. Idempotente (rerun não duplica).
  INBOXES_JSON=$(curl -s -H "api_access_token: ${CW_API_TOKEN}" \
    "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/inboxes" 2>/dev/null)
  CW_WHATSAPP_INBOX_ID=$(echo "$INBOXES_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    lista = d.get('payload', d) if isinstance(d, dict) else d
    for inbox in lista:
        if 'whatsapp' in str(inbox.get('channel_type', '')).lower():
            print(inbox['id']); break
except Exception:
    pass
" 2>/dev/null)

  if [ -n "$CW_WHATSAPP_INBOX_ID" ]; then
    relatorio "PASS" "WhatsApp inbox" "reutilizado (id=${CW_WHATSAPP_INBOX_ID}) — já existia, não recriado"
  else
    PAYLOAD_INBOX=$(NOME_LOJA_ENV="$NOME_LOJA" TELEFONE_ENV="$META_DISPLAY_PHONE" \
      TOKEN_ENV="$META_SYSTEM_USER_TOKEN" PHONE_ID_ENV="$META_WA_PHONE_NUMBER_ID" \
      WABA_ID_ENV="$META_WA_BUSINESS_ACCOUNT_ID" python3 -c "
import json, os
print(json.dumps({
    'name': f\"WhatsApp {os.environ['NOME_LOJA_ENV']}\",
    'channel': {
        'type': 'whatsapp',
        'phone_number': os.environ['TELEFONE_ENV'],
        'provider': 'whatsapp_cloud',
        'provider_config': {
            'api_key': os.environ['TOKEN_ENV'],
            'phone_number_id': os.environ['PHONE_ID_ENV'],
            'business_account_id': os.environ['WABA_ID_ENV']
        }
    }
}))
")
    HTTP_INBOX=$(curl -s -o /tmp/synapse_cw_inbox.json -w '%{http_code}' \
      -X POST "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/inboxes" \
      -H "api_access_token: ${CW_API_TOKEN}" -H 'Content-Type: application/json' \
      -d "$PAYLOAD_INBOX")
    if [ "$HTTP_INBOX" = "200" ] || [ "$HTTP_INBOX" = "201" ]; then
      CW_WHATSAPP_INBOX_ID=$(python3 -c "
import json
try:
    print(json.load(open('/tmp/synapse_cw_inbox.json')).get('id',''))
except Exception:
    pass
" 2>/dev/null)
      relatorio "PASS" "WhatsApp inbox" "criado (id=${CW_WHATSAPP_INBOX_ID})"
    else
      # nunca ecoa o corpo cru sem checar segredo — provider_config não volta
      # na resposta de erro do Chatwoot, mas por precaução mascaramos mesmo
      # assim antes de logar.
      CORPO_ERRO_INBOX=$(cat /tmp/synapse_cw_inbox.json 2>/dev/null | sed "s/${META_SYSTEM_USER_TOKEN}/***MASCARADO***/g" | head -c 300)
      relatorio "FAIL" "WhatsApp inbox" "HTTP ${HTTP_INBOX} ao criar — ${CORPO_ERRO_INBOX}"
    fi
  fi

  if [ -n "$CW_WHATSAPP_INBOX_ID" ]; then
    grava_env_n8n "CHATWOOT_WHATSAPP_INBOX_ID" "$CW_WHATSAPP_INBOX_ID"
  fi

  # --- Webhook da conta Chatwoot -> Harmonia. Cria se não existir
  #     (idempotente), e CONFIRMA lendo de volta — um POST 200 sozinho não
  #     é considerado suficiente.
  WEBHOOK_ALVO="https://${DOMINIO_N8N}/webhook/synapse-atendimento"
  WEBHOOKS_JSON=$(curl -s -H "api_access_token: ${CW_API_TOKEN}" \
    "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/webhooks" 2>/dev/null)
  JA_EXISTE_WEBHOOK=$(echo "$WEBHOOKS_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    lista = d.get('payload', d) if isinstance(d, dict) else d
    print('sim' if any(w.get('url') == '${WEBHOOK_ALVO}' for w in lista) else 'nao')
except Exception:
    print('nao')
" 2>/dev/null)
  if [ "$JA_EXISTE_WEBHOOK" != "sim" ]; then
    curl -s -o /tmp/synapse_cw_webhook.json -w '%{http_code}' \
      -X POST "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/webhooks" \
      -H "api_access_token: ${CW_API_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"url\":\"${WEBHOOK_ALVO}\",\"subscriptions\":[\"message_created\"]}" > /dev/null
  fi
  # confirma o estado FINAL, não o retorno do POST
  WEBHOOKS_JSON_DEPOIS=$(curl -s -H "api_access_token: ${CW_API_TOKEN}" \
    "https://${DOMINIO_CHAT}/api/v1/accounts/${CW_ACCOUNT_ID}/webhooks" 2>/dev/null)
  WEBHOOK_CONFIRMADO=$(echo "$WEBHOOKS_JSON_DEPOIS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    lista = d.get('payload', d) if isinstance(d, dict) else d
    for w in lista:
        if w.get('url') == '${WEBHOOK_ALVO}':
            subs = w.get('subscriptions', [])
            print('sim' if 'message_created' in subs else 'sem_evento')
            break
    else:
        print('nao')
except Exception:
    print('nao')
" 2>/dev/null)
  case "$WEBHOOK_CONFIRMADO" in
    sim) relatorio "PASS" "Chatwoot webhook" "confirmado: ${WEBHOOK_ALVO} com evento message_created ativo" ;;
    sem_evento) relatorio "FAIL" "Chatwoot webhook" "URL existe mas sem o evento message_created habilitado" ;;
    *) relatorio "FAIL" "Chatwoot webhook" "não encontrado ao reconsultar a conta — o POST pode ter retornado 200 sem persistir" ;;
  esac
fi

cd /home/ubuntu/n8n && docker compose up -d
ok ".env do Harmonia atualizado e N8N reiniciado"

# =============================================================================
# 9.5 PAINEL — deploy do frontend estático (painel.${DOMINIO_BASE})
#    É um único arquivo HTML/CSS/JS sem build: em runtime, ele resolve os
#    domínios de Ritmo/Harmonia/Harpa/Eco a partir do próprio hostname
#    (ver resolverAmbienteSynapse() dentro do arquivo) — então servir esse
#    arquivo estático é tudo que este passo precisa fazer.
#    Fonte, em ordem de prioridade:
#      (a) arquivo local passado como 4º argumento do script
#          (PAINEL_HTML_OVERRIDE)
#      (b) /root/synapse_painel.html na própria VPS (default, sem precisar
#          passar argumento — só copiar o arquivo pra lá antes de rodar)
#      (c) github.com/nomen-me/painel, index.html na raiz (ou 1 nível
#          abaixo)
#    Se nenhuma das três existir, o passo é pulado (não-fatal, mesmo padrão
#    usado pra Brazil NF e pros workflows do Harmonia) e entra no resumo
#    final como pendência, em vez de travar o resto da instalação.
# =============================================================================
log "Instalando o Painel (frontend estático em https://${DOMINIO_PAINEL})..."
mkdir -p /home/ubuntu/painel
PAINEL_HTML_ORIGEM=""
if [ -n "$PAINEL_HTML_OVERRIDE" ]; then
  PAINEL_HTML_ORIGEM="$PAINEL_HTML_OVERRIDE"
  ok "Usando arquivo local informado para o Painel: ${PAINEL_HTML_ORIGEM}"
elif [ -f /root/synapse_painel.html ]; then
  PAINEL_HTML_ORIGEM="/root/synapse_painel.html"
  ok "Usando /root/synapse_painel.html (default, sem precisar passar argumento)"
else
  if clonar_repo_nomen "painel" "/home/ubuntu/painel_src"; then
    CANDIDATO_PAINEL="$(find /home/ubuntu/painel_src -maxdepth 2 -iname 'index.html' 2>/dev/null | head -1)"
    if [ -n "$CANDIDATO_PAINEL" ]; then
      PAINEL_HTML_ORIGEM="$CANDIDATO_PAINEL"
      ok "index.html do Painel encontrado em github.com/${GITHUB_ORG}/painel"
    else
      warn "github.com/${GITHUB_ORG}/painel clonou mas não achei um index.html na raiz (nem 1 nível abaixo)."
    fi
  else
    warn "Não consegui clonar github.com/${GITHUB_ORG}/painel (repo pode não existir ainda, ou GITHUB_TOKEN sem acesso). Passe o HTML como 4º argumento, ou copie-o pra /root/synapse_painel.html, pra não depender desse repo."
  fi
fi

PAINEL_INSTALADO="nao"
if [ -n "$PAINEL_HTML_ORIGEM" ]; then
  # Mount de PASTA, não de arquivo único. Bind mount de arquivo é resolvido
  # por inode na criação do container; qualquer coisa que substitua o arquivo
  # (scp, vim, git, e o próprio `sed -i` logo abaixo) cria um inode novo e o
  # container continua servindo o arquivo antigo, já apagado do host. Como
  # `docker compose up -d` não recria container cujo compose não mudou, cada
  # reexecução entregava o arquivo novo pro host e mantinha o velho no ar.
  # Pasta o Docker resolve por caminho — trocar o index.html passa a valer.
  mkdir -p /home/ubuntu/painel/site /home/ubuntu/painel/conf
  cp "$PAINEL_HTML_ORIGEM" /home/ubuntu/painel/site/index.html

  # Preenche em runtime os 2 únicos valores que o próprio arquivo não tem
  # como descobrir sozinho (o resto é resolvido no navegador a partir do
  # hostname) — sem isso, alguém teria que editar isso à mão depois de
  # publicado. Se o layout do SYNAPSE_CONFIG mudar no repo do painel, estes
  # dois sed's silenciosamente não substituem nada (o grep abaixo avisa).
  sed -i "s|empresa: null,.*|empresa: '$(printf '%s' "$NOME_LOJA" | sed "s/'/\\\\'/g")', // preenchido automaticamente pela instalação|" /home/ubuntu/painel/site/index.html
  sed -i "s|chatwootContaId: null,.*|chatwootContaId: ${CW_ACCOUNT_ID:-null}, // preenchido automaticamente pela instalação|" /home/ubuntu/painel/site/index.html

  if grep -q "empresa: null" /home/ubuntu/painel/site/index.html; then
    warn "Não consegui preencher 'empresa' automaticamente no Painel (o texto 'empresa: null,' não foi encontrado no arquivo — o layout do SYNAPSE_CONFIG pode ter mudado). Preencha manualmente."
  fi
  if grep -q "chatwootContaId: null" /home/ubuntu/painel/site/index.html && [ -n "${CW_ACCOUNT_ID:-}" ]; then
    warn "Não consegui preencher 'chatwootContaId' automaticamente no Painel. Preencha manualmente com o valor ${CW_ACCOUNT_ID}."
  fi

  # O painel é um arquivo único que muda a cada deploy. Revalidação obrigatória
  # custa um HEAD; descobrir semanas depois que o navegador segurou a versão
  # antiga custa muito mais.
  cat > /home/ubuntu/painel/conf/default.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location = / {
        add_header Cache-Control "no-store, must-revalidate" always;
        expires -1;
    }
    location = /index.html {
        add_header Cache-Control "no-store, must-revalidate" always;
        expires -1;
    }
    location / {
        try_files $uri =404;
    }
}
EOF

  cancao_backup_painel_config

  cat > /home/ubuntu/painel/docker-compose.yml << EOF
services:
  painel:
    image: nginx:${SYNAPSE_NGINX_VERSION}
    container_name: painel
    restart: always
    volumes:
      - ./site:/usr/share/nginx/html:ro
      - ./conf:/etc/nginx/conf.d:ro
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
  # --force-recreate: numa reexecução o compose não mudou, e sem isso o
  # container antigo seguiria no ar com o conteúdo antigo.
  cancao_painel_aprovacoes_aplicar /home/ubuntu/painel/site/index.html
  cd /home/ubuntu/painel && docker compose up -d --force-recreate
  cancao_painel_verifica_mount

  # Verificação contra a realidade, não contra a intenção: não basta o
  # container ter sido recriado (docker compose up) nem o HTTPS responder
  # 200 — HTTP 200 só prova que ALGUMA página respondeu, não que é a certa.
  # Só declara sucesso se host, container e o HTTPS público servirem,
  # byte a byte, o mesmo arquivo. Qualquer divergência é FAIL, não aviso:
  # já aconteceu publicação "concluída" com o Panel antigo continuando no ar.
  sleep 2
  PAINEL_H_HOST="$(sha256sum /home/ubuntu/painel/site/index.html | awk '{print $1}')"
  PAINEL_H_CONT="$(docker exec painel sha256sum /usr/share/nginx/html/index.html 2>/dev/null | awk '{print $1}')"
  PAINEL_H_HTTPS="$(curl -fsSL "https://${DOMINIO_PAINEL}/" 2>/dev/null | sha256sum | awk '{print $1}')"
  log "PANEL_DEPLOY_OK candidato — host_hash=${PAINEL_H_HOST} container_hash=${PAINEL_H_CONT:-vazio} https_hash=${PAINEL_H_HTTPS:-vazio}"
  if [ -n "$PAINEL_H_HOST" ] && [ "$PAINEL_H_HOST" = "$PAINEL_H_CONT" ] && [ "$PAINEL_H_HOST" = "$PAINEL_H_HTTPS" ]; then
    ok "Painel publicado e validado em https://${DOMINIO_PAINEL} — host, container e HTTPS servem o mesmo arquivo (${PAINEL_H_HOST})"
    relatorio "PASS" "Panel" "host=container=https=${PAINEL_H_HOST}"
    PAINEL_INSTALADO="sim"
  else
    err "Painel NÃO validado — host, container e HTTPS não batem (host=${PAINEL_H_HOST} container=${PAINEL_H_CONT:-vazio} https=${PAINEL_H_HTTPS:-vazio}). Não declarando como instalado."
    relatorio "FAIL" "Panel" "host=${PAINEL_H_HOST} container=${PAINEL_H_CONT:-vazio} https=${PAINEL_H_HTTPS:-vazio} — rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate"
    PAINEL_INSTALADO="nao"
  fi
else
  err "Painel NÃO foi publicado — nenhuma fonte de HTML disponível nesta execução. Rode de novo passando o caminho local como 4º argumento, copiando o arquivo pra /root/synapse_painel.html, ou criando github.com/${GITHUB_ORG}/painel com o index.html (o script é idempotente)."
fi

# =============================================================================
# 9.6 HOME — deploy do frontend estático da raiz (https://${DOMINIO_BASE})
#    Diferente do Painel (9.5), a Home NÃO é um arquivo único: o index.html
#    referencia páginas irmãs (ex: como-funciona.html, integracoes.html,
#    privacy.html, status.html, support.html, terms.html) e uma subpasta
#    assets/ com imagens — então este passo serve uma PASTA inteira via
#    nginx, não só um arquivo. Fonte, em ordem de prioridade:
#      (a) pasta ou arquivo local passado como 5º argumento do script
#          (HOME_SRC_OVERRIDE) — se for pasta, copia tudo que tiver dentro;
#          se for um arquivo único, vira só o index.html (páginas irmãs vão
#          dar 404 até serem colocadas na pasta manualmente)
#      (b) /root/home-site na própria VPS (pasta — default, sem argumento)
#      (c) /root/index.html na própria VPS (arquivo único — default)
#    Se nenhuma existir, o passo é pulado (não-fatal, mesmo padrão do
#    Painel). Ainda não existe um repo oficial pra clonar (diferente do
#    Painel, que já tem github.com/nomen-me/painel) — se/quando existir,
#    adicionar aqui o mesmo fallback de clonar_repo_nomen usado acima.
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

# =============================================================================
# 11. ONBOARDING DA PRÓPRIA NOMEN NA LYRA CENTRAL (tenant "atendente interna")
#    Lyra Central está NA MESMA VPS — chama local (127.0.0.1:8080), sem
#    depender de DNS/TLS pra essa parte. A chave já foi capturada na fase 4,
#    sem precisar de nenhuma variável de ambiente externa.
# =============================================================================
log "Provisionando a própria Nomen como tenant '${TENANT_ID}' na Lyra Central..."
HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "http://127.0.0.1:8080/admin/tenants" \
  -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}" -H "Content-Type: application/json" \
  -d "{\"tenant_id\": \"${TENANT_ID}\"}")
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" = "409" ]; then
  warn "Tenant '${TENANT_ID}' já existia na Lyra Central — girando (rotate) a chave pra reaproveitar neste provisionamento."
  HTTP_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "http://127.0.0.1:8080/admin/tenants/${TENANT_ID}/rotate" \
    -H "Authorization: Bearer ${LYRA_ADMIN_API_KEY}")
  HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
  HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
fi

LYRA_TENANT_API_KEY=""
if [ "$HTTP_STATUS" = "201" ] || [ "$HTTP_STATUS" = "200" ]; then
  LYRA_TENANT_API_KEY=$(echo "$HTTP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null)
fi

if [ -n "$LYRA_TENANT_API_KEY" ]; then
  salvar_credencial "LYRA_ATENDENTE_TENANT_ID" "$TENANT_ID"
  salvar_credencial "LYRA_ATENDENTE_API_KEY" "$LYRA_TENANT_API_KEY"
  grava_env_n8n "LYRA_CENTRAL_URL" "https://${DOMINIO_LYRA}"
  grava_env_n8n "LYRA_TENANT_ID" "$TENANT_ID"
  grava_env_n8n "LYRA_API_KEY" "$LYRA_TENANT_API_KEY"
  cd /home/ubuntu/n8n && docker compose up -d
  ok "Nomen provisionada como tenant da própria Lyra Central — Harmonia interno já conectado, sem passo manual"
else
  err "Falha ao provisionar a Nomen como tenant (HTTP ${HTTP_STATUS}): ${HTTP_BODY}. Corrija e rode de novo — o script é idempotente."
fi

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
    # O repo, hoje, tem só um Json.zip cru dentro (sem os arquivos extraídos
    # commitados) — mesma situação que já existia pro repo da Lyra, mesmo
    # fallback: se não achar *.json direto na raiz, procura um .zip e extrai,
    # achatando pra WORKFLOWS_DIR não importar em qual subpasta o zip guardava
    # os arquivos (evita repetir aqui o bug de "0 workflows encontrados" que
    # antes só aparecia como erro fatal do importador, sem essa correção).
    if [ -z "$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null)" ]; then
      ZIP_WORKFLOWS="$(find "$WORKFLOWS_DIR" -maxdepth 2 -name '*.zip' -not -path '*/.git/*' 2>/dev/null | head -1)"
      if [ -n "$ZIP_WORKFLOWS" ]; then
        warn "Não achei .json direto em ${WORKFLOWS_DIR} — achei '${ZIP_WORKFLOWS}' (repo só com o zip cru, sem commit dos arquivos extraídos). Extraindo automaticamente (muleta; o certo é commitar os arquivos extraídos no repo, não o .zip)."
        command -v unzip >/dev/null 2>&1 || apt install -y unzip >/dev/null 2>&1
        EXTRACT_TMP_WF="$(mktemp -d)"
        unzip -o "$ZIP_WORKFLOWS" -d "$EXTRACT_TMP_WF" >/dev/null 2>&1
        # Achata: copia qualquer *.json encontrado em qualquer profundidade
        # direto pra WORKFLOWS_DIR, não importa a subpasta onde o zip guardou.
        find "$EXTRACT_TMP_WF" -name '*.json' -exec cp -t "$WORKFLOWS_DIR" {} + 2>/dev/null
        find "$EXTRACT_TMP_WF" -name '*.js' -exec cp -t "$WORKFLOWS_DIR" {} + 2>/dev/null
        rm -rf "$EXTRACT_TMP_WF"
      fi
    fi
    QTD_JSON="$(find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
    if [ "$QTD_JSON" -gt 0 ]; then
      ok "Workflows encontrados em ${WORKFLOWS_DIR} (${QTD_JSON} arquivos .json — o lyra_functions.json de lá é ignorado na importação, não é workflow, é o schema de tools consumido pela Lyra Central, não pelo Harmonia)"
    else
      err "Nenhum .json encontrado em ${WORKFLOWS_DIR} mesmo depois de tentar extrair zip — importação de workflows será pulada. Confira manualmente o conteúdo de github.com/${GITHUB_ORG}/json."
      WORKFLOWS_DIR=""
    fi
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

  # Não existe forma oficial (API/CLI/env var) de criar essa chave sem
  # passar pela UI — confirmado na documentação e na comunidade do próprio
  # n8n. Isto continua batendo em endpoints internos não documentados (não
  # tem alternativa), mas agora espera o n8n estar de pé de verdade antes de
  # tentar — tentar isso logo depois do "docker compose up -d" é o motivo
  # mais comum de falha (container ainda migrando o banco), não o formato
  # do endpoint em si.
  log "Aguardando o Harmonia (n8n) responder em ${N8N_BASE}/healthz..."
  N8N_PRONTO=false
  for _tentativa in $(seq 1 30); do
    if curl -fsS -o /dev/null "${N8N_BASE}/healthz" 2>/dev/null; then
      N8N_PRONTO=true
      break
    fi
    sleep 3
  done
  if [ "$N8N_PRONTO" = false ]; then
    warn "n8n não respondeu em /healthz depois de 90s — tentando gerar a API key mesmo assim (pode falhar por isso)."
  else
    ok "n8n respondendo em /healthz"
  fi

  N8N_API_KEY=""
  for _tentativa in 1 2 3; do
    COOKIEJAR="/tmp/synapse_n8n_cookie_$$"

    HTTP_SETUP=$(curl -s -o /tmp/synapse_n8n_setup.json -w '%{http_code}' -c "$COOKIEJAR" \
      -X POST "${N8N_BASE}/rest/owner/setup" -H 'Content-Type: application/json' \
      -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"firstName\":\"Synapse\",\"lastName\":\"Automacao\",\"password\":\"${SENHA}\"}")

    if [ "$HTTP_SETUP" != "200" ]; then
      # owner já pode existir de um rerun anterior — tenta login em vez de
      # setup, e mostra o corpo real de cada resposta pra não ficar cego
      # sobre qual dos dois passos falhou e por quê.
      HTTP_LOGIN=$(curl -s -o /tmp/synapse_n8n_login.json -w '%{http_code}' -c "$COOKIEJAR" \
        -X POST "${N8N_BASE}/rest/login" -H 'Content-Type: application/json' \
        -d "{\"email\":\"${N8N_AUTOMACAO_EMAIL}\",\"password\":\"${SENHA}\"}")
      if [ "$HTTP_LOGIN" != "200" ]; then
        warn "Tentativa ${_tentativa}/3: setup=HTTP ${HTTP_SETUP} ($(cat /tmp/synapse_n8n_setup.json 2>/dev/null | head -c 200)), login=HTTP ${HTTP_LOGIN} ($(cat /tmp/synapse_n8n_login.json 2>/dev/null | head -c 200))"
        rm -f "$COOKIEJAR"
        sleep 5
        continue
      fi
    fi

    HTTP_KEY=$(curl -s -b "$COOKIEJAR" -o /tmp/synapse_n8n_key.json -w '%{http_code}' \
      -X POST "${N8N_BASE}/rest/api-keys" \
      -H 'Content-Type: application/json' -d '{"label":"synapse-provisionamento"}')
    rm -f "$COOKIEJAR"

    if [ "$HTTP_KEY" = "200" ] || [ "$HTTP_KEY" = "201" ]; then
      N8N_API_KEY=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/synapse_n8n_key.json'))
    for k in ('rawApiKey', 'apiKey', 'key'):
        v = d.get(k) or (d.get('data') or {}).get(k)
        if v:
            print(v); break
except Exception:
    pass
" 2>/dev/null)
      [ -n "$N8N_API_KEY" ] && break
      warn "Tentativa ${_tentativa}/3: /rest/api-keys respondeu HTTP ${HTTP_KEY} mas sem chave reconhecível no corpo: $(cat /tmp/synapse_n8n_key.json 2>/dev/null | head -c 200)"
    else
      warn "Tentativa ${_tentativa}/3: /rest/api-keys respondeu HTTP ${HTTP_KEY}: $(cat /tmp/synapse_n8n_key.json 2>/dev/null | head -c 200)"
    fi
    sleep 5
  done

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
resultados = []
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
    ativado = False
    if resultado and wf_id:
        ativado = chamar("POST", f"/api/v1/workflows/{wf_id}/activate") is not None
        print(f"   {acao} e ativado: {nome}")
    else:
        print(f"   FALHOU: {nome} — revise o erro acima")
    resultados.append({"nome": nome, "id": wf_id, "acao": acao if resultado else "falhou", "ativo": ativado})

with open("/tmp/synapse_import_resultado.json", "w", encoding="utf-8") as f:
    json.dump(resultados, f, ensure_ascii=False)
print("Pronto. Confira no editor do n8n se os webhooks path batem com o que os outros serviços chamam.")
PYEOF

    # Verificação real do que foi importado — não confia só no que o loop
    # acima imprimiu, reconsulta a API e confere existência + estado ativo
    # do workflow que a cadeia WhatsApp precisa (Lyra_L1_triagem), além de
    # contar falhas de qualquer outro.
    if [ -f /tmp/synapse_import_resultado.json ]; then
      RESUMO_IMPORT=$(python3 -c "
import json
try:
    r = json.load(open('/tmp/synapse_import_resultado.json'))
except Exception:
    print('erro|0|0'); raise SystemExit
falhas = [w['nome'] for w in r if w['acao'] == 'falhou']
l1 = next((w for w in r if 'L1' in w['nome'] and 'Triagem' in w['nome']), None)
l1_ok = 'sim' if (l1 and l1['ativo']) else 'nao'
print(f\"{len(r)}|{len(falhas)}|{l1_ok}|{','.join(falhas) if falhas else '-'}\")
" 2>/dev/null)
      IFS='|' read -r QTD_WF QTD_FALHAS_WF L1_ATIVO NOMES_FALHOS <<< "$RESUMO_IMPORT"
      if [ "${QTD_FALHAS_WF:-1}" = "0" ] && [ -n "$QTD_WF" ]; then
        relatorio "PASS" "workflows" "${QTD_WF} workflows importados e ativados, verificado via GET /api/v1/workflows"
      else
        relatorio "FAIL" "workflows" "${QTD_FALHAS_WF:-?} de ${QTD_WF:-?} falharam: ${NOMES_FALHOS:-desconhecido}"
      fi
      if [ "$L1_ATIVO" = "sim" ]; then
        relatorio "PASS" "workflow Lyra L1 Triagem" "existe e está ativo"
      else
        relatorio "FAIL" "workflow Lyra L1 Triagem" "não encontrado ativo após import — cadeia do WhatsApp não vai responder"
      fi
    else
      relatorio "FAIL" "workflows" "script de importação não gerou resultado (falha antes de terminar)"
    fi
  else
    relatorio "FAIL" "N8N API key" "não gerada automaticamente após retries — ver diagnóstico HTTP acima"
    relatorio "FAIL" "workflows" "pulado — sem API key do n8n"
    err "Não consegui gerar a API key pública do N8N automaticamente (endpoint interno pode ter mudado). Importação de workflows pulada. A UI do Harmonia não responde mais publicamente (GUI escondida de propósito) e a porta 5678 não é publicada no host — pra gerar a chave manualmente: (1) adicione 'ports: [\"127.0.0.1:5678:5678\"]' ao serviço n8n em /home/ubuntu/n8n/docker-compose.yml, (2) 'docker compose up -d', (3) na sua máquina: 'ssh -L 5678:localhost:5678 <usuario>@<ip-da-vps>' e abra http://localhost:5678 (Configurações > API), (4) remova a linha 'ports:' e rode 'docker compose up -d' de novo pra fechar o acesso. Depois: N8N_URL=https://${DOMINIO_N8N} N8N_API_KEY=<chave> python3 2_importar_workflows_harmonia.py ${WORKFLOWS_DIR}"
  fi
fi

# =============================================================================

cancao_validar
# =============================================================================
# 13. SEMAPHORE UI (orquestração de Ansible) — rede própria, sem Traefik,
#    só acessível via túnel SSH (não é por-cliente, é só pra operação da Nomen)
# =============================================================================
log "Instalando Semaphore UI..."
if docker inspect semaphore >/dev/null 2>&1; then
  warn "Já existe um container 'semaphore' nesta VPS — reaproveitando/atualizando."
fi
docker network create semaphore-network 2>/dev/null || true

porta_em_uso() {
  local porta="$1"
  if docker ps --filter "name=^semaphore$" --format '{{.Ports}}' 2>/dev/null | grep -q "127.0.0.1:${porta}->"; then
    return 1
  fi
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${porta}$"
}
while porta_em_uso "$SEMAPHORE_PORT"; do
  warn "Porta 127.0.0.1:${SEMAPHORE_PORT} já está em uso por outro serviço nesta VPS — tentando a próxima."
  SEMAPHORE_PORT=$((SEMAPHORE_PORT + 1))
done
ok "Semaphore vai usar a porta local ${SEMAPHORE_PORT} (127.0.0.1:${SEMAPHORE_PORT} -> container:3000)"

SEMAPHORE_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
SEMAPHORE_ACCESS_KEY_ENCRYPTION="$(head -c32 /dev/urandom | base64)"
salvar_credencial "SEMAPHORE_PORT" "$SEMAPHORE_PORT"
salvar_credencial "SEMAPHORE_ADMIN_USER" "$SEMAPHORE_ADMIN_USER"
salvar_credencial "SEMAPHORE_ADMIN_PASSWORD" "$SEMAPHORE_ADMIN_PASSWORD"

mkdir -p /home/ubuntu/semaphore
cat > /home/ubuntu/semaphore/docker-compose.yml << EOF
services:
  semaphore:
    image: semaphoreui/semaphore:${SYNAPSE_SEMAPHORE_VERSION}
    container_name: semaphore
    restart: always
    ports:
      - "127.0.0.1:${SEMAPHORE_PORT}:3000"
    environment:
      # bolt (BoltDB embutido) foi descontinuado no Semaphore 2.16 e REMOVIDO
      # de vez no 2.19 — a baseline fixa v2.19.12, onde "bolt" já não existe
      # mais e crasharia com "Unknown database dialect: bolt" se usado.
      # sqlite é o substituto oficial recomendado, mesma ideia (embutido, um
      # arquivo só, sem precisar de MySQL/Postgres à parte) — funciona com
      # as mesmas variáveis, sem precisar de configuração extra.
      SEMAPHORE_DB_DIALECT: sqlite
      SEMAPHORE_ADMIN: ${SEMAPHORE_ADMIN_USER}
      SEMAPHORE_ADMIN_PASSWORD: ${SEMAPHORE_ADMIN_PASSWORD}
      SEMAPHORE_ADMIN_NAME: "Synapse Ops"
      SEMAPHORE_ADMIN_EMAIL: ${SEMAPHORE_ADMIN_EMAIL}
      SEMAPHORE_ACCESS_KEY_ENCRYPTION: ${SEMAPHORE_ACCESS_KEY_ENCRYPTION}
      TZ: America/Sao_Paulo
    volumes:
      - semaphore_config:/etc/semaphore
      - semaphore_data:/var/lib/semaphore
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - semaphore-network
      - stack-network   # o Harmonia (n8n) precisa alcancar http://semaphore:3000 (Integration)
volumes:
  semaphore_config:
  semaphore_data:
networks:
  semaphore-network:
    external: true
  stack-network:
    external: true
EOF

cd /home/ubuntu/semaphore && docker compose up -d || err "Falha ao subir o Semaphore UI. Verifica 'docker logs semaphore'."

log "Aguardando o Semaphore responder localmente..."
TENTATIVAS=0
until curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${SEMAPHORE_PORT}"; do
  TENTATIVAS=$((TENTATIVAS+1))
  [ $TENTATIVAS -ge 20 ] && { err "Semaphore não respondeu em 40s. Verifica 'docker logs semaphore'."; break; }
  sleep 2
done
ok "Semaphore UI no ar (verificado localmente em http://127.0.0.1:${SEMAPHORE_PORT})"

# =============================================================================
# 13B. SEMAPHORE — CONFIGURAÇÃO AUTOMÁTICA (só nesta VPS de gestão; clientes
#      nunca recebem Semaphore). Usa o configurar_semaphore_synapse.sh do
#      bundle oficial — não reimplementa nada: cria projeto, Key Store,
#      repositório, Environment, Inventory, templates e agendamento via API,
#      de forma idempotente. O container acima já existe, então o script do
#      bundle NÃO tenta instalar o Semaphore de novo (ele detecta e preserva).
#
#      Onde estão os arquivos do bundle (nesta ordem):
#        1. SEMAPHORE_BUNDLE_DIR (variável de ambiente, pasta 'semaphore/'
#           extraída do bundle)
#        2. github.com/${GITHUB_ORG}/synapse, subpasta semaphore/
#      Nenhum dos dois achado => etapa FALHA de forma explícita no relatório
#      (nunca some em silêncio).
# =============================================================================
log "Configurando o Semaphore (projeto Synapse, chaves, repo, templates)..."
SEMA_BUNDLE_DIR="$CANCAO_DIR/semaphore"   # bundle fixado e verificado por sha256 (nao depende de arquivo local nem de repo privado)
[ -f "$SEMA_BUNDLE_DIR/configurar_semaphore_synapse.sh" ] || SEMA_BUNDLE_DIR=""

SEMA_CONFIG_OK=false
if [ -z "$SEMA_BUNDLE_DIR" ]; then
  relatorio "FAIL" "Semaphore configurado" "bundle não encontrado — exporte SEMAPHORE_BUNDLE_DIR=<pasta semaphore/ extraída> ou commite o bundle em ${GITHUB_ORG}/synapse (subpasta semaphore/) e rode de novo (idempotente)"
else
  SEMA_LOG="/var/log/synapse_semaphore_config.log"
  : > "$SEMA_LOG"; chmod 600 "$SEMA_LOG"
  # Segredos entram só por variável de ambiente deste processo filho —
  # nunca por argumento (apareceria em ps) e nunca no log (filtro abaixo).
  ( cd "$SEMA_BUNDLE_DIR" && \
    SEMAPHORE_URL="http://127.0.0.1:${SEMAPHORE_PORT}" \
    SEMAPHORE_LOGIN="$SEMAPHORE_ADMIN_USER" \
    SEMAPHORE_PASSWORD="$SEMAPHORE_ADMIN_PASSWORD" \
    GITHUB_TOKEN="$GITHUB_TOKEN" \
    LYRA_CENTRAL_URL="$LYRA_CENTRAL_URL" \
    LYRA_ADMIN_API_KEY="$LYRA_ADMIN_API_KEY" \
    SYNAPSE_PAINEL_REF="${SYNAPSE_PAINEL_REF:-}" \
    bash ./configurar_semaphore_synapse.sh ) 2>&1 \
    | sed -e "s|${GITHUB_TOKEN}|***REDACTED***|g" \
          -e "s|${SEMAPHORE_ADMIN_PASSWORD}|***REDACTED***|g" \
          -e "s|${LYRA_ADMIN_API_KEY}|***REDACTED***|g" >> "$SEMA_LOG"
  SEMA_RC=${PIPESTATUS[0]}

  # Verificação INDEPENDENTE do que o script disse: loga na API de novo e
  # confere que o projeto Synapse e os 3 templates existem de verdade.
  SEMA_COOKIE="$(mktemp)"
  SEMA_LOGIN_BODY=$(SEMA_U="$SEMAPHORE_ADMIN_USER" SEMA_P="$SEMAPHORE_ADMIN_PASSWORD" python3 -c "
import json, os
print(json.dumps({'auth': os.environ['SEMA_U'], 'password': os.environ['SEMA_P']}))")
  SEMA_HTTP=$(curl -s -o /dev/null -w '%{http_code}' -c "$SEMA_COOKIE" -X POST \
    -H 'Content-Type: application/json' -d "$SEMA_LOGIN_BODY" \
    "http://127.0.0.1:${SEMAPHORE_PORT}/api/auth/login")
  if [ "$SEMA_HTTP" = "204" ] || [ "$SEMA_HTTP" = "200" ]; then
    SEMA_PROJ_ID=$(curl -s -b "$SEMA_COOKIE" "http://127.0.0.1:${SEMAPHORE_PORT}/api/projects" \
      | jq -r '.[] | select(.name=="Synapse") | .id' 2>/dev/null | head -n1)
    SEMA_QTD_TPL=0
    if [ -n "$SEMA_PROJ_ID" ]; then
      SEMA_QTD_TPL=$(curl -s -b "$SEMA_COOKIE" "http://127.0.0.1:${SEMAPHORE_PORT}/api/project/${SEMA_PROJ_ID}/templates" \
        | jq -r '[.[] | select(.name=="Provisionar Cliente" or .name=="Atualizar Cliente" or .name=="Backup Diário")] | length' 2>/dev/null)
    fi
    if [ -n "$SEMA_PROJ_ID" ] && [ "${SEMA_QTD_TPL:-0}" -ge 3 ]; then
      SEMA_CONFIG_OK=true
      relatorio "PASS" "Semaphore configurado" "projeto Synapse (id=${SEMA_PROJ_ID}) com os 3 templates, confirmado via API"
    else
      relatorio "FAIL" "Semaphore configurado" "após o script: projeto=${SEMA_PROJ_ID:-ausente}, templates encontrados=${SEMA_QTD_TPL:-0}/3 (exit do script=${SEMA_RC}) — ver ${SEMA_LOG}"
    fi
  else
    relatorio "FAIL" "Semaphore configurado" "login na API falhou (HTTP ${SEMA_HTTP}) — o script de configuração não teria conseguido autenticar (exit=${SEMA_RC}); ver ${SEMA_LOG}"
  fi
  rm -f "$SEMA_COOKIE"

  # O bundle lista suas próprias pendências: repassa as linhas dele, sem
  # esconder nenhuma (ex.: falha de push por token só-leitura).
  SEMA_PENDENCIAS=$(sed -n '/4\. Etapas pendentes/,/Templates confirmados/p' "$SEMA_LOG" \
    | grep '^  - ' | sed 's/\x1b\[[0-9;]*m//g' | head -c 1500)
  if [ -n "$SEMA_PENDENCIAS" ]; then
    relatorio "EXCEÇÃO" "Semaphore — pendências declaradas pelo bundle" "$(echo "$SEMA_PENDENCIAS" | tr '\n' ' ')"
  fi
fi


cancao_integrar_n8n_semaphore
# =============================================================================
# 14. VALIDAÇÃO FINAL
# =============================================================================
log "Validando serviços instalados..."
sleep 10
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
check_service "Lyra Central — local"       "http://127.0.0.1:8080/healthz"
check_service "Lyra Central — pública"     "https://${DOMINIO_LYRA}/healthz"

# GEMINI_API_KEY/GEMINI_MODEL: confirma que estão gravados no .env real da
# Lyra Central (não em variável do instalador, que não prova que o
# PROCESSO da Lyra os usa) e depois faz uma chamada REAL a /v1/chat pra
# confirmar que o motor está de fato respondendo através deles.
if [ -f "${LYRA_APP_DIR}/.env" ] && grep -q '^GEMINI_API_KEY=.\+' "${LYRA_APP_DIR}/.env"; then
  relatorio "PASS" "Gemini" "GEMINI_API_KEY presente no .env da Lyra Central"
else
  relatorio "FAIL" "Gemini" "GEMINI_API_KEY ausente ou vazio em ${LYRA_APP_DIR}/.env"
fi
GEMINI_MODEL_CONFIGURADO=$(grep '^GEMINI_MODEL=' "${LYRA_APP_DIR}/.env" 2>/dev/null | cut -d= -f2-)

if [ -n "$LYRA_TENANT_API_KEY" ]; then
  HTTP_CHAT_TESTE=$(curl -s -o /tmp/synapse_lyra_chat_teste.json -w '%{http_code}' --max-time 30 \
    -X POST "https://${DOMINIO_LYRA}/v1/chat" \
    -H "Authorization: Bearer ${LYRA_TENANT_API_KEY}" -H "X-Tenant-ID: ${TENANT_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"conversation_id":"synapse-provisionamento-teste","message":"teste automático de provisionamento, responda em 1 palavra"}')
  if [ "$HTTP_CHAT_TESTE" = "200" ]; then
    FINISH_REASON_TESTE=$(grep -o "finish_reason[^}]*" /tmp/synapse_lyra_chat_teste.json 2>/dev/null | head -1)
    if echo "$FINISH_REASON_TESTE" | grep -qi "infra_failure"; then
      relatorio "FAIL" "Lyra Central" "/v1/chat respondeu HTTP 200 mas com finish_reason infra_failure — Gemini configurado (${GEMINI_MODEL_CONFIGURADO:-default}) porém a chamada real falhou"
    else
      relatorio "PASS" "Lyra Central" "/v1/chat respondeu com sucesso usando GEMINI_MODEL=${GEMINI_MODEL_CONFIGURADO:-default}"
    fi
  else
    relatorio "FAIL" "Lyra Central" "/v1/chat HTTP ${HTTP_CHAT_TESTE} — $(cat /tmp/synapse_lyra_chat_teste.json 2>/dev/null | head -c 200)"
  fi
else
  relatorio "FAIL" "Lyra Central" "sem LYRA_TENANT_API_KEY — onboarding do tenant falhou antes, não dá pra testar /v1/chat de verdade"
fi
check_service "ERPNext (Ritmo) — API"      "https://${DOMINIO_ERP}/api/method/ping"
check_service "N8N (Harmonia) — healthz"   "https://${DOMINIO_N8N}/healthz"
check_service "Chatwoot (Harpa) — widget"  "https://${DOMINIO_CHAT}/packs/js/sdk.js"
check_service "Uptime (Eco) — Basic Auth"  "https://${DOMINIO_UPTIME}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"

# --- Teste de ponta a ponta AUTOMÁTICO possível daqui: injeta um evento no
#     formato real do Chatwoot direto no webhook do n8n e confere no
#     próprio n8n se a execução rodou com sucesso. Isso prova
#     Chatwoot-shape -> n8n -> Lyra -> Gemini -> Lyra -> n8n de ponta a
#     ponta. O único trecho que ISSO NÃO prova é Meta -> Chatwoot em si
#     (exigiria mandar uma mensagem de um número de telefone real) — fica
#     honestamente marcado como exceção, não fingido como testado.
if [ -n "${N8N_API_KEY:-}" ] && [ "$L1_ATIVO" = "sim" ]; then
  PAYLOAD_TESTE_E2E=$(python3 -c "
import json
print(json.dumps({
    'event': 'message_created',
    'message_type': 'incoming',
    'private': False,
    'content': 'teste automático de provisionamento',
    'conversation': {'id': 999999001, 'status': 'open'},
    'inbox': {'channel_type': 'Channel::Whatsapp'},
    'sender': {'id': 999999001, 'name': 'Provisionamento Synapse', 'phone_number': '+000000000'}
}))
")
  curl -s -o /dev/null -X POST "https://${DOMINIO_N8N}/webhook/synapse-atendimento" \
    -H 'Content-Type: application/json' -d "$PAYLOAD_TESTE_E2E"
  sleep 8
  L1_WF_ID=$(python3 -c "
import json
try:
    r = json.load(open('/tmp/synapse_import_resultado.json'))
    l1 = next((w for w in r if 'L1' in w['nome'] and 'Triagem' in w['nome']), None)
    print(l1['id'] if l1 else '')
except Exception:
    pass
" 2>/dev/null)
  if [ -n "$L1_WF_ID" ]; then
    EXEC_JSON=$(curl -s -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
      "https://${DOMINIO_N8N}/api/v1/executions?workflowId=${L1_WF_ID}&limit=1" 2>/dev/null)
    STATUS_EXEC=$(echo "$EXEC_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ex = (d.get('data') or [None])[0]
    print(ex.get('status','desconhecido') if ex else 'sem_execucao')
except Exception:
    print('erro')
" 2>/dev/null)
    if [ "$STATUS_EXEC" = "success" ]; then
      relatorio "PASS" "integração ponta a ponta (sintética)" "Chatwoot-shape -> n8n -> Lyra -> Gemini -> n8n executou com sucesso. Meta -> Chatwoot em si só é validado com uma mensagem real de telefone (fora do alcance de automação sem enviar mensagem real a um destinatário)."
    else
      relatorio "FAIL" "integração ponta a ponta (sintética)" "última execução do workflow L1 = '${STATUS_EXEC}' (esperado 'success') — confira em ${N8N_BASE}/workflow/${L1_WF_ID}/executions"
    fi
  else
    relatorio "FAIL" "integração ponta a ponta (sintética)" "não achei o ID do workflow L1 pra checar a execução"
  fi
else
  relatorio "FAIL" "integração ponta a ponta (sintética)" "pulado — depende de N8N API key e do workflow L1 ativo"
fi
check_service "Netdata (Acorde) — Basic Auth" "https://${DOMINIO_NETDATA}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  check_service "Painel"                     "https://${DOMINIO_PAINEL}"
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  check_service "Home (raiz)"                "https://${DOMINIO_BASE}"
fi

CODE_SEMA=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${SEMAPHORE_PORT}" 2>/dev/null)
[ "$CODE_SEMA" = "200" ] && ok "Semaphore — local respondeu HTTP 200" || err "Semaphore local não respondeu (HTTP ${CODE_SEMA})"

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
# 15. REINÍCIO (SE NECESSÁRIO PARA O PATCH DE KERNEL)
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
      warn "Reinício adiado — os containers têm restart:always e o systemd da Lyra Central volta sozinho quando você reiniciar manualmente (sudo reboot)."
    fi
  fi
fi

# =============================================================================
# RELATÓRIO FINAL — PASS/FAIL real, não "instalação concluída" por hábito
# =============================================================================
# Confere de verdade — o script usa 'set -uo pipefail', NÃO 'set -e', e o
# próprio helper err() não interrompe a execução (de propósito, pra um
# check isolado não derrubar o provisionamento inteiro). Então nenhuma
# dessas linhas pode ser assumida como PASS sem checar agora — a alegação
# antiga aqui ("set -e já teria interrompido") tinha 2 erros factuais e
# foi removida.
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
  && relatorio "PASS" "Docker" "daemon respondendo" \
  || relatorio "FAIL" "Docker" "'docker info' falhou"

systemctl is-active --quiet redis-server \
  && relatorio "PASS" "Redis (Lyra, local)" "redis-server ativo" \
  || relatorio "FAIL" "Redis (Lyra, local)" "systemctl is-active redis-server falhou"

docker exec harpa-redis redis-cli ping 2>/dev/null | grep -q PONG \
  && relatorio "PASS" "Redis (Harpa)" "PONG" \
  || relatorio "FAIL" "Redis (Harpa)" "container harpa-redis não respondeu PING"

docker exec harpa-postgres pg_isready >/dev/null 2>&1 \
  && relatorio "PASS" "PostgreSQL (Harpa)" "pg_isready OK" \
  || relatorio "FAIL" "PostgreSQL (Harpa)" "container harpa-postgres não respondeu pg_isready"

docker exec ritmo-db-1 mariadb-admin ping -h localhost --silent 2>/dev/null \
  && relatorio "PASS" "MariaDB (Ritmo/ERPNext)" "ping OK" \
  || relatorio "FAIL" "MariaDB (Ritmo/ERPNext)" "container ritmo-db-1 não respondeu"

CODE_ERPNEXT_PING=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMINIO_ERP}/api/method/ping" 2>/dev/null)
[ "$CODE_ERPNEXT_PING" = "200" ] \
  && relatorio "PASS" "ERPNext API" "HTTP 200 em /api/method/ping" \
  || relatorio "FAIL" "ERPNext API" "HTTP ${CODE_ERPNEXT_PING}"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   RELATÓRIO FINAL DE PROVISIONAMENTO — ${DOMINIO_BASE}${NC}"
echo -e "${GREEN}============================================================${NC}"
for _linha in "${RELATORIO_LINHAS[@]}"; do
  if [[ "$_linha" == "[PASS]"* ]]; then
    echo -e "${GREEN}${_linha}${NC}"
  elif [[ "$_linha" == "[EXCEÇÃO]"* ]]; then
    echo -e "${YELLOW}${_linha}${NC}"
  else
    echo -e "${RED}${_linha}${NC}"
  fi
done
echo -e "${GREEN}============================================================${NC}"
if [ "$FALHA_CRITICA" = true ] || [ "${INSTALL_ERROS:-0}" -gt 0 ]; then
  echo -e "${RED}INSTALAÇÃO PARCIALMENTE CONCLUÍDA — há [FAIL] acima. NÃO declarar concluída.${NC}"
elif printf '%s\n' "${RELATORIO_LINHAS[@]}" | grep -q '^\[EXCEÇÃO\]'; then
  echo -e "${YELLOW}INSTALAÇÃO CONCLUÍDA COM EXCEÇÕES DECLARADAS — nenhum [FAIL], mas há [EXCEÇÃO] acima que exige ação manual explícita.${NC}"
else
  echo -e "${GREEN}INSTALAÇÃO CONCLUÍDA — todos os checks do relatório passaram.${NC}"
fi
echo -e "${GREEN}============================================================${NC}"
echo -e "  Lyra Central      → https://${DOMINIO_LYRA}  (systemctl status lyra-central-api)"
echo -e "  Lyra atendente    → tenant '${TENANT_ID}' (a própria Nomen, já conectada ao Harmonia)"
echo -e "  Ritmo (ERPNext)   → https://${DOMINIO_ERP}  (com Brazil NF instalado)"
echo -e "  Harmonia (N8N)    → https://${DOMINIO_N8N}"
echo -e "  Harpa (Chatwoot)  → https://${DOMINIO_CHAT}"
echo -e "  Eco (Uptime)      → https://${DOMINIO_UPTIME}"
echo -e "  Acorde (Netdata)  → https://${DOMINIO_NETDATA}"
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  echo -e "  Painel            → https://${DOMINIO_PAINEL}"
else
  echo -e "  Painel            → ${RED}NÃO publicado nesta execução${NC} (ver pendência 4 abaixo)"
fi
if [ "$HOME_INSTALADO" = "sim" ]; then
  echo -e "  Home (raiz)       → https://${DOMINIO_BASE}"
else
  echo -e "  Home (raiz)       → ${RED}NÃO publicada nesta execução${NC} (ver pendência 4b abaixo)"
fi
echo -e "  Semaphore         → só via túnel SSH: ssh -L ${SEMAPHORE_PORT}:localhost:${SEMAPHORE_PORT} <usuario>@<ip-desta-vps>"
echo -e "  Credenciais       → ${CRED_FILE} (chmod 600) — TUDO num arquivo só"
echo ""
echo -e "${YELLOW}PRÓXIMOS PASSOS (fora do alcance de script):${NC}"
echo -e "  1. Confirme o teto de gastos no projeto GCP (Vertex AI/Gemini)."
echo -e "  2. Pra atualizar o código da Lyra Central depois, use o scripts/deploy.sh"
echo -e "     que já vem no repo (dentro de ${LYRA_APP_DIR}) — git pull + rollback automático."
echo -e "  3. NODE_ENV=development (SECRETS_PROVIDER=env) na Lyra Central — API Keys de"
echo -e "     tenant ficam em texto local. Não é produção real com cliente pagante ainda"
echo -e "     (gcp_secret_manager/vault são stubs no repo)."
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  echo -e "  4. No Painel (https://${DOMINIO_PAINEL}), cadastrar Melhor Envio / InfinitePay / 99 Empresas."
else
  if [ -z "$PAINEL_HTML_ORIGEM" ]; then
    echo -e "  4. ${RED}Painel não publicado${NC} — nenhuma fonte de HTML disponível. Rode de novo com o HTML como 4º argumento, copie pra /root/synapse_painel.html, ou crie github.com/${GITHUB_ORG}/painel."
  else
    echo -e "  4. ${RED}Painel publicado mas NÃO validado${NC} — host/container/HTTPS não bateram (ver PANEL_DEPLOY_OK acima). Rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate, e confira se https://${DOMINIO_PAINEL} responde antes de reexecutar."
  fi
fi
if [ "$HOME_INSTALADO" != "sim" ]; then
  echo -e "  4b. ${RED}Home não publicada${NC} — rode de novo com a pasta/arquivo como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo)."
fi
echo -e "  5. Inbox de WhatsApp no Harpa: precisa de credenciais de um provedor."
echo -e "  6. Confirmar Plano de Contas BR no Ritmo, se o passo automático não achou o nome certo."
echo -e "  7. Criar a Status Page do Eco com slug 'synapse' (Basic Auth: ${BASICAUTH_USER})."
echo -e "  8. Confirmar os 8 registros DNS (raiz/lyra/ritmo/harmonia/harpa/acorde/eco/painel) apontando pro IP desta VPS — a raiz (apex) é nova, precisa existir pra Home funcionar."
echo -e "  9. Semaphore: projeto, Key Store, repo (github.com/nomen-me/synapse), Environment, Inventory e templates"
echo -e "     são configurados AUTOMATICAMENTE na seção 13B (log em /var/log/synapse_semaphore_config.log)."
echo -e "     Manual restante (declarado como [EXCEÇÃO] no relatório): a Integration n8n->Semaphore"
echo -e "     (Project > Integrations) — o bundle não automatiza porque o schema do payload não foi confirmado."
if [ -z "${LYRA_TENANT_API_KEY:-}" ]; then
  echo -e "  10. ${RED}Onboarding da Nomen como tenant falhou — rode o script de novo (é idempotente).${NC}"
fi
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  echo -e "  11. O card de Consumo (VPS) do Painel chama o webhook 'monitoramento/metricas' no"
  echo -e "      Harmonia como proxy pro Acorde — esse workflow ainda não existe no repo de"
  echo -e "      workflows, precisa ser criado à parte (o Painel sobe normalmente sem ele; só"
  echo -e "      esse card específico fica sem dado até o workflow existir)."
fi
echo -e "${GREEN}============================================================${NC}"

}

main "$@"
exit $?
#__CANCAO_PAYLOAD__
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
