# Zabbix Migrador — 7.2 para 7.4

Migração automática entre servidores Zabbix. O mesmo comando é executado em ambas as máquinas — o script deteta a versão instalada e executa a recolha ou o restore conforme o caso.

---

## Requisitos

- Executar como `root` em ambos os servidores
- Zabbix instalado com `/etc/zabbix/zabbix_server.conf` presente em cada máquina
- Acesso SSH (porta 22) do servidor 7.2 para o servidor 7.4

---

## Execução

O mesmo comando nas duas máquinas, pela ordem indicada:

**No servidor 7.2:**
```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```
No final da recolha, o script pede o IP do servidor 7.4 e transfere o pacote automaticamente.

**No servidor 7.4:**
```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```
O script localiza o pacote em `/root/`, faz o restore completo e apresenta o link de acesso no final.

---

## O que é migrado

- Base de dados completa (MySQL/MariaDB ou PostgreSQL)
- Configurações de `/etc/zabbix/`
- Scripts de alerta e externos de `/usr/lib/zabbix/`
- Certificados SSL e chaves PSK de `/var/lib/zabbix/`
- Módulos de frontend

---

## Após a migração

Abrir no browser: `http://<IP_DO_7.4>/zabbix`

O Zabbix 7.4 faz o upgrade do schema da base de dados automaticamente ao arrancar.

Para acompanhar o arranque:
```bash
tail -f /var/log/zabbix/zabbix_server.log
```

---

## Notas

- O script cria um backup do estado atual do servidor 7.4 em `/root/zabbix_74_backup_<data>/` antes de qualquer alteração.
- Se a versão do Zabbix não for 7.2 nem 7.4, o script pergunta manualmente qual o papel da máquina.
- Se preferir transferir o pacote manualmente, deixe o campo de IP em branco e execute depois: `scp /root/zabbix_clone_*.tar.gz root@<IP_7.4>:/root/`
