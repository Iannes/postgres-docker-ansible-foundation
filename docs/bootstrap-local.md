# Local Bootstrap — Smart Market PostgreSQL

Operational guide for standing up and running the local PostgreSQL environment.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker Engine | 24.x or later recommended |
| Docker Compose v2 | `docker compose` (plugin), not `docker-compose` (v1) |
| `openssl` | For generating credentials |
| `psql` (optional) | Only needed for `--remote` mode in `db-connect.sh` |

Verify your setup:

```bash
docker --version
docker compose version
```

Both commands must succeed before continuing.

---

## First-time setup

### 1. Clone and enter the repo

```bash
git clone <repo-url> smartmarket-infra
cd smartmarket-infra
```

### 2. Create your `.env` file

```bash
cp env/.env.example .env
```

Open `.env` and replace every `CHANGEME_` value with a real credential. Generate strong passwords with:

```bash
openssl rand -base64 32
```

You need values for:

- `POSTGRES_PASSWORD` — PostgreSQL superuser password
- `SMARTMARKET_MIGRATIONS_PASSWORD` — password for the migrations role
- `SMARTMARKET_PIPELINE_PASSWORD` — password for the pipeline runtime role

Leave `POSTGRES_IMAGE_TAG`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_HOST_AUTH_METHOD`, `POSTGRES_LOCAL_PORT`, `BACKUP_DIR`, and `BACKUP_RETENTION_COUNT` at their defaults unless you have a reason to change them.

**Never commit `.env`.** It is listed in `.gitignore`.

### 3. Run the bootstrap script

```bash
./scripts/bootstrap-local.sh
```

This script:
1. Checks Docker is available and running
2. Validates `.env` has no placeholder values
3. Pulls the pinned PostgreSQL image
4. Starts the stack (base compose + local override)
5. Waits for the healthcheck to pass
6. Runs a smoke-test query to confirm connectivity
7. Verifies the application roles were created

On success you will see:

```
[bootstrap] ✓ PostgreSQL is running
```

The bootstrap is safe to re-run. If the volume already exists, PostgreSQL starts without re-initialising it.

---

## What the bootstrap creates

### Docker resources

| Resource | Name | Notes |
|---|---|---|
| Container | `smartmarket_postgres` | PostgreSQL 16.3, pinned |
| Volume | `smartmarket_postgres_data` | Named volume, persists across `down`/`up` |
| Network | `smartmarket_net` | Internal bridge, no external exposure |

### Database roles

| Role | Purpose | Auth |
|---|---|---|
| `postgres` | Superuser, operator use only | scram-sha-256 (TCP) / trust (unix socket) |
| `smartmarket_migrations` | DDL: run by migration tooling | scram-sha-256 |
| `smartmarket_pipeline` | DML runtime: pipeline process | scram-sha-256 |

### Schema

The `smartmarket` schema is created and owned by `smartmarket_migrations`. The `smartmarket_pipeline` role has `USAGE` on the schema and `SELECT/INSERT/UPDATE/DELETE` on all tables created by `smartmarket_migrations` (via default privileges). Table creation is the responsibility of your migration runner — not this bootstrap.

---

## Connecting to the database

### As superuser (local, unix socket — no password)

```bash
./scripts/db-connect.sh
```

This runs `docker exec psql` via the unix socket inside the container. No password is required. This is the intended local operator access path.

### As an application role (TCP via published port)

```bash
./scripts/db-connect.sh --role migrations
./scripts/db-connect.sh --role pipeline
```

Requires `psql` installed locally. Uses `127.0.0.1:5432` (or `POSTGRES_LOCAL_PORT`). Password is read from `.env`.

### Direct psql (if you prefer)

```bash
docker exec -it smartmarket_postgres psql -U postgres -d smartmarket
```

### Using a GUI tool (DBeaver, TablePlus, etc.)

Connect with:

| Field | Value |
|---|---|
| Host | `127.0.0.1` |
| Port | `5432` (or `POSTGRES_LOCAL_PORT`) |
| Database | `smartmarket` |
| User | `postgres` |
| Password | `POSTGRES_PASSWORD` from `.env` |

The port is only available locally because of the `127.0.0.1` bind in `docker-compose.override.yml`.

### Remote access (production)

```bash
./scripts/db-connect.sh --remote deploy@your-server-ip
./scripts/db-connect.sh --remote deploy@your-server-ip:2222   # custom SSH port
```

Opens an SSH tunnel and connects through it. PostgreSQL is never exposed publicly; the tunnel is the only remote access path.

---

## Backup and restore

### Create a backup

```bash
./scripts/backup.sh
```

Produces `./backups/smartmarket_YYYYMMDD_HHMMSS.dump` (PostgreSQL custom format, compressed). Old backups beyond `BACKUP_RETENTION_COUNT` are removed automatically.

To skip rotation:

```bash
./scripts/backup.sh --no-rotate
```

### Restore from a backup

```bash
./scripts/restore.sh ./backups/smartmarket_20260401_120000.dump
```

This **drops and recreates** the database. You must type the database name to confirm. See the header of `scripts/restore.sh` for full notes on role handling and disaster recovery.

### Full disaster recovery (fresh volume)

If the volume is lost or you want a clean rebuild:

```bash
# 1. Tear down (removes the volume)
docker compose --project-name smartmarket \
  -f docker/compose/docker-compose.yml down -v

