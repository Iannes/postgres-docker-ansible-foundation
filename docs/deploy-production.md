# Production Deployment — Smart Market PostgreSQL

Step-by-step guide to provisioning and hardening a fresh Ubuntu VPS using the Ansible playbooks in `ansible/`.

---

## Prerequisites

### Control machine (your laptop or CI runner)
- Ansible installed: `pip install ansible`
- SSH key pair for the deploy user (see below)
- Ansible Vault password stored securely (see `docs/secrets-management.md`)

Verify:
```bash
ansible --version          # 2.14 or later
ansible-playbook --version
```

### Target VPS
- Ubuntu 24.04 LTS (Noble Numbat)
- Root SSH access or cloud provider initial user (e.g. `ubuntu` on AWS)
- Reachable on port 22 from your control machine

Assumed provider: Hetzner Cloud. Adjust for other providers as needed.

---

## Step 1 — Generate a deploy SSH key

Create a dedicated key pair for the deploy user. Do not reuse your personal SSH key.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/smartmarket_deploy -C "smartmarket-deploy-$(date +%Y)"
```

Store the path in `ansible/group_vars/all/vars.yml`:
```yaml
ansible_ssh_key_path: "~/.ssh/smartmarket_deploy"
```

The public key (`~/.ssh/smartmarket_deploy.pub`) goes into Ansible Vault as `vault_deploy_ssh_pubkey`.

---

## Step 2 — Create and populate the Ansible Vault

```bash
# Create the vault (opens $EDITOR)
ansible-vault create ansible/group_vars/all/vault.yml
```

Paste and fill in the following (reference `vault.yml.example` for the full template):

```yaml
vault_server_ip:         "YOUR_VPS_IP"
vault_deploy_ssh_pubkey: "ssh-ed25519 AAAA... your-deploy-key"
```

Save and close the editor. The file is AES-256 encrypted on disk.

Store the vault password in your password manager. See `docs/secrets-management.md`.

---

## Step 3 — Update vars.yml (if needed)

Review `ansible/group_vars/all/vars.yml`. Defaults are production-ready. The most likely things to change:

| Variable | Default | Notes |
|---|---|---|
| `ssh_port` | `22` | Change to reduce scan noise (see SSH port section below) |
| `timezone` | `UTC` | Change to your preferred server timezone |
| `fail2ban_bantime` | `3600` | Increase for stricter banning (e.g. `86400` = 24h) |

---

## Step 4 — Run bootstrap.yml (first-run only)

Bootstrap creates the `deploy` user, installs its SSH key, and grants it passwordless sudo. Run this once against a fresh server using root or the cloud provider's initial user.

```bash
cd ansible/

ansible-playbook \
  -i inventories/production/hosts.yml \
  --user root \
  --ask-pass \
  --ssh-extra-args='-o StrictHostKeyChecking=accept-new' \
  --vault-password-file ~/.vault_pass \
  bootstrap.yml
```

For providers that use a non-root initial user (e.g. `ubuntu` on AWS, `debian` on some providers):
```bash
ansible-playbook \
  -i inventories/production/hosts.yml \
  --user ubuntu \
  --private-key ~/.ssh/your_cloud_key \
  --ssh-extra-args='-o StrictHostKeyChecking=accept-new' \
  --vault-password-file ~/.vault_pass \
  bootstrap.yml
```

After bootstrap completes, verify you can SSH as the deploy user before continuing:
```bash
ssh -i ~/.ssh/smartmarket_deploy -p 22 deploy@YOUR_VPS_IP
```

---

## Step 5 — Dry-run site.yml

Run a check pass to see what would change without applying anything:

```bash
cd ansible/

ansible-playbook \
  -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  --check --diff \
  site.yml
```

Review the diff output. Confirm the SSH hardening config and firewall rules look correct before applying.

---

## Step 6 — Run site.yml

```bash
cd ansible/

ansible-playbook \
  -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  site.yml
```

This applies all three roles: `common`, `firewall`, `docker`.

**Watch for:**
- `TASK [common : Deploy SSH hardening drop-in config]` — if this changes, sshd will restart at the end of the play
- `TASK [firewall : Enable UFW]` — confirms UFW goes active
- `TASK [docker : Verify docker CLI is functional]` — confirms Docker installed

---

## Step 7 — Verify idempotency

Immediately re-run site.yml and confirm `changed=0`:

```bash
ansible-playbook \
  -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  site.yml
```

If any task still shows `changed`, investigate before proceeding.

---

## Step 8 — Post-provision checks

SSH into the server as the deploy user and verify:

```bash
ssh -i ~/.ssh/smartmarket_deploy -p 22 deploy@YOUR_VPS_IP

# Confirm SSH hardening is active
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication|allowusers|maxauthtries'

# Confirm UFW status
sudo ufw status verbose

# Confirm fail2ban is running
sudo systemctl status fail2ban
sudo fail2ban-client status sshd

# Confirm Docker is running
docker info
docker compose version

# Confirm Docker has no TCP socket (should return empty or error)
docker -H tcp://localhost:2375 info 2>&1 | grep -i "error\|refused" || echo "TCP socket check passed"
```

---

## Applying individual roles (tags)

Re-run a specific role without running the entire playbook:

```bash
# Re-apply only the firewall role
ansible-playbook -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  --tags firewall site.yml

