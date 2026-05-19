# Zabbix Migrador — Migração Automática 7.2 para 7.4

Script único que migra um servidor Zabbix 7.2 para um servidor Zabbix 7.4. O mesmo comando é executado em ambas as máquinas — o script deteta automaticamente a versão instalada e decide se deve fazer a recolha (origem) ou o restore (destino).

---

## Pré-requisitos

| Requisito | Detalhe |
|-----------|---------|
| Permissões | Executar como `root` em ambos os servidores |
| Zabbix 7.2 | Instalado e com `/etc/zabbix/zabbix_server.conf` presente na máquina de origem |
| Zabbix 7.4 | Instalado e com `/etc/zabbix/zabbix_server.conf` presente na máquina de destino |
| Base de dados | MySQL/MariaDB ou PostgreSQL acessível com as credenciais definidas no `zabbix_server.conf` |
| Conectividade SSH | O servidor 7.2 precisa de acesso SSH (porta 22) ao servidor 7.4 para transferir o pacote via `scp` |
| `curl` | Disponível em ambos os servidores |

---

## Passo 1 — Executar no servidor 7.2 (origem)

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script deteta a versão 7.2 e executa automaticamente os seguintes passos:

**[1/6] Estrutura de directorios**
Cria `/root/zabbix_clone/` com as subpastas `database/`, `configs/`, `scripts/`, `ssl/`, `enc/`, `modules/`, `logs/` e `meta/`.

**[2/6] Meta-informações**
Guarda em `meta/info.env` o hostname, IP, versão do Zabbix, nome da base de dados e sistema operativo da máquina de origem. Este ficheiro é usado pelo script no servidor 7.4 para identificar a origem dos dados.

**[3/6] Exportação da base de dados**
Lê as credenciais diretamente do `/etc/zabbix/zabbix_server.conf` (campos `DBName`, `DBUser`, `DBPassword`, `DBHost`, `DBPort`) e exporta com `mysqldump` para MySQL/MariaDB ou com `pg_dump` para PostgreSQL. O ficheiro SQL fica em `database/zabbix_db_<data>.sql`.

**[4/6] Configurações**
Copia todo o directório `/etc/zabbix/` incluindo `zabbix_server.conf`, `zabbix.conf.php` (frontend), `zabbix_agent2.conf` e `zabbix_agentd.conf`.

**[5/6] Scripts**
Copia os alertscripts e externalscripts de `/usr/lib/zabbix/`.

**[6/6] SSL e chaves PSK**
Copia os certificados de `/var/lib/zabbix/ssl/` e as chaves PSK de `/var/lib/zabbix/enc/`.

No final, comprime tudo num único ficheiro `/root/zabbix_clone_<data>.tar.gz` e pergunta:

```
IP do servidor Zabbix 7.4: _
```

Se introduzir o IP, o pacote é transferido automaticamente:

```bash
scp /root/zabbix_clone_<data>.tar.gz root@<IP_7.4>:/root/
```

Se deixar o campo em branco, o script mostra o comando `scp` para executar manualmente mais tarde.

---

## Passo 2 — Executar no servidor 7.4 (destino)

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script deteta a versão 7.4, localiza automaticamente o ficheiro `zabbix_clone_*.tar.gz` mais recente em `/root/` e executa:

**[1/7] Extração do pacote**
Extrai o pacote para `/root/zabbix_restore_work/` e lê o `meta/info.env` para mostrar a informação do servidor de origem (hostname, IP, versão, base de dados).

**[2/7] Paragem dos serviços**
Para `zabbix-server`, `zabbix-agent2` e `zabbix-agent` antes de qualquer alteração.

**[3/7] Backup do estado atual do 7.4**
Antes de sobrescrever qualquer dado, cria um backup completo do servidor 7.4 em `/root/zabbix_74_backup_<data>/`, incluindo o dump SQL atual e o directório `/etc/zabbix/`. Permite reverter em caso de erro.

**[4/7] Importação da base de dados**
Apaga a base de dados existente no 7.4, recria-a e importa o dump SQL proveniente do 7.2. Suporta MySQL/MariaDB e PostgreSQL. As credenciais usadas são as do `zabbix_server.conf` do servidor 7.4.

