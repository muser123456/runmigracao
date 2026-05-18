#!/bin/bash
# =============================================================================
#  SCRIPT 1 — RECOLHA ZABBIX 7.2
#  Executa no servidor Zabbix 7.2 como root
#  Resultado: /root/zabbix_clone/  (pronto para transferir para o 7.4)
# =============================================================================

set -euo pipefail

# ── Cores para output ────────────────────────────────────────────────────────
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

# ── Configuração ─────────────────────────────────────────────────────────────
DESTINO="/root/zabbix_clone"
DATA=$(date +%Y%m%d_%H%M%S)
LOG="$DESTINO/recolha_$DATA.log"
CONF="/etc/zabbix/zabbix_server.conf"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   RECOLHA ZABBIX 7.2 — Clone para 7.4       ║${RESET}"
echo -e "${BOLD}║   Data: $(date '+%Y-%m-%d %H:%M:%S')              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"

# ── Criar estrutura de directorios ───────────────────────────────────────────
step "[0/6] A criar estrutura de directorios"

mkdir -p "$DESTINO"/{database,configs,scripts/{alertscripts,externalscripts},ssl/{certs,keys,ssl_ca},enc,modules,logs,meta}

exec > >(tee -a "$LOG") 2>&1
echo "[$(date)] Início da recolha — Zabbix 7.2 → 7.4"

# ── Ler configurações do Zabbix ──────────────────────────────────────────────
if [[ ! -f "$CONF" ]]; then
    fail "Ficheiro de configuração não encontrado: $CONF"
    exit 1
fi

# Função para ler valor do config (ignora comentários, trata '= valor' e ' valor')
cfg() {
    grep -E "^${1}\s*=" "$CONF" 2>/dev/null \
        | head -1 \
        | sed "s/^${1}\s*=\s*//" \
        | tr -d '[:space:]' \
        || true
}

DB_NAME=$(cfg DBName)
DB_USER=$(cfg DBUser)
DB_PASS=$(cfg DBPassword)
DB_HOST=$(cfg DBHost)
DB_PORT=$(cfg DBPort)
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-3306}

ok "Estrutura criada em $DESTINO"

# ── META — gravar informações do sistema ─────────────────────────────────────
step "[1/6] A gravar meta-informações do sistema"

{
    echo "=== META INFORMAÇÕES ==="
    echo "Data recolha    : $(date)"
    echo "Hostname        : $(hostname)"
    echo "IP              : $(hostname -I | awk '{print $1}')"
    echo "OS              : $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "Zabbix versão   : $(zabbix_server --version 2>/dev/null | head -1 || echo 'N/A')"
    echo "DB Name         : $DB_NAME"
    echo "DB User         : $DB_USER"
    echo "DB Host         : $DB_HOST"
    echo "DB Port         : $DB_PORT"
    echo ""
    echo "=== SERVIÇOS ZABBIX ==="
    systemctl status zabbix-server --no-pager -l 2>/dev/null | head -10 || true
} > "$DESTINO/meta/sistema_info.txt"

ok "Meta-informações guardadas"

# ── BASE DE DADOS ─────────────────────────────────────────────────────────────
step "[2/6] A exportar base de dados"

DB_FILE="$DESTINO/database/zabbix_db_$DATA.sql"

# Detectar MySQL vs PostgreSQL
if command -v mysqldump &>/dev/null && mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -e "USE $DB_NAME" &>/dev/null 2>&1; then

    info "Motor detectado: MySQL / MariaDB"
    info "A exportar base de dados '$DB_NAME'..."

    mysqldump \
        -u"$DB_USER" \
        -p"$DB_PASS" \
        -h"$DB_HOST" \
        -P"$DB_PORT" \
        "$DB_NAME" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        --add-drop-table \
        --extended-insert \
        --complete-insert \
        > "$DB_FILE"

    echo "ENGINE=mysql" > "$DESTINO/database/db_type.txt"

elif command -v pg_dump &>/dev/null; then

    info "Motor detectado: PostgreSQL"
    info "A exportar base de dados '$DB_NAME'..."

    PGPASSWORD="$DB_PASS" pg_dump \
        -U "$DB_USER" \
        -h "$DB_HOST" \
        -F plain \
        --no-owner \
        --no-acl \
        "$DB_NAME" \
        > "$DB_FILE"

    echo "ENGINE=postgresql" > "$DESTINO/database/db_type.txt"

