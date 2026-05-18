#!/bin/bash
# =============================================================================
#  ZABBIX MIGRADOR — Script único e automático
#  Detecta sozinho se está no servidor 7.2 (origem) ou 7.4 (destino)
#  e executa a acção correcta em cada máquina.
#
#  USO:
#    curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
# =============================================================================

set -euo pipefail

# ── Cores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}    ✔  $*${RESET}"; }
info() { echo -e "${CYAN}  ▸  $*${RESET}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
fail() { echo -e "${RED}  ✖  $*${RESET}"; exit 1; }
step() { echo -e "\n${BOLD}>>> $*${RESET}"; }
linha(){ echo -e "${BOLD}══════════════════════════════════════════════${RESET}"; }

# ── Verificar root ───────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && fail "Este script tem de ser executado como root.\nUsa: sudo bash <(curl -fsSL ...)"

# ── Banner ───────────────────────────────────────────────────────────────────
clear
echo ""
linha
echo -e "${BOLD}   ZABBIX MIGRADOR — Clone automático 7.2 → 7.4${RESET}"
echo -e "   $(date '+%Y-%m-%d %H:%M:%S')"
linha

# =============================================================================
#  DETECÇÃO AUTOMÁTICA DA VERSÃO DO ZABBIX
# =============================================================================
step "A detectar versão do Zabbix nesta máquina..."

IP_LOCAL=$(hostname -I | awk '{print $1}')
HOSTNAME_LOCAL=$(hostname)

info "Hostname : $HOSTNAME_LOCAL"
info "IP       : $IP_LOCAL"

# Tentar obter versão instalada
ZABBIX_VER=""

# Método 1: binário zabbix_server
if command -v zabbix_server &>/dev/null; then
    ZABBIX_VER=$(zabbix_server --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || true)
fi

# Método 2: package manager
if [[ -z "$ZABBIX_VER" ]]; then
    ZABBIX_VER=$(rpm -q zabbix-server-mysql zabbix-server-pgsql 2>/dev/null \
        | grep -oP '\d+\.\d+' | head -1 || true)
fi
if [[ -z "$ZABBIX_VER" ]]; then
    ZABBIX_VER=$(dpkg -l 'zabbix-server-*' 2>/dev/null \
        | grep -oP '\d+\.\d+' | head -1 || true)
fi

# Método 3: ficheiro de configuração
if [[ -z "$ZABBIX_VER" && -f /etc/zabbix/zabbix_server.conf ]]; then
    warn "Versão não detectada pelo binário, a assumir pela presença do config..."
    ZABBIX_VER="desconhecida"
fi

[[ -z "$ZABBIX_VER" ]] && fail "Zabbix não encontrado nesta máquina. Verifica a instalação."

info "Versão detectada: Zabbix $ZABBIX_VER"

# Determinar papel desta máquina
PAPEL=""
VER_MAJOR=$(echo "$ZABBIX_VER" | cut -d. -f1)
VER_MINOR=$(echo "$ZABBIX_VER" | cut -d. -f2)

if [[ "$VER_MAJOR" == "7" && "$VER_MINOR" == "2" ]]; then
    PAPEL="ORIGEM"
elif [[ "$VER_MAJOR" == "7" && "$VER_MINOR" == "4" ]]; then
    PAPEL="DESTINO"
else
    echo ""
    warn "Versão $ZABBIX_VER não é 7.2 nem 7.4."
    echo ""
    echo "  Esta máquina tem Zabbix $ZABBIX_VER."
    echo "  Qual é o papel desta máquina na migração?"
    echo ""
    echo "  [1] Origem  — Esta máquina é o servidor a copiar (recolha)"
    echo "  [2] Destino — Esta máquina é o servidor novo (restore)"
    echo ""
    read -rp "  Escolha (1 ou 2): " ESCOLHA
    case "$ESCOLHA" in
        1) PAPEL="ORIGEM" ;;
        2) PAPEL="DESTINO" ;;
        *) fail "Opção inválida." ;;
    esac
fi

echo ""
echo -e "  ${BOLD}Papel desta máquina: ${CYAN}$PAPEL${RESET}"
echo ""

# =============================================================================
#  FUNÇÕES AUXILIARES
# =============================================================================

# Ler valor do zabbix_server.conf
cfg() {
    local KEY="$1"
    local FILE="${2:-/etc/zabbix/zabbix_server.conf}"
    grep -E "^${KEY}\s*=" "$FILE" 2>/dev/null \
        | head -1 \
        | sed "s/^${KEY}\s*=\s*//" \
        | tr -d '[:space:]' \
        || true
}