**[5/7] Restauro das configurações**
Restaura o directório `/etc/zabbix/` com os ficheiros provenientes da origem.

**[6/7] Restauro de scripts, SSL e PSK**
Restaura alertscripts, externalscripts, certificados SSL e chaves PSK nos caminhos originais. Corrige automaticamente todas as permissões:
- `chown -R zabbix:zabbix` em `/var/lib/zabbix/` e `/usr/lib/zabbix/`
- `chmod 640` no `zabbix_server.conf`
- `chmod +x` em todos os scripts de alerta e externos

**[7/7] Arranque do Zabbix 7.4**
Inicia o `zabbix-server`. O Zabbix 7.4 executa automaticamente o upgrade do schema da base de dados de 7.2 para 7.4 sem intervenção manual. O script aguarda até 120 segundos a confirmar nos logs que o servidor arrancou com sucesso.

No final apresenta o endereço de acesso e os ficheiros de log:

```
IP desta máquina (7.4) : 192.168.x.x
Backup pré-restore     : /root/zabbix_74_backup_<data>/
Log do restore         : /root/zabbix_restore_<data>.log

http://192.168.x.x/zabbix
```

---

## Verificações após a migração

1. Abrir no browser: `http://<IP_DO_7.4>/zabbix`
2. Confirmar a versão em Administration → General
3. Verificar hosts, templates e triggers
4. Confirmar histórico de dados
5. Testar um alerta

Para acompanhar os logs em tempo real:

```bash
tail -f /var/log/zabbix/zabbix_server.log
```

---

## Estrutura do pacote de migração

```
/root/zabbix_clone_<data>.tar.gz
└── zabbix_clone/
    ├── meta/
    │   └── info.env              # hostname, IP, versão, credenciais da BD
    ├── database/
    │   ├── zabbix_db_<data>.sql  # dump completo da base de dados
    │   └── db_type.txt           # mysql ou postgresql
    ├── configs/
    │   ├── etc_zabbix.tar.gz     # /etc/zabbix/ completo
    │   ├── zabbix_server.conf
    │   ├── zabbix.conf.php
    │   └── zabbix_agent2.conf
    ├── scripts/
    │   ├── alertscripts.tar.gz
    │   └── externalscripts.tar.gz
    ├── ssl/
    │   └── ssl.tar.gz
    ├── enc/
    │   └── enc.tar.gz            # chaves PSK
    ├── modules/
    │   └── modules.tar.gz        # módulos de frontend
    └── logs/
        └── server_tail.log       # últimas 500 linhas do log do servidor
```

---

## Comportamento com versões diferentes de 7.2 e 7.4

Se o script for executado numa máquina com uma versão do Zabbix que não seja 7.2 nem 7.4, não assume nada e pergunta manualmente:

```
[1] Origem  — Esta máquina é o servidor a copiar (recolha)
[2] Destino — Esta máquina é o servidor novo (restore)

Escolha (1 ou 2): _
```

---

## Reversão em caso de erro

O script cria automaticamente um backup do servidor 7.4 antes de qualquer alteração em `/root/zabbix_74_backup_<data>/`. Este directório contém o dump SQL original e as configurações, permitindo restaurar o estado anterior se necessário.

---

## Resolução de problemas

**O script não deteta a versão**
Verifique se o Zabbix está instalado e o serviço registado: `systemctl status zabbix-server`. O script tenta a deteção por três métodos: binário `zabbix_server --version`, gestor de pacotes (`rpm` ou `dpkg`) e presença do ficheiro de configuração.

**Falha na transferência via `scp`**
Verifique se a porta 22 está acessível entre os dois servidores e se o login SSH como `root` está permitido no servidor 7.4 (`PermitRootLogin` em `/etc/ssh/sshd_config`). O `scp` pode pedir a password do root do servidor 7.4 durante a execução.

**Pacote não encontrado no servidor 7.4**
Confirme que o ficheiro `zabbix_clone_*.tar.gz` está presente em `/root/`. Se não for encontrado automaticamente, o script pede o caminho completo.

**O servidor demora a arrancar após o restore**
O upgrade automático do schema pode demorar vários minutos dependendo do volume de dados históricos. O script aguarda até 120 segundos. Acompanhe com: `tail -f /var/log/zabbix/zabbix_server.log`.
