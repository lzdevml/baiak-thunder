# Baiak Thunder — Deploy Paralelo (Staging)

Deploy paralelo ao server ao vivo para validar engine + datapack antes de cutover.
**Nao toca o server ao vivo** (`baiak-server`). Portas e DB separados.

---

## Estrutura do repo

```
btdeploy/
  engine/           # source TFS-1.5-Downgrades-8.60 (copiado do tfs15source.rar)
    src/            # .cpp / .h
    cmake/          # modulos CMake
    CMakeLists.txt
  data/             # datapack baiakthunder-master completo
    world/real02.otbm
    ...
  infra/
    docker/
      engine-u32.sh # patch u32 (level/hp/mana 4 bytes)
  scripts/
    docker-entrypoint.sh
  config.lua        # config baiakthunder (DB injetado em runtime pelo entrypoint)
  schema.sql        # schema vanilla TFS (importado no primeiro boot)
  Thunder.sql       # dump completo baiakthunder (importado APOS schema.sql)
  key.pem           # RSA key do engine
  Dockerfile        # multi-stage Alpine 3.18
  docker-compose.yaml  # referencia local (NAO usar no Coolify)
  .dockerignore
```

---

## Portas

| Porta | Funcao | Live server |
|-------|--------|------------|
| 7181  | login + status | 7171 |
| 7182  | game protocol  | 7172 |

---

## Env vars (obrigatorias)

| Var | Descricao | Exemplo |
|-----|-----------|---------|
| `OT_DB_HOST` | Host do MariaDB | `db` (compose) ou IP da DB no Coolify |
| `OT_DB_NAME` | Nome do banco | `thunder` |
| `OT_DB_USER` | Usuario DB | `thunder_user` |
| `OT_DB_PASSWORD` | Senha DB | gerada |
| `OT_DB_PORT` | Porta DB (default 3306) | `3306` |
| `OT_SERVER_NAME` | serverName no config | `Baiak Thunder Staging` |
| `OT_SERVER_IP` | IP publico do server | IP da VPS |

---

## Como buildar localmente (Docker Desktop)

```bash
cd C:/tmp/btdeploy

# Subir MariaDB + engine (primeiro boot importa schema + Thunder.sql automaticamente)
OT_DB_USER=thunder_user OT_DB_PASSWORD=senha123 \
  MYSQL_ROOT_PASSWORD=root123 \
  docker compose up --build

# Acompanhar logs
docker compose logs -f engine

# Validar que o server esta ouvindo nas portas
nc -zv localhost 7181   # login
nc -zv localhost 7182   # game
```

---

## Como deployar no Coolify (passo a passo)

### Pre-requisitos
- Repo btdeploy publicado no GitHub (ex: `lzdevml/baiak-thunder`)
- Coolify com acesso ao repo (GitHub App ja configurado — getqju7h218rv22oy0v79yx7)
- MariaDB Resource separado no Coolify (projeto "baiak" ou projeto novo de staging)

### Passo 1 — Criar MariaDB Resource no Coolify

No Coolify UI (http://187.127.5.64:8000):
1. Ir em Projeto > New Resource > Database > MariaDB
2. Nome: `bt-staging-db`
3. Environment: production (ou staging se criar)
4. Configurar:
   - `MYSQL_ROOT_PASSWORD` = (senha forte gerada)
   - `MYSQL_DATABASE` = `thunder`
   - `MYSQL_USER` = `thunder_user`
   - `MYSQL_PASSWORD` = (senha forte gerada)
5. Salvar e deployar o DB — aguardar ficar healthy
6. Anotar o internal hostname do container (ex: `<uuid>-mariadb`)

### Passo 2 — Criar Application no Coolify

1. Ir em Projeto > New Resource > Application > GitHub
2. Selecionar repo `lzdevml/baiak-thunder`, branch `master`
3. Build Pack: **Dockerfile** (nao Nixpacks, nao Docker Compose)
4. Dockerfile path: `Dockerfile` (raiz do repo)
5. Portas expostas: `7181,7182` (NAO ligar proxy Traefik — game server e TCP puro)

### Passo 3 — Env vars da Application

Setar no Coolify UI (aba Environment Variables):

```
OT_DB_HOST=<internal hostname do MariaDB resource>
OT_DB_NAME=thunder
OT_DB_USER=thunder_user
OT_DB_PASSWORD=<senha do passo 1>
OT_DB_PORT=3306
OT_SERVER_NAME=Baiak Thunder Staging
OT_SERVER_IP=<IP publico da VPS, ex: 187.127.5.64>
```

### Passo 4 — Disparar deploy via API

```powershell
$TOKEN = Get-Content C:\tmp\coolify_token.txt
$APP_UUID = "<uuid-da-application-criada>"
curl -s -X GET "http://187.127.5.64:8000/api/v1/deploy?uuid=$APP_UUID&force=false" `
     -H "Authorization: Bearer $TOKEN"
```

### Passo 5 — Monitorar

```powershell
# Logs da application
$TOKEN = Get-Content C:\tmp\coolify_token.txt
$APP_UUID = "<uuid>"
curl -s "http://187.127.5.64:8000/api/v1/applications/$APP_UUID/logs" `
     -H "Authorization: Bearer $TOKEN" | ConvertFrom-Json | Select-Object -Last 50
```

Build leva ~10-15 min (compilacao C++ com -j$(nproc)).

---

## O que validar apos o deploy

- [ ] Logs do entrypoint mostram "DB is up" e "First-boot import complete"
- [ ] Logs do TFS mostram mapa carregado sem erros (`>> Loaded map...`)
- [ ] `nc -zv <VPS-IP> 7181` retorna open
- [ ] Cliente OTC conectado em `<VPS-IP>:7181` consegue logar
- [ ] Personagem aparece no mapa real02
- [ ] Level / HP / mana aparecem corretos (u32 patch valido)

---

## Rollback

Para reverter ao estado anterior: basta nao fazer o cutover.
O server ao vivo (porta 7171/7172, DB "tibia") **nao e tocado** por este deploy.
Para destruir o staging: deletar a Application e o MariaDB resource no Coolify UI.

---

## Notas tecnicas

- **Alpine 3.18 fixo**: nao bumpar. Alpine 3.19+ traz fmt 10 que quebra o build
  (`static_assert` em iomapserialize.cpp por remocao de enum formatting implicito).
- **Thunder.sql e importado APOS schema.sql**: Thunder.sql e um dump completo
  (phpMyAdmin) que inclui CREATE TABLE + dados. schema.sql e o vanilla TFS schema
  e serve de base; Thunder.sql sobrescreve / complementa com as tabelas custom.
- **Sem VOLUME para /opt/otserver/data**: o datapack fica na imagem (imutavel).
  Para mudar algo no datapack: editar arquivo, commit, redeploy.
- **Sem git clone no build**: diferentemente do live server, o engine source
  esta no repo (`engine/`). Isso elimina dependencia de rede durante o build.
- **u32 patch**: o patch `engine-u32.sh` aplica sed em `protocolgame.cpp` antes
  do cmake. O cliente mehah patchado le level/hp/mana como getU32 (4 bytes).
  Sem o patch, os valores truncam em 65535.
