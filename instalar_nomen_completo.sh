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
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.6-flash}"
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
err()  { echo -e "${RED}[ERRO]${NC} $1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

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
    image: traefik:v3.6
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
    image: nginx:alpine
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
systemctl restart lyra-central-api 2>/dev/null || warn "Não consegui reiniciar lyra-central-api agora — reinicie manualmente se necessário."

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

cat > .env << EOF
ERPNEXT_VERSION=v15.25.0
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
if clonar_repo_nomen "brazil-nf" "/home/ubuntu/brazil_nf_src"; then
  # "pip install -e <APP_DIR>" precisa achar pyproject.toml/setup.py DENTRO
  # de APP_DIR — e no layout padrão de apps Frappe, esse arquivo fica na
  # raiz do repo (um nível ACIMA da pasta que contém hooks.py, ex:
  # repo/pyproject.toml + repo/brazil_nf/hooks.py). Por isso a busca
  # prioriza achar o pyproject.toml/setup.py primeiro; só cai pro
  # dirname(hooks.py) se o repo não tiver um desses (layout mais antigo,
  # sem packaging próprio).
  APP_DIR="$(find /home/ubuntu/brazil_nf_src -maxdepth 2 \( -name 'pyproject.toml' -o -name 'setup.py' \) -exec dirname {} \; | head -1)"
  if [ -z "$APP_DIR" ]; then
    warn "Não achei pyproject.toml/setup.py no repositório brazil-nf — tentando pelo diretório do hooks.py (layout sem packaging próprio)."
    APP_DIR="$(find /home/ubuntu/brazil_nf_src -maxdepth 4 -name 'hooks.py' -exec dirname {} \; | head -1)"
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
      ok "Brazil NF instalado"
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
        ],
        "Bank Account": [
            {"fieldname": "synapse_codigo_banco", "label": "Código do Banco", "fieldtype": "Data", "insert_after": "bank"},
            {"fieldname": "synapse_tipo_conta", "label": "Tipo de Conta", "fieldtype": "Select", "options": "corrente\\npoupanca", "insert_after": "synapse_codigo_banco"},
            {"fieldname": "synapse_chave_pix", "label": "Chave PIX", "fieldtype": "Data", "insert_after": "synapse_tipo_conta"},
        ]
    }, ignore_validate=True)
    frappe.db.commit()
    print("Campos customizados garantidos")
PYEOF
ok "Campos customizados (Company, Bank Account) garantidos"

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
# 6. N8N (HARMONIA)
#    docker-compose usa "env_file: .env" (não valores fixos) — assim as
#    fases seguintes só escrevem no .env e reiniciam, sem tocar no compose.
# =============================================================================
log "Instalando N8N (Harmonia)..."
mkdir -p /home/ubuntu/n8n
cat > /home/ubuntu/n8n/docker-compose.yml << EOF
services:
  n8n:
    image: n8nio/n8n:latest
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
    image: chatwoot/chatwoot:latest
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
    image: pgvector/pgvector:pg15
    restart: always
    environment:
      POSTGRES_DB: harpa
      POSTGRES_USER: harpa
      POSTGRES_PASSWORD: ${SENHA}
    volumes: [harpa_postgres_data:/var/lib/postgresql/data]
    networks: [stack-network]
  redis:
    container_name: harpa-redis
    image: redis:alpine
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
grava_env_n8n "ERPNEXT_DOMAIN" "https://${DOMINIO_ERP}"
grava_env_n8n "ERPNEXT_API_KEY" "${ERP_API_KEY:-}"
grava_env_n8n "ERPNEXT_API_SECRET" "${ERP_API_SECRET:-}"
grava_env_n8n "CHATWOOT_DOMAIN" "https://${DOMINIO_CHAT}"
grava_env_n8n "CHATWOOT_API_TOKEN" "${CW_API_TOKEN:-}"
grava_env_n8n "CHATWOOT_ACCOUNT_ID" "${CW_ACCOUNT_ID:-}"
grava_env_n8n "HARMONIA_DOMAIN" "https://${DOMINIO_N8N}"

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

  cat > /home/ubuntu/painel/docker-compose.yml << EOF
services:
  painel:
    image: nginx:alpine
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
  cd /home/ubuntu/painel && docker compose up -d --force-recreate

  # Verificação contra a realidade, não contra a intenção: o que o container
  # serve tem que ser byte a byte o que está no host.
  sleep 2
  PAINEL_H_HOST="$(sha256sum /home/ubuntu/painel/site/index.html | cut -c1-12)"
  PAINEL_H_CONT="$(docker exec painel sha256sum /usr/share/nginx/html/index.html 2>/dev/null | cut -c1-12 || echo erro)"
  if [ "$PAINEL_H_HOST" = "$PAINEL_H_CONT" ]; then
    ok "Painel publicado em https://${DOMINIO_PAINEL} — host e container servem o mesmo arquivo (${PAINEL_H_HOST})"
  else
    warn "Painel publicado, mas o container serve conteúdo diferente do host (host=${PAINEL_H_HOST} container=${PAINEL_H_CONT}). Rode: cd /home/ubuntu/painel && docker compose up -d --force-recreate"
  fi
  PAINEL_INSTALADO="sim"
