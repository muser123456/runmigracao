#!/bin/bash
# =============================================================================
#  SCRIPT 2 — RESTORE ZABBIX 7.4
#  Executa no servidor Zabbix 7.4 como root
#  Requer: o ficheiro zabbix_clone_YYYYMMDD_HHMMSS.tar.gz transferido do 7.2
# =============================================================================

set -euo pipefail

# ── Cores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}    ✔  $*${RESET}"; }
info() { echo -e "${CYAN}  ▸  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✖  $*${RESET}"; }
step() { echo -e "\n${BOLD}>>> $*${RESET}"; }

# ── Verificar root ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "Este script tem de ser executado como root."
    exit 1
fi

# ── Localizar pacote ─────────────────────────────────────────────────────────
PACOTE="${1:-}"

if [[ -z "$PACOTE" ]]; then
    # Tentar encontrar automaticamente
    PACOTE=$(ls -t /root/zabbix_clone_*.tar.gz 2>/dev/null | head -1 || true)
fi

if [[ -z "$PACOTE" || ! -f "$PACOTE" ]]; then
    fail "Pacote não encontrado. Uso: $0 /root/zabbix_clone_YYYYMMDD_HHMMSS.tar.gz"
    exit 1
fi

# ── Configuração ─────────────────────────────────────────────────────────────
WORK="/root/zabbix_restore_work"
DATA=$(date +%Y%m%d_%H%M%S)
LOG="/root/zabbix_restore_$DATA.log"
CONF_74="/etc/zabbix/zabbix_server.conf"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   RESTORE ZABBIX 7.4 — Clone do 7.2         ║${RESET}"
echo -e "${BOLD}║   Data: $(date '+%Y-%m-%d %H:%M:%S')              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""
info "Pacote: $PACOTE"

exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] Início do restore — Zabbix 7.4"

# ── Extrair pacote ───────────────────────────────────────────────────────────
step "[0/7] A extrair pacote"

rm -rf "$WORK"
mkdir -p "$WORK"
tar -xzf "$PACOTE" --preserve-permissions -C "$WORK"

# Encontrar o directório extraído
CLONE=$(find "$WORK" -maxdepth 2 -name "sistema_info.txt" | head -1 | xargs dirname | xargs dirname || true)
if [[ -z "$CLONE" ]]; then
    CLONE="$WORK/zabbix_clone"
fi

ok "Pacote extraído em $WORK"

# Mostrar meta-informações do servidor de origem
if [[ -f "$CLONE/meta/sistema_info.txt" ]]; then
    echo ""
    echo "  ──── Servidor de origem (7.2) ────"
    grep -E "^(Hostname|IP|OS|Zabbix versão|DB Name|DB Host)" \
        "$CLONE/meta/sistema_info.txt" | sed 's/^/  /'
    echo ""
fi

# ── Ler configuração do Zabbix 7.4 ──────────────────────────────────────────
cfg74() {
    grep -E "^${1}\s*=" "$CONF_74" 2>/dev/null \
        | head -1 \
        | sed "s/^${1}\s*=\s*//" \
        | tr -d '[:space:]' \
        || true
}

DB_NAME=$(cfg74 DBName)
DB_USER=$(cfg74 DBUser)
DB_PASS=$(cfg74 DBPassword)
DB_HOST=$(cfg74 DBHost)
DB_PORT=$(cfg74 DBPort)
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-3306}

info "Base de dados 7.4: $DB_NAME @ $DB_HOST"

# ── Parar serviços Zabbix ────────────────────────────────────────────────────
step "[1/7] A parar serviços Zabbix"

for SVC in zabbix-server zabbix-agent2 zabbix-agent; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        systemctl stop "$SVC"
        ok "Parado: $SVC"
    else
        warn "$SVC não está a correr (ignorado)"
    fi
done

# ── BACKUP DO 7.4 ANTES DE SOBRESCREVER ──────────────────────────────────────
step "[2/7] A fazer backup do estado actual do 7.4 (por segurança)"

BACKUP_74="/root/zabbix_74_backup_antes_restore_$DATA"
mkdir -p "$BACKUP_74"

# Backup DB actual do 7.4
DB_TYPE_FILE="$CLONE/database/db_type.txt"
DB_ENGINE="mysql"
[[ -f "$DB_TYPE_FILE" ]] && DB_ENGINE=$(grep -oP '(?<=ENGINE=)\w+' "$DB_TYPE_FILE" || echo "mysql")

