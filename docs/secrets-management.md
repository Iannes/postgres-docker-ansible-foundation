# Secrets Management — Smart Market

How secrets flow through the Smart Market infrastructure, where they live, and how to rotate them.

---

## Principles

- No plaintext secrets in the repository, ever
- Local dev secrets live in `.env` (git-ignored) on the developer's machine
- Production secrets live in Ansible Vault (`ansible/group_vars/all/vault.yml`, git-ignored)
- Ansible Vault writes production secrets to the server at deploy time
- On the server, secrets land as a mode-600 `.env` file owned by the deploy user
- Compose reads the `.env` file; container processes receive them as environment variables
- Environment variables are **not** secure storage — they are deployment plumbing. `docker inspect` and `/proc/<pid>/environ` can expose them to any process with root access on the host. Do not treat this as a vault equivalent.

---

## Secret locations by layer

| Layer | Location | Encrypted? | Committed? |
|---|---|---|---|
| Local dev | `.env` at project root | No | No (git-ignored) |
| Production secrets | `ansible/group_vars/all/vault.yml` | Yes (AES-256) | No (git-ignored) |
| Vault template | `ansible/group_vars/all/vault.yml.example` | No | Yes (placeholder values only) |
| Vault password | `~/.vault_pass` or password manager | N/A | No |
| Server runtime | `/opt/smartmarket/.env` (Phase 3) | No | No |

---

## Ansible Vault workflow

### Creating the vault (first time)

```bash
# Option A: interactive vault password
ansible-vault create ansible/group_vars/all/vault.yml

# Option B: vault password from a file (better for automation)
echo "your-strong-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass
ansible-vault create --vault-password-file ~/.vault_pass ansible/group_vars/all/vault.yml
```

The vault editor opens. Copy the structure from `vault.yml.example` and fill in real values.

### Editing the vault

```bash
ansible-vault edit --vault-password-file ~/.vault_pass ansible/group_vars/all/vault.yml
```

### Viewing the vault (without editing)

```bash
ansible-vault view --vault-password-file ~/.vault_pass ansible/group_vars/all/vault.yml
```

### Encrypting an existing plaintext file

If you accidentally wrote vault content to an unencrypted file:
```bash
ansible-vault encrypt --vault-password-file ~/.vault_pass path/to/file.yml
```

### Using the vault in playbooks

```bash
# Pass vault password file
ansible-playbook -i inventories/production/hosts.yml \
  --vault-password-file ~/.vault_pass site.yml

# Prompt for vault password interactively
ansible-playbook -i inventories/production/hosts.yml \
  --ask-vault-pass site.yml
```

To avoid passing `--vault-password-file` every time, uncomment this line in `ansible/ansible.cfg`:
```ini
vault_password_file = ../.vault_pass
```

---

## Vault password management

The vault password protects all production secrets. Losing it means the vault contents are unrecoverable.

**Minimum requirements:**
- Generate with `openssl rand -base64 32` — do not use a human-memorable password
- Store in your password manager (1Password, Bitwarden, pass, etc.) as the primary copy
- Store a second copy in a separate location (encrypted USB, secure note offsite)
- Never commit `~/.vault_pass` or any file containing the vault password

If multiple operators need vault access, each uses the same vault password. Share it via an encrypted channel (e.g. Signal, or a shared password manager vault).

---

## Secret inventory

### Phase 1–2 secrets

| Variable | Used in | Purpose |
|---|---|---|
| `vault_server_ip` | Ansible inventory | VPS IP address |
| `vault_deploy_ssh_pubkey` | bootstrap.yml, common role | SSH public key for deploy user |

### Phase 3 additions (smartmarket role)

| Variable | Used in | Purpose |
|---|---|---|
| `vault_postgres_password` | smartmarket role → `.env` | PostgreSQL superuser password |
| `vault_migrations_password` | smartmarket role → `.env` | smartmarket_migrations role password |
| `vault_pipeline_password` | smartmarket role → `.env` | smartmarket_pipeline role password |

---

## Rotating secrets

### Rotating the deploy SSH key

1. Generate a new key pair:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/smartmarket_deploy_new -C "smartmarket-deploy-$(date +%Y)"
   ```
2. Edit the vault and update `vault_deploy_ssh_pubkey` with the new public key
3. Run site.yml — the common role will add the new key via `authorized_key`
4. Verify you can connect with the new key:
   ```bash
   ssh -i ~/.ssh/smartmarket_deploy_new deploy@YOUR_VPS_IP
   ```
5. Edit the vault again and set `exclusive: true` on the authorized_key task (or manually remove the old key from `~/.ssh/authorized_keys` on the server)
6. Delete the old key pair from your machine

### Rotating database passwords (Phase 3)

1. Edit the vault and update the relevant password variable
2. Run site.yml with the `--tags smartmarket` tag — Ansible will rewrite the server `.env`
3. Run `docker compose ... up -d --force-recreate` on the server to pick up the new credentials
4. The application roles on PostgreSQL must also have their passwords updated. Run the `scripts/rotate-secrets.sh` script (Phase 4) or manually:
   ```sql
   ALTER ROLE smartmarket_pipeline WITH PASSWORD 'new-password';
   ```

### Rotating the vault password

1. Decrypt the vault to a temp file:
   ```bash
   ansible-vault decrypt --vault-password-file ~/.vault_pass \
     ansible/group_vars/all/vault.yml \
     --output /tmp/vault_plaintext.yml
   ```
2. Re-encrypt with the new password:
   ```bash
   ansible-vault encrypt --vault-password-file /tmp/new_vault_pass \
     /tmp/vault_plaintext.yml \
     --output ansible/group_vars/all/vault.yml
   ```
3. Shred the temp file:
   ```bash
   shred -u /tmp/vault_plaintext.yml
   ```
4. Update your password manager and distribute the new vault password to all operators
5. Update `~/.vault_pass` on all control machines

---

## What not to do

- Do not store the vault password in the repository
- Do not store the vault password in `.env`
- Do not use `ansible_become_pass` in inventory or vars to store sudo passwords — the deploy user has NOPASSWD sudo
- Do not add `vault.yml` to `.gitignore` and assume it's safe to leave unencrypted — encrypt it first, then check the gitignore is working
- Do not share secrets via email, Slack, or unencrypted channels
- Do not put the server IP in `inventories/production/hosts.yml` as a plaintext value — it is referenced via `vault_server_ip` for a reason

---

## Checking gitignore is working

```bash
# From the project root:
git status --porcelain | grep -E 'vault\.yml$|^\.env$'
```

If this returns any output, the secrets file is tracked. Stop and fix the gitignore before committing.

```bash
# If vault.yml was accidentally staged:
git rm --cached ansible/group_vars/all/vault.yml

# If .env was accidentally staged:
git rm --cached .env
```