else
  warn "Painel NÃO foi publicado — nenhuma fonte de HTML disponível nesta execução. Rode de novo passando o caminho local como 4º argumento, copiando o arquivo pra /root/synapse_painel.html, ou criando github.com/${GITHUB_ORG}/painel com o index.html (o script é idempotente)."
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
    image: nginx:alpine
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
    image: louislam/uptime-kuma:latest
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
    image: netdata/netdata:latest
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
    ok "Workflows encontrados em ${WORKFLOWS_DIR} (o lyra_functions.json de lá é ignorado na importação — não é workflow, é o schema de tools consumido pela Lyra Central, não pelo Harmonia)"
  else
    warn "Falha ao clonar github.com/${GITHUB_ORG}/json (confirma GITHUB_TOKEN) — importação de workflows será pulada."
    WORKFLOWS_DIR=""
  fi
fi

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
    warn "Não consegui gerar a API key pública do N8N automaticamente (endpoint interno pode ter mudado). Importação de workflows pulada. A UI do Harmonia não responde mais publicamente (GUI escondida de propósito) e a porta 5678 não é publicada no host — pra gerar a chave manualmente: (1) adicione 'ports: [\"127.0.0.1:5678:5678\"]' ao serviço n8n em /home/ubuntu/n8n/docker-compose.yml, (2) 'docker compose up -d', (3) na sua máquina: 'ssh -L 5678:localhost:5678 <usuario>@<ip-da-vps>' e abra http://localhost:5678 (Configurações > API), (4) remova a linha 'ports:' e rode 'docker compose up -d' de novo pra fechar o acesso. Depois: N8N_URL=https://${DOMINIO_N8N} N8N_API_KEY=<chave> python3 2_importar_workflows_harmonia.py ${WORKFLOWS_DIR}"
  fi
fi

# =============================================================================

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
    image: semaphoreui/semaphore:latest
    container_name: semaphore
    restart: always
    ports:
      - "127.0.0.1:${SEMAPHORE_PORT}:3000"
    environment:
      # bolt (BoltDB embutido) foi descontinuado no Semaphore 2.16 e REMOVIDO
      # de vez no 2.19 — como a imagem é :latest, "bolt" agora crasha com
      # "Unknown database dialect: bolt" (container fica em restart loop).
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
volumes:
  semaphore_config:
  semaphore_data:
networks:
  semaphore-network:
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
check_service "ERPNext (Ritmo) — API"      "https://${DOMINIO_ERP}/api/method/ping"
check_service "N8N (Harmonia) — healthz"   "https://${DOMINIO_N8N}/healthz"
check_service "Chatwoot (Harpa) — widget"  "https://${DOMINIO_CHAT}/packs/js/sdk.js"
check_service "Uptime (Eco) — Basic Auth"  "https://${DOMINIO_UPTIME}" "${BASICAUTH_USER}:${BASICAUTH_PASS}"
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
# RESUMO FINAL
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   NOMEN — INSTALAÇÃO COMPLETA: ${DOMINIO_BASE}${NC}"
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
  echo -e "  4. ${RED}Painel não publicado${NC} — rode de novo com o HTML como 4º argumento, copie pra /root/synapse_painel.html, ou crie github.com/${GITHUB_ORG}/painel."
fi
if [ "$HOME_INSTALADO" != "sim" ]; then
  echo -e "  4b. ${RED}Home não publicada${NC} — rode de novo com a pasta/arquivo como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo)."
fi
echo -e "  5. Inbox de WhatsApp no Harpa: precisa de credenciais de um provedor."
echo -e "  6. Confirmar Plano de Contas BR no Ritmo, se o passo automático não achou o nome certo."
echo -e "  7. Criar a Status Page do Eco com slug 'synapse' (Basic Auth: ${BASICAUTH_USER})."
echo -e "  8. Confirmar os 8 registros DNS (raiz/lyra/ritmo/harmonia/harpa/acorde/eco/painel) apontando pro IP desta VPS — a raiz (apex) é nova, precisa existir pra Home funcionar."
echo -e "  9. Dentro do Semaphore: criar Team/Project, cadastrar chaves SSH no Key Store,"
echo -e "     apontar o repo de playbooks (github.com/nomen-me/semaphore)."
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