if [[ "$DB_ENGINE" == "postgresql" ]]; then
    PGPASSWORD="$DB_PASS" pg_dump -U "$DB_USER" -h "$DB_HOST" "$DB_NAME" \
        > "$BACKUP_74/zabbix_74_pre_restore.sql" 2>/dev/null || true
else
    mysqldump -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" \
        --single-transaction \
        > "$BACKUP_74/zabbix_74_pre_restore.sql" 2>/dev/null || true
fi

# Backup configs actuais
[[ -d "/etc/zabbix" ]] && cp -a /etc/zabbix "$BACKUP_74/etc_zabbix_74/" 2>/dev/null || true

ok "Backup do 7.4 guardado em $BACKUP_74"

# ── RESTAURAR BASE DE DADOS ───────────────────────────────────────────────────
step "[3/7] A restaurar base de dados"

DB_FILE=$(ls "$CLONE/database/"*.sql 2>/dev/null | head -1 || true)

if [[ -z "$DB_FILE" ]]; then
    fail "Ficheiro SQL não encontrado em $CLONE/database/"
    exit 1
fi

DB_SIZE=$(du -sh "$DB_FILE" | cut -f1)
info "A importar: $(basename $DB_FILE) ($DB_SIZE)"

if [[ "$DB_ENGINE" == "postgresql" ]]; then

    info "Motor: PostgreSQL"
    # Limpar DB existente e reimportar
    PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -h "$DB_HOST" -c \
        "DROP DATABASE IF EXISTS ${DB_NAME}_old; ALTER DATABASE $DB_NAME RENAME TO ${DB_NAME}_old;" \
        postgres 2>/dev/null || true
    PGPASSWORD="$DB_PASS" createdb -U "$DB_USER" -h "$DB_HOST" "$DB_NAME" 2>/dev/null || true
    PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -h "$DB_HOST" "$DB_NAME" < "$DB_FILE"

else

    info "Motor: MySQL / MariaDB"
    # Apagar todas as tabelas existentes antes de importar
    mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -P"$DB_PORT" \
        -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
    mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -P"$DB_PORT" "$DB_NAME" < "$DB_FILE"

fi

ok "Base de dados importada com sucesso"

# ── RESTAURAR CONFIGURAÇÕES ───────────────────────────────────────────────────
step "[4/7] A restaurar ficheiros de configuração"

# Extrair configs arquivadas
if [[ -f "$CLONE/configs/etc_zabbix_completo.tar.gz" ]]; then
    info "A restaurar /etc/zabbix/ completo..."
    tar -xzf "$CLONE/configs/etc_zabbix_completo.tar.gz" \
        --preserve-permissions \
        -C /
    ok "Directório /etc/zabbix/ restaurado"
else
    # Copiar ficheiros individuais
    for f in "$CLONE/configs/"*; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.tar.gz ]] && continue
        NOME=$(basename "$f")
        cp -a "$f" "/etc/zabbix/$NOME" 2>/dev/null && ok "$NOME" || warn "Não foi possível copiar $NOME"
    done
fi

# ── RESTAURAR SCRIPTS ─────────────────────────────────────────────────────────
step "[5/7] A restaurar scripts"

if [[ -f "$CLONE/scripts/alertscripts.tar.gz" ]]; then
    tar -xzf "$CLONE/scripts/alertscripts.tar.gz" \
        --preserve-permissions \
        -C /usr/lib/zabbix/
    ok "alertscripts restaurados"
fi

if [[ -f "$CLONE/scripts/externalscripts.tar.gz" ]]; then
    tar -xzf "$CLONE/scripts/externalscripts.tar.gz" \
        --preserve-permissions \
        -C /usr/lib/zabbix/
    ok "externalscripts restaurados"
fi

# ── RESTAURAR SSL / PSK ───────────────────────────────────────────────────────
step "[6/7] A restaurar certificados SSL e chaves PSK"

mkdir -p /var/lib/zabbix/{ssl/{certs,keys,ssl_ca},enc}

if [[ -f "$CLONE/ssl/ssl_completo.tar.gz" ]]; then
    tar -xzf "$CLONE/ssl/ssl_completo.tar.gz" \
        --preserve-permissions \
        -C /var/lib/zabbix/
    ok "Certificados SSL restaurados"
else
    warn "Sem SSL para restaurar"
fi

