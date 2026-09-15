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
#    - Painel (mesmo produto pra todo cliente) → 4º argumento local,
#      /root/synapse_painel.html, ou clone de github.com/nomen-me/painel
#      (nessa ordem — ver seção 9.5)
#    - Home/site da raiz (próprio da loja, diferente pra cada cliente,
#      sem repo padrão) → 5º argumento local, /root/home-site (pasta) ou
#      /root/index.html (arquivo) — ver seção 9.6
#
#  Pré-requisitos antes de rodar:
#    - VPS Ubuntu 24.04 limpa, root/sudo
#    - 7 registros DNS tipo A apontando pro IP desta VPS:
#        ritmo. harmonia. harpa. acorde. eco. painel. <dominio-base>
#        + o próprio <dominio-base> (raiz/apex, sem subdomínio — é onde a
#        Home é publicada, seção 9.6)
#    - LYRA_CENTRAL_URL, LYRA_ADMIN_API_KEY e GITHUB_TOKEN exportados no ambiente
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
err()  { echo -e "${RED}[ERRO]${NC} $1"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $1"; exit 1; }

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
apt install -y curl git nano ufw jq python3 || fatal "Falha ao instalar pacotes base."

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
    image: traefik:v3.6
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
#    É o mesmo produto (Painel de operações) pra todo cliente, um único
#    arquivo HTML/CSS/JS sem build: em runtime, ele resolve os domínios de
#    Ritmo/Harmonia/Harpa/Eco a partir do próprio hostname (ver
#    resolverAmbienteSynapse() dentro do arquivo) — então servir esse
#    arquivo estático é tudo que este passo precisa fazer.
#    Fonte, em ordem de prioridade:
#      (a) arquivo local passado como 4º argumento do script
#          (PAINEL_HTML_OVERRIDE)
#      (b) /root/synapse_painel.html na própria VPS (default, sem precisar
#          passar argumento — só copiar o arquivo pra lá antes de rodar)
#      (c) github.com/nomen-me/painel, index.html na raiz (ou 1 nível
#          abaixo) — normalmente é esta a fonte usada em produção, já que
#          é o mesmo Painel pra todo cliente
#    Se nenhuma das três existir, o passo é pulado (não-fatal, mesmo padrão
#    usado pro Brazil NF e pros workflows do Harmonia) e entra no resumo
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
  cp "$PAINEL_HTML_ORIGEM" /home/ubuntu/painel/index.html

  # Preenche em runtime os 2 únicos valores que o próprio arquivo não tem
  # como descobrir sozinho (o resto é resolvido no navegador a partir do
  # hostname) — sem isso, alguém teria que editar isso à mão depois de
  # publicado. Se o layout do SYNAPSE_CONFIG mudar no repo do painel, estes
  # dois sed's silenciosamente não substituem nada (o grep abaixo avisa).
  sed -i "s|empresa: null,.*|empresa: '$(printf '%s' "$NOME_LOJA" | sed "s/'/\\\\'/g")', // preenchido automaticamente pela instalação|" /home/ubuntu/painel/index.html
  sed -i "s|chatwootContaId: null,.*|chatwootContaId: ${CW_ACCOUNT_ID:-null}, // preenchido automaticamente pela instalação|" /home/ubuntu/painel/index.html

  if grep -q "empresa: null" /home/ubuntu/painel/index.html; then
    warn "Não consegui preencher 'empresa' automaticamente no Painel (o texto 'empresa: null,' não foi encontrado no arquivo — o layout do SYNAPSE_CONFIG pode ter mudado). Preencha manualmente."
  fi
  if grep -q "chatwootContaId: null" /home/ubuntu/painel/index.html && [ -n "${CW_ACCOUNT_ID:-}" ]; then
    warn "Não consegui preencher 'chatwootContaId' automaticamente no Painel. Preencha manualmente com o valor ${CW_ACCOUNT_ID}."
  fi

  cat > /home/ubuntu/painel/docker-compose.yml << EOF
services:
  painel:
    image: nginx:alpine
    container_name: painel
    restart: always
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
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
  cd /home/ubuntu/painel && docker compose up -d
  ok "Painel publicado em https://${DOMINIO_PAINEL} (empresa='${NOME_LOJA}', chatwootContaId=${CW_ACCOUNT_ID:-null} já preenchidos)"
  PAINEL_INSTALADO="sim"
else
  warn "Painel NÃO foi publicado — nenhuma fonte de HTML disponível nesta execução. Rode de novo passando o caminho local como 4º argumento, copiando o arquivo pra /root/synapse_painel.html, ou criando github.com/${GITHUB_ORG}/painel com o index.html (o script é idempotente)."
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
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  check_service "Painel"                     "https://${DOMINIO_PAINEL}"
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
echo -e "${GREEN}   SYNAPSE — PROVISIONAMENTO CONCLUÍDO: ${DOMINIO_BASE}${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Ritmo (ERPNext)   → https://${DOMINIO_ERP}"
echo -e "  Harmonia (N8N)    → https://${DOMINIO_N8N}"
echo -e "  Harpa (Chatwoot)  → https://${DOMINIO_CHAT}"
echo -e "  Eco (Uptime)      → https://${DOMINIO_UPTIME}"
echo -e "  Acorde (Netdata)  → https://${DOMINIO_NETDATA}"
if [ "$PAINEL_INSTALADO" = "sim" ]; then
  echo -e "  Painel            → https://${DOMINIO_PAINEL}"
else
  echo -e "  Painel            → ${RED}NÃO publicado nesta execução${NC} (ver pendência 8 abaixo)"
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
if [ -z "$LYRA_API_KEY" ]; then
  echo -e "  8. ${RED}Onboarding da Lyra falhou — rode o script de novo (é idempotente) depois de corrigir LYRA_CENTRAL_URL/LYRA_ADMIN_API_KEY.${NC}"
fi
if [ "$PAINEL_INSTALADO" != "sim" ]; then
  echo -e "  8. ${RED}Painel não publicado${NC} — rode de novo com o HTML como 4º argumento, copie pra /root/synapse_painel.html, ou crie github.com/${GITHUB_ORG}/painel."
fi
if [ "$HOME_INSTALADO" != "sim" ]; then
  echo -e "  9. ${RED}Home não publicada${NC} — rode de novo com a pasta/arquivo como 5º argumento, ou copie pra /root/home-site (pasta) ou /root/index.html (arquivo)."
fi
echo -e "${GREEN}============================================================${NC}"

}

# Chamada única, na última linha do arquivo — só a partir daqui o bash
# executa qualquer coisa (ver comentário no início da função main acima).
main "$@"
