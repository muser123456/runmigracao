# Zabbix Migrador — Migração Automática 7.2 para 7.4

Script de migração automatizada entre servidores Zabbix. O script deteta automaticamente a versão instalada e executa o fluxo correspondente — recolha, transferência e restore — sem necessidade de configuração manual.

---

## Passo 1 — Servidor de Origem (Zabbix 7.2)

Execute como root:

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script irá:

1. Detetar que está no servidor 7.2
2. Recolher todos os dados (configuração, base de dados, ficheiros)
3. Empacotar num ficheiro `.tar.gz`
4. Solicitar o IP do servidor 7.4 e transferir o pacote automaticamente via `scp` para `/root/`

---

## Passo 2 — Servidor de Destino (Zabbix 7.4)

Execute o mesmo comando como root:

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | bash
```

O script irá:

1. Detetar que está no servidor 7.4
2. Localizar o pacote de migração em `/root/`
3. Executar o restore completo
4. Apresentar o endereço de acesso: `http://<IP>/zabbix`

---

## Pré-requisitos

| Requisito | Detalhe |
|-----------|---------|
| Permissões | Executar como `root` em ambos os servidores |
| Conectividade | O servidor 7.2 deve ter acesso SSH (porta 22) ao servidor 7.4 |
| `curl` | Disponível em ambos os servidores |
| Zabbix | Versão 7.2 instalada na origem, versão 7.4 instalada no destino |

---

## Verificação Prévia do Script

Recomenda-se inspecionar o conteúdo do script antes de executar em ambientes de produção:

```bash
curl -fsSL https://raw.githubusercontent.com/muser123456/runmigracao/main/zabbix_migrador.sh | less
```

---

## Resolução de Problemas

**Falha na transferência via `scp`**
Verifique se a porta 22 está acessível entre os dois servidores e se as credenciais SSH estão corretas.

**Versão não detetada corretamente**
Confirme que o serviço Zabbix está ativo: `systemctl status zabbix-server`

**Pacote não encontrado no servidor 7.4**
Verifique se o ficheiro `.tar.gz` existe em `/root/` e se a transferência foi concluída sem erros.