else
    fail "Não foi possível detectar o motor de base de dados (MySQL/MariaDB ou PostgreSQL)."
    fail "Verifica se mysqldump ou pg_dump estão instalados."
    exit 1
fi

DB_SIZE=$(du -sh "$DB_FILE" | cut -f1)
ok "Base de dados exportada: database/zabbix_db_$DATA.sql ($DB_SIZE)"

# ── FICHEIROS DE CONFIGURAÇÃO ─────────────────────────────────────────────────
step "[3/6] A copiar ficheiros de configuração"

# Preservar permissões originais com tar
CONFIGS_ENCONTRADOS=0

CONFIG_PATHS=(
    "/etc/zabbix/zabbix_server.conf"
    "/etc/zabbix/zabbix_agent2.conf"
    "/etc/zabbix/zabbix_agentd.conf"
    "/etc/zabbix/zabbix_proxy.conf"
    "/etc/zabbix/web/zabbix.conf.php"
)

for f in "${CONFIG_PATHS[@]}"; do
    if [[ -f "$f" ]]; then
        # Copiar preservando permissões e dono
        cp -a "$f" "$DESTINO/configs/"
        # Guardar metadata (dono + permissões)
        stat -c "%U %G %a %n" "$f" >> "$DESTINO/meta/file_permissions.txt"
        ok "$f"
        (( CONFIGS_ENCONTRADOS++ ))
    else
        warn "Não encontrado (ignorado): $f"
    fi
done

# Guardar directório completo do Zabbix se existir config extra
if [[ -d "/etc/zabbix" ]]; then
    tar -czf "$DESTINO/configs/etc_zabbix_completo.tar.gz" \
        --preserve-permissions \
        -C / etc/zabbix 2>/dev/null || true
    ok "Directório /etc/zabbix arquivado em configs/"
fi

ok "$CONFIGS_ENCONTRADOS ficheiro(s) de configuração copiados"

# ── SCRIPTS ───────────────────────────────────────────────────────────────────
step "[4/6] A copiar scripts externos e de alertas"

# Alert scripts
if [[ -d "/usr/lib/zabbix/alertscripts" ]]; then
    COUNT=$(find /usr/lib/zabbix/alertscripts -type f | wc -l)
    if [[ $COUNT -gt 0 ]]; then
        tar -czf "$DESTINO/scripts/alertscripts.tar.gz" \
            --preserve-permissions \
            -C /usr/lib/zabbix alertscripts
        ok "alertscripts: $COUNT ficheiro(s) arquivados"
        # Guardar permissões
        find /usr/lib/zabbix/alertscripts -type f -exec stat -c "%U %G %a %n" {} \; \
            >> "$DESTINO/meta/file_permissions.txt"
    else
        warn "alertscripts: directório vazio"
    fi
else
    warn "alertscripts: directório não encontrado"
fi

# External scripts
if [[ -d "/usr/lib/zabbix/externalscripts" ]]; then
    COUNT=$(find /usr/lib/zabbix/externalscripts -type f | wc -l)
    if [[ $COUNT -gt 0 ]]; then
        tar -czf "$DESTINO/scripts/externalscripts.tar.gz" \
            --preserve-permissions \
            -C /usr/lib/zabbix externalscripts
        ok "externalscripts: $COUNT ficheiro(s) arquivados"
        find /usr/lib/zabbix/externalscripts -type f -exec stat -c "%U %G %a %n" {} \; \
            >> "$DESTINO/meta/file_permissions.txt"
    else
        warn "externalscripts: directório vazio"
    fi
else
    warn "externalscripts: directório não encontrado"
fi

# ── SSL / TLS ─────────────────────────────────────────────────────────────────
step "[5/6] A copiar certificados SSL e chaves PSK"

SSL_ENCONTRADO=0