# =============================================================================
#  PAPEL: ORIGEM (Zabbix 7.2) — RECOLHA
# =============================================================================
modo_recolha() {
    linha
    echo -e "${BOLD}   MODO: RECOLHA (Zabbix $ZABBIX_VER — Origem)${RESET}"
    linha

    DESTINO="/root/zabbix_clone"
    DATA=$(date +%Y%m%d_%H%M%S)
    LOG="$DESTINO/recolha_$DATA.log"
    CONF="/etc/zabbix/zabbix_server.conf"

    [[ ! -f "$CONF" ]] && fail "Configuração não encontrada: $CONF"

    # Ler config da DB
    DB_NAME=$(cfg DBName)
    DB_USER=$(cfg DBUser)
    DB_PASS=$(cfg DBPassword)
    DB_HOST=$(cfg DBHost); DB_HOST=${DB_HOST:-localhost}
    DB_PORT=$(cfg DBPort); DB_PORT=${DB_PORT:-3306}

    # Criar estrutura
    step "[1/6] A criar estrutura de directorios"
    mkdir -p "$DESTINO"/{database,configs,scripts/{alertscripts,externalscripts},ssl,enc,modules,logs,meta}
    exec > >(tee -a "$LOG") 2>&1
    ok "Estrutura criada em $DESTINO"

    # Meta-informações
    step "[2/6] A guardar meta-informações"
    {
        echo "ZABBIX_VERSION=$ZABBIX_VER"
        echo "HOSTNAME=$HOSTNAME_LOCAL"
        echo "IP=$IP_LOCAL"
        echo "DATA=$DATA"
        echo "DB_NAME=$DB_NAME"
        echo "DB_USER=$DB_USER"
        echo "DB_HOST=$DB_HOST"
        echo "DB_PORT=$DB_PORT"
        echo "OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -a)"
    } > "$DESTINO/meta/info.env"
    ok "Meta-informações guardadas (IP de origem: $IP_LOCAL)"

    # Base de dados
    step "[3/6] A exportar base de dados"
    DB_FILE="$DESTINO/database/zabbix_db_$DATA.sql"

    if command -v mysqldump &>/dev/null && \
       mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -e "USE $DB_NAME" &>/dev/null 2>&1; then

        info "Motor: MySQL / MariaDB — a exportar '$DB_NAME'..."
        mysqldump -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -P"$DB_PORT" "$DB_NAME" \
            --single-transaction --routines --triggers --events \
            --hex-blob --add-drop-table --complete-insert \
            > "$DB_FILE"
        echo "ENGINE=mysql" > "$DESTINO/database/db_type.txt"

    elif command -v pg_dump &>/dev/null; then
        info "Motor: PostgreSQL — a exportar '$DB_NAME'..."
        PGPASSWORD="$DB_PASS" pg_dump -U "$DB_USER" -h "$DB_HOST" \
            -F plain --no-owner --no-acl "$DB_NAME" > "$DB_FILE"
        echo "ENGINE=postgresql" > "$DESTINO/database/db_type.txt"

    else
        fail "Motor de base de dados não detectado (MySQL ou PostgreSQL)."
    fi

    ok "Base de dados exportada ($(du -sh "$DB_FILE" | cut -f1))"

    # Configurações
    step "[4/6] A copiar configurações"
    tar -czf "$DESTINO/configs/etc_zabbix.tar.gz" \
        --preserve-permissions -C / etc/zabbix 2>/dev/null || true

    for f in /etc/zabbix/zabbix_server.conf /etc/zabbix/web/zabbix.conf.php \
              /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agentd.conf; do
        [[ -f "$f" ]] && { cp -a "$f" "$DESTINO/configs/"; ok "$f"; } || true
    done

    # Scripts
    step "[5/6] A copiar scripts"
    for DIR in alertscripts externalscripts; do
        SRC="/usr/lib/zabbix/$DIR"
        if [[ -d "$SRC" ]] && [[ $(find "$SRC" -type f | wc -l) -gt 0 ]]; then
            tar -czf "$DESTINO/scripts/${DIR}.tar.gz" \
                --preserve-permissions -C /usr/lib/zabbix "$DIR"
            ok "$DIR: $(find $SRC -type f | wc -l) ficheiro(s)"
        else
            warn "$DIR: vazio ou não encontrado"
        fi
    done

    # SSL / PSK
    step "[6/6] A copiar SSL e chaves PSK"
    [[ -d /var/lib/zabbix/ssl ]] && \
        tar -czf "$DESTINO/ssl/ssl.tar.gz" \
            --preserve-permissions -C /var/lib/zabbix ssl 2>/dev/null && ok "SSL copiado" || true

    [[ -d /var/lib/zabbix/enc ]] && \
        tar -czf "$DESTINO/enc/enc.tar.gz" \
            --preserve-permissions -C /var/lib/zabbix enc 2>/dev/null && ok "PSK/enc copiado" || true

    PSK_FILE=$(cfg TLSPSKFile || true)
    [[ -n "$PSK_FILE" && -f "$PSK_FILE" ]] && cp -a "$PSK_FILE" "$DESTINO/enc/" && ok "PSK extra: $PSK_FILE" || true

    # Módulos frontend
    if [[ -d /usr/share/zabbix/modules ]] && \
       [[ $(find /usr/share/zabbix/modules -mindepth 1 -maxdepth 1 -type d | wc -l) -gt 0 ]]; then
        tar -czf "$DESTINO/modules/modules.tar.gz" \
            --preserve-permissions -C /usr/share/zabbix modules
        ok "Módulos frontend copiados"
    fi

    # Logs recentes
    [[ -f /var/log/zabbix/zabbix_server.log ]] && \
        tail -500 /var/log/zabbix/zabbix_server.log > "$DESTINO/logs/server_tail.log" || true

    # Comprimir pacote final
    echo ""
    info "A comprimir pacote final..."
    PACOTE="/root/zabbix_clone_${DATA}.tar.gz"
    tar -czf "$PACOTE" --preserve-permissions -C /root zabbix_clone

    # ── Perguntar se quer transferir agora para o 7.4 ────────────────────────
    echo ""
    linha
    echo -e "${BOLD}   RECOLHA CONCLUÍDA ✔${RESET}"
    linha
    echo ""
    echo "  📦 Pacote : $PACOTE ($(du -sh "$PACOTE" | cut -f1))"
    echo "  📋 Log    : $LOG"
    echo ""
    echo -e "  ${CYAN}Queres transferir o pacote agora para o servidor 7.4?${RESET}"
    echo ""
    read -rp "  IP do servidor Zabbix 7.4: " IP_74

    if [[ -n "$IP_74" ]]; then
        echo ""
        info "A transferir pacote para $IP_74..."
        scp "$PACOTE" "root@${IP_74}:/root/"

        ok "Pacote transferido para root@${IP_74}:/root/"
        echo ""
        echo -e "  ${CYAN}Agora no servidor 7.4, executa:${RESET}"
        echo ""
        echo "  curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash"
        echo ""
    else
        echo ""
        warn "Transferência ignorada. Faz manualmente:"
        echo "  scp $PACOTE root@IP_DO_74:/root/"
        echo ""
        echo "  Depois no servidor 7.4:"
        echo "  curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash"
        echo ""
    fi
}

