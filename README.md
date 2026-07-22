# Self-Hosted Vaultwarden — Secrets Vault

Infrastructure-as-code for a self-hosted, multi-user password vault running
[**Vaultwarden**](https://github.com/dani-garcia/vaultwarden) (the lightweight
Rust reimplementation of the Bitwarden server) on a single DigitalOcean droplet.

Reachable over HTTPS from the official Bitwarden desktop, mobile, browser and CLI
clients; multiple accounts with shared collections; layered, encrypted, off-site
backups.

> **Security note:** this repository contains **templates and documentation only**.
> No secrets, keys, tokens, domains, or credentials are committed. All real values
> live in a git-ignored `.env` on the server, and the backup encryption private key
> never touches the server at all.

---

## Architecture

```
Internet ──443──▶ Caddy (TLS, Let's Encrypt) ──▶ vaultwarden:80  (internal Docker network)
                                                      │
                                                 ./vw-data (host bind-mount:
                                                 db.sqlite3, attachments, config, rsa keys)
```

- **Caddy** is the only container that publishes ports (80/443) and terminates
  TLS with an automatically provisioned & renewed Let's Encrypt certificate.
- **Vaultwarden** is never exposed to the public interface; it listens only on
  the internal Docker network.
- All persistent state lives in the `vw-data` bind-mount on the droplet's **main
  disk** (not an attached block volume — those are excluded from DigitalOcean
  droplet backups).

## Repository layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Vaultwarden + Caddy services |
| `.env.example` | Template for the git-ignored `.env` (copy & fill on the droplet) |
| `Caddyfile` | Reverse proxy + automatic HTTPS; reads `{$DOMAIN}` / `{$ACME_EMAIL}` |
| `backup/backup.sh` | Daily app-consistent, `age`-encrypted, off-site backup |
| `backup/vaultwarden-backup.{service,timer}` | systemd units to run it daily |
| `fail2ban/` | Filters + jail for failed user and `/admin` logins |
| `docs/handoff.md` | Full deployment specification |

## Security model

- **Per-user accounts.** Each person has their own login + master password. Vault
  items are encrypted **client-side**; the server only ever stores ciphertext.
- **One super-admin, three hats:** a normal user account; holder of the
  `ADMIN_TOKEN` that gates `/admin`; and sole **Owner** of the single Organization
  that holds all shared Collections.
- **Hard boundary:** no role can read another user's *personal* vault — not even
  the admin. Cross-user recovery of personal items is only possible via Bitwarden
  **Emergency Access**, granted voluntarily per user.
- **Secrets hygiene:** admin token is an Argon2 PHC hash; backups are encrypted to
  an `age` public key whose private key is kept off-server.

## Deployment (summary)

Full ordered runbook is in [`docs/handoff.md`](docs/handoff.md). In brief, on the
droplet under `/opt/vaultwarden`:

```bash
# 1. Base hardening: apt upgrade, non-root deploy user, UFW (OpenSSH/80/443 only)
# 2. Install Docker Engine + Compose plugin
# 3. Clone this repo into /opt/vaultwarden
git clone git@github.com:moates695/secrets_vault.git /opt/vaultwarden

# 4. Create the real environment file (never committed)
cp .env.example .env
#    Generate the admin token hash and paste it into .env:
docker run --rm -it vaultwarden/server:1.36.0 /vaultwarden hash
nano .env            # set DOMAIN, ACME_EMAIL, ADMIN_TOKEN, ...

# 5. Bring it up (needs DNS A record + open 80/443 for the ACME challenge)
docker compose up -d

# 6. Register the super-admin account, create the Organization + Collections,
#    then set SIGNUPS_ALLOWED=false in .env and `docker compose up -d`.

# 7. Install fail2ban assets
cp fail2ban/filter.d/*.conf /etc/fail2ban/filter.d/
cp fail2ban/jail.d/vaultwarden.local /etc/fail2ban/jail.d/
systemctl restart fail2ban        # ensure the default [sshd] jail is enabled too

# 8. Install the backup timer (after `rclone config` + placing backup-age.pub)
cp backup/vaultwarden-backup.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now vaultwarden-backup.timer
```

### DNS / Cloudflare

Point an **A record** for your host at the droplet's public IP. If the domain is
on Cloudflare, set the record to **DNS-only (grey cloud)** so Caddy can complete
the Let's Encrypt challenge and serve its own certificate. A proxied (orange)
record terminates TLS at Cloudflare and will break the ACME flow unless you switch
to a DNS-01 challenge or a Cloudflare Origin certificate.

## Design decisions worth calling out

- **`env_file` instead of inline env vars.** The Argon2 admin-token hash contains
  `$` characters, which Docker Compose would try to interpolate (the classic
  `$` → `$$` escaping trap). Loading secrets via `env_file` passes them to the
  container verbatim — no escaping, no foot-gun.
- **SQLite `.backup`, not `cp`.** A raw copy of a live SQLite file can be torn;
  `.backup` produces a consistent snapshot.
- **Encrypt to a public key.** Backups are `age`-encrypted to a public key; the
  private key lives off-server, so a full host compromise still can't decrypt the
  backup history.
- **Two independent backup layers.** DigitalOcean droplet images (whole-machine,
  same account/region) *plus* the app-consistent encrypted off-site archive here.
  Neither replaces the other.

## Backups

- **Layer 1 — DigitalOcean droplet backups:** enabled in the control panel,
  daily or better. Fast whole-machine recovery, but same account/region and not
  application-aware.
- **Layer 2 — this repo's `backup.sh`:** daily systemd timer → consistent SQLite
  snapshot + the rest of `/data` → `zstd` → `age`-encrypted → `rclone` off-site,
  14-day local retention. **A backup that has never been restored is only an
  assumption** — a test restore is part of the deploy checklist.

Restore:

```bash
age -d -i /secure/offsite/backup-age.key vw-<stamp>.tar.zst.age | zstd -d | tar -x -C /restore
docker compose stop vaultwarden
# replace ./vw-data with the restored db.sqlite3 + data/ contents
docker compose start vaultwarden
```

## Acceptance criteria

See [`docs/handoff.md` §9](docs/handoff.md). Highlights: valid Let's Encrypt cert
with HTTP→HTTPS redirect; official mobile & desktop clients connect; shared
Collection visible only to intended members; per-item password history; signups
closed after setup; `/admin` gated by token; UFW limited to 22/80/443; fail2ban
jails active; both backup layers verified including a successful test restore.
