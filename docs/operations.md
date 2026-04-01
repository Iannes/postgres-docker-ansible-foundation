# Operations Guide — Smart Market PostgreSQL

Day-to-day operational reference for the production PostgreSQL deployment.

---

## Local vs production: key differences

| Concern | Local development | Production VPS |
|---|---|---|
| Compose files | `docker-compose.yml` + `docker-compose.override.yml` | `docker-compose.yml` + `docker-compose.prod.yml` |
| Port 5432 published | Yes, `127.0.0.1:5432` (override file) | No — never published |
| `.env` location | Project root on your machine | `/opt/smartmarket/.env` (mode 600, Ansible-managed) |
| `.env` source | Manually copied from `env/.env.example` | Templated by Ansible from Ansible Vault |
| Stack managed by | `scripts/bootstrap-local.sh` | `systemd` — `smartmarket.service` |
| Admin DB access | `docker exec psql` or `127.0.0.1:5432` | SSH tunnel only |
| Start command | `./scripts/bootstrap-local.sh` | `systemctl start smartmarket` |
| Stop command | `docker compose ... down` | `systemctl stop smartmarket` |
| Logs | `docker logs smartmarket_postgres` | Same (via SSH) |
| Backup | `./scripts/backup.sh` (local) | `./scripts/backup.sh` (via SSH or Phase 4 timer) |

The base `docker-compose.yml` is **identical** in both environments. Production deploys it verbatim. All environment-specific differences live in the overlay files and the `.env` source.

---

## Connecting to the production database

**PostgreSQL is never reachable from the public internet.** The only access path is an SSH tunnel.

### Using the provided helper script

```bash
# From your local machine (project root)
./scripts/db-connect.sh --remote deploy@YOUR_VPS_IP

# With a custom SSH port (if you changed ssh_port in vars.yml)
./scripts/db-connect.sh --remote deploy@YOUR_VPS_IP:2222

# Connect as the migrations role
./scripts/db-connect.sh --remote deploy@YOUR_VPS_IP --role migrations
```

### Manual SSH tunnel

```bash
# Open tunnel (background)
ssh -f -N -L 15432:127.0.0.1:5432 deploy@YOUR_VPS_IP

# Connect with psql
PGPASSWORD="your-postgres-password" psql \
  -h 127.0.0.1 -p 15432 -U postgres -d smartmarket

# Close the tunnel when done
kill $(pgrep -f "15432:127.0.0.1:5432")
```

Use port `15432` (not `5432`) for the local tunnel end to avoid collision with a running local development instance.

---

## Service management

All service operations run on the production server as the `deploy` user (or with `sudo` where required).

### Check service status
```bash
systemctl status smartmarket
```

A healthy service shows `active (exited)` — this is correct for `Type=oneshot RemainAfterExit=yes`. It means `docker compose up --detach --wait` completed successfully and the containers are running.

### Start the stack
```bash
sudo systemctl start smartmarket
```

### Stop the stack (containers stop, volume preserved)
```bash
sudo systemctl stop smartmarket
```

`ExecStop` runs `docker compose stop`, which halts containers cleanly. The `smartmarket_postgres_data` volume is not touched. Data is preserved.

### Restart the stack
```bash
sudo systemctl restart smartmarket
```

### Check container status
```bash
docker ps --filter name=smartmarket_postgres
docker inspect --format='{{.State.Health.Status}}' smartmarket_postgres
```

### View container logs
```bash
docker logs smartmarket_postgres
docker logs --follow smartmarket_postgres
docker logs --tail 100 smartmarket_postgres
```

Log rotation: 10 MB / 3 files (set in `docker-compose.yml`). On a data pipeline, monitor log volume if `log_min_duration_statement` is enabled.

---

## Disk usage

```bash
# Docker volume sizes (includes postgres_data)
docker system df -v

# Physical path of the data volume
docker volume inspect smartmarket_postgres_data | grep Mountpoint

# Backup directory size
du -sh /opt/smartmarket/backups/

# Overall application directory
du -sh /opt/smartmarket/
```

Disk growth comes from two sources: the `postgres_data` volume (database contents) and the `backups/` directory (pg_dump files). Monitor both. Tune `backup_retention_count` in `vars.yml` if disk is constrained.

---

## Backup from production

The backup scripts are designed to run on whichever machine has the Docker container accessible. To backup production, SSH in and run:

```bash
ssh deploy@YOUR_VPS_IP

cd /path/to/smartmarket-infra   # if repo is cloned on server (Phase 4 adds this)
# Or run manually:
docker exec smartmarket_postgres \
  pg_dump -U postgres -d smartmarket --format custom --compress 9 --no-password \
  > /opt/smartmarket/backups/smartmarket_$(date +%Y%m%d_%H%M%S).dump
```

Automated backups via a systemd timer are a Phase 4 deliverable.