# =============================================================================
#  PAPEL: DESTINO (Zabbix 7.4) — RESTORE
# =============================================================================
modo_restore() {
    linha
    echo -e "${BOLD}   MODO: RESTORE (Zabbix $ZABBIX_VER — Destino)${RESET}"
    linha

    # Localizar pacote automaticamente
    PACOTE=$(ls -t /root/zabbix_clone_*.tar.gz 2>/dev/null | head -1 || true)

    if [[ -z "$PACOTE" ]]; then
        echo ""
        warn "Pacote não encontrado automaticamente em /root/"
        read -rp "  Caminho completo do pacote .tar.gz: " PACOTE
        [[ ! -f "$PACOTE" ]] && fail "Ficheiro não encontrado: $PACOTE"
    fi

    info "Pacote encontrado: $PACOTE ($(du -sh "$PACOTE" | cut -f1))"

    # Extrair
    step "[1/7] A extrair pacote"
    WORK="/root/zabbix_restore_work"
    DATA=$(date +%Y%m%d_%H%M%S)
    LOG="/root/zabbix_restore_$DATA.log"

    rm -rf "$WORK"
    mkdir -p "$WORK"
    tar -xzf "$PACOTE" --preserve-permissions -C "$WORK"

    CLONE=$(find "$WORK" -name "info.env" | head -1 | xargs dirname | xargs dirname || true)
    [[ -z "$CLONE" ]] && CLONE="$WORK/zabbix_clone"

    exec > >(tee -a "$LOG") 2>&1
    ok "Pacote extraído"

    # Mostrar info do servidor de origem
    if [[ -f "$CLONE/meta/info.env" ]]; then
        source "$CLONE/meta/info.env" 2>/dev/null || true
        echo ""
        echo "  ── Servidor de origem ──────────────────"
        echo "  Hostname  : ${HOSTNAME:-N/A}"
        echo "  IP origem : ${IP:-N/A}"
        echo "  Versão    : Zabbix ${ZABBIX_VERSION:-N/A}"
        echo "  Base dados: ${DB_NAME:-N/A}"
        echo "  ────────────────────────────────────────"
        echo ""
        # Restaurar variáveis de DB da origem para usar no import
        DB_NAME_ORIG="${DB_NAME:-zabbix}"
        DB_USER_ORIG="${DB_USER:-zabbix}"
        DB_HOST_ORIG="${DB_HOST:-localhost}"
    fi

    # Ler config do 7.4 (destino)
    CONF_74="/etc/zabbix/zabbix_server.conf"
    DB_NAME_74=$(cfg DBName "$CONF_74")
    DB_USER_74=$(cfg DBUser "$CONF_74")
    DB_PASS_74=$(cfg DBPassword "$CONF_74")
    DB_HOST_74=$(cfg DBHost "$CONF_74"); DB_HOST_74=${DB_HOST_74:-localhost}
    DB_PORT_74=$(cfg DBPort "$CONF_74"); DB_PORT_74=${DB_PORT_74:-3306}

    info "Base de dados destino: $DB_NAME_74 @ $DB_HOST_74"

    # Parar serviços
    step "[2/7] A parar serviços"
    for SVC in zabbix-server zabbix-agent2 zabbix-agent; do
        systemctl is-active --quiet "$SVC" 2>/dev/null && \
            { systemctl stop "$SVC"; ok "Parado: $SVC"; } || true
    done

    # Backup do 7.4 antes de sobrescrever
    step "[3/7] A fazer backup do estado actual do 7.4"
    BACKUP="/root/zabbix_74_backup_$DATA"
    mkdir -p "$BACKUP"

    DB_ENGINE=$(grep -oP '(?<=ENGINE=)\w+' "$CLONE/database/db_type.txt" 2>/dev/null || echo "mysql")

    if [[ "$DB_ENGINE" == "postgresql" ]]; then
        PGPASSWORD="$DB_PASS_74" pg_dump -U "$DB_USER_74" -h "$DB_HOST_74" "$DB_NAME_74" \
            > "$BACKUP/zabbix_74_backup.sql" 2>/dev/null || true
    else
        mysqldump -u"$DB_USER_74" -p"$DB_PASS_74" -h"$DB_HOST_74" "$DB_NAME_74" \
            --single-transaction > "$BACKUP/zabbix_74_backup.sql" 2>/dev/null || true
    fi
    [[ -d /etc/zabbix ]] && cp -a /etc/zabbix "$BACKUP/etc_zabbix/" 2>/dev/null || true
    ok "Backup guardado em $BACKUP"

    # Importar base de dados
    step "[4/7] A importar base de dados"
    DB_FILE=$(ls "$CLONE/database/"*.sql 2>/dev/null | head -1 || true)
    [[ -z "$DB_FILE" ]] && fail "Ficheiro SQL não encontrado em $CLONE/database/"

    info "A importar: $(basename "$DB_FILE") ($(du -sh "$DB_FILE" | cut -f1))"

    if [[ "$DB_ENGINE" == "postgresql" ]]; then
        PGPASSWORD="$DB_PASS_74" psql -U "$DB_USER_74" -h "$DB_HOST_74" \
            -c "DROP DATABASE IF EXISTS $DB_NAME_74;" postgres 2>/dev/null || true
        PGPASSWORD="$DB_PASS_74" createdb -U "$DB_USER_74" -h "$DB_HOST_74" "$DB_NAME_74" 2>/dev/null || true
        PGPASSWORD="$DB_PASS_74" psql -U "$DB_USER_74" -h "$DB_HOST_74" "$DB_NAME_74" < "$DB_FILE"
    else
        mysql -u"$DB_USER_74" -p"$DB_PASS_74" -h"$DB_HOST_74" -P"$DB_PORT_74" \
            -e "DROP DATABASE IF EXISTS $DB_NAME_74; CREATE DATABASE $DB_NAME_74 CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
        mysql -u"$DB_USER_74" -p"$DB_PASS_74" -h"$DB_HOST_74" -P"$DB_PORT_74" \
            "$DB_NAME_74" < "$DB_FILE"
    fi
    ok "Base de dados importada"

    # Restaurar configurações
    step "[5/7] A restaurar configurações"
    if [[ -f "$CLONE/configs/etc_zabbix.tar.gz" ]]; then
        tar -xzf "$CLONE/configs/etc_zabbix.tar.gz" \
            --preserve-permissions -C / 2>/dev/null
        ok "Directório /etc/zabbix/ restaurado"
    fi

    # Restaurar scripts
    step "[6/7] A restaurar scripts, SSL e PSK"
    for ARQ in alertscripts externalscripts; do
        [[ -f "$CLONE/scripts/${ARQ}.tar.gz" ]] && \
            tar -xzf "$CLONE/scripts/${ARQ}.tar.gz" \
                --preserve-permissions -C /usr/lib/zabbix/ && ok "$ARQ restaurado" || true
    done

    [[ -f "$CLONE/ssl/ssl.tar.gz" ]] && \
        tar -xzf "$CLONE/ssl/ssl.tar.gz" \
            --preserve-permissions -C /var/lib/zabbix/ && ok "SSL restaurado" || true

    [[ -f "$CLONE/enc/enc.tar.gz" ]] && \
        tar -xzf "$CLONE/enc/enc.tar.gz" \
            --preserve-permissions -C /var/lib/zabbix/ && ok "PSK/enc restaurado" || true

    # Módulos frontend
    if [[ -f "$CLONE/modules/modules.tar.gz" ]]; then
        mkdir -p /usr/share/zabbix/modules
        tar -xzf "$CLONE/modules/modules.tar.gz" \
            --preserve-permissions -C /usr/share/zabbix/
        ok "Módulos frontend restaurados"
    fi

    # Corrigir permissões
    chown -R zabbix:zabbix /var/lib/zabbix/ 2>/dev/null || true
    chown -R zabbix:zabbix /usr/lib/zabbix/ 2>/dev/null || true
    chown root:zabbix /etc/zabbix/zabbix_server.conf 2>/dev/null || true
    chmod 640 /etc/zabbix/zabbix_server.conf 2>/dev/null || true
    find /usr/lib/zabbix/alertscripts/ -type f -exec chmod +x {} \; 2>/dev/null || true
    find /usr/lib/zabbix/externalscripts/ -type f -exec chmod +x {} \; 2>/dev/null || true
    ok "Permissões corrigidas"

    # Iniciar Zabbix 7.4 (faz upgrade do schema automaticamente)
    step "[7/7] A iniciar Zabbix 7.4"
    info "O Zabbix 7.4 vai fazer upgrade automático do schema (7.2 → 7.4)..."

    systemctl start zabbix-server
    sleep 5

    # Aguardar arranque
    MAX=120; ESPERA=0
    while true; do
        if journalctl -u zabbix-server --since "2 minutes ago" --no-pager 2>/dev/null \
           | grep -q "server #0 started\|database version is up to date"; then
            ok "Zabbix 7.4 iniciado!"; break
        fi
        [[ $ESPERA -ge $MAX ]] && { warn "A demorar mais que o esperado — verifica os logs."; break; }
        sleep 5; (( ESPERA+=5 ))
        info "  ... aguardando arranque ($ESPERA/${MAX}s)"
    done

    for SVC in zabbix-agent2 zabbix-agent; do
        systemctl list-unit-files 2>/dev/null | grep -q "$SVC" && \
            systemctl start "$SVC" 2>/dev/null && ok "Iniciado: $SVC" || true
    done

    # Relatório final
    echo ""
    linha
    echo -e "${BOLD}   CLONE CONCLUÍDO ✔${RESET}"
    linha
    echo ""
    echo "  IP desta máquina (7.4) : $IP_LOCAL"
    echo "  Backup pré-restore     : $BACKUP"
    echo "  Log do restore         : $LOG"
    echo ""
    echo -e "  ${CYAN}Estado dos serviços:${RESET}"
    for SVC in zabbix-server zabbix-agent2; do
        systemctl is-active --quiet "$SVC" 2>/dev/null \
            && echo -e "    ${GREEN}✔ $SVC — ACTIVO${RESET}" \
            || echo -e "    ${YELLOW}⚠ $SVC — inactivo${RESET}"
    done
    echo ""
    echo -e "  ${CYAN}Verificações recomendadas:${RESET}"
    echo "  1. Abre o browser: http://$IP_LOCAL/zabbix"
    echo "  2. Administration → General → verifica versão"
    echo "  3. Confirma hosts, templates e triggers"
    echo "  4. Verifica histórico de dados"
    echo "  5. Testa um alerta"
    echo ""
    echo "  tail -f /var/log/zabbix/zabbix_server.log"
    echo ""
}

# =============================================================================
#  EXECUTAR MODO CORRECTO
# =============================================================================
case "$PAPEL" in
    ORIGEM)  modo_recolha ;;
    DESTINO) modo_restore ;;
esac
