#!/bin/bash
# Registra um cliente em inventory/clientes_ativos.yml da branch de INVENTARIO, de forma segura sob concorrencia.
# Uso: registrar_inventario_com_retry.sh <dominio> <vps_ip> <nome_loja> [timestamp]
# Env: INV_BRANCH (padrao inventario) | INV_REPO_URL (padrao https://x-access-token:$GITHUB_TOKEN@github.com/nomen-me/synapse.git)
#      INV_MAX_TENTATIVAS (padrao 15)
# Garantia: a mudanca e REAPLICADA sobre a ponta atual da branch a cada tentativa (nunca forca, nunca descarta em
# silencio). Se nao conseguir apos N tentativas, sai com erro != 0 (o provisionamento NAO e dado como concluido).
set -u
DOMINIO="${1:?dominio}"; VPS_IP="${2:?vps_ip}"; NOME="${3:?nome_loja}"; TS="${4:-$(date -u +%FT%TZ)}"
BRANCH="${INV_BRANCH:-inventario}"; MAX="${INV_MAX_TENTATIVAS:-15}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${INV_REPO_URL:-}"
[ -z "$URL" ] && { [ -n "${GITHUB_TOKEN:-}" ] || { echo "ERRO: GITHUB_TOKEN ou INV_REPO_URL ausente" >&2; exit 2; }; URL="https://x-access-token:${GITHUB_TOKEN}@github.com/nomen-me/synapse.git"; }
redigir() { if [ -n "${GITHUB_TOKEN:-}" ]; then sed "s/${GITHUB_TOKEN}/***REDACTED***/g"; else cat; fi; }
LOCK=/tmp/synapse_inventario.lock
for i in $(seq 1 "$MAX"); do
  TMP="$(mktemp -d)"
  if ! git clone --quiet --depth 1 --branch "$BRANCH" "$URL" "$TMP" 2> >(redigir >&2); then
    echo "tentativa $i/$MAX: clone da branch '$BRANCH' falhou" >&2; rm -rf "$TMP"; sleep $((RANDOM % 3 + 1)); continue
  fi
  RES="$(python3 "$SCRIPT_DIR/registrar_cliente_inventario.py" "$TMP/inventory/clientes_ativos.yml" "$DOMINIO" "$VPS_IP" "$NOME" "$TS")" || { echo "ERRO no registro local do inventario" >&2; rm -rf "$TMP"; exit 3; }
  case "$RES" in
    *JA_EXISTIA*) echo "JA_EXISTIA (tentativa $i)"; rm -rf "$TMP"; exit 0;;
  esac
  ( cd "$TMP" && git config user.email semaphore@nomen.me && git config user.name "Semaphore (registro automatico de cliente)" \
    && git add inventory/clientes_ativos.yml && git commit --quiet -m "chore(inventario): adiciona/atualiza ${DOMINIO}" )
  if ( cd "$TMP" && git push --quiet origin "HEAD:${BRANCH}" 2> >(redigir >&2) ); then
    echo "ADICIONADO (tentativa $i)"; rm -rf "$TMP"; exit 0
  fi
  echo "tentativa $i/$MAX: push recusado (outra atualizacao chegou antes); reaplicando sobre a ponta atual" >&2
  rm -rf "$TMP"; sleep "0.$((RANDOM % 9 + 1))"
done
echo "ERRO: inventario NAO atualizado para ${DOMINIO} apos ${MAX} tentativas (nada foi descartado em silencio; reexecute)." >&2
exit 4
