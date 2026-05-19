<div align="center">

# Zabbix Migrador

### Migração automática de Zabbix 7.2 para 7.4

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![Zabbix](https://img.shields.io/badge/Zabbix-7.2_→_7.4-D40000?style=flat-square&logo=zabbix&logoColor=white)
![Root](https://img.shields.io/badge/Requer-root-critical?style=flat-square)
![License](https://img.shields.io/badge/Uso-Interno-blue?style=flat-square)

</div>

---

## Como funciona

Um único comando executado em cada servidor. O script deteta automaticamente a versão do Zabbix instalada e decide se executa a **recolha** (7.2) ou o **restore** (7.4).

---

## Execução

> Executar como `root` em ambos os servidores, pela ordem indicada.

**`PASSO 1` — Servidor de origem (Zabbix 7.2)**

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script recolhe todos os dados, comprime num pacote e pede o IP do servidor 7.4 para transferir automaticamente via `scp`.

**`PASSO 2` — Servidor de destino (Zabbix 7.4)**

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script localiza o pacote em `/root/`, executa o restore completo e apresenta o endereço de acesso no final.

---

## O que é migrado

| Componente | Origem |
|---|---|
| Base de dados | MySQL/MariaDB ou PostgreSQL via `zabbix_server.conf` |
| Configurações | `/etc/zabbix/` |
| Scripts | `/usr/lib/zabbix/alertscripts` e `externalscripts` |
| Certificados e PSK | `/var/lib/zabbix/ssl` e `enc` |
| Módulos frontend | `/usr/share/zabbix/modules` |

---

## Requisitos

| | |
|---|---|
| Permissões | `root` em ambos os servidores |
| Zabbix | Instalado com `zabbix_server.conf` presente em cada máquina |
| Conectividade | Acesso SSH porta `22` do servidor 7.2 para o 7.4 |
| `curl` | Disponível em ambos os servidores |

---

## Após a migração

Aceder no browser:

```
http://<IP_DO_SERVIDOR_7.4>/zabbix
```

O Zabbix 7.4 realiza o upgrade do schema da base de dados automaticamente ao arrancar. Para acompanhar:

```bash
tail -f /var/log/zabbix/zabbix_server.log
```

---

<div align="center">

> **Segurança** — Antes de qualquer alteração, o script cria automaticamente um backup do servidor 7.4 em `/root/zabbix_74_backup_<data>/`

</div>
