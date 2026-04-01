# Postgres Docker Ansible Foundation

This repository provides a secure, reproducible baseline for running PostgreSQL locally and deploying it to a hardened Ubuntu VPS with minimal drift.

Originally built for the Smart Market pipeline, but designed to be reusable as a general-purpose infrastructure template.

---

## ✨ Goals

- **Secure by default**
- **Reproducible from scratch**
- **Local ⇄ production parity**
- **Minimal operational complexity**
- **No overengineering (no Kubernetes)**

This is intended for serious single-node deployments where reliability and clarity matter more than abstraction.

---

## 🌐 Live Example

This setup is used in production for:

- Scoop — [https://scoopgr.netlify.app/](https://scoopgr.netlify.app/)
  Pipeline-driven product aggregation system

The application uses this repository as its PostgreSQL infrastructure foundation.

## 🧱 Architecture Overview

### Local

- Docker Compose (PostgreSQL 16, pinned)
- Named volume for persistence
- No public exposure by default
- `.env` for local secrets (git-ignored)
- Optional localhost port binding via override file

### Production (VPS)

- Ubuntu 24.04 LTS (Hetzner or similar)
- Ansible provisioning:
  - SSH hardening (no root login, key-only auth)
  - UFW firewall (default deny)
  - fail2ban (SSH protection)
  - unattended security upgrades
  - Docker Engine + Compose plugin
- Docker Compose runtime (same base config as local)
- PostgreSQL not publicly exposed
- Admin access via SSH + container access
- Secrets managed via Ansible Vault → deployed `.env`

---

## 🔐 Security Model

- PostgreSQL is **never exposed publicly**
- No default port publishing
- SSH access only (key-based)
- Non-root deploy user
- Firewall default deny
- fail2ban enabled
- Least-privilege database roles
- Secrets never committed to the repo

> `.env` files are treated as deployment plumbing, not a secure secret store.

---

## 📁 Project Structure

```

docker/
compose/
docker-compose.yml
docker-compose.override.yml
docker-compose.prod.yml
postgres/
initdb/

ansible/
bootstrap.yml
site.yml
inventories/
group_vars/
roles/

scripts/
bootstrap-local.sh
backup.sh
restore.sh
db-connect.sh

env/
.env.example

docs/
bootstrap-local.md
deploy-production.md
operations.md

````

---

## 🚀 Local Setup

```bash
git clone https://github.com/<your-username>/postgres-docker-ansible-foundation.git
cd postgres-docker-ansible-foundation

cp env/.env.example .env
# generate strong values
# openssl rand -base64 32

./scripts/bootstrap-local.sh
````

### Connect to DB

```bash
./scripts/db-connect.sh
```

---

## 🖥️ Production Deployment

### 1. Provision VPS

* Create Ubuntu 24.04 server
* Add your SSH key
* Note IP

### 2. Configure inventory

```yaml
# ansible/inventories/production/hosts.yml
all:
  hosts:
    your-server:
      ansible_host: <IP>
      ansible_user: root
```

### 3. Bootstrap server

```bash
ansible-playbook -i ansible/inventories/production/hosts.yml ansible/bootstrap.yml
```

### 4. Provision system

```bash
ansible-playbook -i ansible/inventories/production/hosts.yml ansible/site.yml
```

### 5. Deploy stack (Phase 3)

Handled by `smartmarket` role via `site.yml`.

---

## 🔌 Admin Access

PostgreSQL is not exposed publicly.

Use one of:

```bash
# option 1: SSH into host
ssh deploy@server
docker exec -it <container> psql -U postgres

# option 2: wrapper
./scripts/db-connect.sh --remote
```

---

## 💾 Backups

```bash
./scripts/backup.sh
```

* Uses `pg_dump`
* Timestamped + rotated
* Stored under `/opt/smartmarket/backups/` in production

Restore:

```bash
./scripts/restore.sh <backup-file>
```

---

## 🔄 Operations

### Restart stack

```bash
sudo systemctl restart smartmarket
```

### Check status

```bash
sudo systemctl status smartmarket
docker ps
```

### Logs

```bash
docker logs <container>
```

---

## ⚠️ Design Decisions

* No Kubernetes
* No managed DB dependency
* No public database exposure
* No schema logic in container init
* Docker + Ansible only

---

## 🧠 When to Extend

Add these only when needed:

* pgBouncer (connection pooling)
* Read replica (streaming replication)
* WAL archiving (point-in-time recovery)
* Monitoring stack (Prometheus/Grafana)

---

## 📜 License

MIT
