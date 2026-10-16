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
CANCAO_BUNDLE_SHA256="042b3e21dbb1d807246bef2b1ac4cd4f79f8bfbf3d932886b4e31854f6a02c20"
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
  # install-app sincroniza os DocTypes do synapse_core e, na MESMA chamada,
  # dispara o hook after_install (synapse_core.setup.ensure), que configura
  # o proprio DocType Single "Synapse Autonomia" recem-criado por essa mesma
  # sincronizacao. Isso falha com "DocType Synapse Autonomia not found"
  # mesmo em instalacao 100% limpa, sem residuo nenhum - nao e um problema
  # de rerun. O "&&" que existia aqui antes abortava nesse exato ponto e
  # nunca chegava ao "bench migrate" seguinte, que e o passo que teria
  # resincronizado tudo e disparado o hook equivalente de novo
  # (after_migrate, mesmo hooks.py), desta vez com o DocType ja visivel.
  # Por isso: tenta install-app, tolera falha SO dessa tentativa especifica
  # (log completo, nao escondido), roda migrate incondicionalmente na
  # sequencia, e so entao confere de verdade - consultando o Frappe, nao o
  # exit code - se "Synapse Autonomia" existe. Continua fatal se, depois
  # dessas duas tentativas, o DocType realmente nao estiver la: isso NAO
  # mascara um erro de verdade, so da ao migrate a chance que o "&&" antigo
  # nunca dava.
  # Precaucao: o synapse_core acabou de ser colocado em apps.txt por fora do bench;
  # limpar o cache do site antes evita que um cache de modulos velho atrapalhe o
  # install-app. Se o install-app ainda retornar erro, o after_migrate recupera (abaixo).
  docker exec -u frappe $C bash -c "cd $B && bench --site ${DOMINIO_ERP} clear-cache" >/dev/null 2>&1 || true
  if app_instalado_no_site synapse_core; then
    INSTALL_APP_LOG="synapse_core ja instalado no site - install-app pulado"; INSTALL_APP_RC=0
  else
    INSTALL_APP_LOG=$(docker exec -u frappe $C bash -c "cd $B && bench --site ${DOMINIO_ERP} install-app synapse_core" 2>&1)
    INSTALL_APP_RC=$?
  fi
  [ $INSTALL_APP_RC -ne 0 ] && { echo "---- ultimas linhas do install-app (rc=${INSTALL_APP_RC}) ----"; echo "$INSTALL_APP_LOG" | tail -n 25; echo "-----------------------------------------------"; }
  [ $INSTALL_APP_RC -ne 0 ] && warn "Cancao: install-app do synapse_core retornou erro (rc=${INSTALL_APP_RC}) - normalmente o hook after_install tentando configurar a propria Synapse Autonomia antes dela estar visivel nesse mesmo processo. Seguindo para 'bench migrate', que resincroniza e tenta de novo via after_migrate."
  MIGRATE_LOG=$(docker exec -u frappe $C bash -c "cd $B && bench --site ${DOMINIO_ERP} migrate" 2>&1)
  MIGRATE_RC=$?
  R=$(ritmo_exec <<PYEOF
def main():
    import frappe
    print("CANCAO_DOCTYPE_OK" if frappe.db.exists("DocType", "Synapse Autonomia") else "CANCAO_DOCTYPE_FALTANDO")
PYEOF
)
  if ! echo "$R" | grep -q CANCAO_DOCTYPE_OK; then
    echo "---------------- saida do install-app (rc=${INSTALL_APP_RC}) ----------------"
    echo "$INSTALL_APP_LOG"
    echo "---------------- saida do migrate (rc=${MIGRATE_RC}) ----------------"
    echo "$MIGRATE_LOG"
    fatal "Cancao: install-app/migrate do synapse_core falhou (DocType Synapse Autonomia nao existe mesmo depois de install-app + migrate - ver saida completa acima)"
  fi
  [ $MIGRATE_RC -ne 0 ] && warn "Cancao: 'bench migrate' retornou erro (rc=${MIGRATE_RC}) mas Synapse Autonomia ja existe - seguindo, mas revise o log do migrate depois:"
  [ $MIGRATE_RC -ne 0 ] && echo "$MIGRATE_LOG"
  app_instalado_no_site synapse_core \
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
  grep -qE "Harmonia\.chamarMultipart\('atendimento/enviar-anexo'|atendimentoEnviarAnexo: 'atendimento/enviar-anexo'" "$idx" || fatal "Cancao: Painel sem a ligacao do anexo ao Harmonia apos o patch"
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
    R=$(curl -s -m 30 -H "X-N8N-API-KEY: ${N8N_API_KEY}" "${N8N_INT:-https://${DOMINIO_N8N}}/api/v1/workflows?limit=250" | python3 -c "
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
    # O usuario de automacao (System Manager + Synapse Automacao) NAO tem permissao para criar Item:
    # o POST antigo devolvia 403 "No permission for Item" (escondido por -o /dev/null) e o teste
    # terminava em 'ausente' porque o Outbox nunca recebia evento. O gatilho agora e criado pelo
    # Administrator (bench execute); o que se valida segue sendo Outbox -> Harmonia -> gate, lido
    # pela API com o proprio usuario de automacao.
    local ITEM_OUT ITEM_OK=0
    ITEM_OUT=$(ritmo_exec <<PYEOF
def main():
    import frappe
    try:
        frappe.get_doc({"doctype": "Item", "item_code": "${CODE}", "item_name": "${CODE}", "item_group": "${GRP}", "stock_uom": "Nos", "is_stock_item": 0}).insert(ignore_permissions=True)
        frappe.db.commit()
        print("SYNAPSE_KV|item|criado")
    except Exception as e:
        frappe.db.rollback()
        print("SYNAPSE_KV|item_erro|" + repr(e)[:300])
PYEOF
)
    grep -q 'SYNAPSE_KV|item|criado' <<<"$ITEM_OUT" && ITEM_OK=1
    local i ST="" GA="" N_TENT=40
    [ "$ITEM_OK" = 1 ] || N_TENT=0
    for i in $(seq 1 "$N_TENT"); do
      R=$(curl -s -m 30 -H "$AUTH" -G "https://${DOMINIO_ERP}/api/resource/Synapse%20Outbox" --data-urlencode "filters=[[\"entity_id\",\"=\",\"${CODE}\"]]" --data-urlencode 'fields=["status","gate_action","event_type"]' | python3 -c "import sys,json
try:
  d=json.load(sys.stdin)['data']; print((d[0]['status']+'|'+str(d[0].get('gate_action'))) if d else '')
except Exception: print('')")
      ST="${R%%|*}"; GA="${R##*|}"
      [ "$ST" = "PROCESSED" ] && break
      sleep 6
    done
    if [ "$ST" = "PROCESSED" ]; then cancao_check PASS "ciclo Ritmo->Outbox->Harmonia->gate" "evento de ${CODE} PROCESSED (gate=${GA})"
    elif [ "$ITEM_OK" != 1 ]; then cancao_check FAIL "ciclo Ritmo->Outbox->Harmonia->gate" "nao consegui criar o Item de teste: $(grep -o 'item_erro|.*' <<<"$ITEM_OUT" | head -1 | cut -c1-300)"
    else cancao_check FAIL "ciclo Ritmo->Outbox->Harmonia->gate" "evento de ${CODE} terminou em '${ST:-ausente}' apos ~4 min (relay do Outbox, webhook da Harmonia ou ACK falhou)"; fi
    ritmo_exec >/dev/null 2>&1 <<PYEOF
def main():
    import frappe
    if frappe.db.exists("Item", "${CODE}"):
        frappe.delete_doc("Item", "${CODE}", force=1, ignore_permissions=True)
        frappe.db.commit()
PYEOF
  fi
  # 4) Lyra Central: rota /v1/decide instalada e autenticada (evento de controle - nao depende do Gemini)
  local LK="${LYRA_API_KEY:-${LYRA_TENANT_API_KEY:-}}" LT="${LYRA_TENANT_ID:-${TENANT_ID:-}}" LU="${LYRA_CENTRAL_URL:-}"
  if [ -n "$LK" ] && [ -n "$LT" ] && [ -n "$LU" ]; then
    local DECIDE_BODY='{"event":{"event_id":"smoke","event_type":"intent_expired","entity_type":"Item","entity_id":"X","state_version":1,"payload":{"operation_id":"smoke","conversa_id":"0"}}}'
    local R_LOCAL; R_LOCAL=$(curl -s -m 30 -X POST "http://127.0.0.1:8080/v1/decide" -H "Authorization: Bearer ${LK}" -H "X-Tenant-ID: ${LT}" -H 'Content-Type: application/json' -d "$DECIDE_BODY" | python3 -c "import sys,json
try:
  d=json.load(sys.stdin); print('ok' if d.get('notifications') and d['notifications'][0]['kind']=='reconfirm_intent' else 'resposta inesperada')
except Exception: print('sem JSON')")
    R=$(curl -s -m 30 -X POST "${LU}/v1/decide" -H "Authorization: Bearer ${LK}" -H "X-Tenant-ID: ${LT}" -H 'Content-Type: application/json' \
      -d '{"event":{"event_id":"smoke","event_type":"intent_expired","entity_type":"Item","entity_id":"X","state_version":1,"payload":{"operation_id":"smoke","conversa_id":"0"}}}' | python3 -c "import sys,json
try:
  d=json.load(sys.stdin); print('ok' if d.get('notifications') and d['notifications'][0]['kind']=='reconfirm_intent' else 'resposta inesperada')
except Exception: print('sem JSON (rota /v1/decide ausente?)')")
    if [ "$R" = "ok" ]; then cancao_check PASS "Lyra /v1/decide" "rota ativa e autenticada"
    elif [ "$R_LOCAL" = "ok" ]; then cancao_check FAIL "Lyra /v1/decide" "a rota funciona LOCALMENTE (127.0.0.1:8080), mas ${LU} nao responde: problema de certificado/DNS/Traefik (o n8n chama a Lyra por esse URL)"
    else cancao_check FAIL "Lyra /v1/decide" "publico: ${R}; local: ${R_LOCAL}"; fi
  else
    cancao_check FAIL "Lyra /v1/decide" "credenciais/URL da Lyra Central ausentes para o teste"
  fi
  # 5) Painel publicado com Aprovar/Rejeitar
  if [ -n "${DOMINIO_PAINEL:-}" ]; then
    # Captura a pagina ANTES do grep: "curl | grep -q" com pipefail da falso negativo, porque o grep
    # sai no 1o match e o curl (pagina de ~450 KB) leva SIGPIPE (erro 23) - falhava 5/5 mesmo com a aba la.
    local PAGINA_PAINEL; PAGINA_PAINEL="$(curl -s -m 30 "https://${DOMINIO_PAINEL}/" 2>/dev/null)"
    if [ -z "$PAGINA_PAINEL" ]; then
      cancao_check FAIL "Painel Aprovar/Rejeitar" "https://${DOMINIO_PAINEL} nao respondeu (certificado/DNS - veja o diagnostico do Traefik acima)"
    elif grep -q 'page-aprovacoes' <<<"$PAGINA_PAINEL"; then
      cancao_check PASS "Painel Aprovar/Rejeitar" "publicado em https://${DOMINIO_PAINEL}"
    else
      cancao_check FAIL "Painel Aprovar/Rejeitar" "a pagina publicada nao contem a aba Aprovacoes"
    fi
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

# Mostra o erro ACME COMPLETO de um dominio. "429" = limite do Let's Encrypt (falhas de validacao por
# hora, certificados duplicados por semana ou por dominio registrado): so passa com o tempo, e cada
# nova rodada/restart do Traefik gasta mais cota. A mensagem traz o "retry after".
acme_diagnostico() {
  local h="$1" linha
  linha="$(docker logs traefik 2>&1 | grep -F -- "$h" | grep -iE 'unable to obtain|acme|ratelimited|429' | tail -1)"
  if [ -n "$linha" ]; then
    warn "  Traefik/ACME (${h}): $(echo "$linha" | cut -c1-900)"
    if grep -qE '429|rateLimited' <<<"$linha"; then
      warn "  >> 429 = LIMITE DO LET'S ENCRYPT. Leia o 'retry after' acima e AGUARDE esse horario antes de reexecutar; nao apague o volume traefik_certs nem reinicie o Traefik em loop. Se for 'failed authorizations', confira o DNS de ${h}."
    fi
  else
    warn "  Traefik/ACME (${h}): nenhum erro ACME recente nos logs (confira: docker logs traefik --tail 50)"
  fi
}

# O "bench list-apps" do Frappe v15 NAO imprime so o nome do app: cada linha e
# "<app> <versao> <branch>" (ex.: "synapse_core 0.1.0 None"). Por isso um
# "grep -qx <app>" nunca casa, mesmo com o app instalado (falso negativo).
# Aqui comparamos so a 1a coluna. Captura a saida numa variavel antes do grep
# pra nao depender de SIGPIPE/pipefail.
app_instalado_no_site() {
  local app="$1" saida
  saida="$(docker exec -u frappe ritmo-backend-1 bash -c "cd /home/frappe/frappe-bench && bench --site ${DOMINIO_ERP} list-apps" 2>/dev/null)" || true
  grep -qx "$app" < <(awk 'NF{print $1}' <<<"$saida")
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

# Node >= 20 e exigido pelo install.sh da Lyra Central. O Node 20 saiu de suporte em
# 30/04/2026 e o script "setup_20.x" do NodeSource esta depreciado; instalamos o Node 22
# (LTS) direto do repositorio NodeSource. O Ubuntu 24.04 traz Node 18.19.1 por padrao,
# que e o que aparece se o NodeSource nao entrar - por isso verificamos no fim.
NODE_MAJOR_ALVO=22
node_major_atual() { local v; v="$(command -v node >/dev/null 2>&1 && node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"; echo "${v:-0}"; }
if [ "$(node_major_atual)" -lt 20 ]; then
  log "Instalando Node.js ${NODE_MAJOR_ALVO} (repositorio NodeSource, pra Lyra Central)..."
  esperar_apt_livre
  apt install -y ca-certificates curl gnupg || fatal "Falha ao instalar dependencias do repositorio NodeSource."
  # Remove restos do setup_20.x / de pacotes do Ubuntu que conflitam com o nodejs do NodeSource
  rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.sources
  apt purge -y npm libnode-dev nodejs-doc >/dev/null 2>&1 || true
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg \
    || fatal "Falha ao baixar a chave do repositorio NodeSource."
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR_ALVO}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  # Prioriza o nodejs do NodeSource sobre o do Ubuntu (18.19.1)
  printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 1001\n' > /etc/apt/preferences.d/nodejs
  esperar_apt_livre
  apt update || fatal "Falha no apt update apos adicionar o repositorio NodeSource."
  apt install -y nodejs || fatal "Falha ao instalar Node.js ${NODE_MAJOR_ALVO}."
  hash -r
fi
if [ "$(node_major_atual)" -lt 20 ]; then
  err "node no PATH: $(command -v node) -> $(node -v 2>/dev/null)"
  apt-cache policy nodejs 2>/dev/null | head -12
  fatal "Node.js >= 20 nao foi instalado (o install.sh da Lyra Central exige). Veja a saida do 'apt-cache policy nodejs' acima."
fi
ok "Node.js $(node -v) OK ($(command -v node))"

# Pre-voo de DNS (so avisa, nao bloqueia): os certificados Let's Encrypt so saem se cada
# subdominio apontar para esta VPS. Subdominio sem registro = HTTPS falhando (HTTP 000) la na frente.
_IP_PUB="$(curl -s -m 6 https://api.ipify.org 2>/dev/null || curl -s -m 6 https://ifconfig.me 2>/dev/null)"
if [ -n "$_IP_PUB" ]; then
  for _h in "${DOMINIO_ERP}" "${DOMINIO_N8N}" "${DOMINIO_CHAT}" "${DOMINIO_LYRA}" "${DOMINIO_PAINEL}" "${DOMINIO_NETDATA}" "${DOMINIO_UPTIME}"; do
    _r="$(getent ahostsv4 "$_h" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ "$_r" = "$_IP_PUB" ]; then ok "DNS ${_h} -> ${_r}"
    else warn "DNS ${_h} -> ${_r:-SEM REGISTRO} (esta VPS e ${_IP_PUB}). Sem o registro A correto o certificado HTTPS NAO sera emitido."; fi
  done
else
  warn "Nao consegui descobrir o IP publico desta VPS; pulando a checagem de DNS."
fi

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

# O Traefik (container) chega na Lyra Central (processo no HOST, porta 8080) via
# host.docker.internal. Para o host isso e trafego de ENTRADA vindo da rede docker, e o ufw
# (so 22/80/443) o descarta em silencio: o HTTPS publico da Lyra fica pendurado (curl: timeout
# com 0 bytes) mesmo com a Lyra saudavel em 127.0.0.1:8080. Liberamos SO a sub-rede da
# stack-network, so na porta 8080 - a Lyra continua nao exposta na internet.
STACK_SUBNET="$(docker network inspect stack-network -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -m1 '\.')"
if [ -n "$STACK_SUBNET" ]; then
  ufw allow from "$STACK_SUBNET" to any port 8080 proto tcp comment 'Traefik -> Lyra Central' >/dev/null 2>&1 \
    && ok "Firewall: ${STACK_SUBNET} (stack-network) -> porta 8080 liberada so para o Traefik alcancar a Lyra Central" \
    || warn "Nao consegui criar a regra ufw ${STACK_SUBNET} -> 8080 (rode: ufw allow from ${STACK_SUBNET} to any port 8080 proto tcp)"
else
  warn "Nao consegui obter a sub-rede da stack-network; sem a regra ufw o HTTPS da Lyra pode ficar pendurado."
fi

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
      if app_instalado_no_site brazil_nf; then
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

    # Site criado sem o Setup Wizard nao tem o Warehouse Type "Transit", e o ERPNext
    # o exige ao criar o armazem "Goods In Transit" da Empresa. Sem isso a criacao
    # falha com "Could not find Warehouse Type: Transit". Idempotente.
    # O Setup Wizard tambem cria os cadastros-base (Item Groups, UOM "Nos", Customer Group,
    # Territory...). Num site sem wizard NAO existe nenhum Item Group, e tudo que cria
    # item/cliente depois (inclusive o teste de ciclo) falha. Rodamos a mesma rotina de
    # fixtures do proprio ERPNext, so se ainda nao houver nenhum Item Group.
    try:
        if not frappe.db.count("Item Group"):
            from erpnext.setup.setup_wizard.operations import install_fixtures
            install_fixtures.install("Brazil")
            frappe.db.commit()
            print("SYNAPSE_KV|fixtures|instaladas")
    except Exception as _e:
        frappe.db.rollback()
        print("SYNAPSE_KV|fixtures_erro|" + repr(_e)[:200])

    if not frappe.db.exists("Warehouse Type", "Transit"):
        frappe.get_doc({"doctype": "Warehouse Type", "name": "Transit"}).insert(ignore_permissions=True)
        frappe.db.commit()

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
  # "docker compose start" so religa containers que ja existem; aqui o rails/sidekiq nunca
  # foram criados (so o "run --rm" de uma vez), entao nao existia harpa-rails. "up -d" cria.
  if docker compose up -d rails sidekiq; then
    ok "Chatwoot instalado em https://${DOMINIO_CHAT}"
  else
    err "Nao consegui subir rails/sidekiq do Chatwoot. Rode: cd /home/ubuntu/chatwoot && docker compose up -d rails sidekiq && docker compose logs --tail 50 rails"
  fi
else
  err "Falha ao preparar a BD do Chatwoot. Rode depois: cd /home/ubuntu/chatwoot && docker compose run --rm -T rails bundle exec rails db:chatwoot_prepare"
fi
log "Aguardando o Rails do Chatwoot responder (ate 3 min)..."
_CW_IP=""; _CW_OK=0
for _i in $(seq 1 60); do
  _CW_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' harpa-rails 2>/dev/null | awk '{print $1}')
  if [ -n "$_CW_IP" ] && [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${_CW_IP}:3000/api" 2>/dev/null)" != "000" ]; then _CW_OK=1; break; fi
  sleep 3
done
[ "$_CW_OK" = 1 ] && ok "Rails do Chatwoot respondendo" || warn "Rails do Chatwoot ainda nao respondeu; seguindo (veja: docker logs harpa-rails --tail 50)"

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
  # Na 1a publicacao o Traefik ainda precisa emitir o certificado (Let's Encrypt); ate la o curl
  # falha e o corpo vem vazio (sha256 e3b0c442...). Espera ate 3 min pelo conteudo certo.
  log "Aguardando o HTTPS do Painel responder com o arquivo novo (certificado na 1a publicacao; ate 3 min)..."
  PAINEL_H_HTTPS=""
  for _t in $(seq 1 36); do
    PAINEL_H_HTTPS="$(curl -fsSL -m 10 "https://${DOMINIO_PAINEL}/" 2>/dev/null | sha256sum | awk '{print $1}')"
    [ "$PAINEL_H_HTTPS" = "$PAINEL_H_HOST" ] && break
    sleep 5
  done
  if [ "$PAINEL_H_HTTPS" != "$PAINEL_H_HOST" ]; then
    warn "  curl: $(curl -sS -m 8 -o /dev/null "https://${DOMINIO_PAINEL}/" 2>&1 | tail -1 | cut -c1-200)"
    warn "  DNS de ${DOMINIO_PAINEL}: $(getent ahostsv4 "${DOMINIO_PAINEL}" 2>/dev/null | awk 'NR==1{print $1}') (deve ser o IP publico desta VPS)"
    acme_diagnostico "${DOMINIO_PAINEL}"
  fi
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
  # O Traefik so publica /webhook, /webhook-test, /api/v1 e /healthz do Harmonia (a GUI e o
  # /rest/* sao escondidos de proposito). Por isso a criacao do owner e da API key NAO pode
  # ir por https://${DOMINIO_N8N}: o /rest/* cai no "blackhole 404". Falamos com o n8n pelo
  # IP do container na rede docker (o host alcanca o bridge), sem expor nada novo.
  N8N_INT=""
  for _t in $(seq 1 30); do
    _ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' harmonia 2>/dev/null | awk '{print $1}')
    if [ -n "$_ip" ]; then N8N_INT="http://${_ip}:5678"; break; fi
    sleep 2
  done
  [ -z "$N8N_INT" ] && warn "Nao achei o IP do container 'harmonia' (docker ps -a | grep harmonia) - nao da pra gerar a API key do N8N."

  # /healthz responde 200 ainda durante as migracoes do banco; /healthz/readiness so depois.
  log "Aguardando o Harmonia (n8n) ficar pronto em ${N8N_INT:-?} (/healthz/readiness)..."
  N8N_PRONTO=false
  for _t in $(seq 1 90); do
    if [ -n "$N8N_INT" ] && [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "${N8N_INT}/healthz/readiness" 2>/dev/null)" = "200" ]; then N8N_PRONTO=true; break; fi
    sleep 2
  done
  [ "$N8N_PRONTO" = true ] && ok "n8n pronto (${N8N_INT})" || warn "n8n nao ficou pronto em 3 min - tentando gerar a API key mesmo assim (veja: docker logs harmonia --tail 50)."

  # n8n exige senha com >=1 maiuscula e >=1 numero; a SENHA aleatoria (24 alfanumericos) nao
  # garante isso em ~1,4% dos casos. O sufixo garante (so o owner de automacao usa esta senha).
  N8N_OWNER_SENHA="${SENHA}Aa1"
  _n8n_token_de() { grep -i '^set-cookie: *n8n-auth=' "$1" 2>/dev/null | head -1 | sed -E 's/^[^=]*=([^;]*).*/\1/' | tr -d '\r\n'; }
  _n8n_api_ok()   { [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "X-N8N-API-KEY: $1" "${N8N_INT}/api/v1/workflows?limit=1" 2>/dev/null)" = "200" ]; }

  N8N_API_KEY=""
  # Reaproveita a chave de uma execucao anterior, se ainda valer (evita login/novas chaves a cada rerun).
  _k_ant="$(ler_credencial_existente N8N_API_KEY 2>/dev/null || true)"
  if [ -n "$_k_ant" ] && [ -n "$N8N_INT" ] && _n8n_api_ok "$_k_ant"; then
    N8N_API_KEY="$_k_ant"; ok "API key do N8N de uma execucao anterior ainda e valida - reaproveitada"
  fi

  if [ -z "$N8N_API_KEY" ] && [ -n "$N8N_INT" ]; then
   for _tentativa in 1 2 3; do
    TOKEN=""; rm -f /tmp/synapse_n8n_h.txt
    HTTP_SETUP=$(curl -s -m 30 -D /tmp/synapse_n8n_h.txt -o /tmp/synapse_n8n_setup.json -w '%{http_code}' \
      -X POST "${N8N_INT}/rest/owner/setup" -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"firstName":"Synapse","lastName":"Automacao","password":sys.argv[2]}))' "$N8N_AUTOMACAO_EMAIL" "$N8N_OWNER_SENHA")")
    [ "$HTTP_SETUP" = "200" ] && TOKEN="$(_n8n_token_de /tmp/synapse_n8n_h.txt)"

    if [ -z "$TOKEN" ]; then
      # owner ja existe (rerun): login. O n8n 2.x exige o campo "emailOrLdapLoginId" (so "email" da 400).
      HTTP_LOGIN="-"
      for _pw in "$N8N_OWNER_SENHA" "$SENHA"; do
        rm -f /tmp/synapse_n8n_h.txt
        HTTP_LOGIN=$(curl -s -m 30 -D /tmp/synapse_n8n_h.txt -o /tmp/synapse_n8n_login.json -w '%{http_code}' \
          -X POST "${N8N_INT}/rest/login" -H 'Content-Type: application/json' \
          -d "$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"emailOrLdapLoginId":sys.argv[1],"password":sys.argv[2]}))' "$N8N_AUTOMACAO_EMAIL" "$_pw")")
        if [ "$HTTP_LOGIN" = "200" ]; then TOKEN="$(_n8n_token_de /tmp/synapse_n8n_h.txt)"; [ -n "$TOKEN" ] && break; fi
      done
      if [ -z "$TOKEN" ]; then
        warn "Tentativa ${_tentativa}/3: setup=HTTP ${HTTP_SETUP} ($(head -c 200 /tmp/synapse_n8n_setup.json 2>/dev/null)), login=HTTP ${HTTP_LOGIN} ($(head -c 200 /tmp/synapse_n8n_login.json 2>/dev/null))"
        sleep 5; continue
      fi
    fi

    # O cookie do n8n e "Secure": o curl nao o reenviaria por http:// para um IP que nao seja
    # localhost, entao vai explicito no header. O n8n 2.x tambem exige "scopes" (e "expiresAt")
    # no corpo; pegamos a lista permitida do proprio n8n.
    SCOPES_JSON=$(curl -s -m 20 -H "Cookie: n8n-auth=${TOKEN}" "${N8N_INT}/rest/api-keys/scopes" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin); d = d.get('data', d)
    print(json.dumps([x for x in d if isinstance(x, str)]))
except Exception:
    print('[]')" 2>/dev/null)
    if [ -z "$SCOPES_JSON" ] || [ "$SCOPES_JSON" = "[]" ]; then
      SCOPES_JSON='["workflow:create","workflow:read","workflow:update","workflow:list","workflow:delete","workflow:activate","workflow:deactivate"]'
    fi

    HTTP_KEY=$(curl -s -m 30 -H "Cookie: n8n-auth=${TOKEN}" -o /tmp/synapse_n8n_key.json -w '%{http_code}' \
      -X POST "${N8N_INT}/rest/api-keys" -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"label":sys.argv[1],"scopes":json.loads(sys.argv[2]),"expiresAt":None}))' "synapse-provisionamento-$(date +%s)" "$SCOPES_JSON")")

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
      if [ -n "$N8N_API_KEY" ] && _n8n_api_ok "$N8N_API_KEY"; then break; fi
      warn "Tentativa ${_tentativa}/3: chave criada mas a API publica nao a aceitou."
      N8N_API_KEY=""
    else
      warn "Tentativa ${_tentativa}/3: /rest/api-keys respondeu HTTP ${HTTP_KEY}: $(head -c 200 /tmp/synapse_n8n_key.json 2>/dev/null)"
    fi
    sleep 5
   done
  fi

  if [ -n "$N8N_API_KEY" ]; then
    salvar_credencial "N8N_API_KEY" "$N8N_API_KEY"
    ok "API key pública do N8N gerada automaticamente"

    log "Importando workflows de ${WORKFLOWS_DIR}..."
    N8N_URL="${N8N_INT:-$N8N_BASE}" N8N_API_KEY="$N8N_API_KEY" python3 - "$WORKFLOWS_DIR" <<'PYEOF'
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
  local code="000" tentativas=3 esp=5 i
  # HTTPS publico: na 1a vez o Traefik ainda esta emitindo o certificado Let's Encrypt;
  # ate la o curl falha (HTTP 000). Espera ate ~2 min antes de dar o servico como falho.
  case "$url" in https://*) tentativas=12; esp=10 ;; esac
  for i in $(seq 1 "$tentativas"); do
    if [ -n "$auth" ]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -u "$auth" "$url" 2>/dev/null)
    else
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
    fi
    [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]] && break
    [ "$i" -lt "$tentativas" ] && sleep "$esp"
  done
  if [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
    ok "$nome respondeu HTTP $code"
  else
    err "$nome não respondeu correctamente (HTTP $code) — verifica DNS e logs do container"
    case "$url" in https://*)
      local h="${url#https://}"; h="${h%%/*}"
      warn "  curl: $(curl -sS -m 8 -o /dev/null "$url" 2>&1 | tail -1 | cut -c1-200)"
      warn "  DNS de ${h}: $(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}') (deve ser o IP publico desta VPS)"
      acme_diagnostico "$h" ;;
    esac
  fi
}
check_service "Lyra Central — local"       "http://127.0.0.1:8080/healthz"
# O Traefik alcanca a Lyra (no host) pelo host.docker.internal? Se nao, o HTTPS publico fica pendurado.
if docker exec traefik wget -q -T 5 -O /dev/null "http://host.docker.internal:8080/healthz" 2>/dev/null; then
  ok "Traefik alcanca a Lyra Central no host (host.docker.internal:8080)"
else
  warn "Traefik NAO alcanca a Lyra Central em host.docker.internal:8080 — normalmente e o ufw. Veja: ufw status | grep 8080 ; docker exec traefik wget -T5 -O- http://host.docker.internal:8080/healthz"
fi
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