if [[ -f "$CLONE/enc/enc_completo.tar.gz" ]]; then
    tar -xzf "$CLONE/enc/enc_completo.tar.gz" \
        --preserve-permissions \
        -C /var/lib/zabbix/
    ok "Chaves PSK/enc restauradas"
else
    warn "Sem chaves PSK para restaurar"
fi

# Ficheiros PSK individuais
for f in "$CLONE/enc/"*; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.tar.gz ]] && continue
    cp -a "$f" /var/lib/zabbix/enc/
done

# ── RESTAURAR MÓDULOS DO FRONTEND ─────────────────────────────────────────────
if [[ -f "$CLONE/modules/modules.tar.gz" ]]; then
    mkdir -p /usr/share/zabbix/modules
    tar -xzf "$CLONE/modules/modules.tar.gz" \
        --preserve-permissions \
        -C /usr/share/zabbix/
    ok "Módulos frontend restaurados"
fi

# ── CORRIGIR PERMISSÕES ───────────────────────────────────────────────────────
step "[6b] A corrigir permissões e donos"

# Donos padrão do Zabbix
chown -R zabbix:zabbix /var/lib/zabbix/ 2>/dev/null || true
chown -R zabbix:zabbix /usr/lib/zabbix/ 2>/dev/null || true
chown root:zabbix /etc/zabbix/zabbix_server.conf 2>/dev/null || true
chmod 640 /etc/zabbix/zabbix_server.conf 2>/dev/null || true

# Tornar scripts executáveis
find /usr/lib/zabbix/alertscripts/ -type f -exec chmod +x {} \; 2>/dev/null || true
find /usr/lib/zabbix/externalscripts/ -type f -exec chmod +x {} \; 2>/dev/null || true

ok "Permissões corrigidas"

# ── INICIAR SERVIÇOS ──────────────────────────────────────────────────────────
step "[7/7] A iniciar serviços Zabbix"

info "O Zabbix 7.4 vai agora fazer upgrade automático do schema (7.2 → 7.4)..."
info "Isto pode demorar alguns minutos dependendo do tamanho da DB."

systemctl start zabbix-server
sleep 5

# Aguardar que o upgrade do DB termine
MAX_ESPERA=120
ESPERA=0
info "A aguardar upgrade do schema da base de dados..."
while true; do
    if journalctl -u zabbix-server --since "2 minutes ago" --no-pager 2>/dev/null \
        | grep -q "server #0 started"; then
        ok "Zabbix 7.4 iniciado com sucesso!"
        break
    fi
    if [[ $ESPERA -ge $MAX_ESPERA ]]; then
        warn "Timeout aguardando arranque. Verificar logs manualmente."
        break
    fi
    sleep 5
    (( ESPERA+=5 ))
    info "  ... aguardando ($ESPERA/${MAX_ESPERA}s)"
done

# Iniciar agente se existir
for SVC in zabbix-agent2 zabbix-agent; do
    if systemctl list-unit-files | grep -q "$SVC"; then
        systemctl start "$SVC" 2>/dev/null && ok "Iniciado: $SVC" || true
    fi
done

# ── VERIFICAÇÃO FINAL ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}──── Verificação do sistema ────${RESET}"

# Estado dos serviços
for SVC in zabbix-server zabbix-agent2; do
    if systemctl is-active --quiet "$SVC" 2>/dev/null; then
        ok "Serviço $SVC: ACTIVO ✔"
    else
        warn "Serviço $SVC: não está a correr"
    fi
done

# Versão DB após upgrade
echo ""
info "Últimas linhas do log (verificar upgrade da DB):"
tail -20 /var/log/zabbix/zabbix_server.log 2>/dev/null \
    | grep -E "(version|upgrade|started|error)" \
    | tail -10 \
    | sed 's/^/    /'

# ── RELATÓRIO FINAL ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║           RESTORE CONCLUÍDO ✔                ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo "  📋 Log do restore    : $LOG"
echo "  💾 Backup pré-restore: $BACKUP_74"
echo ""
echo -e "  ${CYAN}Verificações recomendadas:${RESET}"
echo "  1. Abre o frontend do Zabbix 7.4 no browser"
echo "  2. Vai a Administration → General → verifica versão"
echo "  3. Verifica que os hosts, templates e triggers estão todos presentes"
echo "  4. Verifica que o histórico de dados está intacto"
echo "  5. Testa um alerta para confirmar que os scripts funcionam"
echo ""
echo "  tail -f /var/log/zabbix/zabbix_server.log"
echo ""
echo "[$(date)] Restore concluído." >> "$LOG"
