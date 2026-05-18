# 🔄 Zabbix Migrador — Migração Automática 7.2 → 7.4

Script de migração automatizada entre servidores Zabbix. Um único comando em cada servidor trata de tudo: recolha, transferência e restore.

---

## ⚙️ Como Funciona

O script deteta automaticamente a versão do Zabbix instalada no servidor e executa o fluxo correspondente — não é necessário especificar nada manualmente.

---

## 🖥️ Passo 1 — No Servidor Zabbix 7.2 (Origem)

Execute o seguinte comando como **root**:

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script irá automaticamente:

1. Detetar que está no servidor **7.2**
2. Fazer a recolha completa dos dados (configuração, base de dados, ficheiros)
3. Empacotar tudo num ficheiro `.tar.gz`
4. Perguntar o **IP do servidor 7.4** para transferir o pacote via `scp`

> ✅ No final, o pacote é transferido automaticamente para `/root/` no servidor de destino.

---

## 🖥️ Passo 2 — No Servidor Zabbix 7.4 (Destino)

Execute o **mesmo comando** como **root**:

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script irá automaticamente:

1. Detetar que está no servidor **7.4**
2. Localizar o pacote de migração em `/root/`
3. Executar o restore completo
4. Apresentar o link de acesso ao Zabbix no final

> ✅ No final, o script mostra o link de acesso: `http://<IP>/zabbix`

---

## 📋 Pré-requisitos

| Requisito | Descrição |
|-----------|-----------|
| Permissões | Executar como `root` em ambos os servidores |
| Conectividade | O servidor 7.2 deve conseguir fazer `scp` para o 7.4 |
| `curl` | Disponível em ambos os servidores |
| Zabbix instalado | Versão 7.2 na origem e 7.4 no destino |

---

## 🔐 Segurança

- O script é descarregado diretamente deste repositório via HTTPS
- Recomenda-se verificar o conteúdo do script antes de executar em ambientes de produção:

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | less
```

---

## 🐛 Problemas Comuns

**O `scp` falha na transferência**
→ Verifique se a porta 22 está aberta entre os dois servidores e se as credenciais SSH estão corretas.

**O script não deteta a versão correta**
→ Confirme que o Zabbix está instalado e que o serviço está ativo: `systemctl status zabbix-server`

**Pacote não encontrado no servidor 7.4**
→ Verifique se o ficheiro existe em `/root/` e se a transferência `scp` foi concluída com sucesso.

---

## 📄 Licença

Uso interno. Consulte os responsáveis do projeto para mais informações.
