# AGENTS.md

Canonical instructions for all coding agents working on this repository.

This project is building a production-minded PostgreSQL foundation for the Smart Market pipeline. All agents must follow the standards in this file unless a task-specific instruction explicitly overrides them in a narrow, justified way.

---

## 1. Mission

Build a secure, reproducible, production-minded PostgreSQL deployment foundation that:

- runs locally in Docker for development and validation
- has a clean path to Ubuntu VPS deployment
- uses Ansible for host provisioning and hardening
- uses Docker/Compose for runtime portability
- follows best practices and industry-standard security defaults
- remains understandable and operable by a solo technical owner

This is not a toy setup. Treat it as critical infrastructure for a pipeline-centric system.

---

## 2. Smart Market context

Smart Market is pipeline-first:

- the pipeline owns writes and database mutations
- the web app is read-only and consumes SQL/RPC outputs
- the database is critical infrastructure
- durability, reproducibility, and operational clarity matter

Do not design as if this were a generic demo app.

---

## 3. Core engineering principles

### Security first
- Prefer secure defaults over convenience.
- Minimize attack surface.
- Never expose PostgreSQL publicly by default.
- Use least privilege.
- Avoid hardcoded secrets.
- Treat eventual internet deployment as the default threat model.

### Reproducibility
- Local and remote environments should be structurally similar.
- Avoid manual snowflake setup.
- Everything important should be represented in versioned files.
- Setup should be rebuildable from scratch from repository contents plus secrets.

### Production-minded simplicity
- Use boring, proven tools.
- Avoid unnecessary complexity.
- Do not introduce Kubernetes, Terraform, or service meshes unless explicitly requested.
- Favor small, understandable systems with strong defaults.

### Separation of concerns
- Ansible provisions and hardens hosts.
- Docker/Compose defines and runs services.
- Database schema and migrations belong to the application/pipeline layer unless explicitly stated otherwise.

### Operational discipline
- Persistence must be explicit.
- Backup and restore paths must be designed, not implied.
- Versions should be pinned where practical.
- Health checks, restart behavior, and failure modes should be considered.

---

## 4. Required technical direction

Unless explicitly overridden, assume this architecture:

- Ubuntu host for remote deployment
- Ansible for provisioning and hardening
- Docker Engine + Docker Compose for runtime
- PostgreSQL in a container
- persistent volume for database data
- PostgreSQL not publicly exposed
- access via Docker private network, SSH tunnel, VPN, or similarly constrained path
- environment-variable-driven configuration
- documented bootstrap, backup, restore, and upgrade flows

---

## 5. Security baseline requirements

All agents must preserve or improve the following baseline.

### Host security
- non-root admin user
- SSH keys only where feasible
- disable root SSH login
- disable password SSH auth where feasible
- firewall with default deny inbound
- explicit allow rules only for necessary services
- fail2ban or equivalent where appropriate
- minimal installed packages

### Container/runtime security
- expose only required ports
- keep PostgreSQL internal by default
- avoid privileged containers unless absolutely necessary
- prefer named volumes or explicitly managed bind mounts
- do not bake secrets into images
- keep service boundaries clear

### PostgreSQL security
- strong credentials
- least-privilege application roles
- no public bind by default
- explicit persistence strategy
- explicit backup/restore strategy
- version pinning for PostgreSQL image
- careful upgrade plan

### Secrets management
- never commit real secrets
- provide `.env.example` or equivalent templates
- use Ansible Vault or equivalent for deployment secrets
- document required variables clearly

---

## 6. Output and implementation standards

When producing designs or code, prefer this structure:

1. short architecture summary
2. file/folder structure
3. implementation files or patches
4. setup/run instructions
5. security notes, tradeoffs, and follow-ups

When making assumptions:
- choose a sensible default
- state the assumption explicitly
- continue making progress

Do not stall on minor ambiguity when a safe and conventional choice exists.

---

## 7. Documentation standards

Agents should create or update documentation when changing behavior that affects:

- setup
- deployment
- backups/restores
- security posture
- environment variables
- operational workflow

Documentation should be concise, practical, and implementation-oriented.

Prefer:
- `README.md` for overview and quickstart
- `docs/` for operational details
- inline comments only where they add real clarity

---

## 8. What to avoid

Unless explicitly requested, do not:

- expose PostgreSQL on a public interface
- add Kubernetes
- add overly complex orchestration
- add multiple overlapping config systems
- mix schema logic into ad hoc container init without a clear reason
- commit real secrets, keys, tokens, or passwords
- optimize for novelty over reliability

---

## 9. Quality bar

All outputs should be:

- secure by default
- reproducible
- production-minded
- minimal-drift across environments
- easy to review
- realistic for solo operation
- aligned with industry best practices

If there are multiple valid options, recommend one and explain why.

If there is a tradeoff, state it clearly.

If something is risky, say so directly.

---

## 10. Instruction precedence

Unless a more specific task instruction applies, follow this precedence:

1. direct user/task instruction
2. `AGENTS.md`
3. repository-local conventions already established by the project
4. general best practices

`CLAUDE.md` is only a pointer file. `AGENTS.md` is the canonical agent standard.

---

## 11. Agent behavior expectation

Act like a senior infrastructure/backend engineer.

That means:
- be concrete
- be opinionated when standards are clear
- avoid hand-waving
- preserve security
- preserve reproducibility
- optimize for maintainable forward progress

## Infra-specific standards

- Never expose PostgreSQL publicly by default.
- Never use `latest` tags for infrastructure images.
- Treat `docker-entrypoint-initdb.d` as bootstrap-only, not migration infrastructure.
- Prefer systemd timers over cron for operational jobs on Ubuntu unless there is a clear reason otherwise.
- Prefer localhost-only port publishing in local overrides (`127.0.0.1:HOST:CONTAINER`).
- Do not treat `.env` or Compose env files as a secure secret-management system; use them as deployment plumbing only.
- Keep schema migration ownership explicit and separate from infrastructure bootstrap.