# Re-apply only Docker role
ansible-playbook -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  --tags docker site.yml
```

---

## SSH port change procedure

If you want to move SSH to a non-default port (reduces scan/brute-force noise):

1. **Before changing:** ensure your cloud provider's network firewall allows the new port
2. Update `ssh_port` in `ansible/group_vars/all/vars.yml` to the new port
3. Run site.yml — it will open the new port in UFW and update sshd config
4. Test the new port BEFORE closing the current session:
   ```bash
   ssh -i ~/.ssh/smartmarket_deploy -p NEW_PORT deploy@YOUR_VPS_IP
   ```
5. If the new port works, optionally close port 22 in UFW:
   ```bash
   sudo ufw delete allow 22/tcp
   ```
6. Update `ansible_port` in `inventories/production/hosts.yml` to match

**Never close port 22 until you have confirmed the new port works.** If you lock yourself out, you will need console/KVM access to recover (Hetzner provides this via their web console).

---

## Docker + UFW interaction

Docker adds iptables rules that bypass UFW's INPUT chain for container-published ports. This is intentional Docker behavior, but it means **a published container port is reachable even if UFW has no allow rule for it.**

**This is not an issue in Phase 1–2** because no containers publish ports publicly. PostgreSQL is accessible only on the internal Docker bridge network.

**In Phase 3,** when the smartmarket role deploys Compose services:
- Do not publish PostgreSQL to the host (already by design — `ports:` is absent in `docker-compose.yml`)
- If you ever need to open a container port to the public, use the `DOCKER-USER` iptables chain rather than UFW rules:
  ```bash
  sudo iptables -I DOCKER-USER -p tcp --dport PORT -j ACCEPT
  ```
- Or restrict published ports to localhost in Compose (`"127.0.0.1:PORT:PORT"`)

The safest approach — which this project already follows — is to never publish ports that should not be public.

---

## Unattended upgrades

Unattended upgrades apply security patches automatically overnight. PostgreSQL and Docker packages are excluded from automatic upgrades (see `50unattended-upgrades.j2`) and must be upgraded manually.

To check upgrade history:
```bash
sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
```

To manually apply all pending upgrades:
```bash
sudo apt-get update && sudo apt-get upgrade -y
```

---

## Phase 3 — Deploy the Smart Market stack

Phase 3 runs the `smartmarket` Ansible role against an already-provisioned host (Phases 1–2 complete). It deploys the Compose files, templates the `.env` from vault credentials, installs the systemd unit, and verifies health.

### Prerequisites for Phase 3

- Steps 1–7 above are complete and idempotent (server is hardened, Docker is running)
- The Ansible Vault contains the Phase 3 secrets (`vault_postgres_password`, `vault_migrations_password`, `vault_pipeline_password`). Add them now if not already present:
  ```bash
  ansible-vault edit --vault-password-file ~/.vault_pass ansible/group_vars/all/vault.yml
  ```
  Reference `ansible/group_vars/all/vault.yml.example` for the required variable names.

### Step 8 — Populate Phase 3 vault secrets

Open the vault and add (replacing CHANGEME_ values with `openssl rand -base64 32` output):

```yaml
vault_postgres_password:   "generated-password-1"
vault_migrations_password: "generated-password-2"
vault_pipeline_password:   "generated-password-3"
```

Each password must be unique. Save and close.

### Step 9 — Dry-run the smartmarket role

```bash
cd ansible/
ansible-playbook -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  --tags smartmarket \
  --check --diff --no-diff \
  site.yml
```

`--no-diff` suppresses diff output for the `.env` template (which would expose credential values). Remove it if you need to see non-sensitive diffs.

### Step 10 — Deploy the stack

```bash
cd ansible/
ansible-playbook -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  --tags smartmarket \
  site.yml
```

This will:
1. Create `/opt/smartmarket/` directory layout
2. Copy `docker-compose.yml` and `docker-compose.prod.yml` to the server
3. Copy `docker/postgres/initdb/01-roles.sh` to the server
4. Template `/opt/smartmarket/.env` (mode 600) from vault variables
5. Install `/etc/systemd/system/smartmarket.service`
6. Enable the service (start on boot)
7. Start the stack: `docker compose up --detach --wait`
8. Wait for the PostgreSQL healthcheck to pass
9. Run a connectivity smoke test and verify application roles

### Step 11 — Verify deployment

```bash
# On the server
ssh deploy@YOUR_VPS_IP

systemctl status smartmarket                      # active (exited) = correct
docker ps --filter name=smartmarket_postgres      # Up N minutes, healthy
docker inspect --format='{{.State.Health.Status}}' smartmarket_postgres

# Verify port is NOT exposed
sudo ss -tlnp | grep 5432     # should show nothing (no host binding)
```

From your local machine:
```bash
# Verify admin access via SSH tunnel works
./scripts/db-connect.sh --remote deploy@YOUR_VPS_IP
```

### Step 12 — Confirm idempotency

Re-run with `--check`:

```bash
cd ansible/
ansible-playbook -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass \
  --tags smartmarket \
  --check site.yml
```

Expect `changed=0` if nothing has changed since the initial deploy.

---

## Re-deploying after changes

The `smartmarket` role is safe to re-run. Common re-deploy scenarios:

| Change | Command |
|---|---|
| Credential rotation | Edit vault → re-run smartmarket role with `--no-diff` |
| Compose file update | Commit change → re-run smartmarket role |
| PostgreSQL image upgrade | Update `postgres_image_tag` in vars.yml → re-run smartmarket role |
| Full re-provision (new VPS) | Run all steps from Step 4 |

Any change that modifies `.env`, Compose files, or the systemd unit automatically triggers a service restart via the Ansible handler.