# 2. Bootstrap (creates roles + empty database)
./scripts/bootstrap-local.sh

# 3. Restore data
./scripts/restore.sh ./backups/smartmarket_<timestamp>.dump
```

---

## Stopping and starting

### Stop (keep data)

```bash
docker compose --project-name smartmarket \
  -f docker/compose/docker-compose.yml down
```

The `postgres_data` volume persists. `up` resumes from where you left off.

### Stop and destroy data

```bash
docker compose --project-name smartmarket \
  -f docker/compose/docker-compose.yml down -v
```

The `-v` flag removes the named volume. **All data is lost.** Back up first if needed.

### Start again after stopping

```bash
docker compose \
  --project-name smartmarket \
  --env-file .env \
  -f docker/compose/docker-compose.yml \
  -f docker/compose/docker-compose.override.yml \
  up -d
```

Or just run `./scripts/bootstrap-local.sh` again — it is safe to re-run.

---

## Monitoring

### Container status and health

```bash
docker ps --filter name=smartmarket_postgres
docker inspect --format='{{.State.Health.Status}}' smartmarket_postgres
```

### Container logs

```bash
docker logs smartmarket_postgres
docker logs --follow smartmarket_postgres
```

Log rotation is configured at 10 MB / 3 files. If you are running verbose query logging, monitor log growth.

### Disk usage

```bash
docker system df -v                     # volume sizes
du -sh ./backups/                       # backup directory
docker volume inspect smartmarket_postgres_data   # volume path on host
```

---

## Troubleshooting

**Bootstrap fails: "placeholder value not replaced"**
Open `.env`, find the `CHANGEME_` value flagged, replace it with a real credential, and re-run.

**Bootstrap fails: healthcheck timed out**
Check container logs:
```bash
docker logs smartmarket_postgres
```
Common causes: wrong password in `.env`, port conflict (5432 already in use on host), insufficient disk space for the volume.

**Port 5432 already in use**
Change `POSTGRES_LOCAL_PORT=5433` (or any free port) in `.env` and re-run bootstrap.

**Application roles missing after bootstrap**
This happens if the volume was created before the initdb scripts were added. The initdb scripts only run when the data directory is first initialised. To re-run them:
```bash
docker compose --project-name smartmarket \
  -f docker/compose/docker-compose.yml down -v
./scripts/bootstrap-local.sh
```
This destroys the volume. Back up first if the database has data.

**Restore fails: "role does not exist"**
The roles must exist before restoring. Run `bootstrap-local.sh` to create them, then restore. See the full disaster recovery procedure above.

**`docker compose` not found**
You have Docker Compose v1 (`docker-compose`). Upgrade to Docker Engine 24+ with the Compose plugin, or install it separately. The scripts use `docker compose` (v2 syntax) and will not work with `docker-compose` v1.

---

## Security notes

- The local port (`127.0.0.1:5432`) is only reachable from your machine. It is not accessible from other hosts on your network.
- The `.env` file contains real credentials and is git-ignored. Keep it out of shared drives and note-taking apps.
- The `postgres` superuser connection via unix socket uses `trust` auth (Docker image default for local connections). This is acceptable inside a container on a development machine. It is not a production concern because the socket is not externally reachable.
- PostgreSQL TLS is not configured locally. All access is through the Docker private network or localhost. See `docs/architecture.md` for the full TLS rationale.
- In production, access is exclusively via SSH tunnel. See `docs/deploy-production.md` (Phase 3).

---

## Reference: manual compose commands

Run from the project root. Always pass `--project-name smartmarket` for consistent container naming.

```bash
# Start
docker compose --project-name smartmarket --env-file .env \
  -f docker/compose/docker-compose.yml \
  -f docker/compose/docker-compose.override.yml \
  up -d

# Stop (keep data)
docker compose --project-name smartmarket \
  -f docker/compose/docker-compose.yml down

# Stop and remove volume
docker compose --project-name smartmarket \
  -f docker/compose/docker-compose.yml down -v

# View logs
docker compose --project-name smartmarket \
  -f docker/compose/docker-compose.yml logs -f

# Pull latest pinned image
docker compose --project-name smartmarket --env-file .env \
  -f docker/compose/docker-compose.yml pull
```