To transfer a backup to your local machine:
```bash
scp deploy@YOUR_VPS_IP:/opt/smartmarket/backups/smartmarket_TIMESTAMP.dump ./backups/
```

To restore to production, follow the full restore runbook in `docs/bootstrap-local.md` (same procedure, executed via SSH on the server).

---

## Credential rotation

When rotating database passwords:

1. Edit the Ansible Vault and update the relevant password variable:
   ```bash
   ansible-vault edit --vault-password-file ~/.vault_pass ansible/group_vars/all/vault.yml
   ```

2. Re-run the smartmarket role (pass `--no-diff` to avoid showing credential values):
   ```bash
   cd ansible/
   ansible-playbook -i inventories/production/hosts.yml \
     --vault-password-file ~/.vault_pass \
     --tags smartmarket \
     --no-diff \
     site.yml
   ```
   Ansible will update `/opt/smartmarket/.env` and restart the stack automatically via the handler.

3. Update the role's password on the PostgreSQL cluster itself (the restart picks up the new env var for new connections, but the existing role password in PostgreSQL must also change):
   ```bash
   ./scripts/db-connect.sh --remote deploy@YOUR_VPS_IP
   -- Then in psql:
   ALTER ROLE smartmarket_pipeline WITH PASSWORD 'new-password';
   ALTER ROLE smartmarket_migrations WITH PASSWORD 'new-password';
   ```

4. Verify the pipeline can still connect with the new credentials.

---

## Upgrading PostgreSQL

PostgreSQL is pinned to a minor version (`postgres_image_tag` in `vars.yml`). Upgrades are intentionally manual. The procedure:

1. Take a backup: `scripts/backup.sh` (run from the server)
2. Update `postgres_image_tag` in `ansible/group_vars/all/vars.yml`
3. Test locally first: update local `.env`, recreate the container, run `bootstrap-local.sh`, verify
4. Deploy to production: re-run the smartmarket role — Ansible deploys the new `.env`, the stack restarts with the new image tag
5. Verify health: `systemctl status smartmarket` and `docker ps`

Major version upgrades (e.g. 16 → 17) require a data migration (`pg_upgrade` or dump/restore). This is not automated — follow the PostgreSQL upgrade documentation and test thoroughly before applying to production.

---

## Post-deployment verification checklist

Run this after every production deployment:

```bash
# On the VPS
systemctl status smartmarket                    # active (exited)
docker ps --filter name=smartmarket_postgres    # Up, healthy
docker inspect --format='{{.State.Health.Status}}' smartmarket_postgres  # healthy
sudo ufw status verbose                         # SSH open, everything else closed
sudo fail2ban-client status sshd               # running
docker exec smartmarket_postgres psql -U postgres -d smartmarket \
  -c "SELECT version();" --no-align --tuples-only  # returns PostgreSQL version string

# Verify PostgreSQL is NOT reachable without SSH tunnel
# (run from your local machine — should timeout or connection refused)
nc -z -w3 YOUR_VPS_IP 5432 && echo "OPEN (unexpected)" || echo "Closed (correct)"

# Verify admin access works via tunnel
./scripts/db-connect.sh --remote deploy@YOUR_VPS_IP
```

---

## Recovery: full disaster (volume lost)

If the data volume is destroyed or the VPS is rebuilt:

```bash
# 1. Provision a fresh server (if VPS rebuilt)
cd ansible/
ansible-playbook -i inventories/production/hosts.yml \
  --user root --ask-pass \
  --ssh-extra-args='-o StrictHostKeyChecking=accept-new' \
  --vault-password-file ~/.vault_pass bootstrap.yml

ansible-playbook -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass site.yml

# 2. The stack starts with an empty volume — roles are created by initdb bootstrap

# 3. Stop the stack before restoring
ssh deploy@YOUR_VPS_IP "sudo systemctl stop smartmarket"

# 4. Transfer the backup
scp ./backups/smartmarket_TIMESTAMP.dump deploy@YOUR_VPS_IP:/opt/smartmarket/backups/

# 5. Restore (run on the server)
ssh deploy@YOUR_VPS_IP
sudo systemctl start smartmarket   # ensure container is running
# Run restore via docker exec (same approach as scripts/restore.sh)
docker exec smartmarket_postgres psql -U postgres -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='smartmarket' AND pid<>pg_backend_pid();"
docker exec smartmarket_postgres psql -U postgres -d postgres \
  -c "DROP DATABASE IF EXISTS smartmarket; CREATE DATABASE smartmarket OWNER postgres;"
docker cp /opt/smartmarket/backups/smartmarket_TIMESTAMP.dump smartmarket_postgres:/tmp/restore.dump
docker exec smartmarket_postgres \
  pg_restore -U postgres -d smartmarket --exit-on-error --no-password /tmp/restore.dump
docker exec smartmarket_postgres rm /tmp/restore.dump

# 6. Verify
docker exec smartmarket_postgres psql -U postgres -d smartmarket \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname='smartmarket';"
```