if [[ -d "/var/lib/zabbix/ssl" ]]; then
    TOTAL=$(find /var/lib/zabbix/ssl -type f | wc -l)
    if [[ $TOTAL -gt 0 ]]; then
        tar -czf "$DESTINO/ssl/ssl_completo.tar.gz" \
            --preserve-permissions \
            -C /var/lib/zabbix ssl
        find /var/lib/zabbix/ssl -type f -exec stat -c "%U %G %a %n" {} \; \
            >> "$DESTINO/meta/file_permissions.txt"
        ok "SSL: $TOTAL ficheiro(s) arquivados"
        SSL_ENCONTRADO=1
    fi
fi

# Chaves PSK
PSK_ENCONTRADO=0

if [[ -d "/var/lib/zabbix/enc" ]]; then
    TOTAL=$(find /var/lib/zabbix/enc -type f | wc -l)
    if [[ $TOTAL -gt 0 ]]; then
        tar -czf "$DESTINO/enc/enc_completo.tar.gz" \
            --preserve-permissions \
            -C /var/lib/zabbix enc
        find /var/lib/zabbix/enc -type f -exec stat -c "%U %G %a %n" {} \; \
            >> "$DESTINO/meta/file_permissions.txt"
        ok "Chaves enc/PSK: $TOTAL ficheiro(s) arquivados"
        PSK_ENCONTRADO=1
    fi
fi

# PSK definido manualmente no config
PSK_FILE=$(cfg TLSPSKFile || true)
if [[ -n "$PSK_FILE" && -f "$PSK_FILE" ]]; then
    cp -a "$PSK_FILE" "$DESTINO/enc/"
    stat -c "%U %G %a %n" "$PSK_FILE" >> "$DESTINO/meta/file_permissions.txt"
    ok "PSK extra copiado: $PSK_FILE"
    PSK_ENCONTRADO=1
fi

[[ $SSL_ENCONTRADO -eq 0 ]] && warn "Sem SSL configurado (ignorado)"
[[ $PSK_ENCONTRADO -eq 0 ]] && warn "Sem chaves PSK configuradas (ignorado)"

# ── MÓDULOS DO FRONTEND ───────────────────────────────────────────────────────
step "[6/6] A copiar módulos do frontend"

if [[ -d "/usr/share/zabbix/modules" ]]; then
    COUNT=$(find /usr/share/zabbix/modules -mindepth 1 -maxdepth 1 -type d | wc -l)
    if [[ $COUNT -gt 0 ]]; then
        tar -czf "$DESTINO/modules/modules.tar.gz" \
            --preserve-permissions \
            -C /usr/share/zabbix modules
        ok "Módulos frontend: $COUNT módulo(s) arquivados"
    else
        warn "Módulos: directório vazio"
    fi
else
    warn "Sem módulos personalizados em /usr/share/zabbix/modules"
fi

# ── LOGS DO ZABBIX (opcional — últimas 1000 linhas) ──────────────────────────
if [[ -f "/var/log/zabbix/zabbix_server.log" ]]; then
    tail -1000 /var/log/zabbix/zabbix_server.log > "$DESTINO/logs/zabbix_server_tail.log"
    ok "Últimas 1000 linhas do log guardadas"
fi

# ── COMPRIMIR TUDO ───────────────────────────────────────────────────────────
echo ""
info "A comprimir o pacote final..."

PACOTE="/root/zabbix_clone_${DATA}.tar.gz"
tar -czf "$PACOTE" \
    --preserve-permissions \
    -C /root zabbix_clone

PACOTE_SIZE=$(du -sh "$PACOTE" | cut -f1)

# ── RELATÓRIO FINAL ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║           RECOLHA CONCLUÍDA ✔                ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo "  📦 Pacote final  : $PACOTE ($PACOTE_SIZE)"
echo "  📁 Directório    : $DESTINO"
echo "  📋 Log           : $LOG"
echo ""
echo "  Conteúdo recolhido:"
find "$DESTINO" -type f | sort | while read -r f; do
    SIZE=$(du -sh "$f" | cut -f1)
    echo "    [$SIZE]  ${f#$DESTINO/}"
done
echo ""
echo -e "  ${CYAN}Próximo passo — transferir para o servidor 7.4:${RESET}"
echo "  scp root@$(hostname -I | awk '{print $1}'):$PACOTE /root/"
echo ""
echo "[$(date)] Recolha concluída com sucesso." >> "$LOG"
