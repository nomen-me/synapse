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
CANCAO_BUNDLE_SHA256="894514affdb3a4ec7251a6aaccb5dc292932022fdd711557dbaf010d09a35f57"
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
H4sIAAAAAAAAA+xc63LbRpb2bz5FB6kJAJsERV0TUFKWkWlHG1n0inKSGY2K0wSaZNsAGm4AukSjqn2IfYGp/bG1+3dqa/+v32SfZM/pBkCAkixflZmMUIkFNLpPn1uf8/UFdNoPPvu1BNfG2pr6C9fiX3XfWessr62srK6q8o2NpfUHZO3zs/bgQZakVBLyQAqRvq3ebe//Ti+nHVMesWAU09SbfR5neG/7d5ZXVtbu7X8X14L9aSzFifMycdKzTyctGnh9dfUm+2+srncW7L+6vrb0gCx9Mg7ecv2D27/Rfki28CI9ND198x9v/l2QWRbSiBJrh0a6wKdk71xSW9dtEEJ6ZMIDShihxGceT7DWCT9hIYkEOdg9fDYgVnIe0ThhI09I5tCYOw9thwzIc+VxJHnzVwL+xhIWpUiIRSecVsl5IiQU+0pYggXtneHBE+ILEss3f40lF0TETFJfSJdAnzwNoc2MeRSeYhpDF8qdsQKQl+yEBhwEYWBxXzTJCZOqG0YOD/cc7GefRSA5ScUrFoF4Z1AJmJsBvYxkSfbmL9gnS2JgkAYkAkKMfH/4bM8hD9sNT0RJSnrPDwY/jp4Nn5ItcgE02RnzspT5rqn16ytJVSHcO2YT6kDLlJ2lI29Go+m8qta8GCciYClFEfOKgoSZLzKH7CO5ieAlQUH+71//DSXlCfRCoCX3ODAZAblSr7pTDqSidMTOYi4X+1SFSNsCzdjX9VMy7mVSssg7BxtHE+gtdc1BruGbudStJXvJPKWaAZpRd42FfK6aLKJZOhOS/4L1huBdUDXkyh3AxlJbU/uBIuCYjctuY5JFXspFpB2gn3hWal8A7TSTERmmkkdTK93airIg+NY03dR2JIsD6jGrffTV5rZhHrenTeKRrW1iXZhfma75FQ3jrtk0N/E+SPF2G2+n6tbA29eZwAfDNODhy5VvuublkXds211y2aAwFDxSsuVR0NqUSq10T7DEsi+0QsGHxuIMvMcXXhaCiZwpS/sBw9vvznd9y1QytQIOgptAnE+I9QU0sXP5ukAnledIriAogRw9pTzVg8QZSfY6A8VZJgR83g4ZqNhvXxmtMYt80NSIxorNIIHuKlRFnABd6YQwOumUkT//mRwdVyt4t0vhiSxKWykdF5J4NvEcdPIdoRwUSEA/TsCiaTrTxJXA80IwLEjv8ChiEgcjtDA3fX5CkvQ8YFuGiCmMgXPX2ejG1EeB3M7X8RlZMrb1eK+6D6HTjEqfRuC+dD4inM02UNw2u4WOwaTIymLHyFVIY0ug52gLlNrKxzHWcvSoSUdgwpSNMBChV3yxhe/UMIXH+stujRiFAS4UpXz8km9B6CSmUSG1JwIIi196SyvfLI+N7X4xojE+RGrwCB8CBJNFjKQgIxLYNvOeqpc7Z/+GjsbfAGZnxnZ98EPMSfxqiujCfUWvyMCbv4BSvSxB7iBm54G85Ab6Ns0F6eUUPa8c2/88HOw7iRrVfHJuCQcr2Ha9keB+tY1wlNFxNI64X9bNQ4R2IC+gSbJlTCDMx0YhbwjEeeR2ltCF5h61Gp8Z21W383kCEeXcnQTsrPsSUAaw1vK0U7sgmsdaY5aeMhZ1pzR2O8vxWRfrtk4lPOI/RsUUjzRL25vjbfNRRQiq4on9yNxsj7fJ//4Pqb2FrsDzR+l5zKDKte9A9sVOCgkmwGwrgcjrdjrOGrA3H0lrXa2GVipiV4n+o8qtaOv0zX/We6plmmREU+QFWC3yr19J+bWG14+EhdY0zSAX19pdO7qUjtQgfmd56zJ2T4X0W2PJ6CtX/duiQWCgOcDbCuI30FuuU1tHjUFDHMVly7czV3MndBgIYV3Q+TRqQYIPE/WihVg2XfSbcZammHO0N0OUb43TyAC1p7Slo7CItwzzEYyQR2atnHpUbBk6/DMDlGyVAedbEzii44D5kPpMUO72Ji8HDG0h8vAJ3CAeewUjo823c4QpwVUVR+/CJpnORJK+B7MaVBg3cHMGRii4OdBI4yZ2KkYpgr96f2k7LwWPLLNIhpgDIJvK8yELoGshe0FgmUc1jo9N25kI2afezBpjbhg7EDj6J+Cle5DHGWQQy/QAPr0ym8SysQY6v88LhECFNXaQZMJSR1EdxE2yUNSDaraOe5ceTucsZl9cm6dqrlVLFfOItqxzJBidFSkeoL857A+HvcFod//H3t7u4575rTnMaIHQNXKEuA//nQjvzX/pXJPWcRtGiQKYO6ZbjtyyH3s+WJUwjSsA6op2ymi+6zcJlijJIWOB7P45gnFSDfguqTQgl9gLwgpsiFMcYmo/MgFc6PQRAgnoLIwBND0TKT9RcUuhVZ3JgAMPqNHAdgssEypSCDJLbKbLbcUUYE6agCxbJNR44tOgNhPcF+Vogsi6jms+HwwPwbOUKi5rIC5BhGXNQdxXX80RnYMBNEtsRHZFDk4FBQ7KWc5Rkh7ja8vsq7QPyfpRktpNRRf1WMx/TKxVFBbI30Q0IV6pHM+kNK9zXd1h6RqawKITIp3rJgfazWQ7n1WAt0FXlvmEBjOKrM49rlnlAJH4NQi9C37Y+LUn7J/4unb9J0bjf7oVoFvWfzqry4vrf2sdXP+7X//5/BcOsSrYRdMbhPv6Ticw5f7Gdp4eq7U96rcgr4UtjCwlRC5SyDKgJrKMQAXgg5wE4rR17sJ8XpS06tQWgTZgYe6nM/ebr5cQMFXmJZuzlQ/A2VW45MFrJmtEgayachSrEf/Nkhumg/n6WD5FqZN4K4xZUBDgQIIzh+4i9DSIiBQcQBVfDUQ3wRspEPEWaAuBMf+lAnCqCmzPVmrP8Q2o9SrmRyxMloie8fSIWocguO7nF2twFgResLJUEwLbIb1CebJZrtOVq3HlLIDNF+aKuQSrBnQKBktUNb2MJGGKGNdkQFdCz60skBg5eJv7W/Wx8pDf/tbC+63XtfE/peNPuQFwS/xfWoZ3C+v/GxvL9/H/Lq6rUXgG1s8nVpgC8uGkc8A8LEX0JF/DU2/MZjrjCQYmtTZUkOIQiG8KVlnCZHV6mEfTch0awm8+KH9tHf2Wr4Xxr/4d5UVz8zrx+Uf0ccv4X1nfWF8Y/xtrG6v34/8uri+/aGeJbI951GbRCYnPYcIYrTQMw+j5XE1occV2TIk5ByAmsfKlnHaxiGITmDjn+3piwtX+mBWJkEWtkOUu1sqnqrbTeJHATPFmXyObPPLZmTNLw0Bl/CjFxettAGiU419CDgVgBxrBrBc31ABEcOgV6rgQWgJcZd8GroVMqQOiNHgYwz1JzhNAIPC/ZI0ZkwxX0KE/ms4cn8uIhswqnuk4wb/WaDThARuNbLuRSE8t8bPIAkK4yHxy1DluAneeQDi3ZWbppPW1iZtJ1LfsBsz1zQUUbRIeESDkKtBRp7UMtMxT8zqCpxJQqwXt7C6JJY9Sy3iJs9sAZRYGlCIVdsZTa8luvAQJsd8mgVCO03vVTyGZWr1C6ZtkYt/MPQFcTybIbh7n81MBwJ9ZnyXOS3LcYIKyfDbBZAFMg8YDv0kidtokpzOa2m6xi5M4avvHgvc2+WKLdNy5GBOjt78zOOgR8wIbXZqu2njF3V7SwRWeGePkokrh0tAr2fkSflJu6c2774ARQR+gR/W34M98hySIvpWkUiSGqdX66P2bmTiOyhLTvsrEW2Zic0rbpjZvwcI7N0Jn5NHNLBj5FvZ3veHocW/0rHd4sPsHeH9kQv3ZWMBMyGyaMfO5D22bJsw1Ip/jlp6ApzlV42NJVXFFna5Zp7gogLknXqp9UXc+LfgQ7j+czltYB++FWEIK0ousP2W4acE+mvUPpnM76wXpBdb12mnuXGp9Dq2fhcK0L/4Y6TEJ8Vzu6FLL7mLppXFt0woXRetr1+IUCfznQ/s2AcKSam91ocqlZkS6mj4Ey8C+gKYvExh7xh+jt9Ux8SUkRXgFpN830s/j/OAHIBZga4j+wFdru3iGKPvx+f9t+G9GZSgiTj8O/d2K/9Y7S4vnvzaWO/fzvzu53oL/cDGNJWRvsNPb2/1D7/FgiEs8OcjTy+vk+9xFiKWxWFKBYkk3x2K436ORWonKupCjGIAyXKVjiAg6dknL8WY0pNIlnmQ+blPTIHFNDjPPzGcmaW0TU4Q8NR3Sm/cfwVDLEshtQrzirKvOjs3bqGEIIUSdBDvjU6aQQs/zWJK08KSJFEGrF+AK5U6l01RmahFKCj5mpLfTGxDzIaBfIPd1pLrUZ9autFQ7eClCVCULnn/CLQcCKJQAqhk6DbJ8ReBnWZBy0GtKrISFJD8A0zo8j5lbkwCwFdgAisYAfnwqzwFRkxWbjCeTPvIjexE7A4CN+hDkVMhXuPZK+j/vDg/7+4d9gttBpH3KxjPQVruSBdpKHtmiSIBYuIwqaQqk4A4X6ugI5u6PCE1TAGDYIjk6buaoK4kFrgReJBlqVSjlNbl/CaEMpDlhv6AfBOAIMNyMkikA+hxaRvyEBcZ1E4NKECKb+URATQyK2YB+qKP8D8Lqxk32sMybVGQad4Hn/56wNNhBpWy9g8mScg9zwnBXb/j7/d7zYX/U3//RKSyLOLZ0Rty9TIJs2iyPTy3sYV4bFJp53RkYE9zUvSBmdfiYLsAKpVzM1u2XiYhMclk0wr0LlywcIorpeSCoj7uWF5d2vvNf3ThFkF8KB4I6SNWyHb17qffwLWhqVw6tYTXxyibpTILrgxpJX0ohLaRVPUanNyhxSk3VFFzCMC6cszh2kJsGm+Z75F3Q/V0bQAXiJlRqt2+KxW4lDqvYezVcXo2x9/ZEafShh8VopK2D226PobJdOzJwl/Z+pyQVFmy31T6h0jLm5iJ11WxWyPRJzYMGUAbJE5OaJUA6TtjthlPPDF597Kg0xfglS6v1GyhO4qiFLstYON5Sz+TW3NaYGsZvaYhZCVrJ1xk/Eb151rKMPFwfufQYJy/GO3fZUMb+qUjYMIQThdoQDBbiuO8MKUp/eCumQECDvb4ICdWyKOiEB2B4AsNedEH3xZuETRGmheC4oZBcWQgYi6lDtMUgxQcYYGCGBkA1wnkZSThwAn+0T6j+rnG0D0AElZFZnCqqeR8e8kVo9L7Op8yiQiuetOcyxOytzssqWbUD1tzvsoEwHof30dg9/tudgt5fv+LltCXux7cgn362L0Hf//u/znrn/vvPO7mq9j/o9x4/6zuh/4n7uG3/Hw971e2/snS//3c315ekeoC00ejFMXkiwRvY/DzPa0ivMLfWX++o/cDydM/82A4eh92haskz/1jQuc8Nf/tXdfzH5wCS8GSuk4ow+HR93Db+N9YX4//q2v35z7u5jsYZD/wW4MKUhccNhbD1LPLImAQ8VWGBbG+tOKvNzVXjuKHrj6n3CgAwVJvXctQrGnOj0TjKPem4gbvqWK0aZoyG/qpTdXNBiir7eF4AoCULKQ+wwGcn/6QOEQAsNsjlccNniSd5rCYs8H6oacIsVMLs81DSKNEfRAHeH2TpWJw1F2MVnh3EGGUJoBLCVIZ7JBDeqyZ+BNycr0p7nNp4TgA/ceUBVx8GMPJ471/U583qPL5Raqull82RJdRUZwlfUV9LVWZVo+EDvyH3lHLzz5IMFAo/tMQutd6PQX2pEIEzhrKZM1HRuFWtddzQhbrDzpqz5Cw1Nzvr+NdoMBnDXCG9/uWi/avjv2qiTwkG3x//ra50lu7x311cN9p/NOIRDOzRx27+Pbg9/i8tL57/Wl/tbNzH/7u4RsX3kaMRBowlp3NdlLi/fqvXjeOfTqd46AKz6Wfe/19dWd9Y3P/vrK/cj/+7uHCjXxnao/oHVx6/6A1xidHneCoGMdMkyJKZS571fh71f+zvHw7x6058+qm3e0isgQTMRJ5wBF0JQzKdVdtpNAZknE0mDH96RajVV/zxlAKxaXRGLFzPnFG1hBvhLjkPqO2SgEczmpDezg+KpSl+xq2B3ZbZe/r0oP+0d9g3GzgvpRzbIZmJkDQkzw8GO/3hsP/Y0XxbNohwIoIT4CIh/f0f+3uD5/0h2Rk8e77XPxwMcTc/ZEmoCIQ0FTjv1ezZhDX2ewMSUunROWXSIomonn2AphR3t2PBlcJw8kselVgTdKFYYf6IpmrBXR2rBckE2ev3hn11QGI6Halao4BRGIMJIk8/cUE1RE+n22V/6iyBLDsUWtJmQxDVNv/5FqIkZviNMfwFFaSgHqp+8oEFbMpPGDRWW/w8yuAV/ggDbgpjeRM0qn6pBgrwsBiJ8PueLN+fbsRCou5F7ZPaYtpPEGhLfqLWBIRmAH9mwGlU9ug1fgUYC+bV906W8iAh+Xvq+6NUjHywPPAiTtU/6hFQOx5shX9HPp9MAKUUumpoctUoVpATyp5X3ztqLX1aVPMmU/DbF4ffDX7GLW3VyNHPjYbahs+t48GkYjKx8u33fNW9wrNV5dbCz2E1i1st6MIybjC2Ydt5N37GRlMpsjjRlNKtfRGxvDtdAgzmN0KSeneqVkjPRkr3YEy8V/sZW6Tsf/7eAP5qxVh1zpOippmB9rmx/LGTvA6s8rOqCdh22N/r7xwqT37FzpswxF7sH1oPbRI1ybPdfQumjPjjD3iEgSUpeXIweEb+lNLxhdbw5Z9qH9L99H3/oE/0F8gw6nd+MElv//FNsUC9y3smu0OyPzgk+y/29hZ+ywRrWZXBiDWhFhkckErpJvldYtdaPj0YvHhOvvt90YXa07MWnKEJeqQJeKWXbh3iDo8iAabUkzqlJrDVFI+MaH26ZSfqy+ZrvTp3gCaZHhlac8bxnDk+wXKYRcIUvWJyt8Y9sOCg1SLfujAKCVxsWDwcqxO7WZTq4kgVAE+lF7hEnSc39Cfr8GjM04FxOeeHBcARCpOzg650R8xgNipYKfbBMpYPKJ0L8h6KYStO382jH17jqx/hn1u/S2oaeQ+nhLLH/QN0xIS9Jk+gxovnj4G+9sdy5C045rV+CXZCBcyNU9fDxNCUF6Qe9g8rTIEkuR7UEs7uPvCIjIDLYtBLIWEwS4IJ4S24KHq/RO/Hjm27ZqqqL5RyGHmAcslRHoxZdMICyDqWtOvkjovakGpUA+i2eF7s+vj/2fvX3kaubEEQ7c/5K7bpqmIwTVKinjZdspuWmGlVKSWVpLSrWqlLh8iQFE6SQUeQykzrCBhgMDPoAaYbt2c+DBoD9FQ3cA+qcQ8wQOECg/M1/8n5A7d/wqzH3jt2PBkUKTlti+VKkRH7vddee73X7SODoz7Z9D8GAJub9adPPv3fAA5gJe7/v7b6GP/xQT5I/x/uhroesutVlOaSojvRlgI9rgK24BroAItIuQKWGRD7YElvbeIbPLHjddEsqGJ6YKHVzpMYEZhNtmHTQ2/golW99A1n52/ArtWZiDom3siZ3wqNJoeeGkQd+I2OHD40bpWijAra1ZFZRKmSQJhkxqErNMksSrZke1BRFjvUjZO1h6L0Ot9b11EyEpeojrZqAbzBUbqBO4TZo4HlNQZWAdTn9GFo19DEv5atv7mCwaHHu8XWW8HWaQlNcpBWIPNRmgZcTK8tTZBzr2pRVGg7RfZGis7eEzB8aO/i9HQjwZQOMTSTUQ0WJqx5hwFc2G7f6B1l+UgtwAJ2r5yBrcReJmGdNTLUAvg9anHiO1ObvMNgybz2nYWgDFTOD1vLVeCBB+54a315eergqCoa6qjqcPXiT2phpqW7cmx/fO7YY0vvAw0nb430Ga1n1J5lAErf4ljTuzPKztBDz+n2bR8RxTBgQ7YCXaVVmtLn8/YJIg2zawpHF+8tQgM9fRr2eenIAHZISZXQEBYpI/0a0IBjDzpXZL1+O8MCyIBMYcAsOSBA0jvQGOrCEHnvDofezlfAy49Rq+aiDo2CN1I1VoYZHhzCikgCJkO365Fv6djGUB8jYExRDoRiHt+j+4AwMCNo5HqSa+KNgDYHJBCOU3NQ9ngMPY+JnMOIudaqgZXH/rsowyEXV18c9XAFDL7lbdcZ6cvgTxjOTa0GoetokyGp7Hv9PupCrSi/iEyQHOTWlliJ1qZB2W7gRJ7iKtSDvuOMrOX68jowHZZq4hPRmOkYy4B9kT2J3jHhYqSWnenEopo3Ul3hRRNtJPrNqXeHo5WIVGtl9ZtScobZEneHF5VxCRgcX1WzeCkY80mSyTJ5rCjBwZyWyUz+NqgaDKTBdm0xz5U2jGoofYsxW5o1aopwJiWjDeS9zRaT7NksSMdQJnSAKVe7k034heUzcLOhnTCEZXcAncnwNbCrQyk4sdS1G2LFtpSgIl2nHKKQ7sXlacJ4LqELdKVBL4YApeDuj/jrc2Di97db4tpFsTShTIm9bY0A0y6BDHGEkkXwbmFE16SATb4DRAIXx2AEHLLrByjJc7BA68/JAn1bvg8lHHE4LIVDYJiLSDhe7v9x/+Db/XIoIQsHGAorhmKnfbwt9nZf7J5IEUFIoCTFZneDqzQRz2IALNry7CAmQ+3ybW7E5K2qNxo9A2DsOS4MwBa7+88Ojl60Tna/aZGpPEnptfYAA5IBPB61tw/2t3f3dvefo5QX2bMRhXy3xQ8TKkRhnh3icXtOYMuYYL0MGKRokKk0yGmJObAOEwBkY1NioaZEqdmiNAW7Gl4zgY0hzFgiRHUoH9MLpR6w4A1FTlb5sL2/AytQrpZ32nu730ATO/AdRXKVUlWPIrrycGatcPUrldPlM/gvkxqTUehxF3HEV944ayNh7/WlZvd5+QBpBuNq5LovjTxgBs/7BBZ9LoF+e6Wv2629k6//UkKx/rnn9S25vNjwZBhS1lo0Jt/Pgo5HE/8ym8SWjIUs9Cgq+0V/suV/GvbnlgLmy/9WNtcS8Z82MCTUo/zvAT5I4LD9toHYq+INYC0fCd1qKBSIm0PGNf8o9mtUxadV8VlVNJbh/xtoByARGvrtG9cV/oQfx+yS3jk+QToYnsnS9eTLwCPNMnLi5Prk+U/S+HJDD0+hCN6Fb7vv4HXXG3DsKpbU9e3uZMgGBL4TeP1rt2dXn+Ab1pwLtrocY2B71Hgjw12lmmgLitYJQFEANcSuWTJypTeTrnt+9bYSjhaUiO6cVFkqSgt7jBGi9LVTRYNVvUv4M74RpUqWivzlfmgjgW3Kexkb0Rcz/oCbGRpBnd3z1mHneLu1D8UbhAykVNQgPPiSAsIroDZTqBDU/PBTyjaBvwcUoZuktgqQOxGhVPQVaqbpYfSKvrRHHVzLUpW/jz31TYGK18HbHR4SIa1PCjyVenMc9M3rJunXX7PK6jXKLXA+nEIkSKesyFcz/Q20obcr4qUvF4/THkBXHc32Wkn6EkGXhD14IGDcbv+K4nfboY00Wp6w+Ad/kWbAPMEB5Q9xiaAcaHoyX6uqSEE4KBPHoAOBgOk7gSIAe17XJP4uXKff2yonF6OMwUn+iETg8dctqPfiYKcNu7FzEuGoLBwS03dK6ymANhbGY5Kn60XVsvnAGVtPn1L3geYo9LwQRmncHZqNhceKy1bFZNQjUYEHh9h1elvPyN841gJV63Qx/kJ95I2oARIcqI3Up4AiLjBQk2ihKp4+dd7C3shR2QDXiEkcDKgh+FhTnAYWpfXRUL8YMU9zTr7dohGYx2xLKnnlqCz+S8BZqpw215eXz8JRKoULjgSIXGgsFIkpzS7wglqLgkdKEyD4Q2KzOsO2TJQVO6/qc1OiQ9vkWBklOLVNDlmh0EJTDvoWMKbvXgKKRQTub5WO/wJ47kUpJitJbe1W7hGFke7oi3F4KRciFL3IDVPIxPg59kw5Ea0UootbtVqqioDrDFVVWDhcNypfZ0CzdOvqi+6B/+gdmAoFKLCMXAFhjwQbxfc7bRHjlwstZ+ThbQSl6dHGKqpF1h0+efKxqM39CemeQKJSQ8qeYzWi0Rr6s3tJ/pZJrO8SUjvegPrxyVG79aLzx/ZfIqCHMpIQSVU08iJstayRFHHCHe8CrzALFS5yoIlRXqhhcpWq6PV/6DD5Im80p5dj6uL8wIMmnU4Ev/IAgT7ELw05Uh6mxeBuojW7d43KTONC1quuFjmI4it69mZQFXqUdDtm3e0wEnibvKfPpIwDQyxtQXvc7JXbdwQKnkJAH77lAih51w/NRfNeo3IiuvJQKWKXJSUUeJw0WURcvWW82Wm3djp77ZOT9lGJLiVuvRLVGLzB7CPQftTMSjYDyAFXl2rjwH+/pZcpvRUhPlZkr+uHVp998b0d0sAy3gLFiOiZHp/GGAIn2gFlRVKIBnoDTE+LHcMgGdu29WYQASvYnyi8IJUWQgqchJCoaWEJGGXAtrpE/aP1sMUHGA1ZMfLXcMwh6YmRGDvdsS0XIkDVg8tmWRZZH8OMA4pNBhvuXmDcw65LAjXMmkbOsEBEAOYJvCW4Dj3ihGRNmdISDVcBF8AwKpo4SofrODQrcrQwvCrQ7CShkoE4DTBdLemBIbZ3mLg/ToDMJ1vGGVjAnsvJ6d2GYwqjRgg2zNJOSzR/8YU8hGFrcnHxnkRsExp2ZaE6tJPLQWnQhZIowo/fS+k04Ro9jErlVvdPNhwk7Dx9S52/DdWQPNZITZzPW7q8oZQaO57Ut9BxOpI6M/dKdhddc16ym1LQhZsb70+GcrxP5TUrqxFS5jtWPalhFLSS/GU8hwv8jGfpcPMddeykaBOVnHjmjE3Df/FYwV+DZDEolARtdFGSiEceP4zXfAN1Tss0l/LZLf1EwbNV5o4xbm25ciuL4fygVL3OP8ce/MggA/VaacLolJfnzKSNTnF5ziKIB6cj79aMNZAE2xgucNSbXWMaTNxzQySMvZjP0ApRQYaZlk4ecmmM5JA1NzRKcZf56gTyik28x+I6XFs5Vn1u0O55S9ET8APOvyUHWClKt+D8CtIupu1pVZBaxJhG1LA0PtRrpHKjtA1OcLkSQXfXHAUK/Yx76rQ3gcJoZJ750DDLpHP0SlcV4stEB0X1DmHGzi8IXxgqhrHULJAi4NpWmIORNs2FYPvaJqw8FQdjOYV/YW3hZxK/Tlcpqx1ElXK406la5Gubd1Nv5zXMkUfbLIQDuSzMPYr6aOrTMZtmFzRq4w0gGQ9/a8L23jjj22bzBlb5dh6kF2E1CDzlsZfv8Z4K6C5ABiA0G8RfooZX0xfClGKFc6ESkoI0S7C+7H6vsC3jDqNxV9Q8Ne1M3h7JqyeCBbOvN5ocg2/O5aa6O1sUa6ala0VN1YDo2mex7sgbAtlWRqIWJbmUMvravba/LJPOfiAwnBdqTPtK6ovvAxKBkegUyeMvy1PIuKra9imsiclTSoDwzvvOIAj9RMITlgGLChQTp0i1FfpY0G3UJLll0cMivSg+Fm25GkYWLO0sCHjl+LB91BJ77ee7J7svWiQhT/MhaqLsHu0gJMUsOKTMyA4CVEujxXBdCaocUkFP98lItXeY4qYxVVscwUV4oNCNyJrJxyPpx1EpoYAkVC/zJDuwUIUnqjynFuOGkhxibIR9+zLXGcnwa+PJVKRsDzdPCickfIaTDUGUmwcgseBbuq4jox9spwKYN8dbTZ8M7OULLhnK5bE8vOiwv6kXmObc2ScHapAMUrsfwYNb3VHkgJuiOkKFSOdEzWGJqSnSbc+Fy/oSGE9HJVSYDICejiKUZkoP6BqFSt2QW4ZibwZyyL3+D9mSoaSJRhaoGZILBqsUYdLWcgSuYLGgUKGpQ1uToWqmZDiEwRs5D+IrE3oXFkubm8OoFfciU9VimF0YdBUaT3HWV2pCzQI/aZyNHgWwNFQX2JN3xNOUDOkvvSEakDFxRTMjxhvAx3IKYx+DsOOlYoUYG04AX77qmqAzJ+UDIQklLU+mSnxD82JWbmZeXghEMRWZHB9s1tjty0LyGWnFLjuRUwPP1HKi5Yr8ersoEiGin2bZUWG7ndDej9Xh1Bbc1ROXY5s9O8DI6Ttt0Xp5cnC0u9OCr1bo2E7eMxUW+bBH9lvOacjWgyHpMJTMu8krNkVkUAbP2IwZKiEairCPTcXzyaTnWdPTSgXjPQG+0rgk+DUcqaoUYgsK/xrkLyJhGa8bYhkEQXiQVSuUYw2RIYeSpP+UnFG4c/AiXpaHQ8VRJGYyGPGJ7o6dQSnKbnAbwdiD+3XsjaXe9aLv2ehMkcYobx+09trH223r+OULuJbRnK7zw/hdpbpsoMyv3KHClphstNP1ekrer+csZfosSIhI1RITI91hRCsy1BKKhMPEgklT3yGLAQTYkH06PSPnW5QNs2TEdfA4L1cZcbMRBGAAVRQfnqOu2aiu7LDZfQVr385J+fJQT/U4celOTTLXIHBDTK5F4RzQIH5upWEIy8ibBlLwM6TiyDNZbHotpS85ggqNRiV0ISNeFemnpIhgBqUDGXqlKODj8RhnHH/1kTanUS8FU1mr5V8SJalzWqqmol25HBk616o4nwxGpp48vq9xgDuLiqaJHEjwtFtIZsqNr4QeJHnSIyoTNbfGSU7blTnppOi9GrGHbppYzY9JGdmSISJmbGbuWLxyNVYzZSszRaspWzyt+dn3vrBPetqiNhLirYhPeDqURRHYmSJNM2om9SFmOxrnZTSD2EdZj2E4d8TLLkbQ7wM3PhlTWipyJbWHTtcZCGgPsBRm1mHRaJ4e9Yk5mBiyPctjPGdkBKZbYKeYVvO45BWWZqV3T3cZehctRMoim1LbqtUaETPCJsnjbsIrCNUWppRFCtxGHEjzwXYkISqkuUb5NBxTznRv8O+tvCStoGKEYQp13R8au5mcBTKTxiSmGHWWNDy8GYjfMxSS0h01Htx2TmcaVMUNsOKq/g3+exu3OPKQYTea1bFOkMwKn0XZ+ygbp+yTsv1dgSOZZo9rBRh8dYx2ftputudVsKzO3/71wd5OYFruKk4n21pVWSVSMeBbChunwdJj8Y8yLZT0Cspp42rQtaJuNvgNLURix1AaL5QIR/1ppCES6vbSMJSp7ro+xR07u8Mwnj69llagoaFTwt6WRmsaXsut8CYiHBKZyWkpw7KWKiwr0KKQMIhnTB9MjhNz5fV7gfIACgdimARTCb3nJDh7kjVRpFmMeSaaIRDm0cgFeBKV6HfGbve1AaVfqxea2dbRKiz0vO9N+o5faWqTDhbyo7kqgCeHdqNIcWHANthu53t4p/MD01xgbUKtQtxWE9YcKajItP1fgG9Mpv8Hm4wvJATMlPiPK8ubq3H/j8Zq49H/4yE+hkU4ZiukTZ+wh38vDNdosYG2KKsHLWWcW0YXj2d04tDrH1rBYIN2H0AoaGIAQjja9qQ/DkLXDZSQ66Msg8Rwui6xj0cWuOkhSro9tOa6dLvoWRuMbLJPDzjlDaasufTqQg/dhSNJGDw0JmcvDe+JYWWNU5LJDZTIHFrse8NL+FMTGpksYXpCx4dHeDmgC+UAWL63jn9p+08iawS0+pUdDW2YGuJm58SMV65XryRxH7kHmIHJsi01ZjecZ3UwGpeHmv3eRVQ6N4DlgyIV+kHVLNOoo3ehzAwzwt9chPFvojDkBPD7yukSPXyDbuPq6rDfSLMZ0zKfRdkRazAop0wckXPHarCU5qVPLfUu6hLUwkHXaSahBBA1CPFLmgxR7DcV1ZdUZxvGN4ZGSyF++024cR3KRGbsHg1H7ahZzYjsY/ZI7WPUd230LytXebfDm/Alxh3tAY9ILudoAb00xrsMTtqlb19jJFI6euyrTn4FITWW67dg9BYrnu2k8FOjrsfPAj6Z978UIT7A/b+21ojHf9torD3mf36QD+AHzOGIKRsd5TSJhi9WVMqMt3xNhPJkkm1MiO8Ql33v3O6HYZPrYnfY9TlZEFzn+y3xon38oiVOjlr7x5Tgs+cBkhk6lx5wd3BNe+fsiYb5gcmC2uLoQ5Uqmm2PbWDPGQU+JcR2jncLXNiWCr6DtwxGYEYpmuzYE99P8F/k5T3VlczR+FSwuXaPmNqBS4Jw/QgFI5YtB4KJrNEF7honwg6gXIUSBm4D7HjoezUZuOg6R8lJxnZA7Malg3E/pDlR6CcHYwkC1bzZYh3Wt/x7Q376RbP5ey08/aLcjJkemgbtiWwmqcGWn4Tbh8RIpyNFZB1FhSiz0TzdnopSUroxipExnip4q5rroFQXQ2ZIfYhhXcmXa2hcGY1uHJIm5CdbJ5U+vZxg9Gr9NnAonl6dnqIjUiu8Gz0/ce9F/BBLpd394/bRidjdPzlIU6tEBd8Wq2YAumyOh6M8+8JvnXOYpPdm6ABfD3SYssl3e2+rmML1OlOzU5VnrmoYZ0aE09+09l62j4X126Bq/rcM/9M/GtXlSJ2DfbHz8nBvdxvlOLjjUnQuj/eW+kIWfWoK8Jj7stQTNF4y7FtpI5W/cpW2Q/0b3+NITAxqIeHbtBgfKqSylDaVAY/gjoE7FgcqBMnwLFQjR4FIPqOdQqchAuk5Ryi2QLEYJIqkzFXkU3rRDnv9SY2JFJb/QCmT7rSIAAVWyTTpJp2/7ke6xyrCPc2QHP5fnYI/ZndtQ0wW20cAR446oC4dh0oFTSnvR0GkwopwQzjXGAqnp+LawRvfMf2bMVltUEkjkn85yKIcwYrlxG+JRsrhIYAy9LgQQjFwh/oaxRnmSUui9fRnhuLaxB0LQBhRxwXT8fKnpsR+mk82/R+GzLvf+C+r62vJ/E8bm4/5nx7kg/S/PWCxm5EdL7RsQXvblEAv61XRAMqhsQL/x+8bwCCcHOy0WHFtBLtjM28mV2XgzUozkmcPcfbJyR6h7kQomicWKphI5cRj+hFbX7JJF4X9wIsY8SusntN1KadVhGSmRsKkLC1OnA1z5RCYFbib8ILgsbb+9HK3KThXOI9bShm9MAHgk5MJDhaOC9wqQxkrw5YZUMNc5U3Ml6OZEEwMI22LPlHRA7HCEx1ZVeX3HjAPE2BcF6g9vJoMpgoaiyVUIXs8HWwmEX9mtojcxcNwV7W47MmTg0NTIHog5156ctI+erG739qjYC/tP7e3X55w0BhUzL08Omrvb/+lA9+fwU10Ip+ftP980tn+urX/nIvCLY3as/afD3dlxJmX+62XJ18fHO3+G/79rLW7x9+O2n+AO4S01Xu7++3W8zbeBhwTR5tqoAYOjn/HfAC3tDtU3+1JYPc7PWc0viotLBbBlT3s9QF0AULpyJGLsoY+juTWueoAz2n7AOPDnm15Kh4Imk+elmz/Mog6GNpsYNxFznXg+KFroXzhwpEMsoOcG31xJHihWsJ4wFyX7Za9nv0uhY/rhZYcqRaiNyHRJWXZqEI8ttHdGrGQT8utRt8U9mn4i/OGDEb2kKKUypnKB5WQIimNw0ShBPNos4zjRVNFp49W9+/Uc9lK9DEtGtcIG1Wg743YbheW3wxuC6MLy6JVKCWpuClpA1G05D9F6+geHDFljfUDObzBc4zmyFQtPfd5dFQB8HFnMgQ613c9sxfjU3pj+86VNwmoEk8pfFSZfd63Kb2gXZ1Lvn6nEozO5Ghu9YbX3SEGqrHi2uPMrabMIU2qil+VrhjBXmLJOOinglWsWX00YKS9zsjBFFfKrAu7CibnCWXvDKOsEvAyTS8f69/mDNB6qz/z2ZVBbLLPaKRZeUxltBa413sUy9uulHJOYWx+dsYycU/hca7jJYPSLGRfS9v8BTMglLZ5TD10A7NDreKNd1o2D0n57BZogxv7tMzjLZ8lTGMWtgkfC8YASBRYEtVWlQKtKkb4p/IELpWdvfYR3geMmkwUCM1aUQRcTeIqZAIdhX5KMahVLUSfJlthgAxbiWyxaiTyMGUk9B7bWJi/BaJ1GYTmhz4Z4BL2Q7OOi1iWjbjeTZviUjg0qzSy36FmjI1dgkl/XIravVKxC21vZeTEuDh9fSbTYuBb/JkeMIl6xLca3u2AlXf4VJu/oHADh1H/3nPhVem7m9e335GURA/3Io0djVmnHkrL1Bts8jbk/FPdrp9esJ4tQOZX8sC0lFoq1MHVUctriIAMC+GcgD+RDFaHt3eV/8hBpaWTUppRpco1FLk8gSFmV+y7P1LcfS3M+YYNihykmN0h8gPIfeClKBpMRbPJETwOxTSUGgD7h6bwSrq5rcTBKXL1YjAxDmoehSkEEY+DTcQj7sSU25o2d4c8HtRl3wrv3HcvbcqNECZ64SmNw0Qv2N65HbgIWLK7Ev3mC/U0guS5IAKyKmqaVFfS3sAMK0m1dTgf1fdp3OnIGyUMtiOuR8b7KAETfkrprBZVViREaoHKbXLaWTdayuqnt7qkFSLGzgRTtgah5hzXLjYGGNl5/hRMuwSaRNqGYevJ7crYqkJz7yK3fs6JPvFuz/BMcDIWacpy4KYzdFIMSmDdnJ5FD0jAu9W3B+fYP1w65wnwQYn2edTmX8p9+zDjEPzhl2NfOqFFLb5G0AZS3XqtgBkf6jNtcmeZtE/KasmuUDXoYdimsT11AdBEQtqSWEyHVTWOweUxnRjYU01OK/KCtr6095ejFmMtpgRUJEbt3IwNEuYbd2QJjB7KInHVbvK9tEpJyfspB94Zj/s63acSluBDw/eZuzhVyPEMl1kbtJSI6exwvq+ObkL1zI7VXr9HbY7sng/Nh00zE0hDQFF/bCLwgpfHGGy4vCmrUTVfYG1cdVmgiv3EK1MKXBg+VsaQ9kZqVl1N5WSF6nyjyYVM3mqeDgjksYFtB6HNl2CIt5Fp2nOqiRmp2OC5q4dyAWWYx5GK4GjeWFt+gnmU1Cq+UdsV86bx44AZw9eJZcUaqWsdrrNRhFY9vclwsY3y5g5EFlOvJbkk6UCZkuzmRaLpmhE5eaXPmTWS6EnZ+X9suA81tXANeI3t3e29A3TZ/WZ3p4XUhEYP1pXT7y3xEHtk6toHcmJJJYWp1+sVMv2z+2NS43uyIymfhAtGSvM+R9N4bXWAYVgHMT29wkTAJGD6ZbZ7tBk3215dvJj0MHadEu9IV8KPtbiQ7QgCZxLmcrbYSgOOZ4XMIQPWYxkWGHwcDM+vJKo+j3l+pe5CBMDo3yQRIMtE4Dcp/EB7bOhgy4tdAFHfLwkZF6ifukLYUIox5gmU3QAia/Udh21+78jBmzYFFxwuTfGCigmUdw+3nc4zXJwqdgTRCH9V9ZxoYigoSk/43kTVLt0pp02MbK2JHSP2o5ZuRttgIXlPoa7Q+CFkspKriwyXHhcugxF/L3LOquheYlZOk1RpepleanyTJlriD/K1pIbjFi25y3R3ViSJruRxYcEKjtuK7Josexvj+mNbB5j2jeNbkVwbmXOBLuQOc9v05EbuVZN38Vbvp0LOFS2okfp4ZNLHztuxltN0x2+jiZ2JiAzRU7gDUDIMcRElwZPnMuH8H6On0ncBwGbkdBFs4nQ4VM+gAzM2tKQmPCXQwDSUkjVS7VtqprNL8Sad2n4USGCRFyXWIC1Qz46lywuZ1kMPbbooyV1Eawbf49qvkGelo2ywwBLNr9cjurAmNcs8TBszAG234Ooim3d3CCyvI7slEwOiPM20bdhkJP8d0odBBIkQsOY5PidtHVhiMKdRQzTRm8oqJoskASXL+CEdlKMXVZV0bw7FJcERJWgck8JJ6TtBwOgLsZIoPNU0q3zU3m7vfoPel7Eyxn9RKyv8pOF42kz9J8UGLuNhSlPZWD1CXqXyd+kllH939GVBzOMlSNfMmaQzBzEq1XhgkqGxXmNCQEzT4KF40BAjSeZPzgkj2ii6RcskvVvF4sockm36g6Qf5uNKCJzCw+cCyzHBdF24NIhz3llOTBYQTRP5sdiR5QFPAIQPBKlT3AmwzWMnwPjN2wcvXuyeHLzEBGuUEuATSbQg2XpBCnxE4+jYSq5xhtK6Ujc62nPPAWIAayVTRCCZKXGRHD48aO1jIhFAWuja5yNVjOTzvtaCo/7SxTwqUDww+qGMoEDfHmOmUUowPXLQ1uDP4QDZVLb2RWjG1VhprAq41ElZ9qPLqdDIEQKJ6L4xkdxEnRRiRfp/s3Q1eVASxnYxMbZQqXtVY5E7qeNPhkh5DTAATGnovAlTS8hqvjYkDBJcpCI8TSZSycYjPGSSTPJP1fezbFophcks8bAMP86nT6FLTQsZ84n4KmWsn7rkVurKiRp2GS87H+CwJvbb+1+/fNEyhbyCs9VhnIMladcF/QeTgHLaaQkxnWq8ovXBMuUg4ouYiCWdKU24Ahl8R9KGgBmNaENZGSgQuCK8yE3KAJoKm6aNjZJVkFIY/+QFODY/JRLy0O2HxjuoJCPPYVYuhcsHJ6bbd9Gzu6RDPa7WU6xvBCUMVKtsZh9OSTGTmzkim3WRHv4ltPPBYAQoUzKFFBgyOfaQk+AYkd6oD8XnGD0gm1+ag+W5TclkoQ8ZjapUiAeZdftv5aZs1E2rJ7EkQrunq8nAHuoDYIxZSU/jkjxFkso89ygol8xZSmWl98w9IzGrGmbLLwgI2XFS9dMUqOnlPjgenjxN4TpNhpIF+BFOFa+6tMtCiSklQgRIkGylfAHUnRHw0ZtZkEm6lIQ4l5IwAlraL2lto+pwNoBufdvaPYFz0GkdHh4dAKWIqnQpYaJDihhkq5EGwZFiRMnOA8X4GAmZZmhXUBSj3Jm1zz85NgbtNNMw3+cxylDuA1gpKD81FiuilpL0w5U6NESMWjEjgbucEZQTyhbhoNxQQ7dIxtzIxoseko/FWj1uANkMvZnIOD7dNh7LDDGYkKRembuP2NwXEG1Q9I4ZJQNJBbZJJMsIHy43lMVBxAhlmRGKjdDZ21ceWkq5og5wpI4SxSVtCGkYskXWfadaH0ZHQOKgFGlRlKBPQEhMwnlTirWAoULGb28VNMQEYHnHOE6CKBHRFKEQ4RC49XWolPQBKfDbrBtmw4F9jdkXh+OmuECHfbRWHDguXwc9x31ra7k2MBRd1+5/DjwGW2PieaBgJgnjCtWoZRjZlSKlLvr2ZVDX1qe0FTdRxN5M4zJLKcLrfNu9rE+J5dtYOSbhvk2KZaQ8ckuhJgUlUzjIFG4G16ZDi7OVXJwpC6S97NMBMzSSVUjrBo8z8Kj1TgeFQZ3OLVzs6Zjqwnb7GkcVGUNK/4b1rz4ckv9pyie3CzO2ReoT6CsyCZeRNSPBcbTwb/sKzeU9cXxAduIhTZwWaakutm0ZI0nawaPqyLum9KXi5GDnAMB/5I4chJZQVjgZh5Jlt0e2G4UyBZBQMNXSR4XRwpGUw8TsMbo6FO+ZxkCVUMTtcWYSGJMBzCH/Z8ZyZY6WOMaY1lTxw3KFDWCFiYeC8viZ1JEmmcN1gpDHjUqCoRUdHZWILEllIMIMM0YZZDUHLqH8lrIkMDNtqP094EvpraAMS1DAYIYRQQEVNOFNROtwl7KwKA6q5/kVIytm31Hq+JEN+y0J0R4aCugShl8dMrD0KAw1leb1ihfdc6QQObMYdSNJeG4QSdjS8bsALapeAMNw6filSIksWwqg42EjAAEhqoYBixssfssJ5XnwPk4bVwmNj0OrikNNKUmrCpnGSy5tRGQd7keMsREWHUU4QUfSKwOedROeKp+numiEy54AgCcxkE3Iz1UKm8xlMWxMSOiDbDQyOEZLt+Fi7ADvse+N21jSMDLhSJ4KfonnSLILKQHFZpPwRIXuJZgXGc7qGZCKm3M7hJxlKSkGuo3pH6Oy/JAb20qV2uoC0ejspowsgiFSdkbjDEXUVfQJpzMaHRHHdjMVwEk4CG/uj0WUGN/6ggL+Aq7GmGF6rXQcTqRMgYCwC0MSha2Za7MtP8JoyedGSptKMRi41aqoGEpe8P7SqpKAGqnMnjsxDc+zrnvtiaMIDt5GsqKSSAbTEqIqTOHXkPIwGObvmchVEKJin6oS5l3+zO0TNgmlKoC8D2042P0m0l6wNYdHu61jCQUoxA5Dz+HhucKQWSOXIk+p6HJLEnFNw0G5eZKNBCDpmrNZFWTZSjBDz5VG5WpbEFOplk9kJIDboDiS+ptSKc2eGCW6rLiMG7hFqCNNEUVTjs1lkjWNEkmTm2uxi58mdhkZMhMyJcxS4kdsA5LhlCO2Af5U49w881z/vswCpgeBTm8+S7STYVGWbQbhchhKAqCYIiCjrST5+BM75T7gJ9P/m0zKFhL+aVr8p8baeiL+43Jj+dH/+yE+sO8daUtSMve/9ATfwKklvkU76m7rV6PJeR+uborHU9rHOMH8vEdRkFh8AW9OQl9LYJzYPFF8kkLJo30muonxt713vs3tOQPbpcgmPef6Xw+xn/pADqHvdp1hQOND76gnSqaOVy0xzSXHHw1RZHWGUoKvAaLF8e7+9tHB/gFgQI8GMCT3awcDUU7QhpPETUusPV/qAYvKiXxN5278jwubpqD1J/CUXYSD0F3sKaAiw6kVsC0LFiltq+ktLa01wwLVSC1MnHaVU4nfS39L9PDSwSwTQ+r6hLeNUT0V8n/okxpBrKnd9dxgZI+7Vx1JW8W0oNE6oYAkGuDXqGS6xjY2xWo4ltTuRxP/0lHXFM3VvsB0TOQR1u/HIRmt+SejeqRMSVYZuJfoSptbRZYp/TIvhUz8L+WXi7gBpsb/W12P4/+VzbVH/P8QH4z/iwY2lxQxFMMYCCsl3McKMMOrlbp4NhlyVooJ4BuOsLu7dFA3olJMJm7vyZODo93nu/ud1vbJwREHU2CValV6xKB7qjTtV/6BzhugD2PxupAAxAbr+M+aVQkLvx13JIRaLHmvGrla+i7cBxRIyWXqNpAW4tiJCtwQSxW6bfe7E2AHcZ+XuMklKrpEYR0Q6wP/9tYF1o/t8OtPqCoXbbIjmKXj/cnVJMss3wUuRYfBraDUDLkdNKuKIM5wApFoE2oi9M2INMFmTjTXpoi86dDDung5QJlZzwEGFcPGYlR037uYANJmHeByvc4lI8M4UFELMYwhRS7kTj5pCExG6KOYVDULvPO57yDN7NvcirHoTZktFMM293QVbJXi7QcOJhSVTcJ7CybQo/AqKNwfUMxJbPHIucTcS8hvd20fG1RMqbhyAxQqdD0pvUXZuuroc8ECTN4l37l2vUmgd59oEFox6Gpg++/YyK07lqlIFfduQgzyo+ZPtEGRUGsKfCREJOQ50UsyGlCkaWy+VCWZL6WroI450owMJHb9JuZqNGAGKuGMXdFViPfV7XuBkb5Ad8ScMp8M1tXyoKUlQCQeCif3xkiDapW43u+3JPDOuFLc02ns+VnqwqmyRrFo48YaqbL6ETVZeDHpb7z1ORZXweWW/IZ24wrVGYfMdIBOrN9sUJayWAVgLnWJUteyCPTJb8k1InNESfLJSNmJZaEFMdKbEBoRKrESGUhg1D+COkQ11hjYkOEVZ19CYpYixKuHGmWZsrz4AvP4pkw9ez+yYDmsQRlOC0J0ibG/72C0bixc5GAa1blNlWoVK9OKSvdl42UV6iUrosCHYm2ga36iJr8l8ZdZ1VTJp1WOvk9Uj4rMzLmab1JqGIuZcM9WcPZTE2cP8Mmk/wceco9Bffx2brJ3Cv2/vNxI0P/r8OiR/n+AjynY+TXA++Mn+sk8/0rYcu/x/1dXV9YS8T9XGo/x/x/kA5RNqoh2qPWcadKA2mZVNJaRQdPMosMpSHps2nRlylpNexkt3xRLQoktKW02e/tgdh3nre0tTRe3Ap8qw/fbZJmIvpHA77Ixz7XzY1XY3pMLdxANxilU1HH4p04JZXv22MZoKhjo9NrxyXNxCfWVLzrPMBJl50XrsFUf9IjFfALkoe90rzxjTteN9XpjpVFvEGur8uQJNwg8mdHIht6RZofhpWQUGyJfC/TplfR+oSQCmFucXT3lJDFTAEk+Udfc98aY4Ehavcg1D3OhTQ0TKn9JlW6QHza0Z7+DviIBRGcJGarihEpxzayBQo+3v26/aHW+aR8d7x7so6S2UXpy/PLw8ODopL3T4dcsYmqUqpUnnD8yElyUILr0pLX9R6yAOfW4PDxAQVSYsRJ+GHkmUTT1sU5QhWHiIkp32LMRO8P1zOgJlToGnvZIyiEoOqMIZIbBnhdAg1Bj96T9QlhfuUOUn6Ctrfuj2sTjP+1JIya0jL2wMcEEmk5gVliCgWPMVi72nN4lwGobvQZhu9v7J7snf0FIDcX8yYJoScJp0KvCCDwpf9Q5D7q0e9ax5rC8OPTdrjOl+gjLmNVvnxzvtw6Pvz44gYPU3tuhRedGKVZfaM4XidVnBviE74BVhj2ZnT3eL4bH1PbKHfrF7YfBLYmFx4H1gf3rkCAfH3nkrMdhLY2wodV4HE/2w+Ko5tUnFYChE4BCtdAqLl9TRehjRw0Vaq+pvvX5MVu8d1itEFblx73SwsLykeqWHfbQIgUYJ0cLVimRkwxCZI/HvkKHfa9r943p64olle4Ja6NdPDeQSAemGzYbrCeaQ3EGcFuhd470dwhUEc4uGXXtp6a1xRdlyMJHak5TezTC0HWC1+4IPTiM0CCmfbI2tqwj8y41SnAu6bdSF6nfpAXTvxh/JaRZKLjQgi+OQokTRh86fxy8ccdXlkZVpaQzCVZHcypP38yITUiYq4TNHopgA5dzXZoLZ3SnbD5NiNCBeBiteRfGukQHizVDHBOOEZO6U441iQFhMcNip0YDZ/FpYU18j6w3tVCRTWSMv2oE9oxspwoXEQ6dDYSkMQ8aCF3g8GO4KJwDZnjVI4l4olybMWHSQk9eV4WFeKVKUotKzCcFxnF6gSFcrtOtkzUphGOvwu6Nr7yIVsJNgmvY0BO1/g7ePwOEYAT12Gaae8n29wzWjgmoMhDqlopW2mNhVzS5uS4UokBaMrV0pY6KsVgNUZp0a9CXI/rn8EhxW0o35nmQFox1sj2FxS2LclWUO+XKbf2Gm76V40KySc/cjFsUhYZKuM5EZt73MkfHdZd5srkBotzkTBYT2YRtXPnouMMLuIdIsGYtFBtmXC3fe+fqMklgOaUNpOdoMqCM5SfBBANbk/fqgP021aCoGIV8TTeMx/f5HalnrJvUAX9C4bqlhLiht3uu0aY02TRhMhqZZHrCc62e/G0gnh8dvDxEq8msBg0jiqhgXkazJQUBEipRyS5K3qMi25vbalIUe3Mb4lCEazmHYdLekjo6jfRyJj7ZEsP0Etzr2akz5lhZyVeEUrBPUhwlmomO9OyUvhhtxd5Ta3L0RoNayQx15ObzGc6wrU0JkSb1yk9jodL4aVpkNH4jg6HxDwqAZsTxBd7tOWXznOj8cUN9+++befS2D9Al8aSNbCYyCz+qXHJKX8FOVhH/K7YgD52wlBMvX53GJDC6kPkTddjjt1mBLqPYxGzMnH7YZuRpStMRC9uKoWmHJuQXQAHqm3FNc3RK1Zr0yqs8MS4iGoYyb4kocEkxpDBPUqFeip4qM0utHAhiI6uoNhTjVMQUoKrpCA5KKpTMkKrhRIqYRLCGjFcDMx1q391IzjR6nRFWEWPrAoJlc3mLjYHVZcVBEweTHoZM1MESbe11XJUN971Lz0itrEMkZlivY6f0BmVPsAbQIlcIWFevikUmk5WGjOL6wnsGlJjxckYdXq/iCSsYpWskG9e8wsKXKIGm6dBWOmzv72DUjFS1mm6AhxZTe0WGnQggF87DTFcRs+LWjgKqU3eAazMYSVPq0Ag/dlGgi4l5xSU0e3F/lOTTRHoVitqbpxRN6q6pQvxxTH9NZVLVsmkqbG4x8SJFkc3tms/MthMq7ljcKbO2KsReCqlvwsDq5m4CNzywje2MSs1I28+uDonuo4EXyfdr7L8zSAXWhYZJHiQbcTkEJtKIioBoS7O6iXIwldeJEpFkIB3OhQR3iDIvjeffKHaYUoH66VMYQBjFKNmT5gQidyXsOIaVIgo39twkhmOvJF2cykmEPbC0IuVO1ta1apjIR6WnT0i2lNOIWn1puUPrgKKYpANo8QbpcjBaZNGWkmwb4VJkV/GenOEPE2fiWAXNjAWV3irBXeOjEQJwFEhTJZauhH5QOraa9Coylwwod3OomLjEigw+HoOA3ym3ey5Pc1oYa9Z3XNhYWywBNr92+oAfmSCVPzD6jeG4hpEkUemCCS0vJ+ioqNzPhEWCabK4Cxy8pFfwq6HFCc1ZcAsx7J2KrPO6YgS/i19DGXmw4jg3lhoriUDj98eUGyN22UXutwgbU0oggDimzkaYEo/EsJ8M3dA7TdyJKsSvDkkUL1BJZKQwEpzEUHolKosKN0M/jgSP4CFRGhPDxe26whKrMO2GKiuDSlioxSAP5Kr4BnONsDdyars3pU5nMoSdDRz7vO90OsoPmGJgM0uCWe+8wYgSXyt6TDpvaFD0AKqv2TBzZ+9PEcmexsXeGyvE5hm5bQuy3U+zuerZM52EgzKdEw3mWrn3RhjhmK94VAWlqOiY57jqabrXuEqywolzFxnuFo1qLd/p2+8qgIFa23+Ef7VejHYqjo0t4ii2GsvLpsEdNBCGIUedmYIF5cePHbFl8YULp4wspaG7Jd2ZsOAleuZgHkZYoBBbTXyd0eBKtgrX8CWcuA68KkV2BR6kOVS/dlEoR7Hbki2whTHpIidokFxSUdi2MQmG6LKBOEebPHw3vgKOwyKRu7iYBDwnUoELmTWN3FsrwJu/3N9uCYzPBM36lJJ+/+Bbq4IL9QLjwu981ZQ9aZ0yNzSUTUPBgAT+glLJX8OhY01h14NGBzb5Mvk4rpcn29IMezL2Li5iqQ/ihLzKgFCjRYUBq3RvUkXFr7U2pqjHcto5jKCZqLuwZHzKkSLwgUNqyRhNu/vCKu+093aBoMVQumUAmXJFtPZ3xPZBa699vN22zFUPA5lUxO/Fb4NoECbtjIwc8N7ui90TKBJNWszLJ9nmShQHRCRsLJHgcDfwZVmj/RSv5AQaBwpiRGHlWQ1fR7WkBZBYJcy+Fd79MALcMyCM4MBFJ+O9hhZWlpfRnBrbq/OSkY4U5r66vBy/CXR3R/xFhxtqJhtmAk89wih7r1Oz1aTFkmaoiCTFUkgZE2PJ7d99ZsUBoWpuNb+sVCOnKiWJVqJrS+bR8k9Z3XxWiS4cbd0nW9IqndYnovCg4fO+6lJJ6w08tUCGoohC21+wrwL5OIT+hYZBi7ZhifI3OCBiZVByU5IRlJpyDIp5waBP6sLQ6s9pyVq5HwrHk3Xdhp73sdAkAMWm4UQKVtWEtg4amxqmJF0cIkP0uZfsSTrtip8uP8cz/QWcZ0IOJvpAlFEt63umXCkRbCDdd1bhPPSxPU7J6pYCwNwwbkw6YGpA1NvG63xp49k3QuD3rlGpiAndO29sNFm3/deWH2OCzcVmtwFThiQtWtI55T7XoliavODI7sMw4CH8m/Qi6TldJwgARhQD1hTG00BTAr5OlpDxOkz3xmlLKFz00e7BEcaMVnGelZCQLlKW8tGFfAUkg0+5U0IWR2KKJY0nZMznqNgQ2aIwkTWJLpELkrGzqWEZOdtqLMtc1o2K2G8dUPKsoGv7JMGsIa3Chwgpowi3BbczOYbhpNG3yUafJgoN4k3QmsxYEQpFgjRfXRwaT1svj1GGT81bHOzaoA8r6K9gdydDm0NPORjlG6hqIJ1sYQTbxcs/FYI0+aTo1YwkZca7WJqzxJGXsTcK0wPRXck8ucaQtuT51azelnGgw6bwao9AbfzMp90oFeP+j0wUA5FMDV9RVSjNjEUZOaOnb1WotreKBDiTxwP3oyOBxelpRBzMhsh7pDXyHSANieY4hUEZ4VAcjtGmG49FaqMbIBP5p1wAGGIsNJGL8YswFBUnxTGjv8FdnWwFsVMe9VAA14bouyr0Qk7DuxrlFhh2nAKQy2zkbzFwaywkXSIgXRK5h2MOUXwMw+si6AzD7mJyEBT2jr7damMoAJMeRVuc+I5xs3PspKqIyjliLq9HKOtAJg2Y87pokdCo/0NnYL/tIO4B+vnaDjiQJ4aB04a+u8cHe62dAw6BZI9s9PBEPMXgqXhejncYQVJN7ImwY+BeDl3EquLrdmvv5Ou/YCQ9JI7QqlhhrHsnbKwc288UQidDAJ1O62C2gk7fGbMAt5k4DGZnSeI1JoWnbADhgzOmmobS9TL+NuZwOY4kgInoOJPbXYpLPhNIPfOMGmOAA4iGYT4w1hI28YxqVi3+BlOgAK9lR4v/NpYYRr2S4d2wixh46w6S7yox9BDh9uCgjOk/y4g5VlKpu+JNJSg53GpcY/GF9GhV4IYv0sK3pqTdmYr5DHgpV0UEuuRi0eF1yYkZZdNe/9rpbS3n8knWODGZKN5CEsTvUBKBrttHau6iBGdYS7JC4ZVwoUeklmzEIzfDW4k4SmEPW7qrIoqd6AlAzSRAKmnbSJOdOGD4Ox6IRBPG5mlTO8PCPhNra6xKuTkoPh4plljUta5FXXNJQkw+ZSuNUUllg1niUUyMIeJDr+RkbD41pAxRwcXCBIzQE+WdYBYBfRgsekQifvQuUIYwJF8M3B+dxEU18K4dcXzwAillbYugkTda27mBgHlcwWPiH3SnTDF3vXPHxzoYP5CaDQlksU8hRMce/JNgLJZQOGlAD+WdAehYCgMaMuvR1l4ZKOCTThto0Y9PhRWXEdAdZWcJBma+A3EVFVJn9VknusScsSj6TOcv5oMQecfsFGyFjlqL+9YJt4gbDH9HGwufJ6WR2HxCFFnDpwyYbwYRvhgtLYjgtiqnJb1rBiVFHDzfdOglIOGIgukCV8firzdXbt8h6URBfFwClAE73s45wAmSlE6ySZUSg8LnG47o77fi7MqUU6yEkG8GVdoKA0MPE+hHoZyjg287LCWplEyxRnTG2vlIvZLcYUwGeA734etQfonLGzXrU0utJWShoELasjbVrpRkWRRB8Dfy9MApSkMV/oFCCb3N8ObN4FfhiP0TfTL9P0e8Rw/i/w3fY/6faxsbj/6fD/HJ3H8OgfYg8R83VxP7v7yy+rj/D/GBmyYaPW9JRMLeNTn6O1A15JPH3j5kBmqmLa2qTO6BGQpMOpuazqXcivaF4J8dajTyQzuDkkNKx3wVPHlydLDXNj08W9o5QJlxDwOUh4RmXdHMiyRdDazSkddHsxFsLmkFpS08DcNOVaOEsfApbiY8xOrEjwSvO3YXL3+0m7utKPu2pKmcQYV/LF6Q9BtG7Q5d6e/Me4ERroUV8Udkl+DK5+Hic3RKT6VilMrflFUzLVWPbUwNgCZBaL55SiFXqBRxiQkXyL597vS39GrXxO5ONJu6CQqoVqG2SI5b2rHHdnaWPEl70Dqx0nnLdP6E2QIxv9UgeVav4w3777YaFRX5sSrkyrLxSUTWY9BGSD4C49qncmhrZkINkZikMiFD4I6R+27aqM1OLu/cCcneS1IIpoPhRY6kAmMF1JEy8pgmyhQ9/9n43/wxH45BJL+5vj7D/b+5vLzyr8T6fN0W+/zK8X+x/e8ALLrjTudu9MDM9N9Ko7HceLz/H+JTbP/lDXhHPDDz+V9ZXltvPJ7/h/jMtv/qoZbOFIKI2fd/bWV583H/H+Iz7/4XuRlmx/8bq8uP/P+DfObd/8STOpouRvvI3//G8mqjEd1/2P3Vx/jfD/IBrtDkb2W0I+R9SpK9TWNlnlBYnEk/8p5yQ+Ar5uCk81jJGV66Qyq4Oxx6O19REc5bRfUb+Jt5VJl+gDjVkmZIKbyO0+0w98RsWUmzmDQCh4NTfIXialmAmFZ82U5kNUfNym01vaMsPjDeYR+6LNATl/DIvJYUkZLTezU0zCJeDeHr8e4xZZwnM0tZTwpVjHoFht5zgp6TNugdqW6JD3uHKuQ0PPDG7nX6wg9QZHSCKTZijb7gOjmt4pa+Gcy8nd9q1UBO21lqopTOdoeJsesuhAWr7w5s0s1gkDn3cmKHasdKcpuWi40KLfSKj+dlyiDI0nOm3i9tTvlWsNPn9kjkgwU2OE4Fi4zmKItGfntst+ACGFNkrqJNB8L1MWkfnrxrxw2EbicgHSz8fDfs4gAEreOMS0eWKWH6Ens8y/Gi3fOErj7tTHQvLmc+FNvKa4VkoNntp8Q0KLbGmRWNJVzJXcN0rXSx3o+ULj90LbJ6rh2kHMDNvDEkdNjFuj+ksIu1MDC4R0r9ZOfry7lLQNl2x+N+Z2T3fNsDDHA5GWK4s2LDODnZE1yTxO9DuSZW2jKs5o9EJzyk4dxhHJGkiSpja+pANqaM5PKSLNA4SVHBEbQorQR2/aL15077G7g3j5NdNwp1/MYG9kV5Ot2le0x2mD73Rv6JwBFc9CcBHCjKNH3XQaDvMNRHsKTm7gQRKZaAxcaBFp1wNEJ7UbaoRwhFgzA/ZSS5Z0RjWRxN376cFTq/Vg3AqGyM++UJaAkx8F32KNMnrijiUj6PZBWXOoKN/H1JC484EyUmSfpAGC0I6w/HB/spgzl9ZSqHXpWq6vfu8Npzuw49ObTfYTReDipKTzAqqP7C0UK5biIGKT3elioe+rEjF1jsA059VTrLPTIYfrjjvHUvnUHHyFg8y3q0KIQxxWeldlIQWfbicDxP2+8AuurZhUYrOWM7YA0gOrnMuIM8Yt2OCNvJHarvhuOEdSbPViQ/zWezTCeetzydBrITtydlD49XM8bKAKaSk+cMIBkLruAQXnJFurVUXWFhtAHYfg4IV8lFSinuxkW7Ptrj2xorRt3jqccnlP2uFHj+mBW1zHDpkLPylSd1taWd9vE2PQbUpqP1BorXNnTMEV4a1dXMqkcSwfNYUbcq+XD49cZ3x074k1XJ4W826yqpwDCYKRxjcTTJ/MtYv7DHuIp+4Z3CEj55NBG742fx8r+kIHia/LcRt/9ZJZHgo/zvAT6mcQ6gHadfV8H2lQmOSoz65MmTLjDCgXLw0eJAS5WQNgjo+PN4HH8mn7udfxY1FlUHz67/W13bfLT/eJDPXPtf0Cxkdv3f+vrmI/5/kM9c+x/9maL548+U/V9ZXl2J7f/m2vKj/e+DfGbQ/7W1/m1xyr/lIso/YHKuszRaCYZr2yjsOz8YTAZbkyZZlagSzYw1V6zHNlURtG7TW3Z7M7a7u5PXKvqkpjPCKeKob6iwitqrPGNnVIZwj6jCmk19xfUogobSYmX1/LNlihsfElOMcye2TG4crWRTHyY835gDx5cn+at3ItznR4b6V/JZ5P2fRQVO5f9X1uP3//LG4/3/IJ+78/9MDjwy/z/vz93Ov3L9KSYBmJ3/h3/XHvn/h/jMuf+FJACz8/8bjUf+72E+c+5//EGqDGDK/q+vLCfsf1dWlx/3/yE+M/D/B3KPfwIJQDQifDH2+UDVQQ76zvIAmdSuYJ8ts7TqLad1lfI0xRog1cL42CwfnU3g2H73CtBxz3kbPjUsj4/a2+3db9o7r4ZfH+zBvy00XNrdf95pHR4eHXzT2kOb5D+0t0+wSPvP7e2X9A2tlF9imqntv3Tg+7O93e0TenrS/vNJZ/vr1v5zLLa7T9bL7T8f7h7h75f7rZcnXx8c7f4b/PWstbvXzpVj/NzkLumZigpKRDIq53SXzJhQBFwOqJZoGbVMU3TMevdquPeXo9arYZgWL9sUiqJFO73O+buiS3mk6oiv3uW1TcaM445MPzmjge0uVRbbXFm0VGVMvuzKTDCljQLdj8epZh0pGyi7REtItOma3rTzduT6aAx0l5m1ufJdZkYmp3db1q+h6jyLChQFmvz0O5R83XdSz9/2ldNNWDO3ZE1xFK1ZVELJPc8EqC1ZZQqc6pZnW0rdeivX+lunCElZJ6+XaPUwUtw42GgTln+SA1zGgt0cmaVn6MXBvBWzGbpRqovcNinh/czr35bV1Po/ypfvT74cJ9Uexcwf9GfR/F+aHGC6/HczLv/dfLT/epjP3eW/ih18lAD/nD93PP/khHWP9l/w9VH++xCfufb//uy/NlZXHvH/Q3zm2v/oz7vaf22ubibsv9ZXHu//B/nMIv+lXf4JpL9hbtGCAjwsP5fUt7hv/rHzA9pTYd50TKJUu/AdpzKl43SB7X2JiQ2WXUY3fzXU4c1fDVvbf3w11CEN8FUsL4UpdonkKJ8igM5j442krbNs6UlYo4BwfU6R8uyzurug+U4QMavUGaHCEd9MFzbHk9nOImnhfYpVLS40fCg5d2EgSk1JXGx75ahS9FAzbHQs33Kxno+gktBYMFfiGEveXKz9Q6pWqIcw7XOxprex/J1WKiXTdMHZyIpC9503n0RC6annbpuqiB2qMr1plRa6oHhWtn4cqTWDmDaeCbvYmh1TrSLI5KGE2mZ60Fkw1o6qN0U4z/kdZ5L6b/9xmsDfyBUxS8uHqt6U9i/xkphNg/0c7wipxs5bjcvLzmunuHrlkqJVEBb8o642w+GmwBYzr9MzrjVllcxEQ8VONCdO2zZqFFVNxTNfzTQbrCuecd0pc4rl0pqlmz27cC/RjFyz6XpUD0dcN/dkR3NdzXa67V5N1Z0ym5T0WYVVlhgFZZfqwoQidR+dGx5Q+WQSMo+KpyKfRcp/Fmj/39hYf5T/PMRnDv0Pbfqj9ufn/ck8/2Pg4IM5Ez/Iz8z6n8b62vqj//+DfKbs/3yJH+RnZv1PA6DlUf7/IJ8p+++swE97mGXZUeyTv/+NlZT939x8jP/9IJ9SqbTtdvsUmGybNlrlLx15Q4dCOR61W7vHTXGEcCKsZ0QrLL2wfdfe+aqC6cN9p29THvHhp0OxUl9brm8K643nv77oY6JcIO3doCowPKQXVJ5AOcypirKJJTsMYvmF2HvnwxgwYKLdx0p9YS1dN5bQWLrnVOoonhu/QcnmFuY9d0Zjzxdfn5wckj/7sFdzh1DouQNEvyv2WweCsnw5wv5h4ppZyb6nxOjILFbFxO/33fO6NG2uCi9Iy12Wln6VSd6qkYY1UbROEfcuVQ1MRNW9uHzy5I/tv8AUvKDuDK9d3xti9iirdLR78uKgA+8wUdT68qrjNGxns7fqXHQ3mp+tby6vbWw2enbDsVc/K1WeHHyFCdDG9nlMOycTGAdja+CMr7xeFSiy8VVVnHu9d2ZWXUyaHp19XRprW6Wr8XjUXFpqrGzWl+F/jeany43Gkj1yl5AvnvhdZ6kkPpEN9+yxvWXhotZ7k8EosLCnCsytC9SkxUli4Qmmh8UkbGGKWBpMVfAwt+RoaWw5nytgIh0/2LopAXt55fnujyRUQv5u7L12hgIHBotYpZjIaD1dO5F8O+wnZkjD4ks43NJtJA8yzQBFj4EVWxf46Y2coeUz1MDOb20sV+rIz1qVCi14AHtgjd3xpO9VxZsrx3e2So2thsoin5F3NTWN9IVK5Irpm0NFWZV1gFVDpFc1BFfVUEAmdo/F/sGJ2H+5tycu+jKB7c3BVzpz7Q2N8DaSeraUliJ65GN6+YsSJnG+4endqgTxZqbopi4Jb6CxrRv/tAx/y2fN36/eCvwVzgQfrmzwU54UPmks3wqc29YNZoKFV8ZEy2eV5u8/u+UE89S2MfPy2a2Qk9+6Ofe8Pla+6EMdNVS5wThQeTowu3elSWdAsq49N6CEpx3Y6B6mOa98nrJrn+u2OAXbwHaHVnSP8ZRPAse3Sq0eYiKYjY1aqXDVxrhqVkKrnoyzkuJ5BYOOQ0siTfH49rtSIgkeJgg2SyLiIB18IGFCcvhb5US2h3IpYy3CZ5TzDuiE7pVTH3mj9Ox3dN71KryuimtaCCs9uqZIYqH1jc1Pl94451ee91rRKjXOBV4CRGLlBOsVK1QgHmxarFZSMI6VERtabCwv62ZSAzeLjQrskET0Fk4xvhGR8++iZA6w+O5J+0Vtu7W/3TooGeeu1KoIuz+WSRbhFt4DDKquYbr4Dl+eiChexvi7dCfLMOkyuTglo4hf1fp4IM6HpjBxIwXwXbrBkd3Cb0zjHHR9dySR7EUJCEJEBQOnzpm7bwGNfq4GTK1BB81SVZ0y7oPwY4liIDdo2vXJqEeOJZYTIHD3ODDMJ6L1/PlR+3nrpN0U9uXE9oEsCWN8L6l425/TBW8kYqg8MRfuq6XtiswSL3AC3vAKiQjMBS+fUuZI+9rpy0WQaMDBzaE1gBngOAEO7f6lVx96mAAD1oMUFbdAKRiK6i1WMeM5yWknVCFfodAXGks0I5XTqefNnF/aOn8uF1mtJ6yfGjju98v9P+4ffLv/iV4z8bmIjghL7T7fPzhqh4UoaaXG3GJ3X1hl3Wy5Wo62UI7vw07F2Lyt1SYizECsKKjGqMZEHGLXq57aGwZXGcscgKznAgbFIiE1SDQqn2IiVfvO2KNWJPnnDhGhA1IJdxiRTocuLJSfWytGwtdFnAC5DdQmvQz6jjOyVvEVX/Px7VmNHgQEf3WP4Q0MCLO9D3AVQrmwiEK+sPtX3kRs4WFWGS/6lehObZXNtsulOPSEbVJ8ciBGBZPiPS9AoAomA6sRveORkPNPlSnSmdgCxBXCSSW68W3j+FG0J1QOiIgvHBz9ZwdH37aOdiqa+CeiH3YDdg7qHbdfiL29F4StvLF7AcSb5BS+tv2RbWl+QJP/0w9zdAi0vxHTDrT4GNWQ96U0vzB0ClslX21ulhZ8ZiOgYqDKEExii6aXvMrkklzDxPZHaikAAKKpaYxHLyCyU+fOBIdGlG5p6cobOEvdvj3pOUvIyaEgYKkry3ewPBytHll8wgGTtHAdiB13hH+B0h733aETWJXTWuPstLmyunzGY3DeIusm2vQH9cF2IJzcUQGu32nB0JwojD3TMAbMFvBeI0TwABxrKyt808FgHEIKlKLgC2FkXJLr4YQEYBqwQOvO0KsraLgp2XnI/zS0UzzLBIY49fbycAfuOkWeH7dPhLSX2Crf3ITzKksqjfIz/zagxcjuA46tG2K6VaR0GeAi8NZIhzdz0sIwBpTU92oc0szySUTjJFJiIZCFwaIpcfKYEhifpuXeAqB5AoinQ7m2Ox3COp0O0t2dTokxOBPhMinyBdJjwLb17E4fMIqFvyWmL5U4O8HKqrAC+MtXBVLUmDyjTGkrygAQhIl22sd7u88B7j6Xr3vOyHPD97CgLmBLmwQLhcl/lwdIs6D+SkbW8QdlDT5k9uAnYxFSafesCyVCtRe+WQg0U26WTz+9x5tlxTjpFyWCwBv8FxnkKfJf/HduAXC+/HdjcxXexfL/rq486n8f5AP46wRRdyBatT8gf9lHfN2TfGZdsLhXXDfW642VRr0BLFr76HDfeTvWz9bgmRQHs6y4Lo4Bvw687uv6kycHgvKGmIkvhIUCYE3JLNHNUkHm7K3jE58GlMYAaDoPiYMX7eMXrWNxMRnqxC22aB3uPnlzBfd036XwEnDsPEdYwIXAmRM9n+6ESl3sBoEnAP+40L1N944PX4G4tGh+yLEh1f3W04OrfUFvnhAtisTrueMDjQFT8IAOHjuuT0TtN4fHwuIzcj0KlqAr8QwIcxgvBjl1h987gKltlHmKczg+HtG2TyyJZKEBII+u7KqQBAA8kBf/kmkUCKQxtdXlnF9I+kOdIfwKJucBSuRc+SoU2NefxITd6vv4Csk0wKD6AaAI9X0ydMc4nSdpAnCJfyZjtx8ocbbd63XGXgcZDBiR94a+UYvZQnM7NAM0iICqpBKqgt376S1Sj/YlNM24d6p0feekKgBxV0Mxe6aEfPvlMRRG9I0Ftvd2DSweEcU8UcJ0Z2wlJLnA0fTP7e5ra1GSvYx7+a4SPixppHISeG0pATCbfRM7L4XNSF6l1lNVujJlE1CfyGviGs46hJSmZmkpTC2lGkIyvYNqBrG3+8e2KO/UfvvbcrGVMVeD5j5zC5I++i5GINGcdhIzipNACK6GQJTL9b2u3a8rIJfpugC5bVHRLEmiJHzdt+OJjwzXDOJooEdRJxM2SiqzwNIJutT+JIAT6XaYsnVjOo8ZtUpqkzvSQI8PXfj40vcmIzYCHwwQ66tkuamfEpBqPq7GOza/Dcbi4EKcXDniW8/v90q3lbo7hGlqyWrWxCTxhse84KQUuaeBDR5idfVIzs98pOYWdo8tEwjwCMRzKoE0ohvo4su3adJotQIBplLrTMi1rrSPSeDQka7Dj7FbbiG6DpngwjfkZDT2TKUgXByH8cu6KQWzocgIztt4AnczpVADjCZQZ4I3DyDwgUC71QGWCZwfNHeUr+nCJawKliylqKvkCxI+Sge0crWsXdjgO4ywXJmuznJ7OIjTsxQFll73mJTroy2y4zf4NIMfQOwPhQkCzkJuAbqp4zyHvfhbWS+amNiC8lN2CxCG5/ZgSl15dfqXQRXoigD16k+fvn4j9w9RRYLtoJoqjl1Tt1HCRvA3tVWixuCnbDTqiIVW4X85apVuuRcpV7SgX1PB1pOjpVxyHWzX+mH8bquhNM5c6kbjAAMrAPFiD98ljgy7iaqT87zvnZMfDRlU0wGQxtUd1UAFwE+UvnWHPXHovYFbb29vO4ZW8IiyrfQN+l/0gArhdZIn+IcJcOZEI8IzGH+V3de8DlJImEUOZUDLt2e3crZ04mnVrOhEoX3TA9FAJaGjoO41IyJcU5JG9e7Exys7isBuz+QYxt4E/SjglRqDOw6Pm0JrkbqyVN2QbmONEovm4XRHRdyqeGBfO9NwS+CxZtbyRjDH6KLELlWJALYPXu6fWE8ruWRDGGoGWuV7ljs4XT6D/7R56lfA2VqKnK0jc7MdCoH+NZVhYwMGZhywM3452sYXVrcfJO+F/EuUCurb90m0VStw+hdRVYOjkHOhHtSscB6tzhFKK7pu36XAK1+F8yIoQF69Fe/xY7Eq5aRK2XLpcA5QTIyd0MQoDWNEEtOJSBMjx8kEPf0CEDBhWh/2JUS02XYOKUjfODpbZQTcchS/V86M3voXdVgjuPaekxuB34ZD3Lf6ztDCkVRQz2usR2mEliEkWJfyVZTravUTwP7AcT0xBIbTBk4UGJYlYAQBqfaQNbXi/FiUxQs76nsBHkIcwWnjLL7j6dR95NpzfmAox4bSpHYRWRBPTXPYgSfF50t4e+Nuw60M+xvZ1gB3BccX3VK4AgO8+LDf6Bv8GHdfznWeN59AnthCc6I1TJUXp+0/b3wwTpclVykIqtYBIMlRCSf2MfrvwzKNnS5WzW6e2sdk9ciTYqvq99iDi74qLFw4uW3hKK/OIxPReY7zJnJ1floa+xMKugkI1cVU3T9gjwRbNdEwhm98PqZE96RDs8W1iwIJ0sJduKgqNMCl77iAtmwAAwCHAeVv5twswwlw5UCmdO0ePhl4gCyCALWpaOrvoFIdCCS77/4IBYxtzOL7R25IHUFfuBIjty7POO9n8naKLQnScRbWPi3RYM77VLWP1NXnybXjkpoWQsda7CcBBdP6Ys7BpO8+FoPJmFSRcHOOXUASZLOIxC9G1hUWymdYlGGHtdDYSMs36jKQoYXS8FbNG9UaxDSFKXvhp0FHVaoROqNS7OjEl8QgbKscGrSUtnL6/lYjg96Xzenj/ADvwRoe7x5T2N/jExRiOUMinjyAur7dnQxtKnnhuYiL5L1lgIvR8TO7D5d2eDqAHOrbPgLRMEABHwymclqST3vmZiRGP4NuKRMSPjYG7Df5B1zJE9xzYI8igsRPhKTkbTwaIdrwnVHkwKsWnXTTspxdc0anpQHHTMExn4boJQb4kduPqgG58W7Y7dBBcx3a90bYlRSTmsRJZMhpu1B07HSCoEFz11A9ESxs675ut/ZOvv5LZNvo/PkOC3zZ3ofPIXw/PhD2peenwp9aMhguHgtYKLyizNOiIo+Wpk0i7fQ0zPvMHjvFiSMpFE4jkAwdrMS5dWYe2EO0V4hg2h1apfg5RkwkSvXvPQAOHm4lSod+1cHYwBSVGDPApJGhX8XJ0HBv8QLxO/qADS+tEiubv8pRdeVj0K9mxqBVEcZ83lpZID4NR+u9SUg81K7GojKbg6mKRMToqkjnDg1uKSZNNiWbW2VenXJcJII8k541qltZep2IGB0Nj50a0TqTf40xCybgBfveGEVPFizU6WtYwNfh2kWsYsSUz8di0ofrFx0PbaDiKSY37PQoTo9/aNguD9vElMmF0M1XxmWtVobdIPCgeBM0tQ8G7N4h83fJlHyELr0gu5M8IUQVIf00CwDOKjgM2Q+sP5CTjJw/0r0519mSQcP2MIkBU0LzaGAXrf0dMd0gKnW2yDc614S2U4ANuWcRzXaA+hRUL6JlSARRbne2AcnRqnXfpeLJ7TieTOWncYXy9iC19rRzg5OR5jmDCapHydkHvhDAABa5KzxcA03UKIK2twuh7cXI0a5vzxaC5bvhhiKmuOgDPi12PrfTiOnu+C26M52W5Fpim2OMlnFmouckCwr1kDUZAa8KaDp25qqCXqsm4ycSONRrtUsVAgPZKZxQxdSheOPa61+7eYwwHpSMg9uYQrGkLSMf2tRTvS2vsEqUmCI63e53J327KYYecK+0/5jilOyezUYqIvDOfeKIJTbCuYZQupIPpisPA6Z5G3d3CF5JJ2XzmT85bV7xGNbqBEBKyUSwGP7le8dFc4c4Mnvjjq/MLo5sN3ACBTPf0EWAy01x/2O0QnIvkgZVNETSsGv1RmyPlJYjulda21F8027PbqNE8E6H9fsnhodFKorf6fAOdb6HZfXiS5QmqJ+qfyzt1A7+qB+qECg7+skcCsgURWNcqYgf2IFhZ/x2mH11x2T6KbJdPNg4ETjWUoSfCcGqu9Q7WX8+ViLcS9++JpcSuKaPUaDLO4CWM0QE2covxrjkoPLwreOjCTxJxr0JynQANzlvbe9LsW97TZSqsh1o2KawKFcJKUVVm2hM0zVEP974yvEjK0U7fd4B0r2PBGd/MhgGJFnxfgj5Uyk8G70bvIOVDa8MaEk+QxuYIVwB1pUXjLdK2g4SNha1CVuyQ0Sw0GuH9axIKL/x/F78rXrOLp1wQpy0+sbVNcE5dZEKCDzfirzQZ1ZBg5Wp6YlbYkiYwFsqWzsUsbDJAqtK3r2Mg7xwxt0rZEGws2W8l+PABTviDK8mA5ag48ZfuyQGFSPfqTEEFEHJXcMu9ue5PI2qpBaiy2MPzj21KLA65OHlkcnegYgtD6xB3wscK36Z7HRIjdLpOcGF/WOHWoxjyTsgSEw59pOiyMSazokocUIaVcbIIFZEsc/8tev1bamgQkTEYkrEar438l1PmnRWUG/FHKF0dCavCWnVVvAK35mwT7XTHo79d2nX+M9x5zKN/GLbylLrTCMjNZXKg8HEMpPz6N0wdC49IErQTQx/8sU4M0enp6DblsTzGI4pmfkEF0j6JY504PxANOL5BLXLQQcRQ0evZhGe96oRkc5wiO3OFTkazYMXjr76cGFr8cr0AiJgSfdDL2h1G4wtVvST3hqBSn4BdlEr1CsG3+heTrwqwZjU+dg++eq5wFyZ9HK7cwj3pzdMpZHbeSDxefq6SGuuQsuSUElnrcuIxlhlkg3bh15oFfBvo5mtxr+zIxf3mC9pdIbXhqfaEOgP4ISycMfTFKQR7y4pCs4Wa0J/pzqK7xkHK+l0JsOR7QcOEbAdE8X5jXCoKOT3eyoOqaX6Vq3BhrHoEc9fA9lR4sLvVjlHWOI3TiNBXlE02ziNxhWlhyuJh5L0IUwv/+Sh83k1WP7qHIs3i6h6NTnTFGEAFostnGFJk6bhmBMKc2QYKGQ2hBhmmoKY2xjrMSJRfdMC76YEyU1GtE3Gx06JR5ut5eDFJgUHGSTjyFDpAa3gnfo6dYeiqpHw6BWQ6OLnY+RNoB3igFkyPemh7bSbo/qcQ2tOXaKL7UdbQkK0QZmy2ZG2QFPWJQP0unGHvaidGXmtMurNNLh1E255MXNarj+jkn12OoyulN198duAxJYMmltlbSaN+jZrDPSxo0ZUrWhCDW9S+dQk4/EWNSwPlKGF1kh107fw7tYTizVSwADKrN0ZM0I95XNudPgTKeFi1IYM8+xR6PExRlAeIpgPUAUCNGvfA37ITYjqEt7iiAy0O7RXR3rXUbbDdwrvoc5Bjr1l+uXgmM7niLSQ5FdDKSQ0XjwkwDJ2XyublcgAc+BhMVCdKcpvz2NqVUj/L4p9QhuywLmcOIJhDq2jTJr5Wedw4gMQpJHMzxIykijgbBQx1E0cxyJ+GnksRprbBYFtv1cli9Qhhe+Dbk6ba2dV/rbWXDcocNgKVWTdILjRLGFMyCJ0PLRMv0PcuZ79LtiqrS5HjxNxBlA/VTKRR8EbnphAtySoGIvHVBWhm4eJzZ2+c+meu30WwAzJ8fFa+tOgj8Glx6aCYRgjEY24wIVC/NOIIyBD7woASPdjx5sSW8g8iGHTK9OaxhN9p6aNq9tpzIvmVnAsmSEM0vaQ03bAfqEVTZRui24p+RdBMfZv1Fur/jrABTgFDYXOnQs0fp1JNZLQgfDNqCKrExoAkhaRujfsEJxvogsQxqwL3B+drZVppiYcUp/uh7Vcu0EoS+2yveCKQmkfo4Fr3wPkozvqOxd4nG/uxIOXKrcFTqkxTKCKd4ehS1WVuo9C1Fts45TxDNnUqKK8fSjEOB2pp1RjhDUQ55xlmyoNrbeyMzHPB5UJZCjqu+h9sYR3bt9+t1SAPL8DIFUVGNZgu2ME0LMOO093CKK6pMQFTNS5sv0eSsp68bslqR+4uLRKDJydKFgiX7NpwiIH1MgoDAzlchrnmd8+InjznnzeoYhQB+eBBzBux+9LvuZ5zv5A6amr6BlnuuZkUQ3sQFecYMill+gUkMUHHDTMC6KBtNBAAIBLNZyIjCFCEwqHdVNye52Rg44qpSb1dTs1pKpI0YIb7ldxZTgTAcUd1qJNkQpxQaY4pkmuSciSoxl2FIP658q4xusoL7c4nMvdoY6TUFN6bsqZ0oyyUiZbgCp9XsMIKw5ZV/K33C2tYroYDKZM5g59V3lkAFHsTkoPvuGLsqyyMdomJmyBBlCl3s+T6aUK6JOrX6XkprITw6IPfRiUpRtZwGnjN5v6jhkGGFZyof6f9wS1bMk6gZfifpkCHID5vDoStLhYBEHb/KXEhA6975130GkQU/10dJYzKLBe5bh472K0NlTxJ8MOOzkCFh1Ki/DiMkJJECS0QikziMRJsiMgzvvoGPA9Iytpxy3v8PAq8/bprBZah0nDJLLoCK3c5Om/R/BCw1uetDfJ7mY+AzpzNXJs59TqJ6znYm4AcQtEYOXidANjUIzl2Bl5gYs4CCgHmYLKnhmbrsyBTbMwqff6QbDoT4NBPxaTYILkI0kKOa4SI5+ex9JC/hXqyLLiYLwMeJjQTp3a+dfKhwQ3Oi7RzlOzqpZQzkup0DKa1DJ4nVaa1bMB7FDnjdOHyTod1chylfOJSRs9lVrsOZoplNAUL6lYnbJ0CUfrrJkXtHw41HnX8o0XDSQIoDmD47cqmIlTsbl58KlBPtmLv2kNdtS+xLSqObPIFOZSTdY4Mq+EaH8GJuxj0ZuM+p6A443BSvCA+I689BOoTd/i7CSQYs46DZ+t3gM+g7HcBaG9fXAMFvGoauTis7TghLmgjoswF6wX96e5880fYUi/7nBaXsr5myq+/bqDAe0A2EYTPwFoI4rjooVpmJJ7vVSNJ4PG1KUEGyrfMV5kLNw2kxQ3xfptDgnCcdbqQyQm5A9rhNu/wSSmGgdrUpti47ZyKrskez4SKMUI0EKd3Dx9OkqOde1W9439mC/P8Fns2H6dlFRIeYNZFfoEcClFtNccA60qaCpBVaAQLZChtqriFJUWUf84I6TuZzF07+dKTy9KV/Vg7IxuXA4o7sI0XTRC73vnfFbFU7GyvJyQq1LMnaoc6Rb/iV54uSp4BSgoZTfgRk6ZvxmLVDVjblRDO7NMQlRFYfGjyqdMnX646izf/1yuvQ6WFJ0bbYh6l0Mpbx+09trH220rmj+7Wi6nms9lD12FpShEitGSkQFSNw6mBC1dhBaeX45VA7cCoAYETwMuTYDQqoh8T9f6fywIoh2xSuHSickJ2RlpGdU9DVHDLINiM68xxaWi2ClpI0gf1SpAVM9x7RxfQu7+dO3sNCVjuzS0Sp01snMXjk9acDZpwGgWgh3XgCb2p/b5aV6fa6YJFCyfkQ8oA/Ci8DYV1oyJJ2Eue+xWANtIiDYyZBLoI2oDVr175ahnJq4m4yVlv7aKUv/UblisztioKoxETkEhUovDQZDvA7or2Npl/QqIWcBn3Rw221iS6NV2lrVcYafo34WVDOYIqTvYDRgNcEdjjCB75fFB4VgAxJRDkS7njyAXjpHvDjjsjy1hN08gQjjpdI1MbdNUKLLAp2cRJz+j3J4TBJZ9HuiCoiZUo0hGrCwnbriOtJ3pyJjmHfRAHZAaHO228Tgk7OXzL6QSNlPn1Mwp6jy6dooZDeRdP2ajOdH97naXpBj5oa1UJGrdmXRNVnQgBQCXd2pJBhIsSUtWDqmLwIAejyYpt9sxktcnNAuD11KXMKyK1867bHX8MM4h5u+QW3eux6m7k5JtIE1zSvrWLO44S1lq5NzaKutMPOUqBu7twPRSleDwHNMR5AJMFKR3dXKlTOotIwPTKp26WBmdzakRP3O4PYD4Sq9r2E4e2W9EJgbs57BlN/t1ptxFH0tX9qEh8jVYmjWDTJjgRme1nj2eU6t3WpKrjoAMv7QJZg91R2SeCENDMENbUOwJaVZLTZZQfkklTCpVzHBb/diYKO+MVWCZiAzrS9jjI2WQ1Ib1ZZiIPc61kAUrCRrNR/pqi4eeDH9HnD9D/pS41zRe12Bgq2bKChI6RfjX8DXsIbwajEqhnW2KDWhOVIshZg4wVyidlgkBiV2llE036hUOZGZJREloj0++hXCNLw544Xa89jxhUfaySlPKRQgI7BwqqpiaPxPRKxxSZjArlyq3yA1hdNVbRsKc8YliVoRGMam4g1e3o5JDzYpG8JotikjGy3BYjFiYn4eopbFMuAWqluY58UQTGD0ASTBexmxz0/BDQYxAwwzzcCEqoOVuLCMkoP3ZEN0bt76IpdyKXIN/7HytI9alyTN0JtcOWkFSNhkyKUDDah+GNucW6XB5VLZvX3bUuElSEIrRplyrRlasmW/X9JvVvkRdX98enMOFEDRzzdPk9LZqQdpteedbufwafsQwGFk8aeOn5K0Nw7Y2MJ2h/jLlClev7hrHcOR7531nQPK4NLREILmxHIjfC3VpoTEBApJAQzqY2cLs15OOFzMYkqWv5cqyXMNcMWX24qWtR2RpoINAfKHXxsID8snY68PMkAWw1jEBEJ1ftPnPU26iBRRdhIYFVHSHcItKcMjuLdBeFHdQPNYODdsGhKFCcCbEosWwgSFQzrVofJeHAHJ3MZ3Uy97b2STXuBUZoSpTDKWiG0c2b7y35N9ymVjrHpoPXBLX2Ol5xEVOkOfx44udOZ3QKhYjun722WeZGmXdF9JcBaAuKkP/Q2e3h2G82O8h9dL5Q0ezwP34+BErowrlD7ObfIf8bSPVZgdZUsubctQzAsoUqpu0lGkUieDCDhArCYVZfrvKDo3939SvnEphiJg/pEY4zDdezIn5nRHFLmrO8AcVCshwhI9Dhe9ganW4hB0ZXAguZCRGtPIvDizTAmxluKBGYOyBIgShsUCGxmwmGDtfIHhGtW3nMZFLasiszFBaxQFvRcbSiu8+tuvRJsJdMrGDDgVx8ZyElCyyfat3QxFwxYQ5JdRA/IlOC64+cjndIQo9oKmtUsw6Ah8GcAmOr7ZKdeMCUiFewifTbQbwg7k+E1xxug1i3qZTSmMjnYXOjPEJ7GxTIxnKmxFHPMLpw3EumXuKn/QMoImxpnnKR0ZTah8diRIMBI8TkOR1lSUyJvZygQbppyyG6gDW3/femfc7qU90uqz6CX2zxgAJzngLNreSdLYJAeB0jHFY0TYlTAo1Ds4+xxcUUzX6PE6C6v1OGO/wcupUQNE1Uvsl2Oky6Nooi/co6V9wBc0ctQ/brZPWV3ttTNK2ozxQepTBRYY5yjt6/hh9KydjRGThBUQW9fpnCA9n4ikqj7E8jUjmMsaA++yTKnO89fLUNrHzvqoV7VMygurkDzI16E+dY+9D/hTK/4hGf4BiSP1whzSQ+fkfl1fX11Zi+R8bm2ubj/kfH+JTKpW25fZyZltMlIwQ0QTiwpOUGNyEGAILaLad3ecHiD/2UF9G5RUf+K7+PWbaUCbVts4kQmGJ6rGchIAa0OZici65iSrq7EYXbt+p6uNbjeQgTMsrYOQLZOotJU0gwXHdyGOqKiNDUdXJaqoGhcdEXzSSq1wjnHIqK6KWSmvpUGSDenn44io+ZuwUCn1D9XsuKfECjPfh+p40g0P1Vad1uNvZ2TXjHsirQlVMkU8Hr93RCeW5hyHDjSjMloQ1svEawPq1LmUz6ANGcCuMq1Hh6JvgoLSnPbxBKOqUhIZSnDBSu1ofvMavVjC5uHDfAoWDQBAx4f44bJ4S1Nii9fzgqMWJNw0Yk1GuMMzzBepyPYNg1OCEBvDWaWnokSd2qVZTJqj4d0m3RpfE90S0dt/0ttTyofHL9dbN06fh6kNV4MNPjlrbJ52DlyeYL2YyvkUttdN9TepJNKYZYRKgDrwZTRIOsCPTpsCiNOt4O5olTmVcSmbjsyIqT2FVhBGliZbq2r1EyJvG1Br2DoYNgDea5tBUmFfFoCtT2eMZRyHYLCSSgYET+GBcs+ygV1mccl5AVNyfiA7qLB6MllK6XiKqlLgRI67ZmCZc2F4YA0PnX8JMEolgy3lx46Mq9ZhVV0yrlm3mlaJPKxg7UKYAD60hozkGxN7ui90T0Yh7gd9VcZ+wCZHxUKLaQ/XctI7hBzHjQbOj+Eam6A/lJzQZwOFISZK8DeSvK/q7WhUpIPKhU59F6D9KKn739N/T6L+N1c1GPP/3yvLGI/33EB+gy45we+WBr33x9cnJYV0cOcicA5uKP+WVCws17NWAa6U8tWaO0EqTtLY6J7XwBKf0GBpJv+Nk4NV4PKpjnCLHr0qaULPcVZKxh6RgWlLqNIKwYLJolSN6ZmrRpBEPvnry5Ki93d79pr1TFS8OdtokCEKdtow2iDa9mor82jImXMfmcGmPOPTm17Cyfcc3iMqe1zk8OD6J04vnXu9d1DiREKpPNBZJKdwhW9WgxB4wdHBK9D3gytqeM7xETGjGNFETUDIVbD92t5ODDlqZosGZhfM85QnqkGFYQPam9eNvaERvALk41nnp5lZShji1vnfZGeB1felI46mnCEEYfzhCcxNcphLbF5OABbqE4kncO0b1szIISMh3CcovfewUGJv9g2+BdAAyQWWtt16ebFfENWY/fMNvOEaqsLAn/I3SuYrQHV1juoexBy/Gbve1TnMbWdFu37F9XA9zyWDvACpSNFrylHQA+HGGE5+8gRFkmktLOrBzs/Hp8mefLb1xzq8877VC2DWmLEqmwtx3pKvou459gQl3DCOqjWXTviFVsM2Ks54bjCjCBMIGZuqZ4tuOinCga9USpJFTwwjNlNPP3YaQarGkx1MVQ+2hqfMHY4QtpT4ERGQPkSzrOaJxxVhNbzoLmmfLIBpMgBywKnWjQDhYKFoPfNQ9mKgB0cIxfbWsSEhv2nuYw9fG5mXIKGXL3GQHw0AQlu3ZDkAZE2VKSJkzqzEA8I73Zpg2Md3D1WTcgzIJIz91JJ3weMZP5dSjsv5TH5VG+jnJUAcZVrdJsBWpn48FJyOFLbKbsfkmCOVTdJZkTd0pRSpUESqXUettHAIKyvJWWWu9nclaywzLkmSGxni9KdvZ21QrffKsDzhhqtPUEf+ErKUbT6LF9CVKWa1rrz+2iy37jLxruMR58XQwnBll4qT1xVSyGpZPaytNtJ+QAvMpBaX1cSxtemjNRHFfwxqN1IxdubaWeYaVEQvKue0lI+zW7EaTMNecFZ8DmhFiNbIHmE0z41gpHFsTHa9b239sGteCejlcTt5/93GLiRp0FQHQjznwPoxrSdtNKm/X2CDT4TAz2mYkbl/i3o5F3oxG+cs6G4Vta1ag5LAxw5oWpwIaHzpb/mCfIvz/9coczP+/msb/r6ysbcT4/8bmWuNR//MgH2BdDujq2UG1gMsRCjFuSncss9xiNjA0E5X2vRjFEYladL6rymsLo6tEroiqTqaOEvrhldN1oZEn0Tz0cNlRSP0l/nPou10HfhxjGH2x5/QuHV9QXom6ZMeW2keH+87b8ZLi247ard1jDj4/8CQfJvn16fIDiYQmY7cf6ETVofEuBtcJrXefZMscDFPvKqa1roZWc0otVTU1Vfcno7BYSLH98vhE2TkefFXlIJ+m/QoKKqOyjNDSpTJLhymx19CYo/M8wse/cIaeD7t77aIdb3q+WFyyAenPyGj8bbc/cTG0DMY97EjzX7JWJFoyEZkXw4bARVHCaEqqpWhcj7iqLDMkCrU1R/wT+psIdtKCUeVEO8kWP8MnLRKKEtO31GyjUVHyswnk28hjOB9as/wgxuZVnx/QOGa1xAucqZWRxa/sQAUWQr+7UlQvgUtJsqVIOBCpQhQWUC5LzB8tsXKnwknsKcpXWs+RTC7Tu+ZQmhm2asXakrrO9NbmCT2jrZqwURl4LD4BJ3t3Mm3KMvbJOEAp3WRyvcQkYmZ4mxRkZrQ1OvPK5N8T1vfeOfFF6OU86aMY4/hPexUZNxmDaKCRuRlJPuKn8XkmrTqFEF1AeOBCkYqnOw0UjwGbcIDMz1OUtmExCSzSAQmnVyS4tTFDPIzmJWCXznPO6Z0WchFFLzKQzmVKFB1sLNcsd+YgOjpq5s8jjk4xLxwjyiVtgJxhTAbHdBwlYtJB2jDzOjDqsOraZMUdjgG5p4Y7QlLB7emgR3rnS0eNpPnJY5ixnyzMGO+0hZtFVi6wo0jKL7wfyWvrGJ1B3twzr5JxpoUDS3CQjqbgT73O+bvpDgIhyuX5z2B8EIxNYxX8ZfQs7ddb6G+1u/+80zo8PDr4poXJ6dAKtxJGo5AnKP34hWwUULQXbp8cb0ZAkzsJp5X8I2fGS8R2IhY0eTsTFbbxIp1exG0VSGBzQeI1aDwzn0IU1BKRE+8gcQ2Nhbjte4rQZUK0DPmQF6KT46JMX6zcLYj5NLUUF30UMtEzxJSQgX2iUuA5gkzM4w2Ln58s1sTnuBRKZ52kZiP+C/KqRA/6mBaZ044qe02STWgWs2OIOeDYBh4qtDBcm6Ygpzk0a2/y1KAVMXdnVMnGSpEzZ4d89I2ChtSXoSEW6CI3anKWVzrZGyoP8pizeLi2mVEjZg7smx9G4mM2nnOHKOH1hphutxmakVAQH3QdEFGKvi52UNZN2npaNBniWcvAgVuwOPJBpV6vz75I5LacJqcuHiArnCGMgAfJsSabwgs4FMSxNhMkJdfgjpuZlq/tor+ysB2U6i1oMkQOvJHyDQUPy9HnLCyWRD8lkMQQQyuGISTC6N4Ja8t05jAxrQzb08ztJQDGDfQmQJknen2I5dCzz1B5raZZZ8wWScSYMIpge5wMGCdq3nkkXj70/GPkdb5hVidVBthY7jRWOo0GiQCVCxPiXji7gKC9TjDB/Um6KuM1d5oXf9GrX8vgi1lXXDzC42rlTChDag9g57oqrj9p4D8rRdgzeVG/TejDSHvppASWhBrNAremSjOnFZrJhKJGgjy/YeT1oeR5veB0JWsnP0Zr9kt0zVr1RGv/pH2MuHTFExRBpLEC/89z84XOKLxez+FdUno5mf8LsVLMkh2u8tNG8vHigg7oOA80Ow5EIgPrUK5aQrsK3xLP6uQg3HTCMy5D4SWWOnMmPQk1ST84uL0UaKeLrGT8Q6BbGo3k5jXyFgdqZO9AXsUkhJyWeiq1d4H4rkpCFXYdaK3snfKDqkVMZKnliUTxRnTGPopyYHdcCijR0ekUYSgPgjZmEirCMW7DAc9bCj4ihhI+0w8C4EVOP1UUSicw0o4fhS8HlnxqT7mc3KU9wnw2QdejOA9snULiLzYiwRTeeCCmgNNckUXMlNN8snecfU6GfoRqR/PqKZU4qffKWhNYwYGL8SLJ1rmYXhJ95fjcawtQDZSkbRthVbzBKDN4n6qSYdy7OCxiJEp7+C4iF6HJA9z2HYVsnve9cxjdjnNhT/rEW6A3F37vyAYMeh0tq1AntlNrH5/UGgU0YBL8seIMkrm0POv4pxrNsm4+miPNer6mLJGCHXsM5Ppj1/C8kZ+W/Q5nNko8kzgrUsgQXbUJhr+bQm5TCl8jcOq05WcYzdgEBkKMJEfiUDTit/2eOHb6iBRLkRIdHxE+rNFKfb2oOpHy42D2SmHxEdFnI+XE4OkyT34yTU5kckaDjEFwH+kAaWn7C4y76sKpQJcFdyQjS/BhaKpzNUWGT8smhcApK/jDGJtaR8Eq8O2+c+VNAjU8TNNXE98eYreoXO/qJVxGAbIxVWM14UcwOZfyiVxjKDTrkgn2msKHq2AqkxAa7lXz0hdHPLoQhjiDjFZWoPjl+dHBy0P07YoYAxJ6CG1EAXhQLUPiAuBedw7o+myWqjz6zOBAJHxiyFMZfVSVcGM+NlEwQJSyKvHYQzevaYaVvKbTEXpGF0CdJpBzjATks11CygFH3Wze4FIh/VBif8x00Uwk+yKZaWdZI4bsCLKyMr2vsK/RJsOPiAp+IPajGFOZl861kiM7x16qFKHSYuIHH1BEHvkFOF8OJf5DUKlEMqN6JP0TdFO7F0BlCntw7pFFEAx3gOb3nJUZRcrw1gKm1EcPokvSJuDsB4JNUTp979Ltou+5edR8h7xs+aixkDfjqP3ag0nUl954/uuLvvcmWLqvPtDKb3N9Pcv/j75H7f8am2ur/0qs39eAzM+v3P7P3P/l9Q7KWOFSY09qTCEHmNcOyFv/7n3k2382Nlc24/u/ubm6+mj/+RCfG0ByJa0rlzfZv/x3/5t4YUICP3n/NwYHCrdMwRWIZiI0efNEkVKUh2Z9tWv3Pl3bqG2s9JZr62vLTu38YqNbs53PVlY2Vj9d/rT7qY7arPv/lp11wheKyBt+OqxRfzWgsZz6m7Ry32grihX9nLPU0cNTfT8Y5nbK3eYsrIE3Kd4+OLUbXZDci16QexSOB10zjaDTJQzbhc8jx2dJHR+zpHKkfMEUpv69T6EqwnIehcaiQShaS1uilOT8d2ksqyvnuNS92nn3Yq22vn5xXvu0gT/X7NVPuxfdhrNywcyfbCC2Vef2+UrXXj+vna+eX9TWVzYuauef2p/WVleXncZ597PNC2c5uVXf2JjXXFCsEDSkmbJjXXN6s23XysadNmygFngyPID7/5nnt/r9XaLzjWX+PtiW5TASJjDFbEhqKTuEQVWGOalgfOTTG/K8hX6E9xrYV7SrqmqbBfSdxVdSTK3fY9CrJrYknV7pe71et2QAlS+hjvx6K3C/K/AX/nf2+avhqyGPC6P1/cYdjibjOpm3WBXCyXXyB/6Hf4BKn6uiQPL6aGBxDMA3vLSA1qEHUKhcrkApoHesj5b+X6et2r+xaz8u1z7r1F+9qp3dNKqN5eXb3yyRgYpFlSoVpT3FdbEAN1dFmZuzJwHp/b0J0JbX7/8K0OBR8zyIkQdcARKh53X1FWiryZCCzzg9mHMDpro/GZw7vqXK6NHx87ob7EIXQJ1b8j1OQjb3e2gg/PUFO7WmjFYW0GMUVkPYXNoYLvn90Wjlt9hga5HRUpnswfLrtMFw48ZYMC+Z63vmUIgAHtNY1NfYYMq482UYkN5hLqhGJKt9BNW4aNpQjr2BIx0PofAWlhPv/yYoZhFvpKwTg/kxh7pBGKjK1a/y8lXV0CXoKoHTbQ7ugWug4Xy6sVZr2JvnjLvOeyurtU83ljfXGisXn65ubCZxT5uRjuBltL+cin3ci0zcU5+CfdZX7oR9UF3vagxuSB9MxB4RSpTgonCOnSGlVcVJ0EpHi2AO+m+Q6cQ5xpIe8MQIK8tJoMCVQm1Gy4XWhivGi4iZY3T4p5H60VHrnVxZ2/x0E26S2vJnm05t/bPNRu3ccZza5vnm5sXymnNx0VhLpGmITmjr5kb8hrCa91rc3iZL++7llS6eXB5aXIeNzeKrq1eIbjzP6zv2MCVrRGjkg+Wwi7RCLJQ1BxIrc/sk69dZbJkH5+5QDrhkD3uhkPZ2Ci2Qc6jWnHXnYnNzrdb7tLFSWz9fWQPaq7FcW3U2nY31C3t9ZXUteahaXfTlIUJv3xkDEAEXDv9MPVtIGMkoFlmHbG3aIdv89G5XvKbHnrcj5Bi6hDe1S7hNM2s2PoPPkj1yl64bS5GpCTYP/dPE8d8lIKv0Az4+TB9CfHBTjopaa0KfSfi+Tp4EvmzhMEQhqlqsH8bPhTqS9+Rde6IboFBHfAfetR++Ygp1pG6jeE/maZx23MyNRtsJbzIm0e6y4aifJM+lEa2kKtGczKEHBxQYLjwlcMP67w6Gz9gY2QS70sB+e+K7xF+thmS/7Y6/csZvHGeoXjbUSNJRgX2x7KyvrK3X7E8BIa9vrl/UPv30/LPa6rl9sWoDZu5tptyv+7hyffdHm5ILekEBLDAHfd9YXntAAv/7dEJak184G2QAvq9zJHTxu99RfGHvQuhHSJCVvXM0VS3j+49avm+/AwqQ/uqqQAJ+GVZqiu8VxRgtTuvXt8+dPhO4aa8RXUFzN6+GqNfDcQ5gkOUjuT1AUnKmDCCKMFiN41+77/8RvS/FQDHtwNM4A8H9EPqrlD/H5pJkHvMzGI1iZSamJuRabtOoR9XsCtKfqlkeT1MYi1Cle0c+onvodhaS0l5r2GvLKxsA7efdGlCUQFLanzlAjSxf9DY2Nz8DmjMJ8s8IWdgcoJivwnuF+dVlA+ZXl+8b6t1xOtjHWEeEfHdcx0Xw8ZU71q98+03IU1LQ7K7vcvhuKOjUJRgQm0mLaHr+GuzNZMRmAJhpl/kpJiFwvNwSw0n8N363UJYPfCeeOflVvqWDsxz2ggFlMBoRjLpOHoBdx1rCboIvm69eLdF/x58sXQIjdArEwlm5Ehazxt5rZ/gPQCh07C4CfUc+mAC1gXb8OOkK1H+6dOliA94ANrjnYSNB34UmAL5Xl43RyBlsGZMHDLK2vAb4Af+lo6ZL49K8Kj1D42RBsVaHiD9sX8iD/erVZHnZ2eTTzT8+4yP+CoOhW7oT4BSFRfHbyvBcP/5ElCvIPWJ+XChO5xnLNqkYr1xTygqyTvGMwg60nXEGTZgW02Iw0JnOdLfbO1+x15zap11gDtfPl1dqtr28XltdXu2tNuyNzXU75UwTdhyihswTh+RuMfVIszSud+KlSiLD492oN6Yc8PW7Sa3kAL51WZ5IUXJTpIdfwepHqR0SBEWYpiw6RrWhMETYhoRTk2IqxG98urHqLAOrsbLeA7S7sfJZ7bM159Paxuq5c9GzLxp2r5FGZIwNyWjWhqD+7/U7KJuJaadtxKcmA1+bBdV2OW4ejurp04Ki8adPXw2P5UXXPj45enny8qi196K9f9LuHB4d7J8cdFrPX7aOdlr7OwedEyjS7mA47VdDxXRtUcQkBFdffMfH5TuUtGA4f2JhqgLt3fAgdl/XhkAOev5rYaGhgxdQAkEXsIjdx9D6qIp9/4/v/4uHGe3q4hi1pliZEuY0AaF8hRYL6ER+JUgNG7z/O8btPvFt58J9XX9FhGwghtgExhDrA/648vBCwZzLQw8DRUoSZKiIRqBBRkvixrzMb7HRsTfylHDKk5m9YLQU35mPZ6Vugu+Vg+w+3qXmUSq9cXuc1H5lOQqbT+SelmQGhQjsa9VCuMMlVOhGYMXk3mLCmaE8LBli7xgQU8uxdy5gordoxGQ8DnkRxYmcmecs3tucY88Um93T6BP9zTn+aRKK+adRnWU4OdfLPS1o1gLMua457N4DL2keFX5Pa5oy+TmX8+HhIm3Zfj6TeCInUgqc8Ri4CwNpa9dKduyE3q7JjvX2ye1PrTf/pXxM+w/0WursNTpAymAY+zmtPsJPvv3HxvLKSiz/C1DPjUf7jwf5wEnTJDl5reHtstegPycMB8K6dmVCg23ODVLBAx8xAKEDm0ZJZxtOaKMJFZrVHqPLCBHVqkjcWsIdcIBnp/9OFYkrRxgpStZEGkrUuldKaBy3NeHb1Lu2xQtnGNB0Fam/HVYqYoeSypckmZIVJe1cY1bkTOG/7CWMS3NkEPA8e4B0EacSMcBC2+TkgWpmqFHXD0IFft8eeuo1/yDRThAw91AOZS3ekMxbjeaMR6FYQy2vLKN/k2GCLnblBhgtoav71g86qlWscXoWjtTB6OcdFYhADTn6NGYiYQ/tvh4s/cBR6KBnsPFlWq6lJbE98cderev63QkwfU20WZ8AEzQZ4JJ8//6vwg4wg+pEoLxDL4ayIFlCC9fLoeNQW9dwMZJpMYLWG0AomH+ZTxaxX4NJjw+gZLjscx97M5pFM3volFrD8EnoSgasnl2VKU/wPXrxwR+9wEOEbuhUrcUQNxFeu14Nc/J4dbUs39sd1Z5aHJ5FuPQs+h45QxZ8f0SF1Bx5u2lsO5jDl1nPHoYCRq8k9HXuv/+nrktxAdUS4nQvMFGSsH+YuFXleOiwk7cvbGrPxD7EDeNEh9w8RcigaIItmNsQ2xUOGjMMMMqg//6vI+A+ls7hYI3tOrfmIseK1sY+HOMAy145E//9P5G5cZUb3t97SYOzv+crAoMUAaHlYMgq3+k6vjPgTcVghDDV/59jBDbEsPF6iF3bBb4Zp6eX+tlR67h93Dls7+zuHHTIm+wATbZRIl++gC3wKckSr1G5aj4jNIkbGX2Msx6hKM4uV2Ot2H2AhwEWR12mh/AbaYSfpvZALRmI2RgRbMUwuHB81+csUZEmzZfRd9QiumDGe/W9c2o37d25NzaHr2ZK7iTlV8OzBJbZN6QRW/op9l0fe3veG8ffhp23KvREiS4cq7z/bMeUBZ+ifHV1eblGfzcuzkhkXK58LmDjAQC8awdNZsh/FOdJ7ia+7Ye4ibwREfBdhPuOBPqtVACoB97AsS7Q0ixlHnV32O1Pehizp1JR58y1O8HkEuOgoyTeInB7hUoC71WpQkM6R+cCmbELry54/QITF7Qm4/d/H2JUPG8ijifYBFT+8lWJ2mVvRzxrEuNQpit0oIdDxJZDhEW6NiAQOiYDTChJyicEOIz1RcdfQ3x0pFvqgkF8ErlUDKEzbo6UO+NXEd5bVa5eNS+fql60aniLVGPXQ5Vxf5XbMxBeNWuvqtGRY8XbV8Pbs89LCWoDth7JmGGv5nsTJbEMrZbewqFwgZt6h74JgKF2OM+5OGTs2I5gx6+p83zyI1RApWqfkrTH2sbMtEeaIVOKZDnXeinDbinbYokLKIV6ujWSZlyVjiCUMSftiqSNQ/oOm1LzHBujdOOiHKOiXGOiHCOiqMxdi1CyrIVuixDCOPVJ7coEKgWXCH4TCW8EhLg2fMa/zIc/ZVZXEPoaDSWK31iZnfTNxgr1ep32Vx5qJcdpivI23B/eR+IbwHCAsOIXlnkNKmrEvvTgDdFS9bJskFGEL8GBn3GEQIk96Gak7pjAosUWTmQpuUvzulZXaS5GgZsI6tVwThm7xyVCObyVQCeVBWORxuraHPsYuaeHqBW1LD6eIelPBL7SptYay5VKfWCPrAHejBbtOobqa4pBHV2c8QqR6L2MikwMPkcKTqRLMWnVmHdS6nOw2vjtGFacrlE9kvoIg+HcyKa5lWpYiceoierbisFPdT1/hJc6DU1fUlDHGV7XKdHmSXsfCNvO7o4aCd1aMpqYaty8zLCYVKEGzXC5wom8HesDgE6OQwySJJsxbrjo7adKRJ8SAFL5MeCwoGNf227fPsdVOOVWypeOTze03+nCXYn5spEcGwBFMHQDDMxMqS9tjFbVwzcqIaMvQ2uqowREKZZj7yI4IPCya1NbWs2ta4gyLAZ5B/od6WFMZ+UMdi5KJ2jltMYEvCMd3wGaO8AumnKPSOmcPGcDVLnBKfuh1m/EDtgLfCWOuCXmaGB2EYZk0edL40l1TcsReWOSt5Ri28Q0eyA2MBquZER6nMy1g/Fx6Vpgcw/iZyJjZ9qODDUctDCgpB3EfiHpTLwnFxww+YRcDKkJ++45xlr+YYIcz7XdxzDw8Ju5YErtbddL0xGDNNXEO1oflu02Zlrd67w82ru9RWvNUHzDlppfc7KxyA1d4gxkaYaa6TaaIQGhtlolSjshR2f9WtsW2iMOiQLruUSaeXVRVzObbJlGI2ltbn3lADfpC3P+mJX3j+2/hHr4nA7+XDshfFPb3Ult3mxXIyGjZUljRCgJXGJpYWCsbzByuu7FO2V6YJgm0HfDJOEPxwf79YBMhaCCpZBb9ERWNNmVJCe13M+kMFOehQ9ZBUKHAzBjbHYR4wXDapiEkQlcADd6v2ZmQo4hhMjpwQN1KJGdliDm44OEwXTcWnrqtRtFC8rENGlIGmIMneLbA3zqhvmaI/NQhJM4Pm4LC9dxiZzha2w4VCG5i3CB8WZqA5ZdPFPeKlhcDAELHfBmFjn7IVGg0JQgFgr6p+69iMXjed/rUjQEelUP4CyOraVXr/wvX8FtwH+WKnW42KAX6ysmxytk49h3xoKMuLB6uayfqW63YcvhzXDS74fv0Pv86oiCIprv0J/eMkYESyqHVtH3Mb2lbMDkAoVvY+Nd4oFxVzLkgNEJP+9hmuATnG047MgAqAscAPelB0AxXix6yGneAjQossrUUbNcqYRdykJEaW1U6nBoMb9ZfjNkn4mtGAP8JNrUeqypW/5D5q+ybzR1DRuoqERhTnwB5G8Mz3DDT2DYhGIIWCyjjc/hfu9iOHRhORXyqpNNmv2rqSPZSEBRrijggElwc3UCZ+0yl1ZVwU4H8QU0EYMlc+jxqj1v6GCNKIRxx/yww8E4P5e8gbbSvZEjrUa6q0abQuroVpHZZFH0G0Q/p+UCpEz5LGYO7U8ITNJ0DWSA8OWX2XqI9Hefh1oIhmxpXi27wgXiuwOJeX7YFLErhR6HBpbFlgWFTlH0MkXcBOQkLmBVCZ8wjH3IXcou5aE0oaEZHYYsYW5sMzI03cGgE2vno4/MlqbLnvQdGWMS8aVrCxkQCxH8omnW9V+3aCmxd78KoZKPeQzsGk7cThFM4EtUdaEa5xmxJv/FW7BISXuO3V2betFF/MYuQ+YOKhF7S7FUDsq1KfcRBgEU1sB5C0wPBj6Fiw/deJeYda2Ia41aV1mAPpa6IptYJYBK2aaDMuEAmiJxkvDOAVLs8fu/+66nQtxgtool5H/9oe1XhTPuVliJhZlpAxyHYp2hOaHYcxiD7fIQVupAmKJusOu74/d/w6Z7Hqr4lYw/VEq93N8+aB939lZRFZXCxGfx76H+pUuMH+o3dFuG3qJbp3wdKKTpr5KIpr+iFa1DzMzAoLRk+5cT6iSQT6RqI7JB1JguGhjqDmoPueJXJQI/2IdXpSX9Y+VVSU0ek2EpDUffwe2MKjgC1nAE9Sn3hCmA5DWQP4xZAdLnBZCvEpOkAno+edgeE4j0nBr3FDt4O/QOZomKnb3VBSP6lWXlubJ65xMXpUpi441TIOw+BbTRMwaELPethcnicHQJURzCW/g2CobyXZXpNBxtMz7qXJEV0RhZEqtq2JSGkviS5Aq1UFhU4xqpkq0TfH9kvl8YqKwphnX106KgUlgctJSY16NoKNbBo2jo/kRD2acqIVbZlsmtRButWYkIuh8B0crGRuy8zSEgUo4ja/VVmkXPufb6104oJLpA0gGJFIwiOmFDIyIOWKQc2OcOGjt5Ibbi0LpAHbBlgLCk7xjifTRdrjzKjB5lRo8yow9RZmQQCT9vCVGmFEh66kqMtMV0Xpz0+rKuCmBwJfJ4nUmEFBceEbQc+gRxV95HCYODj2R3OUYHakBfEiKAdbAyRk7OIdjfPpkk4s14OXHxC+ba9Vlxx5i5XJkuaSL0nyFm0rYIz/iO4NzSGCAXBu4NbcPEe3HE5qefpl5++oaTi7qFlx9qLfFysqXGFC+jvZWlvdUKZ90h3lF5NrODNJm4ERsd0KSAYykPzZWc4O7iFemXiaOMsNhiEtjXNmeqllITn5WsaD439K7xH0I9eAnPdg/ewTBGyaxMgWYKbFw6PgwTdcC6ENnHJC1j2Pk7G0oRNgvbucAiZYqUYrYu6NHa4g3cpxQQ7//qu/aiDV5Cnne9sMFLqnBTifPSOA2iyxsRoWLE8DAiUKTCKyW58KkEe2KNySaxNggnH/KB2eagd5LWZbk+rDaWZ5bWKYaQgjc0l5Yk07L9devk24ODk87OwYvW7j7whTKwk92l1FdBomBrm6KhE4uzZDL9VDRufwNllPXNA3CX8VgTeexaOCFgBU8O/tjeL8QM3pmBvQcuEDHBK+Ve/6qEcSHUFihEc3v7qlTlcnIfKPw8FwZAvvTgntdFRr57bY/pLR0IwDKq52ksHU6lpjyQUtyETGcgugTaw2vzilPnxr4fnm51VdkCrcwsQ3k8Mr/oI/Pf/tN/+CvrbuGScHynKRZ2iHCEM58hfVMVO0H6jsHsDtehGPveDtDD3t2SNEq/tQ3F3JRLG70uXte4saRHAffBpsVswL3gC3t9dmfFnw77cMSRR9yzcNxT4pVFzHAKP1D+SRDpTQB5AOZAya3jS/v0V6WzwoiD2s2C7gTeOLEvmYUswkDeGV9sbsys38oA+fbR4X77zzGIRyZx4nedpd0g0Lr7+wTWqWoGAmERG7PWMzRTXhy3t4/aJz8/OKZrLphQ4Ea+BOn6lLAsTDdHhDft9JqKbvS9aYTC40a3VT0TgpsZrbwaviB+OXyf5J+NzuCShs0cv+OevnYvr/QrdtXlFwcjZ6hfdCfB2Bt0yC2AX6d43KPfX+Fz26WURTWMzeVkEcwAMLSKLfRhPqGSooWylUOaAqYuuqcT/NmnsRMc13WQRl+UMYA9T768VMaAVihyKLNbp4siY/SZJm0yzsOB02ZkLGKhA4zNn6DSo2dLoc9zB9MWiZ7rO+TIh1oT1/5chNIdoVSYCSNckieNye4DxUKoD0PDerRF6Hldsgqwex7G8WIrXErt5LiY9bo3+RGdfnrOyHMDYWmxVo8sNKAjgG8SMymJkx5OpSplXuS/+v6vRYRPiyCQDN/LuYkkeaJq38uLKWkUoc/kH97/VV4iOgLWgoiljdlNkbKj/aVG+oObeGRPAhude1UkfnT2RXzBB1ujLPbqSDq4vSrdilTtaoq8SIYAqnGf8RUlyD3kV8KS7oO4ui2OhzBFCJceabHgUn+m5XEbc9H0rC4oCrFsbRMB1ogxnoNp0dIgudRfTb/XEmvu1PqrsXV+/2/F3upiIXVlZeXOhhkxGufr1tGLg/3dVkjkyJgoS0Qm9ldrtpbjfpgGGvdAaNzElVE3QpnuMCQZRmFVwwxMvU4YhkX83NO8BSOGTlK4r0K8YDqZ1BNf9LJHo7kkXCrDOmEZBpItNJDcZQPJKQjgzlYO2qpopfDhvyPwrtSUaeUjAP/8AXglHYBXhLWtDWgBhPedy/d/77r3D77rPwORyti7xPTTMpX9o2Rl4ZIVk2nziGmbB9IHtt+1a5octs8dfxyn2xJilRdYSWgCuUWVhEWkHfEn93QSQkmLKZl9QuxaSgzfogHbJMxFo15KiNMGgzok7p1jspgLEgmBGQ9+yXBzFjnqd+t3ppnlMTzzjT2j5ZlGV5B5mHWg1dxOpwc6mW9hctufaXmKB/VY7AoVjnUw50IVmd5MCzbdhGG+ERdZmNkPQAEn8vmGXaCX2eAyy49wTnhIaXbW85LjazY3sKa3PdMIU51yZh3YFPQ2m3XU3KtSsLMP6hzHt2GmwZmSmPmGIVua7UIvyG8vFqiKMUnzrUaBmc0IRKl+TQsZZPZC/PRDTDY635WU6bgy3zAL9XOna2kGu+P5pjBbhx8UBsxtf6aRzmgZN+uw8/HSbEZF8y1Z8YnOxntmWu/cy3CTS/NBjDa13fngMNVOpPgoq0X7KSo4uSPkT9vW+DTvtGiFtfR33uUnNP54co+s1B6PmT0e+JPM/7HS0QElFpQBJD//R2NjfbURy/+xsbL8mP/jQT43qfk/ViLSAjaJ2sWUb5h+Axk7T/xOpBLCiBcWlhkkSw0XTwuifu+HGVmL5QVJKIVMIfM2R7HE2T0L3cQa4l/+x/8AKzRFKj5XapC7h9ZQijpTK4fBMG7J8fE30rsS/WShJSQFt0T5efukXBW45uQyXBU/cJWqSjRyc2u4SA7skX3ijrwdr4uzwtdCh5ctb5OtGUXOHaFVEsVFxvS08ODC84dO1+l5Pjw7nqCeBZ3luHH0d5WhXsjBMyXirHRVxpwcbMElsy2oqKVNYVOkmK4P1f4BAHWMf96Se2OlKsYw6A6afOGlVpUtuT39SFjx8DvcxFLYBLnbqrC59dDNvKfXIrY6p+Eu1CP9n5G7nV4tctrFJTDK23otaEJl7akd7hyeGeXiLffvu6iV6W9uYBUBQl4e7W5jhsghtG3J4VZuv5N15T4bnUdmqrOnADgKB70hM4fKS5Y61pdzDTX9tTEGcyfZCfs+psegkDa/nfZe+6T900xRDltlSbjyvTdi6LwRlHXeKtP43aHMw8ikdvJ8cf7f2LQryp3cWBnzmGaEgE4/qk1OvtDhdMDqOFEqUezrBq0KqmiXaI+9Kj3GEEzVer0OuCjoer7TQRMrsr+koDrq/Okm0nY5fBnuc9oRUggwumV7OB16r5ChCjVg9zp4azTD3sksgnYGa5GzLz4pa8fYc7fvdIaeWUVNV0WLGmO47/C1XgXecFmMx4ZY1GQKLOI5VJlw7e1z230LSJJ8ewnjYD4ReCGNnFH44mBeI+etG4xp0IImgDbRmPyGUR10q/IjGbvYNBc8sr3ROsnti9RM312KSpAOeIl44RLkotdazsYe230nAKLm2nO7Dhfke0+Fa8SQIEEirsDpaRl3HWOh9d3X+Pe73/7mJnJI8YziJHqcRL1cvv3td2dnFR0H0un3UtqVzZbZIgC+SLPtkf0OW+7En48BQF5D5Q5ijPAxytUw/VNZd9h3B+4Ymrl04GwOL8dXADfr5SnLmwy9Puv6fuUOZ1pVF0Mo8lyyllZSFLMsqtEqoMExwFfnh/E7+PHG9p0rbxLMulAcViyOYZ+F9tY6673NCJVXFfHorQx09xzwL147aDB+crDT0ineBSwpGkJd2eJViaf0qgRNYqSOHluhI05B2++q8MSROx541CKmozp35CpsTYZUxelxEGcPJobopF8RGL6HAgkKSgu/vrxcZ8pL7eqW3FdK7vUDRhbBFuXW698qlkoCes/kNClkCxRPrGjYUuIVQtB6WS1TMlCaomt5qEyvIqnKVOp8BmZGJvrUsAQynn2MV1A6MMUn2HJL8hmDuyftKc4VLMI+3wQJuiTntdJ3auQokzBIev9vUYyFL4SFHVXuySx/4f5cOq0QQGJooPhTunJt/Wp8udIDySEmSA8eV9SCzscDXEO5fgxK6WQTCn7u29cKVO/HMk67N6xMD/T/CM250JwFen+aOH4M9tCH9d08E5LETZbNKq0u3aFUrNCR4/t2eotYqlCDiWt3WtuJClMWN/fMAWmRdeQuE46E4YlTgkZhQQP3feYKJNeYXSxHMc4yQ9emxV3LIi7C8GvJmGUfcesY6ctHCs7i3xSFDQOWhYQhUNAt37ff1d2A/nLJShgvTcXMy2zhS/NVU3XFXetYZNzqlBBpEcItNfhuJI4vlQgTQYbh95Gj1NF5bcVRRyOo0bRU8Crf9+QQ5bhhVaKBqtJowgsKJ8qhqlD9G4NajjZqaIfRrRIZ8wVThWGSqOJ0zWzuhoQCZvUVTKTPOpJvEID3GvmLMJdPYJgex1yQYubk0yT9dzLeTWcLzOnf3ewu0fashmypFPd8Y0tpdaZR5VFYs44s33gk/2aZbxUyZjHTSkzBIYsaYGzyH84QsxufDaBSUM+dB/ZLNWNI6v9XO/Zk7A1I/PwQ+v+1lc219bj+v7G+/Kj/f4hPuv6fY363CA74Omxd23Ax4p3zO5FhpnsPqv+o+/ji1P5xZ+bCxMDqL0ftT0K9iN4/qu6PqwQS6WAikdaT2jd8Euq1o8rszjXw4HZBlXaq4obwrSqoBi5Q3B80I8pbeMSBljGjMGYRdsMswvjRGgLgBZSGgQTGP4zf4SMMFSxtBoRvj2Uxp+t1JkPUdbuejFZeqYikEtnUV5GRs6E7Jil5VL2rEgglFAz6nXj/t2iaIKIHjdY/n1nxbixoERW0HGNcu34jWEPVFOUTT+w4fRd4OGEPe+Irt98v566NTHNUxm0ylO0y6VG4YktLgiIUwxpMBgImJgJ3MMLRkyqTm2FrpR6n4e5RrJuvfDtw+xRax3cufVu3duGiAaWwvreHUBMrraxdYVye/Wc1B/UlzoWDTphdDwOU+Rz3WWrElnQrI/uSe62LXeTEYXgcC1p2f+7DyK5ULB5P9L1LT2plqxT0R7dE2XVJz/P+7zJTlPBIURTfdlTYXk6UZnaBoERGAFrzn2yaw82ktCtzWOU2Cn/KsPOTnouZvu2KBNc72C/EsVEzNvBsk4X0FFYSxha4kBn9FLM/YJnZkuOPhs7bcT1w+phmoy5tReoBHtmOh0c28n1gv3Y6/MA1NdvhGaUjLw0X0ua5SF1nthIvof+36bEeRfrYqjK2eOQtP4rrBe9fJxgSJgmFYEutT4I8+mnVgr9qTcCvRa8VU+DKFUiRuKcAcCgbIFessQLl+xG5JzSzH4jIPf34FhW8zytCl5GaM8qqt/kS95+dyF1lRLx2AyigE0P97ndm87nXtyLnvxTlZ1SCslf0KJWHB4R70J0Mr6QNzeR84AZkDsdJrCxH/UZDdqb83rqwyoqsZoAICDx6NlxfLnAvHK6RZSVjtKiz62U1injGiyKKhCRX+lC6hM9mT+n4IKqE5Io8nDbhDuqVRVjdZDBF8ZeaNZrXKMf3xo5r10zWKWmes63S0LZlt/cVOHPegG75EZcjFp864JWmLj8MUueebB5mV8ufT4A1rjG2zYOPkGb4CmsIiX1RetB3xvcU1X8Wbb0cror+Wz5UyYyBM7/2uvb5pM8eTTCqMbDVZAMNSB6YOltEYAbtJDED1Mju+fK2iJshk+30isCAveLblaVvVyu0NHRVGHKW2TI8zUOs6CS6o0xaCHleLBBeyR/RT6RLKhlMIIlhLjxXwNYE7//p2umLPqxlHyDbF54SvSBPSBd4yF6iAECLBOidHbKMinLj1d4SehgqR7Q0ch5eOKSk8Ona7aAVOsc1xpxeoxGuhhoNL885CYAcF/rtmYazKFm5nNg+iVlc6JwMc50BvWApEM0y7Aym1gewaD9r/Zu6aH3P2gNPJ7Cm/NEUXBmvdwwIjeORYibMf8mppamrPsqCLJVEjAiNnlfR2bjDPtsDIiNpVepZS4A0IOzPjj12rGllK5JA0fABOMkOdpyg57RkOSnONcfwpbCw9frQe2NVRC3ysn7pjE/cgWNVKmJJrG6QZifeC1rG+x5K2GItI61LBCwQfOlD+b1YWTNIbxLqtoGr6l9JKlvPmUTAGfLeiKxX/5Ci3toL4Hfr9nlguXV4UAnFvfgX4HMqWR1N9icHtC99RHh0RvpvvRqqfHROuhW0/h7DYX935FxIp51mHBqMUugYMAxszjMJyKmYVYtMKM5y0BoATAzLy8A5f0iTk96bZUvxQNqLIL30fsxLU3FDNWgpsYj4wlg9BeFmtKoFEVWhOczcqVvuRFWFwP+Loat+HhKkV6We1w3Diq5UwwwQMrOEScxFs69xAUw3UdCG+mVqkmxqXpGOvuESkWLayYWjdNb90IyNzRnkTTGiUS9pc4WE/VFdE+e19nSSBqICn/mw64683ycqpwOcfW5IBF4fMxjjIvjOteOPtWIJqMc+KdulHhcH+P6v546LlX7ETLFVTLWNyhaMmQggiyoC1ozJ5KLCcpjm7EHTFehg5Pm6+aEtBvCuCA06P0Z4PPs/ofT4RrhBh+kVvClkRuiOfWkjAaqUHgaurioNunwTI0lENiJRVaQW8HY+Nww0EqhR8pRJnpR6G4qJfW9MFMkOFZf2Gl/gFXtPpuKN9Y1YCO/iiCTcjwYjEu1AnTzSJO7rGbNKwxUhRgBMQewp/PH6PTbPIbwTbpJEEpgDtm8TVlDRTAf2cGL352dL8+jEFKaUc1RncqYpknZdKSZtx+gKKm13yGd8qeVoLDAGwrYMXEkZ9sPuaPgqP6C4PGlGky01N7N739AMIypS5qzDwytuJcMVkbYnE4THlpDcaZ/ZcMRRqqqHF2PQoxJ6Xm2URMZW0hTDewi+tki1rSBYRs7aGbhoXYOe71TGhHdgaq+dHzlPtgHE80nZc0RZCXm7QaFQeSkAXXju8pXZOZ673cwqXIDv9IiR7Iv2W2h3aC8ZHOQv5MpOu1/vKgbt6gWrJRYqUxJqrPKurHRov0MEv+d97wb3JRsNs5XPTucaQ+4hLnj/d0w4J/o8XmFlA1CFLZkoW3z3yr6GMytDfPbCRHi4NnhHwd3z/m+XE05TdeFA+R4rt14ApQEYCSMWFqJPw8toaUns7p+0nx+13v9P7//7A3HY3t9pwwOx0xbbB/vPdo9eyDc4CMBytG5w5ZHojq5FDn8hAOpHnjscM1kfSuZogJR3jdR/VUHX68juj1wUDynrrREMCMkS3+sBEgUURjaFSoM4EEOgzSbv/wbPHR+99n1l3tW9mlCkDWjoENaAeiKJ9PD933ltL+wfhXRFF0NniBm9tLEY7AZgc5tYkwFSBCwv9QY4SMTzmLvOBwrgTxN7iGJSCjJy6UsBKaaS01OFucH9+cOEZ9U+hlXEMSAPAY1R6AAJmLxG9giDmAx7HBRdrx8MaIwWoNAG8kjBmIgbZW4uLDpaiN2ZU6xGbwogNmEZpXTbplaMu6Eas/azdSO61fDMVgjOMPrlX6kdGCVWkizSYNKz6+kWAcWomQ+DcJCpz6P0Q4IaKO+auz6SyeGa4abFLlulEddic1P3bZwNq+dQY1geo7iYYm9a+FDkrSPUwGxHdiccQ5JUy7/alaABShaUMtBMLIUaprAHswsu1+MmWTHs2o6fUTqffDgxG6NHGgGtL6KjLg96uEF2z72GupQIEsaETTgoH0A8jWkd3/+9514+Is9H5PmIPH8K5Bk3JYrzNPl4NBM1UrM2YcUYt5WNH5G1cgg7TpektLGsHnBElHL/6HL9EV0+ostHdPlrQZf2BAXmOoc2brViMGG+JquchiOBC7XZZAOBQIl1ROBhBHOA89oAYP0KpoXHe+l6BVNt+5dOkE12sjGdZyrRp2FWtoPLkQWYsyD8yjXEoXIVuke8uhlPRP1T49UFBGFYvWMQhjxXDHPR7x6KIaOHWQMyZNlYzjfITIP+R2f/IvEsUjbljiEtcmwjZx1ltWCXaS4ci4Km9OncJSNajkXRfIPNbX/GkRYw25l3sPld3BHqcuUe9wZ3hVmJRUFj1jR/YgQyzcplLlRSULmwsBlM07TfcTIPDyyFevyJIWcm6vEnHmtxpekHcxyLnqCZBjw7xX/n6SwyFpEZ/+fb5U73yum+9ibjBUX+4U9+/J/VzdWN5Vj8n/XllZXH+D8P8bkx4v8oNe23yxwFyB2+RhwZQjCy6t/YcBUA47zQaD8yS0BNgd/CI/5EG06N+3PsccJuzc9tR+vcR8Sf4vYecbMrGdEhxW6KvMXJaTDXporcH9weIZgtYWGlunrGyUXqY98dQMWx93I0cvxtmK0VRgilXA+Mr3R9foa1YVWwAW/Pe5OsGcqloCZXNB5Jf4XQssvpOxfe0DE70s/kSIEX79tdx1p69Wpn6bKKz3R9csvRA6XqOk/HNmeAKevCDiDifrQwP6KOdFykj+RKpUUFkWsYiwlSrhhr/01rb3fn4Bh6OEVBU/n4L/utw+N2rXV8vLvfOnl51Kq1j49rX7WO2yy1yiqx3To8yS/x7cqU92vZ7/fbz6eMAUvkjwFL5I2B3ueM4fDoYMoYsET+GLBE3hjofc4Y4M6ethdQYspeQIncvcD3a+VXw7MQyCSY1N1htz8BhGMpqMvwyvtO4eYwWE5T/OZG1rr9LicwiyxT5WMdiZxS1SewSmepKg8JRUhJykY5atHYqRH2ieHbbzikkYNWQ77twtXyru/ZvfsKjXI/5nQyNs8FGfjXOYkU+r912HrtA7Ce+/XESyFvF4QKdmTBTHOYurQLv6uURIVireNLKKo9/qJeL+p83HKdEVbv9IED0MVwseSZ7ahFOzza3W539naPT+hu+AYD2gE8k2dwWbUl4zZhQ43bqsrqgguJj07NzjrkZUi1jHGezWVFL52TazKMVOwwKjPzSCzYQ995/4+k5DIJvezDOXfwlwwlxT5e0T2bNxNIUdSXeRRQDeXD1zC2939Fr2PkEAfnnMfNyt6jKuk4YrvEsUEAbj0/6tM9ALrUPXf7FPavgmQv6k290IbJF9bIh+HgJDGFGpMRHUnGrtSDK7GkSvsdxJrDTpfFpB68rIh91A6j0tGYYFWE4AtYfSC8QDQ26GEgUq6Mp7RzpLtFS2pTewwDZN2k89YGBse9tsk/oOehDxF0OxoHwlJqXa/r+f77/4qsME6/HI4IUzElOy5jYrAyz67fuXDfwmXiBOWlY7hVRuJbdAHvmXFRvEpdHDAZRmae2DpCvEAXa1KE686DwMFccZcuJqRDDwZS0w1If+xy1BdHut1fuJcTpVtk7wXUOymYJjM2jP7CO0PJJ8n3G2OWsaM4u3jbRozTS07MJKP40RbhwsJlCm3guuKm4GK5lxT17f8MRNe5tFH3aej0LxA98ggZRBFgA5u17zTKAc3BgGwaqgQXHgrpuicBav6HlLRbwWkchHGAA4pQ6TE495wLG06ysBDePH8sWTcMdIMRDOUBgskPSFMd2u31nUqV1Ps9x30LO8yRDoE3voL9RGzUu4t7CDsbTInDRPE02d8fCn+pohx9WY+hx8/jzIvWnmcQFlJxrlB8SFpxj4C4+cvvt8RyJJwpbhJujX2I79HBvCzzcNloZ5FzGViwdK9eRbcJftOZlEimwkH5EuSbxL0MTEPSxdJ+oZoxJONM8AQmg4GWEKPTN1FUU3zHCu9PxHc6yx+fFD5HxnEhr0MGX8QIBmj+5ia2FHCNMTIkZBV2EQ5QG7dQwSsAssnARG0AWBT+lScGcAdrAPtNOMGuh1Qq78T+wYv2scogl8spNUWYELENmIRkewX4p9R6MKVteySlAVNZrCYuQmoje97l+38K0NphKh+W3cjh+78HNQ6ZO51ZM6ejsjIX4ODSqhVcBMnjRcdvtFFkDSQfmNlGkSXQvKI5l0Pfu4A7Ei/qHGDQTGRW1YJLIVnN6DRi7RRZDsmS5rZTZEk06xoBckwqCqg1cApwtOkVix4P5npjkG22Uuh8MG+c04qxFIA8prjzKV6XfyF664z6NqZlJVxzKt9TiuZoWbosmoi3AucZ3C9ji54o5zjinZsFryRmtFNstwpWTzHuYi69aAuaqw/XoWhVEgNIayqUBRStR4VD06q04Kpsd1ajdU2EV+WXikdxxAsHyDK0PruvgHgPEjuD1TWPYoOHdJSPJzC9UTnckeM3tgUZ8q7M0q5c3LVA+DfRc6QLyvDKvwnPCpLXGA/9XadHMYV0pCYjoNIn4tONNdKIoeB89/jgmEYHtHIA6+JYy9XGckU76J/emNGMIoIMGc+ooQIYyWi+ROjenmknfjNmENtIEvp5VXpVErcVMb//PpuOFhE+EB/M8cEOpV3mPbnuJ2ILxcQOrSCYDBxJ4W7L/cQAobjlQNmrzZZmvkzocmJeMZoAwIhr1wcinN8Q52n33C6JCdiEG2l3oIBf0Rr5YR+BY3CRLgCeQF404Kh0M8TqUAgIEE3d2OK66xnGsB8EtvnKsX2YuMQqu/vPdvd3T9qHrb90Tg7+2N7/2SGVVyV74E2GJDYEDEPhxHx40LN0zL7MC0zdkHxKn4oGYAE4ghy8x8eoX+9YGvnV0Z4UU8q84HwU+eXIfcsvu0CbTXwSMtJM4FHPYcEPrISWaxYeVkgk3d5yahggQ4ds/icJMu54QDXHtilxdXuzdxiTyWL/dxu1aoFJj5mboGqqDSLZZm+DqmmJcBitP9bSNIyomsPlpThyFKepqrad1tt5O3J9gna6aIwe3tRH/Ulg3VwB5QHXx8rarbxlrAq1o7H9NNSOYZVr0OMUg/fnUEwc6mKLxuN3iG4Wl0zBHGYMDz5tpw3xkvu2zqps+gr//7L+g0+XdVZETXMBhywCJLOpifjTkcCRk529e+Hi3cSEWkIOSuGuhwAe5aSqL+kwEt75QvCAJU0vR0r8lpDjV8OPFunApdOMF8GHscDeJLtsSuxMrieE6FJYMH4bPqlGeLZm2ECUM5Osl9FBJn+V6Ruj2CfVQiqDZHZBWCmHm3GICUo5LJI7IgMbR+3vvbnXzRlGkYnk1Ls+JYqiRHbGXeyNHEZJtCQoAk8Lr4iWOumXc2JZfY/DuKiGQmKAgeBb5xxJtW+v7HHQGo0WHFcx4V0zfVlnCpYOV4QO3veq5L2WV486rFHVpX5sXpR8cKIFzQucS9KRZFKFi9CD29iFIo90tDH5ULVkHPvUcvgiescYHIUEMrUOEkXLxOdpm6/i+CC8RLdfW6AiAOAdRMa91w6ds3wgmCtWfBhwZeXTOcUF21+3Tr49OIjJC64bS3a3i6RlsNRYUqiLllAH3DQQGtSSCpSHoPNhgB0YHXTYoVspjQqPzw4lBz9XGr/Lo2FIP3R8ShBWFU/Nk3Z7+/Qj8d/+07/7t6/gCn41PHYmQl5vT9MO5FMo8w3fkE+PfhM9kECkPXPfOj1rJbRye/XqVamO/1T5n1IFt/z9fw2ecn+H9iXQCNcuEWBw+Y1c8pXUXnky91iTS3+XONbf8Yt/+ff/l/iGzIhYo7yyxsGZ66I1ev/3AMN8a8vQYCJJDwqb3kWNc8/WSuAua24/UjwCAWcnNNvwJuNLj+wkpAHGtSReyc20MGn6BjE+QEOtHx54bekpbwNCDLvD75G0o/t3iA5MfHbuOx7T+sq9ShOVKOGDYO7vKYAXzulPE8ePnd8f8NE8E5KGQqlTSUoLT09fldiIBw6fC/x09dQQDVZjgsGzszMSp03HdGQdlDoI3eFZgWb67sAdd0Z4xvrO8HJ8ldZiY8GB0q6JOcFYaWxykSPv+0YWFdL8VrSVtOyebY0WkmhqvljjQqb0oqRPMko9b5L4QiyLeWOPy8WvsfwxTh/L5f7D+7/KJV8sbXyHPEKPiO5nQ/qk6EziCo+ZJHMYxHq2WqHipXCVUDkz8M7dvtNBIuwu1alvUz9beLwL0aVMR6okMlQn3IppE+4rEnKYJasw5zMTMyzSuWGgJpGCHEgiHIhcOGOutpXyNO+Pdn5y6eqo1irkMxSymJKezOQzTZpyW5pfcvDKB2E31w00WyzGRraP00y+jrlm/Oa8Z/fSzGp6pvHNZNk833iLdjVj9JIplg7zjTmv+Tuv8zSiboHLnKYunstXN6qsmG+kmW3PtrLZEuI5FzK14ZnGlitmnW90WU3P7jqeLwecdZTV3A6LyxYWdwhyjttsm5nFE8y5kSnN3h2FZ9qHLHYfZyWnFrebU3r7AFYuOvZCEH/HQzuNqLrzyKeFQvhVfiLxHxod9EQh35tFBoDIj/+wsr65uRKP/7CyvP4Y/+EhPjdp8R8azCy4w67vDXUSTWQXFHhoz5F/+R8pct/4DSzPQkNCSLPBWjcm7FlYSIh0u0TFLUWwaIT5vo84EHdOvD3WM0iyz2owxRJupzG56Bh28Md75GW1p3ajsPxgYYEwZE5Sr6sCPeBXKI3fjVgN5K63heXqEXGXjghhBo7gckpWFCuihEkd336DkSywqJZK5UeyoFCyz9k9UXBKG098sr7+5/Dzath3jGAZW5HuZJZf9aiOOG8cIBBZ5fX1cgUTr+qXShy9JRorylopbLb8CSYGUg/QzEg4fUAakfZlE1vQRANnlvZiOa1tGEzh1r8QBZvA9aPFsS+xhJKRD71rSv2EbeNejL2x3e/AfqDLdmd85Qaddw7cDV+goAW6ilW/dkdYWw8PmyC7vqBDunqot5qohFZPaM7JMUfSzbPMKAtm8AVoCp4y1iJJJPZIoJjpToGOKjEMGjdCcoSK4LVDqXSBUiyE7+4elWFu7cB0K4mEwcH29sHL/ZPO7g4UJj11F0oFsLvdqy9/0MZLaq0fJGXpogwn+G+2+i4BFTzt2vm72ugKJhtXEsnL3IiUhsr/E7k0D6qh02b5sM7v/zOsqY8OrhQMpaN2cQs3RfiOjA7QI99m/51gPUWdWAjglXsyuLGNPues8wgjUL//53NUo2BlPX3reftEJAFLfkMzmzggVSnbZh/t3QK0zKJ24JwMsBU4+Zy92YlXq6nf9UGv0kSn//f/PHTR6XikZx3o3KJ0RinBwA9VEXg+etGjppdjAcTWJuKXzk62aDxHfuwYHl4FAJjguvgyuqOurF2QbWTr9AB4zTxYPtfuy4yC7//Gzg3GLl1LyxE0V4X/n9PKq4jyllGUMsbgjqGFuje8writHoYqx9AOInB84V4OPfKExhzuw67rBTISAHk8n9tdOD09cQToktGXXPpKVQzsANDm4Bxj4NNaoBeyQyY7KqI15aSCe/X9f631PfLPwIGi4Ykt3MEIyBuVzoGcpCmXjQqTTcHt+5deXRwp+MOzInvyJcSNzQwP1TA3PLpq+xNNWw9lJAOuaPrucybXEAAotr9qkuoX8Q9J1VsPJ4NzihVYyLhTms4C/N/BwnM5FWEl7yzESbUL9JuIYaZ9wy/em0Sw0oeqx76Pm0p6C0y7vWMeDL+OC40mW+xCaxPBbsFB7yMGuXcN6crjzfZ4sz3ebL/im42QU9GbjdDTgl0XtNPUygdyr/2MLqVqZg8fko0WShGUpWjUubAouaB9JrmpNLfJWUkP3RiRdh0+mHdtM2TRdbMuqrXg0rt7o6FQxWhWusnbY7huzydwXZNLDLwY25cq4tudZ2FfYk8kuClq3d71HQyrKc9OHpHD2kQu54l973qKOdKdiRvtYta4sxcmiWYz/TBRaicnzOG+ZGRgkoceyMo9F10lhcVNsGc+Rt81EszzHTegsGp8wfpeDzAtUg6ceUylQsL10+LEg5fCqbEYTsZJG6rG7L6Ai3/YvcL0ZZO3HMrO6fKlxxnaxugK8cPErYs9uPgQqfMIhXPtEkFCLfrYHsPPGYVmmwwoAxreyZjfjdrS926ANzEHeueAdDB+Aavs1VmOSR18SdfZl3UlhlxG8a58M2J7qi/rp8tnX9YxgrGKehYuMm+FLAnl6hQ5TUpiWeAKRE2Yd0yJv1EFo/1lXxUlvF+Vzj6XTp4XMtICNQRj1j8IHhLTqqgxxMYfrZaYCOFb8tuEXR/DDlrolHubGRvXaJti3qZlBEPb5P61U3NT9Chke7K7Q2hAHcqCFu/z5KCd19lkUbyr4aEml/FnxY0+XvyPF/+DXfytk+2vk8hlMuoVvPlb3THcTO6P4fV/Tze/9oKeG80Uc/VYmm9vPwRPkV+No4g+QUpShHGRu450XW9Ih/ZYETgYc56ptPP0MoWOlqdpeliqF7YPJEtoBdO7p8MUGvRnaL92XxweHJ20MMOwxRE/jNitVSYO4QEMB6VsQpmwAA0V2O//qUdxj3WcKQy84Qa2jBXSc1VaamXeEN818dEWhhIDmCAhBWdofP/3EfIYl759HQYspihX0L+0hMHwJFgI6Nm+542EDEZVOCdomgXO3VJIKRMWc+/yLQerGU0W1JkX7+iJPn0JE+2cTmaz8C2i0J1vxNO6mGm809U88w02t/1FrGy6ZmHWQVenwXYBtuJedjUxvXl31xR1LnxrZeN339csYcrPfD9TpnVnK/Osi3K+4U5dkrvvaRaZvMD1Teniw1lfwxI+Yv+90ul7mHsBKMWHs//eWN7cWE/afz/m/3uQT6r99wrn/9OhuYEWOUK7b8f1KDPx4P1f4bF3L/bersyOK18vzNw70m6uubdMa42JYt3elKAwj1bfvzSr75y48QxBEdNbFWBQh4g27cRjL2WUhIQluSxmBCggW2IlL+XnOfbhKhI7KhMoPn0oFXdGsrHgyh2N0KzZ7vVQ8d/pOWO0KviyDk9Ryjy9fSH8ic3Dz25NPei7Q6fBberqwwnM2JulhZVYC+e2609vgaTT72JVu5TLaWpVN1EROd7e1D4xSoFcQ6lgUCkDgIrhymxePnTGnTeOe3k1xtLL9XVZzu4j0jGho8OPOt0Blmwsy4J927+Ml5TPVNF1HfZyAGw6WVpEihvPZZWVZTNQJ0yrC03qaQObP+x1aPw06NwI/mRyno5sJWMr2VlbItr7NjOPCVOy9pCUbRS9+9r+0UVLFEOU0QtT5UjDoxEsCZRFwx+33xNj+7xPmW34FKJXPV4lrJ/r2gFbxwQuvORA4Ip94jxdHJ5tx+ui/E60eGQwBESFPTYJukMI8IHTv/J8DI3hobFW/dxnFc4KvFnCdcCGl7p2vzvp25rH+EmFpNGY4C/ae18fHHXa+9/sHjyEYia7yZeB49dal9BqWoOScFpq1JeFFUzQwMn51zIZnFz5yv1rfy58b6BUFeRL24/G7sQVPWq/aJ9gDvLOdvuQNRFS6zH28uqyRF3eMHW4VyJ1RwDI9qXDMUMJj7wCYEEkZwYYZXx2qzDjq9Ibtze+MktIPGYUYVcfs4yBvMymEr0h4r1lNa8cpaSHIqN0h8EE1fgOJ+9MxEMNUaHRGayB447GOkChfuG9GXau4DDrN2b3AEHXgBNlKJtGdaW6Wl2rrlc3qpvVT6ufVQHDNxrVxkq1sVptrFUBizc2qo3NVyVDVXSnJJDA39QugKyJo+MXhB7YtVp6WyMr9AyLTsmosjA/j1kov6UlcQJ7FZD9YA8jUQIe7vYnKOIOmjB6HxmUQFiwthVgWVo/TvpiG0DKE9ZmRZF+7T9v771U2ZcbVbhHxOaZJgy3Xx6fHHRetP7cOQTEs7PbglJwSa8bDoG4oF3PCTKNVlRBzoSL5VSVOocZtID4/AKB4iM9mDDHb5eMMn73O3rfrTsYHVz+7HI+PP1LJxWBVYHTN6zoAOSya8PdbjklVfW+tJIdR1ZVyNTBoucijf/+n66dvnRCVM2ida5l2VVxXoGZmPmQbB5iRdTMp+fyqZkDG+EIlkY2eboc7sHIt3/0OvI9gVt0ovWB/TaaOlAVNrvEetzr58r/D61w+1c4NW6XXlxgMk+5s8K7UAOKZANU+QmN9rth42EpGDfudvp4sSDuDRf7vTHNStSWpufaQcd3epMf3R6lHjQWpMY/PjfLE1XXoWDjVBjHWjMWJqXwCDGbi8XNykuxruWgedjRir/fSh4VwxzHnKde9ZRlAXJSVRGqBgBrbpXf/U4lbTT3I6wiQc0YjYjsfPdz9fzWtAWaGi8/ekqICww7DcPIR0tx0PiwnMHvJZOJxeegC+L2w9SbuQujIuUbXGpUkxqju3WqDV0hnV8t1MgUhrZQG7p8gqEtVF0VjzBehWpi0RgbVqgeF47zZYWqytJpjFqx9Q5rZHFuhdqJ1crj7AKn75CKtxaF8RhVcYzFWBV8klZu4TnaZnbSKsQendt9JAt/MTzRPTMwubLGLgYZrEVWNJsI1YGtju3+fVlcGHEr72y4HODwojQB8w1yniQpqSRSHMtTmXlKIomgND3Hnf2eW8nIIPMdLRj63kzQg0ml+DUXuM6L2hRHv/nNDbVphJe/Ff/AtD+/pq7M1+gK1LWBxr6kxNnwlXJyGwl7k6az1EfHe63SUPE8yIo2JYI0UV5jJwNSZGRInuWxnuOiDWhXZ5fOz4JXcNl+MUjlVypokZy8FBYUPNAJ8vFWCQa03EaJESJmvFGpDWao1aaq2rQ2o/BJe6/97GA/WiFq2But0H7R2t2LlFa+eVlCpMNnne39wz9E6kjBalYf+zvto/b2QaRKzDQ4NueXL9pH0fLAmo6BRM4a1let3aNYDZTsZ01id6e1E10kEud37PPzrDG1j09aO9EeCovcwjGhogJIeJXV56sjFPaIuEguFSwKQl2ELs8BnILNaRI9d8MLNqbFif7EzoOGWZtjPVM+vMzaJmuesiFq1vZYHTUN5mZtlXVVU6Fy5sGyuLcw3I58rzfpjgkgTlPAVwakLD6SkEWNjOOHiT0cy11o6KeToTu2YXSmQLdgPwmRL83qTE7r2usDZMVmFRFzF+wmVxBesI0povKi6GG6ML0ovRqK29V6FZe333V77iCR12/G9qXcSv4x6+mIwSQCHuc/QxdFWATFSs8huge8Wht7tZBkzOaaWjLJsLA9FHn76Mt4306f90Mgh3pJFZr+kVr+uVLLJY6HR8csVCPyiTkr7vgcAYQc9VW03P25PN0v3MNuYtCJX47o6RHu5Z1SCGvr+2XGU6LApta3z514DKREz5SVoD3GZMLje897d3chG60jO3XfbQ21/E0drykpn4FL7752hxizU9U4VYM4+7KuX6vIrnkKI1Uv1AxR3VRFUbOwYDBFwWTqiYo3pNVK2YqjGYigXN3RbGxqpvqoOHuap8cgXWd3XFP7kW6kti1TZfZC0+cFSxpXVmYXQt/Jh/YYU86LXd4q7Y5v0q8fwlXz63OPVQCYYmmlXinWIqxhQH2iivEuVtGgPDoKLUWrq6ezeNIG9rWTeYwMg3oAwGu74DG6822z9gEFtwrzMz8GurgXCbw7PPfeShiOz+1b+HLcOjzs7O5/dfBn2hMpkMDwMcrIMSDpljZ5TAtQEQk7AZeKPyCHLhawoRJLN0v5jCNyjkiW6P/2n/7X/4846L//a5j+OSaXffqRoCTRLBh7+nEakn4qLjwXQwmO7O4VBv/BBM9Ps47/0zoncVanrhkpKpEL5os+ZKqBohXpIkQb3N6SPZB4/89jx1W5pVsoMrKHV3C5R9kaX3akOBv1eykNp8WFI4UzO8vpezFsE0kas++NWYO8Ey18bxhnrbgfz6TvGCfcxZCIcIxSzzclAyb2Ea5xMykw/d4Nq26kHrfEGo48CmwPCNu9vExEgz/kt6GfF2p4e7bYuMpfvQC48x7M6iTS6oyOUJsPSAB9KVM9b2ES5/SbuPqq9NEW/QEGrBoWgwNN2m+zRAOKnP2OEzdvmWmhM5uOHH1+EvH0MWun39tnvxB6Le16yDUkuXTQP5Dtj9y80B3src56hgADwp747/8z1rknXKCdTopDMoHMiXcMV+f4gBJwljAndCHnvQAr1VjIEDe/wldq5lOOrup6ljOrLbhnPrOzScGiZOWjFOznJwVLyRfNEAv8vJTOBNHkyIUEwZrhqPW96S4N2ppM32vWHlS7p2jf2iax+OFIlXgZQRSPHNiqc3doq/srMJyx4SqoR2grLceShCM2FJFvGQI1WaSec9UkxGIdSlu/xc2EgjFtp/ZRpGBFKOHYmWH4zwmdMUGRWbYuH8eyKl0DcCfLmmK46Bupo5XhLc1yp6GDQR+Wr0NNY7BI6qIewOFzrFqjQhUxYLfvEgo2RH1c+0V7/7j1HP6BykTvl1HH7vTKTRF+ykDz/3+jND1mJVJrTll7PhFlpulJR49xPWUQbltFI/2I3VDL7rAj7zzdCXTwH/9jkQ64SbgCx+oKrIv3/7E/dgcezx2If6wZLgr36U3GnQtSt7KhOfQMff77/75In08D251wLm6mmWxx5X3vfPRUPEOJMzAb2G9dzk72YK5g+V/+j/+h6Oo9VWQZmlGLYIKcsAdd/Wli9zH8uui9/+drt2dXyZV3APQABWUtA/th7KpKKQ6bqjf4lGHyTOaI+kiVicN1MZdxc/RSxMntK3mnbD3FHVwf1RldwmPS2OiJj0pb1SI29fncMndGfCkaojnF9ZfTSmdJhHTW6WPu4P4kq6F579yMxaMsKNbDoyyosCwoLgYKcw3wQZ85AriWgnAIwzwZCFJAtnhJ5e5Z8hpaTBc/bQvI2KAQ1h3yNTRSYTKx3G5Q0wgwttbP4N5pywEsOEnD+uys5KNW6OeuFbpJkTElg6UihSsL2Ia52pv62Ns9PtiBo25VZtHfDGz/dSaIJwOQKYC/b/uajcIhhZPJBCSLJNmeOrErUeIfuU7N/AT1gT2yXHRidvMYoYry3P7K8/qOTZ7WSW8XaLoajiEzVvwAqTjiXmtQI87B4kux5wacsmh3JyjEsd7dfW79zqwqB1FS/CU6WHNi22Pi+KU3VMEEt2buWvN6laQ3NJyasxaf56SrNVvSqWs5Ha6RV9ZoZIsS0+JQ4w8b05rmtLORxguPJQ2Y6nUMTVVNr58JW7pQDerVlmuaZBhKpUiWBmVfVdTBUIWVr1VZNERKeHyExl8qNDZCaETsaksytuZHydPCEJlK435gUGnYkzFoiqUlQcHzCMF7Aq8BYXWv7GtHydXwvonJ8QJDIph5Q2hpoK6kbr7kfuLFqAUCcGvpceZkOJGCSBXcK4vPz5VY3hunb15js8UWj4V7/EBCjKcGSSve+hNNoCbiisdbnmnCBWIGzTfI/A5mGuuUSATzjTO78fnWM839fcErGutipvHmOmHPN86spudbz2zHmAWvampHc56tqAfMgs+Vany+MaYYki94oNEeZguiPcWWd76R5rR+51DfaaaSxUeZdafcmbifb4FybIruvEDTLDvm3NJiPc12ZPI5+vkGHDX3mGlcU/Uxc25+TvOzZYyYhw+Ybw4FROozTSVFbDzfAKMNzplgICrfm3Vg/Po0js0zgX9BZFKqXcd8i1q8sxl5hal80XzjvguWn2kGRaxs73kKGWf97tPIUZTNN5X87Z6NkUna9N15bEbqD/pE8n+sdkb2JYWb9h4u/8fmCnDx8fwfjY31x/wfD/G5Scv/sUpH41DBAgDuV7b71jZyf9jC2uV8bs6h/Y7Q7sIzgQydN/eWDSTRdpGMIJgz6TEhyGNCkJ9JQhAKlxIJMJuWzKFixPhTFZ1h10wb0Zs4nZ7Mb4HxBknTjP/Uh94bqyI+AQh+urGM/zUAoVdYHy0VLxW2M7fKJ2W0rcw1IPvgckdMh8OYcbs9cusy0aUzst/VXQ8N27tXtn/pPIQB2Iy27Lv7z3b3d0/ah62//KxtwOwBGuOxBRhwM+Orug8PepYRyV88FQCcaG6u0zz7PgD6OxXDai9MV22/Q+jvsPkEvx+5b8ME0fYIgI9MNGjI/NSwGY6EuUp15tNtoR0aKmNiUZJUyajlWEYcLIU8ooXVU+1vp2aHMzE6c96OXDaaokMebSREBbe3JyurzfXP4L9/M7sDX9d3UNUHfcfOtUFFhNK+Q13sp88/sBjjqtkCcT/aXv0EOESa/xjYu8N4O3kMU7LFA2R3fvBTXPnhRV2+SKklMQ3bXHNF+3Ji+z1MCRRyY5EkIEW88pMHLSll1mmF7+24aSOjR5/8JIQ/2mH/lD752h1/5uwG5K3/3/7Tf/g7O8TH/fZnxfTKQ2fkeyh24Uah+f9LfMP0+9Oj34iC7RKhw2798N+2N3IxiVlXKqjgmAv7HBh5r8kFvkvFUd/xy3/59zACygTjUSLllTVxhTl36nN47yexUoos7v6x0U/sr7+ymnoWE8vWdwbnaPaQ4bEvPe7FniwG7T6Er/7GT+yrH78yq69K7Imffm/mOedP8cE3OGXTJz9y0+NjJG2J6P9V++WPYM75YYCkQlXtTSAOEd8P7y3ZmObmi4Ps/E756csgJfh66lPO6VyO+cVnm2E+PyVEHjC5dtdGq1EtC9KOhfIohGkv7EuPslLpouEruk3glcVlaqrhilgSFsqRgGPf4H8qUwRx9bq6UiVPTG13RhK+miwSuOh7nm/RKyXp6jnXTofwrA03LY/oiy3ApGjOyz9/L9Y2zdJdjF7cjxRf+zRPqsVe60CMxGBCaxV3MRQ40eEKPu7L1r84aKQ6aJ2z80Mqfkrx0DIXN+KlpR2xEDMWuwsDuET7vZrvDNyEjHoH+uFb0PYX7IwVmpcW9klZ2MopQFvQ0nFzaUu3LTu6r7XbKCzUf2T+Hpm/h2D+/uU//p/////732dHY6uKIC0am3wrbMBBtpD0pghV5pm8G9U2yEnNogGv0zQZsSSJGeHH5EkVNuphbVTDUmpoNE5bWbuahzNTvMZ09mwvWvLenImLY9wFur/yDv9CyPifA/64yRWFyiuw5xX3aeUqWUpEgxtRZ6mIInF+aH68Ax/vwA/rDkyNN6puOIyrow8fif8u7D6bcMavu2NH/DBxA8cXvnNh/+j40Tg7KCr93//nOW4mOQyTL8qP+rmdrHBvKVCKH+vpZk+G4qkWsSJKmj25gwHsHLDT/XczWT0ZXWRYPcXVsQVZ0rmsnj6bjyvlAHNFWSsy8eE75g6RQxCr+N6100vHJomFl5daTVeLrnpoYdfC93DWFsuDaQlY8SVeIDFFS63sGx612z/Z5ZRHYQE295IxRgz5+fxRRlDjZNcuTDIrVTpMFqb3SY1pCelDnwZW3U1FsUqL94s/N2lAXiDu7zSKnvULM1kIzq1KnBuUHun6Dxl1/gzpeoycGdIV8OrChbZ63kfi4Nx3L+FbNRR8EYaJS7/q6YYNYQXFJXyPgUVVeNHAQRB6/4/v/4tXF+2BOPdRtnztdd//V4HpGc/RFEEnCRCYE2EerkDOq2vnMgXbslhROnb+hPJzErOFFQXCike4qujYM2JZzKs0GDuD2iimntWGB7DbaVrcxdKu+rYGInbqikajzsDFqQcfG/u+M7yaGMPXoxeWA2yj79ui7w5G08LIDL2D0UyzCcNtFZiNQkWzBTgqYiD0GP/ow4jGxfGPkuZQBf0fD923H1icoynAKZFVYQ+WR/D8AMJzZeiECsKo0hM9AuojoC4WUFdSohrmSImLu8WbkuOfJdgiMfjlI/B+yMC7WkvwMLVRjDkpDLlJ9uYDA9uu/240xrX1galyfccq85OyYSEYBO6QiNQj5BIxBNiWYm5YXhEgWEUenJbfmrqMWuBeUhNO+awSyyDS9fyR95U/oVHEEtKEYmqsdHMbDipwurD9WCXhJvlt+6uvDw7+KKVasd7CybQDVCjQZHjKbBzpfA08q1UOruyV9Y1yVXVUqXMsTCscbqXecy+BD7XKV85bY72ubTLJ3xIffaRGCcuTtopwRpLjSY0GCYBNa1E1KnSoI7upOsyEby5XC2vW3FEMkGVot5YuYgpB78uHd85o9DOa7CUWbl4O3FhPucKagday2nA92VPDvicWvMhSxoIJfO+4Y1vpMWsXdj+IY7cjLiOscKZogcwTuTf+e3NeQ4x82f/u2Bn8gqX0OKU/TRw/JlDFNDvv5pmP9PNImwn5fgCmGIQeF+4Q/tzcxLC5QQPVsXzwD/+AQjEK8L71hVvXbVQqt7dnZwVE0ew4kjaoxJCk9sx3uhM/8DqAul1yGynSTd8duGPUuaG1NJI3aT0uF9aeJESpz9tpWjlUltTkeIMaD9iNi/qO3PHAM5QrR1xe7PD8BAqZAOSH9+TB0ViJR6nngkjhusOJczB8Zrt9ExaB2uI4sRk70hTv/3nodj3MsDXyxNC79sQABtonuXjPpft06OGkBsLCsCqe6LvXvkOL0HeHr6van86bAL4C+JuQ0LtSF8dQZwTXBl7rA2H3vS7Lw8mA5tpBo1FsBcjQyQD9/XpIlYxghG5g+2hbo1qWY4RxXEwAL3poUhPY4v3fhC1Gzvt/BEQZeH2kLuB/QAMEXaD9bL8qhtgb+VPUS7NTa6yj1aGmy1OVa0qsiGcuTLCA8LDtDRSspAdliWRm0Em47BF2f4OJuS5gzSzZovAu4s1WMN8CcAo6bUNsoyvU2Klx7M8w7UNG6c9RC6FGoQ4F0qG8JIxPpJgdOQiVDoIyRyQ64iI6s8R3//Lf/WfxmxtZgpKXQUtGhdsmvE60cvsdu71IPuzI5PfksApzejF2Dh1yJv2+5OS48Yr5lh+l8nfylcniiS8l7ySH2dS8Fz8I0/kN4LhC87Hh82MMLsOD0rS7PbT7PBoeGPSjuKcy9GJxRXhKX/BReUgC/vI0jyFYZQlITb3fhv4klpKtCXv4f/wPogU8jFR4eQLz2LF2CzNi+96kKp7+5kbNLKJSeyr9bX9zo7v63nOHVhmelSu30hRcRgvRbVDV+ndVNWBegyovYpUXR6cb2bcxkpBRM/RIyk5BIlPJSOQf9w3h0I1tmb/P4s34RK/JojnNxlpaKPf7J9xDSFiEzgyPb8Z6otqMrhV5eS7Y3WZjbeblQ+9mc+XU74x1WzE1sKbp3GQ8Il/J5WxaJ2yAwDetdqNIbT7eadVX8uijlH0neJbkbmQb4Tb1+ldOjQrEzU34HUoK4TBY27AYbzxvPOUsBG/ccfdqtu38dGPm7Xy0MHm0MClqYbLItIW5zEe6HYe6eaLYJNwhea6kOolvIFQqKenn/bAbK8s6PNSns7IbL5wAOKWBA1jDxW9oGzMJKKvvQJSnSG3Lou8B2W933YEtg/PLBejaQPeTGc/YRmbB6XshORR4P2KWgSKk/iNu+CXihjZs2t4siIEu3+ixpkcfCDowaIPpuKBdM0rfGyaYXfDAmGBk93xkxgEB0A4ie6+wQFUE7/9ODMTQeOvQfAhxkGboEkj5HgkB9BJYGTtfBcQTAOqg8zhkmQNUzb5DqHMy33vrBmOnUhf7WOf931AyETj+tfv+Hz1jUCgnmU2isLQktvuUwIWEIRpn8U/ZLGaDCMY0Tdxdkl4ghcy8xihMH+7XXw2hxSPn0sXyJAYZ9t7/12HXJaekC9SUAVQE7//p2ukjyr12fqQXdv/K9kUA7DGU9QJ2mP2cWqPuXFwx4HMmqlfaFnzDS1NP05fIUR3q+BIEBmLgjd1rTKc+88wDPemei64+PA0zgXo5WwEDlVOJVRRHMaG6Eza6YK4tPCjFs3Yu0qh+GpMai7i1/+jf++C3WDSzra1EbhE3lGhSZ32wULSjDDlJugMIrtufuD27HPFAyb9yMlLfdkMBiG42U/ytMc82FQ0Iw2rAu6dLaHUG6fcTcce8dzKo+WPau7wJ50epnW98mW3PmUQqGd5z/l2a2T51vqVJDXE3b+qozPhjc4JZsZ5mGv0US/v5BpyISTbT0KZGr5pvcHnNzzTOlOBQ8x+DtLBJ8803Osz7yI8Vs8eddbj8Op7eKbYQdz6aacE4FjPCnF4Wu8p5VqTzwcZ03/zZTu50Y6z5xpvm1X53pJ1wC148XET6mPN6uQ8CZmoni4XkTKvS4tPIQpwz2pPMt27Zt+ddsm/FYnfeEQqz9mQ2t7T51mUWIm7exGoLopFnvuPmHXc0ytk9Dz7j6lhAbr5kLJx7nkoa7rj7PLLcd+ebRP4FONNoMy1w5xthWrMzjSszsMys48pHW0VMeOdbieIXxkzrU8y2Zb6hT+1jZlYwxXpkviEmG52N+sm1hrgjqMWJn6w+ZhppQYXyYk9HIc3VYrvMEfnPBynTF3A2AeJMgtV7Grrchg924Omb+SEON55U9vHzs/lE8v+udUZeQIbqi0z/OyX/71pjfWM1nv93eW35Mf/vQ3xu0vL/rrF86f3fgxq7LTiAP8bSsgCxQsFcv/eSPmdDvplijasgOSN7zqHX77vDS3OSNmnlxcZDZNF5yPyDaVl0WPM5cYz8OY1XpbNqWMJGr0OMr9ShaBA9mwp9FJa9e2IdM9SgVMH+ypPn9Jy+e+34iQChKUolzgIvL+7JvefOKQ6o8+fOyVoFlsAVnPF8yXOKT/duyXMkuKcmz0meikJ5dHpuNI2OqptMowP/rKzNnEsH2+/A8vYcNaxIPh18HUmnw4gDM1+7nB5nE92G6MfvxWZ9ZV0sLQkoMrxC6ycbveMYFfccwL2fiyz8Q/Zq7mDkoD5wggYsLukGB2RvB9cWlLCHqN+58AL4CRRsIPq2D8hlnuw8Ozhwmn4xa4+7Z+cpDnsLyzEj92pBKWYcrGonAgaRkhDxli9a1B+REfeVbWbum/XRJjrWwwdlTfYzjMipU41m5hL93/9n9gH8AxS8sH8Uk4GNJqHA+0vMg0apuSlpMGC/ounq4mQChbqOP/a+lLE8J7bwRu7QlVa+g4k79hCZev7YRjUTmZoOgRZuqiQ2/+//Rbz/X8fuwONf/06cwN0sHZfP+zC4OaJ3atwewxQR4f8hInoDYdwPoROm6Jg7R/FjwpmfAQq5yWNw8LQ2kuHQM0rOFxZ9YPuvazCVcQ7J/wKtVM0zwNrJ3n2lq9F5LYqfhel5LbpS/lpDv3SdryKe0kL93tfkU8GcFkariWwWEdEvGa0GY1v5JeSv4VwZLYrnWeRp99DFng4h7Hx8hRTkhulActdFtpi6Lgm73azZy0ZOvG/vsAyad1wrHGsnzkxRTK70wBEqXFcel6V0bMgWUTR9eR+rCAljb8974/jbMFWoOvbdgcFPKQIO6Auor6prmu7LOjyPxxgjEUd6aaQ6vqwzvcFhxnQ9I+CCJduom6RIfkAHbmMItATGGJPVVXQJ5YJSNsIp7Left052vzk4hvKnZXWNl6E9NDDpefjNn7gD/Dt6/7cggMsfv8O94ZPuoUwUT5m8Yyikt4uvAc+cq+o958IBygK/Is2Af8cxskE2Yo99G25GLEFfZQPUNvBkl/yqZw+JC+OXNEy7bEYMAYSzG87p/d/Hcsz0jef2tgvLjEuB03J8PUCEw/P3fxsGckSXgBwcmhGsoSun8L/QFLwR/jn3BvyH2gX8bV+7/Ssv8NSUep7PFXHvA93RhQN0I37heRFhhn6bciIYmAPvAZcV9lvY/7l7OfHKnyOnfGH3++d297XyKOOYHXov6wEAgDWiOCQS6oF/7/YncJatUaVSibU9BAYWvZQQMHS4Rb2Ks7bGZ59bSxcqmMepakSxQLitGgE2zGNaNXvJYtxRMfYucFLxXAveuYGtUf6COfY7JJYuHmohjbcn+iae5sispYmpKI8fLqPJ4fMVkp3uSDcmIy4wwJTC17f665n6pmk/FZHhj867tNopNOKHNmEF03ebcLz2z2DCEt3cbb6xylMERT7UdWp60HHyxAPqDGNlHetZTZH1ZgfWyDq7d0iTfrdAgEEwcR75ugcXDQWT8++drpS8mJyTxEQcX0Gz396AQmFIUQ4AVtd3ibrmBpQjb7Q8ED8oOIGrXBE1YoRqRCkel/lTXui7LcVlnkooG8qwhBGe49VwW96cmo0JyxmXqjH8ke8CKIzf8di/di+v9CvT2fJg5Az1C8nnknUav1ZSmkQROYqO0XlUWBYb1QySobHbfe2Ma/q2yGaJT6ikaGE2ykOaLyoB7ocf1pL54ozMI674ueIKLR6AG+39P11O5JkOwzbOjTOY955gzEYDL3U9jBGAcSY5HgGa/Uue58ERCTWmNF++GNhDIBsoYkI9A8m8cHruZPAzQzOKZpmKZUIEI168/1vPve9scnPTJIvUXS2lrvdS3z4HvvFRsbVoqTSvK0L66asShst3/JoNw+vaMkEngA1jo1els+IQb19m3aoR4eiJfSkIdH3RMg297kHIrDW1c9+qj9D+y4D2a3XjzAno6Xg9Aef6grtvAP85oHOpvX4E8YWDeMQGYI/cseyBFwiMOcWBuohONLJxMqXIFgH/GxNjLwcCLwH2BXWoc5VwBs2hUO2vciBhqEGyAbB9zsgpdQIUgZCzcZKWH9mOPkAAUZ4jTeHU+fBJeOggrPPQvcn40nOHl/Jw+sBDj+kVJnVwCh9QktNm3UURxb/WUh1K7vq+Nf8/h4vo8Zw+yDlVOXIx0qbNPBvwNBlnVFrtHAIs+q4NBzEQPfdHPlkenU1bOG9H8JIj1X0p2gHjABsjidNptL+f9IDVGnJAcZUM4GEOY/p9mTTCaQfdvo0ju88MuquzK88fT+Mv/DT+CY4E63TTT+C/+7fiGYwMTxRbtJGq1Qk+4oPZGnPGDP/939+6FB5zMPJteXQf4oBpZVDOCWtd+gAi3QcwdQtzIK09Zs/81SYgNLIQoym9tMWszZx7MG6e+cFkHsTtMzL76dyBZGFgHnjxEWxiGYnxAQBvWW6mWvWz9E2gtrJWGh2tfK+mmowt6TN8a4vWyBnagZBS3SE6F5BnwVSzvrvbKZg5BLKDROa6xM0bdS/dbcmc7UJC7iW6uUOon4WOMd7k3YLsZTmhzDe2vOZnD7KX5eEx3xizml5syKsMZDbr0Pl1PIRFvlX7nQ/WFOPg+Za9mAXtTx00tihGnW8tEtZks007y6hlvkGlNXtnUMpTqt/xDGT0WpD0XWynxTV78+1JgSW9e9SabA3NwgedXJz5hh0TuM833umLcvd4YxmSxwUPOFyOu480Uy4z31jvcFHOOYe5j350AgVuhNkCvKVaEt95jB9eoBwz/gtpGhiYtPVFsIBIMPnxX5Y31tc2Y/FfNleg+GP8lwf43KTEf6G7OYQF+r3n0jopUyLijQpGgZnuImYAnha/atnqwjzFqJdarP2Ez1jWZLP58rlcxR7d1XWRMOV3EXk2/00Kn+8jPTmbtWUNlQ3xqQgJND24fMozRIRJiJRzEnZr6K113+TZORAEFwXghQWJ4XJFkmTxcm3hUhEXo9Jl4dj1HKWqGijRQGa2HiG54wzE0BYXbp9SPxm4oy4OxCFcx5g6ycPIIPYQdWtya3ruheOTHh1qE0hg0JAfJm4A1KM3obRS57awnLdNo+PKXRJpk2vilEgwfdqhLS5L6bC/rI/sd33PJvdCfmw8iCTK3m7tt/Y6hwdHnZPdwwNMmU0eaAACQ5h9s/mtypLcNDImV6Nlntld5xzw1iFQSFjuQv6Ol9uFDm3g1AZYyNU/YqUAfX7r9i6dMXXpnAOoOPEySFOqhsbqe6zM8SDA1wH8eTW8NZNBa6jY4rWjBNtddFWjyXOpSR/9/l4El+RTqcS9KnX3afhECfJrooELq+W+MoSD22uKbt3tycA2qHPCB6Yz55ehsyVGasQiZVmczFybsV06VdW7PNczrJooQqEtdBmSU58xVgEI9VQHPM1O6D6n5/1l1NdVjd/2OhiTt4mLMhn6gMY7dDtgqeWKkfKaDwvOlb/Jx/BV6hk62F23jjIHVGaPsIVuvW8HY8DrY/faHb/r2GOVzZtCRKAkncMOLS2JFxiWB08xhZ3woRnX53NvJLrjJHjBGANh9JxrtlfBIMODKpxqxgbUGhoN2+ISziTgHN9I/EYp9FCxbgvP78FzytftuF791TCkbQPPH1uWXRXnFQQk67wemahcnZqw7LQXsVBKCZfHgHUyKXoCZLPGdiYt8ozfhwK3ke9JzLZgFcEdAl/FXNZNXW7cZV3djrepmboSy6JM5DPXRfPndrHlmMuNPTUu0/QUW6n0493lJ6kXuTnlOQUS8fZnGulUOJ1voHnN3030bC9oeE9ohEBvjoHSudQw4Lx1uhOEigNAOSjeKV03Sh8ez29+svh/inTiLyYM7BT+f72xvBHj/zfWG6uP/P9DfIry/6Rb8pVEbXBv7D/D3T3x/mbjqYx/yix/DXz/z8PKrZBYoJrZxYdj5gYT+cPxwX6dHf6hgkU0I45OGphoDz/K7KwtVprEBpB9WlncVtLJqoQ4ISvnNoB6bRBcTpEkcD6cYifiJxAkmMuzpRYHQ9yxQS1G0zP4CmDyEduTfa4y7sXkgqGNvSWzPwOLdO4DR+GJvueNMFT+3jsfGAWKxPf+7/j+EkOOGvZD9yUpCCZ4LtBA7CMu5fi+56Nh00cfWab4wDUkB24PuZMkbyIbqwpspKnb/pK4NUyxS4nA0XYZFkel02asaIdxlSjWbHkae6NWOB3v/tqZnNRF+blwOPGLcp5sLEn8Yk547oQfkeYf2Zsiw/vlsDePnymfLP5voFTn967/bWyuw/e4/rfxmP/jQT5F+T/DlCIUF90bF6ih754YwVj7qbxg5ox/vRzhz4kRTOPa5tW6TmGVdpyxjbnqDHgR1gjTPZBHzHiaj8RDsE+zsyg4+Skcigpa4/gcivQ6pigz3ku9UCR+6TavTnpdrWQL460q95fceslAqqn8UL1eJ0BHhmg0dN6OO6j6CwfMkSo7cgOb5ngNPxz9Oj60DA4J+vFttxZ2EwOrNr0Xu+G6AZMq27xv5ijGYEf2dlsGr+ddgTFRgrmquPTta+k164lvGx30GgnGvhcAv2wP4YWnjgCxll3fxdLDkDOvi2NHXGMnCB1VLC/DKA0nw65NtQJgtX1vyN5OpKZXbcr2ei7sb6TZKlT0icO/6E/e4iu0byzEqT+K3X4qbKsv5yno9g4X9NyukyuLwLB3ChKnjp4GmhBffRgJBLYeIHnWTJc2I5CajygqLmaJpRVWMdssoH5NNHNPF3YYWPA+Lmy8B/HCxoGelvOukvJZatz0YbD9Jmxg+pmTzSSNmGZuIW7vJCkQ3h3etPSo8Ni1QVskJgTVjMmR6dCALD7I3seejD2/KQZR99CtiHuo+FKU5UDKoimstMKhcP5LDGsuZcpYvBy4wRijn3OqLAr4hx0mjXXgkNn0xneghV7HHqP1TMW0hJLAuhVdmC/ZdkmaKhlvoilnsCuEkLpJ11DP3dFFrOLYxiw7al2r0syKKZ1IQfb07sDNq1qPk0boAN00R5gzhmRnWU1mGODora6qYUbJO2oufDBNjm1cSJHUEXFJdgjaTrEkEzMTawtMczVDtppf8u1yXybDMudm6lTCPJyYbkon4Ey72DHPZgHdJmfiTOvMTM6ponMWabHvDtxxZ4T4jS0l0xpfL9AQWt/5nfN3afUJx8GGo+9x916IAE6YFUwhAt7/RzSfBG5F+Y/jFVnkAM8f7WZ2jecxah+9HoUzMbAaGj3CXUpeezgnoGQMJkrm/TJpG0CJcH9JO+RrtJy0f3RtYZGOlLkznCk0dDlxCYWqVlB1eCdtp9yNIhe5cf1PeHM6sjZUNNuhu3zEdzmZ7Y6IOa1qS9aRYZtPSk6+TZO3RryfKbeCLJZxFxxG3i4M/6/Pnpc1EcMFNjdgC2lJn+XcX3EKkSof6o1IFwqlBy6R3Vbj69yMNFqP7wLBQtZefA8cd6hnjm3FH/BlqF175g7tRWuWG5sfpGo5S7z9oNplYJXvrF5OZ+3vrmQuKpk112JOxXOBLmfz158qEpxv8Lnt333lc4Q0xcdbzehpRjZ+gbu7AACdyjXMN9zia/MhjTqv+dlsIooTd4ta57yO7rTGERpiMeuqmpxpPNkX6XyDSm330fLlQT+m/UfXxmjzHXvke9eU7vTK9kf2/AYgU+z/N1fXVhP2H5ubj/YfD/HJsv/YtjmaChuDEETw768nlJfa+hpho7JQC5CA+68xAC7OCWC4stzIMfTInN0So5QpSoA7GX3E9UlPZmDjFC92rkJx6pyoRm7Rru/09HuWzwVhLET54LT8FhYbp+/4NRKwlc8+h86WljAfy5V97TSB+4eWvFclvM0Ojw4Oj3YPxCSY2L6L/ti4cj2P4hfTRcihOT86r+v0c1KA/NFpWfZUrpZ9B/PuAG+pc0ue13v/T3vf0tzGtTSW9fcrjhXfD0AZAAG+ZFORFZiEJcYSSJOUHxH14RsCQ3CkwQw8g4ElS1ylKqlss8zuJouvfKvuypVNtvwn+SXp7vOYNzCDAUjKd6butcB5nNOnT58+/TrdmPkY3q/V2PTKsX9llv4r62Kkc7USagxEavEqq4omP/IGa8yFfcCmFM5TGwB0KY8oQYT4SGj5p0ZHjv+MDIyah9Xp9D2s0iP5INPfGRTszX3hZGJBnzZChYO/QqKxK8lWhSDseyyMmLoaCj6Rv+sYXO7ye/yXssDzaU1RhoHMNyNk/oOGp35l2XidPtcxFbVJUe9y+lasFW+vt6Q6N/xtCG7RH9iO3oT7TWk/lXi8TsvWe6/M2TwAAObl0z/EEiZ1PrIwuUvC5s/4X2nnWJLoeyvVhMuZ+MYJMAIDZMmqo8847VuYw3SMWUxh1ZIclyVd7bKGXRVNs5JAgTjPdxZEYmHJa0d6JiNbAjlBhTHU/4AMgS73X5I38t0Ua3BZI31Ibszg7mhfuLapT7U9Ec9DZcvG3tD2mqyHKMYwHS4rY/kyEO1nBsgToHDaQJUGGqKhLc70oL1mBZ18e7J3g0i7r7+bGE5C53QfO6menT2vJXYYbo/fD7XEa2T476MjV7zNtxDxtiCjoUavVDBt/9CGH+wL5qacqxHWZjdY1HiM5s6B52Dakb5AGPl2w7d89s4P5ThN/d0AwYC1MzZc2tQ8eqb2WQSLG7NT94LtFMu0Ovek+VvYijeArzZzbwCrsooKPi2/EetHwJFQkRYQtTPHSpoNQYXspO32bgK2stlJF4uu+fIN5xEXgvhYIvdwxq6WNPosuR0UG1OR7pcyEKUv5WIDmdv+0gaaFUH4D2eiWeuVYP+5ND33qg9CsDO90LXpuu0/W5sPt2L5H7fau6X95zauTPafb5Ei6uyZJAng1yc6bE0DQ+Uex21nbFtGLpOQ45nKNE4LHx7PyAYcV60oxIWYBQjSUz0Y7CLuHPqftxPVnvjm344ZhjojLHyAWj0OXNQ/aDPoglVpYSxQHNzBlT6EYZ05xmikO7kkgSWsQqvQm7XRyKGybKCkDf1C1PdZaf6z16eOqdbZleR2zAjkiyVPHQ+Ijs1Q0EIHVfVF56d+94du7+wUNQz868fO4dm6jinlNwvFFWAgUEztlxQ6FNB6X71Whj/4QOT6q7G42oYxTzafI1lAR7yE32Fo0UiEFvEvRhQ9lKBvtWO2iZdjBhrvmNJbjhDx6zq4kx2dgMKhEVWVLmzQ6TUrcWkS8beDSleTMEalcxBpiirV25u+dSMbB47qqc9u/srx9WQ+wozLXMw1doTj9pkr7R8le72H7BVmqf9Wfy8Nk+LPPEw3ZkRQTJeEJ1RqMzCB4jWH27mpW0zr859POv192ApOOs/7L0+eA13P2htoqhvenUiwNNGk0+HiZfANiLm6w4J4UYsgQwc/Nc50SwOgDw/mHaejds+6vY44Gnir9D7l0ukeq0j+pFfqTAfBYOr6KahoO23yuylrQUwnZoO1vSnc2UWVLp3Z70aWCSZVYvtUtdgUYXNIcKxq2lOdaQTb2o5htbd2c6+auEQSCKSNbfnR8FnaAfz305iEPA6VbMe3J26aCKS8LW5ECoJv5khBNMV9YwhzTxA21Y06c/Vxn5odaMmCEjaNgpIdEpTmN6rg3GN2tAsqtIl9pAlaDyM09AKDFNkRNgC66P/RKfDqub36wze7rdzksgqJK4ge8lXwUqTFJa8vo4sR1xzSry1w+b9XLIO1v9xeepsqIoQJT1Apet1D0SvACiIe4zzi11ep4leXe/v4jrKmjWSzJXWx26Rq2HAv7Hf9iWPjAX59WJL3PSTvwC7IN/3z9P3q/IHY99VHOZZAu5W6BI5Pjva7p6fdg/Uugq38Okj2mEASIRqUdzItLtC2TvSBbsz8lbAIZfOiArlEBnLt0MAUI9XBFfrtKMWJxmB2AT2Lw0gKxQZmdp3fuRW9HTU5zrOiK8fSbVjSd29VzlBDK1nxPWTFeZhpeqCZ7wSr/gpqszPWnLcbpjbwLA0zKDqau7Y0X9u5iXoV6oe0A2CEk8hzcdLdP+rtHz4/7D2tFNdD2lELMA+3wpPGgY5Wq4ko4/ntMghHeE1LVeRTZxDp9l7fM45xPxNTe8++4BlmKHJ8XSmFpPC1c6sELXQQPs6SqO8hUV869rjv6r/ssVYe+o4aaoP0jZnLbQxgm4gMR66k9HUZalWIZHbqjhtq9VlKyoKw51iaTOH1OSZTPl5AasQail+hNVQPWUP1VGtmO2rNRPRO0eyNIXNCf0BcK5Vj1VbN7daqOMezzsmLo95hx2cdAn7JNxqk2Np3xifu80IlYSvHAo0ab2X8lVijnFw0FsT4ypfl7naEdPiLt5AWMW0/GupUEh0j6ynjmlWqYveQ1nNJWumm3QOabI2BjnB6eHrW7Z31T886Z11WxQotLhaBHItA8nVtTF9+mcA802P3M0QXLhnwni+0K4iK/OHhy5jJPoFhLdFrrlGlBIQVAzreaC6YosFWxYAJtLbkfCcFy6xqViNt54IwV5xCMYCzdpUL/gU+8mIQpzeeD8ep7ueCCE1qd0n6TPIm5oWunrGvZLfNqlZDZCRL4mMdMGZ0HiwJcXb77aownanHfLnA5hhIi0Gd0vKSuM5mClsVnhf2tvQoFho8VjeEeV3lPHmXyY5QEPKFneSTRhbrsMXgnd/BkvSRXw1ZehCrP/uYcP5PYMVeTfHnf7fo/N/27nY7Wv955+Fuef7vVq4PWc7/HcrljGu7S4vFXe7EX/aAj7CpsHgOqLkpoPiYUGw9IocGq9LyXmd0xzIJfDc2QKweGQM8PY6ChGEZ7pT+1JhibVVkAmOeTQ+4z8CGLeTLOmu34P9b8P/tGhbbGbPDjaPmuQVNwp4PeoXzi2fM8CS+xl72Dvc77NKmPEgXnmEO+4pJNCfvGbw1vvAom4dL/0f4EHmAH2gAbsC2hTuXzYwxKKZTbdyURvjTl8fHRydn3YP+6f6z7ovOKXvMXlXaFT/d89HJ4dPDXr+zf3Z0wp8+e/mi06vUWQVj5vHf05+Bzb4IfHPS/f7l4QlIofi6jJ7CN139F/wHF28/eH9wBWxX/Ab5YAR/aAOQFPBvzPE0fU9lHQJ/8nd5G/IRucT7Mz7pgcfGGBnoeEI9aZ6rmf2hPple0TeDK32sqY9eUwkDmIVj2zT4XIKCqiHmYT85O+mcHbHuT8fPD/cP4Rdq+ZY29Rz9N55BgNNt1YLtF5/NNBP+C3SgTzFBV01MMH+Ll0LSsSSTifntRervx1/DhH/XO/qxt8dgK4d7Ds+T4iIFiVThvZc9IAkd9gcguit8zgsiMwsoyU+oIufjKWx//eMjgPpnmBKq+qDgcBEGNBE7tklUMzAGpo1SDk824Kq6UtAHj3sGEq6xhuxy4mD+GI1KMBtYllg3dbeJfXx7dPJj5+SgT5g7eg5rDlPa8Gwrg/doFL40jcGUpiWS6qYeyz8Dd3h6MZg9h9sGY3dFyhgkIpXn6FIzzOg9EPWFNRievK7H8WHpI3tg2JTTnXCDxrShSHUGk1slJDDXo+U0BCSRgS2SS4Li57EYloOFpi4NVDVoV4d3HTRnDbVaCFHfvDw97IH+hphyseRDn9L1y+IjRK+B2653MTamCQ94H6Ya3OHT3tFJt3/283GXt00LxUXOfmUT/gWb51ElwVnwkXalm7K9ztOnJ10iKtUkWr3ga3vwNjSHeHfiGAM9dtebDOWYZPEFdQ974cVELj2LTLaMJ+yY6lWQyGuchLlb0JqhnxBZgH2JpbHpLGTFvqCUdspV+IHZb8VZBj/tFfCSmW7CCGWauQrDXhkuTVblS+ctg2YlPxMd867h41dvX1MEjgdi4qVh6ZRaL3CfUgKFb1UWwQQ0NAllzfNz4GG+o7cCxGuFgRgL99P4nZKJHyFthvlcrbYAivDrDBmaInYOSLxRARkBFdo1fIDwoyB/XwRG8F3QYogIbL//0GO/d3wkSxf98z+zwJ/NPqx92NRdXbsw9X5/QfeykYHtOKA0YGqcKvpOFCi1SnDQPapu2DQoaHOkOxzx+i81yriY/DS4ZS2cFP2XjdAHNC/IJw3HdiUooSb4ASG4fy32Nc4K2Ed/DcNvwX/gl9h6miyI2se40bNe5wh2obE9RbkEC1F4wPkxG5ZMP0YbCOwltMOyKnBlWL1Druw3A0t5FF7GoogkbEyIEH9HV3gN7F7NyJbiU9aUkJz0qmSqwXcDiNYG/LRDRbwPDEkdP+UpvRIBCbLURS3zdzM2HOGti9pWrwebhx/f6e85jiNEoT4UM50I1XWI9QZb+yBbCs8VrMfKR7kqAwJb0n1j+IhRB34JLZ2XNFXJU5UgibdDnF9Gg8Daf5sUB5KwbGYisWFdHYHbow4FZ5A36yzMzUIvRRldKMYk0j15ZPGruhAcFb1HIFBdp2aNS0sgiknYNdc1LlFArWL7SgO5+TuqIItUpeVziGbXk1YR7Gq/LRzPGksE0ZWb/g83f0UevqZI1vVUBFsQ+MeF3TLG4h7GWPhL//PQoaLkLKxxbiQOn4YZ0RMmRLykpzWRlDJ7dEcs+UfQFM5VUfatZl6RRX/qvGf/77/+D3bw/Pv7E0S73ryV25ubqWwmNW0lfIRVPpybv8JMc/s8yGTa9OZ30JUXI29FySzvJA5ZG7wtedEnxItycIr0gOTO/ndrZgdFElaBzjLzMz5kl6eiqSOAtBdHL1OWCFC6hh5NNqiPrk0J892B5pBn19XZGypBBUI+yCKPEHsNVx83Ap58/V0T5p2n9EDTMlrdapjzryte6hwcIYcZeZitOJScP2SXtmspteAQJ3UJJEqsn30Gw2uqGygFv6ooiCr1ykG3c9B/3j07654EywbgVzzzMsi6iKFUwTYaZk3HHAGOqYYYYNWhDr2vWohNTu27filWIbK4MBsNMz6QlLXizBDb+dNz3VnK6Hi2Abn1wkdASmrxGSPLdhZHnxbbcXfz59QoRmNC9sO1N8GszZh9wHb6GLAA/F4knhFHJ9jXrLWCTCURfB/73ao4iRXT427+ZIXrpsdUUTB2jj1AjyAKaiNPc4bkN5FYe0RVXXVkfZh+x9ECkuJaiVXFS99uAhjcYfsYd1VKh5+QdMjtWX1pQeQP8VaT3wpYEoPPcifvS0+YqpTQA1GyAn2TT7W1lYXezW/1CkqcIPn1bv5w2bOzs2PmehcghE09fcyxwz2GKqW7dLKi01ez9HcaU86pL1SFDumMZtgzOvYnzs0f76jI4QTkVxvdrokSnhB3k6UsIdqmCmux0/f7stYIgCOc2dUJDLSBsK1caHuYv8byKoS2AGFzx530DxTfP6NWlh80g88ol+1XneRreYtkmYsy3OY/Qi5K4vaK9aMXw89OSc8qq8k9GbWXpZyzWA9n32yv3pYwl7muMVukUuCXTg2pWiiSBzJqEIqdQlnxvrC5dTfK/LrSP0YtImcgKBytKfHj5u7dZN8uEz/eX6l/JYkfo+aphPNNa0+9srlEVtO1CIx+aEZx7hA1cXXo3KHjWxP4ceUVswm1S27vlJk0S36RlknzlUylmSwCxfJovs5TYzSVoyh/xHrYyFYrv950d1UT55gcW/PxU8iAuKWSjBYOd1mcrSYh5+ino3XexpLMb34Tg/d1tp05Kttm1DAXOr7XGUCjYh8KJKDwUzWsLc/tbmST4i8umfXm7pZwLMdlyIuVsfZCodXsqwXZ9/u4VmylKriWPSUXe1DHhTdMaLFqoU5qgRpoYfSSBruEUn+tedovqmOy3TS91+JqrxVSe600TXYzlv/y3dTRDNYTvYicCryw66qtnT4172aeglVptQE0rq6g1GbUzoNJSSwfletTbbMjMGVH2n/WOfvx6CgitM7aG9pgYHvW1I292NnfP3opjHYbkpRpZjZUaXmfwOEdESvi3tl+BiPqw3AAjD6JsvPMkv4wQYw9O/qu2/v0pdgBB05umejWwIrhNCsUwY6HULzpyIYPKnU2cYyZiJDhH4gbOQTaqJ2M2AhXka0Z7KW94NrAOEt5dIzf2BDFmINlktenQe+GtlSK+Qztp/z+WHt35hh03Hjrn1jWYtmph3xznfvPGxEfRNfSZbKz9JYvg0hyTHoxYOONLplRQUX05YWnnrGDLMHFxXCRua+cST3yxfiuagw4IbkAnRdeVwyolJZzQRcNYisGUaC15SZzftTYatfAnNCpYlhIbnhZhCwdtrRabGWOBCmGuyzd5MJkloCJYiAv6CHnlpoUjlAMvlibq0j3tw4Sm29YL4aEtGEUSx2YF7J6SsMZ1Nxiw49DnmvgiQ7RYhDNH3LuzJ1Jam0xABNazZvBq6hyUWwA0UkrmuexcLa6rBtMxLtQDAsLBlI02eMqQEzle8tnjMtqEf4kpjDvyAqInitNX5uEjqVhKwjQ6tPl/emuYP4/yj3Zd42phybZlaX/W5D/r/WwDc8i+f92d7bL/H+3cX1Iyf/XpTyklAnQtlzPRCSdImXQvoorcGUZ/4jsNiTZRZ1fS2f8E97cBjXfCDefmAQwaaCk3mAD8w2fS2UCzB/rnyfWBfBle85A3zjFPF3s0JrZxkBh7lOPYeH/xk3133u6E7HVY6q790UGxB2GbuJQXr06p/fOH9TPH5jGW/7jL9L5MoGdemgfDq+v/3L+4PXrDM4LKtCZ2FewJ57ArA/KxOAt7Gx9dPtFHlguz55lO1rwiTSXADgZoDGNsTHtT9A3wT2iSYC1585KcI3GnE5Pu2dxh6iDEkTjwnMHWsMIkm1CTM43+Bb7FlMi0pGWY0L4erwU29FzIfy9RL+/gNeeEod8cHrzBzN1g6BEsG3242bftEcifefN7+wXPKcz1qzpze9jljS9G4lTuxGZVgaYEEkbXZk6ffeqiTk+NebY8B/Ls6DHSw2zB9pjgOSFbsJ65Vyu+WAxE/Id8Nz9Tn735KPpKghdTCP66flbQw1A4Q75Vy2VA7NH2ZgnDki4BmAK/ZbIgzGN8lTHQ0dhjERQoUgbm6raiFJCNHtDZSm0mcau7Dd6rckOXRc4O9ydQC9jtBI4zBszfpIcU41tM32qTTSXmkI00WF3TImrNdnLscZMzIKJBAdwTWyYOMPFLiwPEy1W9akBncNQRqCIDrW6aMbUp5RM09UMjxunRPbsGtPfGSPDAWmfAJ5q4wukAwLawWxnmKOPWqlwICvswvG49S04fzxjPkjFMM+IuQkSNdAY9opjx1SZhM6b36k1z0WDM2Yb18gDOQ5iBH7oFr8Lb/x4pU3dzmTSZLBS0EagAVJwEENNpf3snnWORUZXvhCFej+0MetiN4wVBtCMYUZv/pcFC42/IWZQZEWlYAxBOiJ3W0I8hke2YZWFS3cwKYHsn7CgWzylJoAhAzUoHxjMB5/nDi4aALslIkBEn82kdVgLf9JO/kStx8fwSuSTTRqcGgkOSwyG53pUIyJGwu9Bz8YIbs2DDNcTpt8Rn4RXR9KngceRbzn174kJDd6kQYh8kITJOP++tJ0xLO+GPGrIJbAIC/+Wv8RO5HlEIBR2DKSrmyuOcFkiQdaqYrLiQqloWZ8vlSoVWMuGk0JBWF8lZaTO5lGfLzEvaWWat6UHcVDENJHSRy6IF1JwMWDnNb+cPUVbEXilVeVPdAXtP5cGrAqzP9AdbrQf2n3Qqa60opagBfYfeNSK2H8e7rZ3SvvPbVxp9p9viRY4l/fpgZ0iPazU+sOJbiNAdA1XdhLccAvbgbCHYNPJNqCksd653SeqcoHOAWjQVApb8bdSt2iU6in9paoa81cxse70yrF/ZZb+K+uCzOxUK7JZEpoNi+S4oVapUfpc+pqaSvyWd5n4ZVxmFx3VBaApeSB4Ht70eROxcV0S7RdMVP78s/mTQCxlndu3xxPNeq/CdQVqfHHyU7fUpRuX7nWcLlOHBKO74V5wWbG0QNyYqev4ZYKpixT8dAoPViRF88UpX2Q2E1SzHjtXTGHKbuc64paKdOShqYtMnJSs+1hzXRA/hjikA3uAhCDMY986MPs6WW4GjjGZ2oCpS43h6UxR5AQ+udCA31GFN5CUoZMxxpyx6lgfaJbhAuYsjeeOtxP6rFG+AVlMxOFFOKwrb6wFejSgSwzZYNovntFkN/+dqqwYaD5C6xKGbQseRgYUTLFjByrxuLoz0x3Q8shsMGYz/Tcqk6PNyN/qSAPP0AAeSWnt/UfESrFqpcZgXbG3+nuVsqdOJpxAR1jeYgnLnY0ZJUVcOZpNnMQU48ocYb+V1hX48AlP3r7HKj0E9NI2ADWue/P3mW4yVzNnZEDiuMEaL4F9lQ7UVdK4fsx6gJ/emfEgUTm+c+NBOsO4TcNBu510FjOj5SAmZy0ThB/a+oPDXDrQXra4pO1iHpsuBt/CPkrbRRbwSttF5ErS/6VVrz+wJm9WEAayKP5jczta//HhZruM/7iVK4v+r6y8+73j/7QW5V/20ECKW73mrxpdEPchx3fvFH4cAchqodoLdO/jRyzw1aQKwQO9uvHqX1qNrzqN/6w1fnu9MarTw6n9EmRpZx/gr9aUY43WtkjSi4dv29vCxRZT7REr6D3ih7r2VP09ABm+Aonf0QbwW3crNelZi0uRBK1wvqWr+vGJUgfg5J6yeI7uQte/cDTXMDGXzMAeNy8cUvJxOHh8Vx3Fhb9vRbF/CYpHA8uoT5P0arHMN9rNFqgoVGRN/4+yHh8Hv7bikA6FnqQp/oYeopITXI0ZJvoOFFwQvqaeMdW48ji4AnVtA4Ms3KnDpTMsXM8mN//3wjRANx2iDDTQ4QP2rQ6TqplN1jnr9m7+281/OdoDBckfO/fao8IH6iUGclyAiIyHPUGP8C5wXjbUy/4v9u8ffvlVXb6M2iLQ3mZrc5cDeGm8E4cCRzbdrpGDH8tLCnbHNPNSs7zxze8OAoyF5/Sp0KRpOuAdl6kXXCawpI3Z0Xf18NcuqIBYenZmOBg0YbNKzP0uTij68GOHGPrAlWrAnckjErCkJzsifZNbATQDpd1LzTQvMNE/aM4Dw8bqBu8Md8oVf86pIn0y28OjYjPj5t/QNDk0cBMhNbWC9bEsKmvMlW0SrC0MTcCRk45NQHkOxUg4NjA8/R2sPmsNgTLKdsvVbdTM+XukmWNFhM/EDVxCgQ+GFOvzWH34RERKaL9pdt+1B4Zm7vG+m8F7fOsg175lj/U+zOMUJkWT74Zu4stzm8ADf3i4A5aYKFhJb5toRRnagMB68DZQjB65daEZTuTW2LOMgTExwne9S/zrtUzj8Q1POwFotA2rikEkNXp9YGm6HAr+7gvhFkthAK2CPkHAw34lihZlC8oQoBDOZVgEmUR87Eu7SD5iROIe27ju7ErO8IoElvpnM5A0ffSKChdE9ORLwOWh0sciuwApI3uCnKQu8FAE7B6tljRjzzPFxJH/6RhhwoLvcmkQ4nJZcKgFMh6EGs4F20KBohiE85ovrTBZwCutMPfmCtp/zPeO1tdwW9Wc1Z3+WWT/2Wy3dmLnf7Y226X95zauNPsPHR2nXBuWOILI6UJmKFjtESCkvA1BeSs3/2DjjVDjiWagpAHeI0PQxgbrsJv/2Tvc74DShPYX9EBy+ZJUINT+TA+P1HI/ptAoQd9C0dP7zcAYd43Cvg3QGxyPh2uiD9R2pt7Iu/mby0xj5uikI0IDQ+Pykun4KsZJ8kBx8u9i2Q+Ch/yXqh3XwHQsEwAO3wx8WEMo2q3WX5iNwd8gDxtoXRZ6M7WFg0E9T4wFpOHnmzQtNEKRHAWPAJDPFVA11VXYuaNfikZBDTp/sE8gMmGvcsllOzUmNgZl0wFoVsWIBdDkanvn0IZpcPVxnwKjdae2Jw5g6E4fCaUOgvmFYep9ywaFETY6k2rTTLV39K96d+TY3gQahG12iLH51UPQ5qExY4q57qgh4DUwJ86w72AKpypa0mzQQrlSMuE1beh12RYI+yDB6egQrp56GBBB8LniZxb41Lu8zQdBXfO9i51NsNY8aqaVH+zBzd8EvSC1zKEUQSNUnR5QSkrLF6zC6QNUfHkQxUHjAQOEN5mQI9Ch3e11TulgBTyzL97ogC5qaWJqMPWysQ/nD/jJB1gA5PWvY+mAa+7/ptMrriBIop8wuI6umdyOMdEDANIBBw8moY6nH6whLh9NWjygIdR7XUXpaMEh8rr5G9GXBnrqO7upWuvxgKcZfc2/uMRw+iEeEYHZbrLTKFxE0GRn4VIV+snFig0hES0tV5ivw64zR2Luw3UTqAL+hzXOfboPzKkH+mVgRkOED1opfCYyz8ED7AvaCkAXfIPfBlVZHs95YZA2H8yrorKLVNHQObjSpjV/1cKfQEJ0NsZmT3UsCylCHWDAY16oUqdcQYjvp90Xh71DGV3UZMF0hlhaElgInZJBADDMguvUdAaGmpIAPOK2J3idYjkQBkCcNvNMl0IyxqplIhHyocJnv8L+XiOaoNZgVofExVAmVYHtsAkQ7SEROci8dA1WHuFWcaMo3DAJwR2oQQhWom7TGD5KtphjFaU3VJk50mI9vG7roSlPNbHToZ4GfytlN+T5Uo55QzB2P9WWOvR7P6zuc8sEIQ3cgo29LAfko3ilgXdTApGXg4tDE1sN0vQTWyQy1ekeLirHNpH74UqpUBPBJJzhbZDzRMFi+QuhBfZafP9uSv4PNrVt0+2DHGSY2gX28up1WlRgxATl30q859/kmjwiDLuNTMd1aDoiCV1jbIBY0YAz7YahFniEE8QSRwWy7h36u8W9c8+cipp3BvM5P+04GtouxBZUHekWVRqZ6SBtjDwgkubItkemrk0MFz0ttSZ76eJZTKChcWCnkeyFeyREJqMhSUaIsf7zdh8IGU9M8gJ3VfreZZzbuHXRHrfgkjh9AQuB3w6U5js97TKc6A2qX9CgbQZhImFjgKdEYc2BmG1NYfOa0WbqW5WRfZmwP1JdPzx9Sd4nQAefTeAuQppTfhMrvJU3oxQNotdvho2yH495nPq4hU12JHMtbRjh7UJsuXUuC2gig41nkT2yMdBME5Z8Pj+K/BoH6eqApirloBOOa779Xpj2gPwh9KjpAheeVjfOz50ntKrpn41a1H3wCBvA86AU8YyfVyrqnux2H2CGJ8JbIJ5hreurE13D+Q48u0SJPQARsy8FaDXpUuBP6SQxdkhPI/BucMB4VzpPsxfohN8nW/gZJeNTYIcA4IeVAQDelwKAMQwEoJtYRduZumiTr/Kqa3uVWs3vUrwEO5pe3a01gcrHVQlbWjN4xptaCQD4RbipnUhT18LTQycVeN8fP7LP/AZq0v+oRxHwSJ56fQ+yk/SJ0eZCxFINtPEIpCTYmQdXrIrniv0mg/3LoWNhHSKKSk0SBwyCN0fpm0UMxqPkTyXt9JHgoYkILQVBj346tC0dvwhTGO+Y3+w7dPeRcBip49EfBKT1UHf1cFPXMlhDUCmdJ0+uME+n9Z88SXyGHCzlmTqPMhXEifwf1wHvCsfIN/4KeyJu7rGIPEC3a6olOTKYwcdRLpAiR9PDvmSue34DieHH1GbDhf8ny8jH+Bw4MM956SKvXrdHLbLHEQQObRLGENRSzP6Muxs/y5+6FalNzL40yHkrN7M9f+NJ2HSW8HOPcbtVVQoXKBXRcoWSVJJILTyTtO4+XFceyaP8ZK56DDIZ3CE2gCtC3AwwAkUsgglU9bTAJ9oVhbpuYQYIw2P+JueE9Xo/+Im419HFG30wbb7V37tVhKGmSkok99XjFgCu+VOaRK77wzto8ErsKN1bjcsea1NU4ta2inBba87II3ezu+fvB7yiRUUfgszgyDcZixgRcILJfqBeMIbRxyCBy4fEsfrCzLZHMyK4vXgFp9Qb231uytljcdz5zv35vnE6rGE08KPIuhWZNw+QHLq+ZXLFazfZG5svlGxheSIS4c3NhoyavM/K7q1ojJLaubLG/6qHCJw/8e/kOLaVqEWR/ItzkLxJ7JPhSxiw40sQtnlaYGuqptDeivoZ5ihQRdl7yrqKsnVc4SamGgGkpEdAEecMvCpjMlKTv/DYm+AXFAGCO8O8Y0l81jg3DWWEiffAWROG8wjDtp9fidtKiduFOVi6ES4Wu5NMP7cXvtPeyW+Fu4UDTnNcdrcbXfMwKXlMtuiamD9xiazbC2yxwWEvmx47vYtiGdPnWYyKwZ21q1zwp8r1xWBNajZfoZZ5cksx2NKazldpINdWVwzgzH2VUVhZwCujsMorHv+lzmLdVv7n9u7OzsNo/NfDMv/P7VyZ47/8YOH1RYAp2ltPDFik+QWHAe9vHNgLbYJ5KSbmzd8HxhRUXWOEmSU1Oz2Kig4DibMzmMGUYhwoBISHq5CRiSJWKM4Cj2JwyxfGUOAZMdcQQRA6dQIvVYRFp6IiH8YA1xm0eWAPKNXGY7StS7NPRYZXUVVDipCCmxgiBTf8MCe4J+OcKmSiFodcVJORTl750SyBpKHi9TRjWzgaLHC08fxBQoDMA8IgUJ5O0S9iRGoUeKbDh3/eGUg/okMOJz1aQ5uA2NgQ70XjNOghnz6qIxd66x7EZ+TKgCTPX4ixwmN5ByuW/lnSIPF/C5+jpKTYTpgzpWXFlgyMUkSY+vQeuOvzMLpEZ0Iy5cetTWLkc9xZHz9yT8GCWEg6roibYZ1hAU7hMsdzivYbYpdY6M6h4LAJCeVM7KJ+jKAKe8T8QM7IQ61bhB6eHr3o9s66GHfIXZackVDYqgw1pABC5fSQjfLAXxeDGDAXkvgeOIsxCkQG43FS4T8g0xPxcGzyjYiLADaPHB5YmGx46GkAhgMU4fIzpI4+0aeGE4BehCAeEMRDW6F7TwTNRAy08nHtfsQRJgYRPpIhDdSajFzwKAhk1YGAfraDrKGAOQIAhftFEVq2eMA0yShqIpJK7N0fIixDActQwDIUcHWhgNL0vigQ8CT83qpdVzH/aRn7V8b+lbF/ZexfGftXxv7dXuxfmjy8/ui/tOCNTyf8TzWXOYivFwyxo02Fjqr6LVHG2GYlMT2teil70EXa7JZhF/Os5J9M4EWCCT9f6MU882pwwEuEXKQ0XahUToqdrxikizspFM4SNiQURGpa28UCWMKaTjEQ0xv/UwSplCEUn2wIRcz/T9tvXwPp4QKkL3cVUQCL/P+teP7f1sNW6f+/jSuz//8piWUdSRfIaI+5A3T1cQBEgw1Fg2vKCBNuPjEaIDLo+xcK8K1ncYPLSLc8wxJpLCx7pskgOWWg8ZNYRJLG8OQT5PiQvICHOaO1LBZkh14PXkzVDzeYUSEN2IbtWnOBP831sE2mBekI9PGbv5r2yJZJRaRnPZC2A3Wy8Vh3BjrjyWR1A2MUeCoYw2FD5ULjZV+lew7BGxojY2p7CR651EQkeCbmAcClg+ZhaJh/hKulH6lIJjt/YA3GeFe2GHjKqtLGh9ytSf+r4SeU7SXSlP/y+YOTz+GLeqt1/gBelw2fP3gDHIpKJUyNWRSS6yZDxwWv8ytxWheeKR2m7orwySumuD42k/yNmMBzzJCSeV4MnAtMykoeSCKZK9tDb2PQl+gjwEO9kqdb4ZPog4OeOuiGZ8a0qIaLfEhU2nvZ2++oLCoBXyT6N8d6cAQCQOXwbLLvPfKk/gL0ipW+/ZZnBnpGabr83C8CJzGsChLQuOeTDTxMpzs0ftOxbU7ol5pJoocWBo/q/b5rYuwI5RaRNIPjmGimNoMGG5QomHzEnLKFYfTm98DpBB+TsEKAonv7L8i6C0Df/BvQTa3JDngSJtc/HSaynCglmEeycF05OSNMxMZCeuKdeGZZla9UPNqmmbzmDdWm5tzFsllTt2bS2QpdUnNIgPRCHx724UktV6YYP0uMLO1sc6v28uliyEMshprmJdbibmJBAo6O9b501GBUPwjvzd8tT1ucU0ay0XW4krPmkknZR6Nq2VO5F92fOKXSeVw6j0vncXHnMYqZixzHuPyzStJl5pjSe1x6j0vvcek9Lr3Hn6D3OE0iLnPHLHQeL5X+BVeyb1CiUydSC98TFgBrMJY/J7xOCf8jZAbgN1kofwwHi+Z2mJJHhjHQ/U5BzdN4pR9uLoDdk/bpS01YOUSNGRs0XOoG0xJXKrQFc9MHxpJfap45bWKboQEJtu+PigPU9K0NT3jhEZFRhYYr3oHfkacCA+I5/RV5I4IW8WborvyCOEhCNp2AByH02ePE1AzhtDpqjodCwOAlYznbia5TH1GZky6krM9b9P8vkSfm1tIupGDndv3/sTCYf8rs/48a7Qs5qiNWi+B4i3uq/caLuaqTdKtikC7qonRbl27r8voTXDH/v2HRPr3KAjAL6v/ubG9vRs//77Qelv7/27gy+/8PBV2s8fi/JL31+PvDrSe6+xPHeL8c/icB01xqRZV4HgDyT0UTB9KYJVrQIoe+KixDIfI/klN0or03bW2IpUR5Kx+GhovGvSEM8lqYFkU/5s0fI5DzefyB9otncFe0xiuKSLcYtSItmdwHKI7OjrE6Cm2T4cfPN/lo0NpOByzvKvOlnxkgOfWlPLeelvvyAwsgT9qMZBpM6XkgZ0RAGQs4MpTClZoBk7vmhJUVJjvRKbcvjLCIacBtQpjHgtSEd5hMoMyLmdEDxj37K0lzGSGiu01vWcDJ84KcKBNt6CAnEqzHuflj4hh21PRFHAfd+xjxQYhwYMgbz7do1I7uubzEkPBSPDs7O5Z2nGGm8sD59HlgHSIZpvI2ykLBjx/zsYpsmIFKqB8/CotWckXURZaAlB3zVg0BiUfDs9kB4rv5EpaAzKwyiIBlLQNZOvsHy85X6r7rvYL6n8vlf4xQmBm4LnH6uOhSSBtcFP+9u7MV1v82W9sPy/qft3Kl6X/HPg2wfVkh8VQfa5Mr29FrK1X+BN01AnTXEHS3MlVw0mrPUfwCo93gBajVqNegAubPdhJSAfelNw7DCxtfMzUrrIoK+8ghebPWxOBwLHQ/8RxtT0SKXNoifZEFehm2ib9V1LdOYdQgLMH/eIlPIRw7WHjTmhnkHIcm/S4fs+5PnbOOSmNEwveY193UTfyvqb2/ABSBsjWbuH1jgtnPMJoGg2Dtsd437Td+oOPRcfeks3/UPYWGX1UCBIHJ/2d8ZiqvlVP3pNs/PP5hG17e+JdqdXPnVaux8/rjJvyz/Rr+89Xrj23658Pm9cdXbfjxhP6snZ83ax+2rnN88flGsNNvvz/o8U5faY3f8AX5o/H6Q6u+276W92tPsK8v8E9os767dU0tnVsqIkXzUIUALcGpqmgfmWwuFJ9yBT2KN1T2KvnM0Qf6BQa8wiuvKu8asSXV4JEIr+kbHiWh+lC+f/vtHoY5u7xS6dSDOdsBYmU8WABT8/3c6xyfdvvHJ0c/HJ4eHvX6Z0ffdXvM0mwe1TTihWItEIg1B3RRQ+NZ/ESfCkyAX/3+DATYbMBst9oBYHhWNpC5kSxs2U/oe5SL/XAFhXJBSHIhVTESIRwKhFE1GJ7g45lX9ZDk2TSsgekBG6heNG0EHRZabRHwQUzKj9hQn+kYg8UCxP5RUnoAdzICoslXEWFNBUFgqItYC01cvlX5Wi6YRMsSo8BOjmfbNQmETMRIazcQktFUtyJhGfKBCNRpTu3n9q+6sw98s1pjezLgiBAr1hQHXnyXC3YJhA88tqeAxxAB5DZBuBX3iUPuMyYOewRafFyT7Yme1VO8LYq9sK9Ze7OFs7Px6vzcQ2mnQf+2L88fnMP1+b++3uBjpibzDNiHfuEKqDNJbXvMJ9e6NO2hWYpP/Z4iryQmvcdHfO0vKD8GSGXHfMyDbVMYheKhGAcQYHxcZ42zv0cin6fWtN8q5AQidBKwRJFk8MtHldZ0RNwSjxDgEMwAgigf+FzFJameZ9l7nsV6niX2jGIPdq5mgtNfcLMDIuRo7L7oHD87wqUN++tT4D2dIx+nnZP+cefsGdub8/IPneeHB+JFOSYCAFlG+mecrae8c9LjcfIZ8RLeQgwuogxCUkR4/9Ai+wdHXnJfUfqeJdH3rCl+1pnnmInokmNiX9D81MVOOw+1z7qdg+4JxSH91BCyc+OMttnUGLFW1JbWkYsAhC8ueTJbSXirNsLm9z3ApAyNaNz5BQ99TbSMkumzHQxCgQWkrE/qjc0HKiGor6RLe2gC2raiJkgpAx9992Q+lozLXMJ5zLqY3VAtxwt/++a2caLmk2qSFtZe/1nM4Bt4lHDqoRK0SFf2KlEDNIjRr4LM9vU8AicmEDyCsA4LtVyac0864DFA28OTC1u4iQpiyn4AwgIhy6HkzyHQ8dGlZ5on/jdxorxOJcrtCFH6/Ax1ygPDpXNfAZ2MVTvHhzKIck3m8a9kZNnmEtql2qIcfeZn3Z3Lo6K5d91pSvgm3w6wJ7EPwZv/AaFEDgq/v36Mk1uLZ+v20Qoqg+faHosglWzveMrGpVM3NQqpjm8X2mCgT6boeotuGjjcwL4hRB9xX9BnUwlEUlYKPRWycyrf30kyomNQ0GZrE4R7zX0LCvYlHWsWG2DY2LLCbaDd3s1NIqsKPowsXEF3gIPURbab5n3YVHvpWgIQt1sF1tE84otIR58HFocvJvG7QekxiageRhkQtULnUNH9UwV9eQPGsQES2KqJSLGZ7c1CsoTljS/I3p5JlOBoCokTtGwFaA90PAaeJGsAJrKKGl9GkIpciNKASy5IcQyrlTr8JZkdnetdkhJhSRj6Km1Jbisj63qX5Nb2fUFSKw1J7VY6klq3gqSd3A7TeVbwXE67DEpNcPz5fY3zO8jnIo1pEsVAC7WXC5KlxMe8wNbng7BwAymGnLxDzO8qziVSFRtMrv6Wc3orGacg2udNa75yhPM2w2JApjW9HObUVrTaBRLn4ksPugxEKK/yKq/yKq/yKq/yKq/yKq/yKq/yKq/yKq/yKq/yKq/yKq/yKq/yKq/yKq/VXf8fodNcygC4BgA=
