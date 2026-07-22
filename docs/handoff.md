# Vaultwarden Self-Hosted Deployment — Handover for Claude Code

## 1. Objective

Deploy a self-hosted, multi-user password vault on an existing DigitalOcean droplet using **Vaultwarden** (the lightweight Rust reimplementation of the Bitwarden server). It must be reachable over HTTPS from the official Bitwarden desktop, mobile, browser-extension, and CLI clients, support multiple user accounts with shared collections, and be protected by a layered backup strategy (whole-machine + application-consistent off-site).

Do **not** build a password manager from scratch. Use Vaultwarden. This document is the full spec — implement it end to end, pausing only for the human decisions listed in section 10.

## 2. Target environment

- **Host:** existing DigitalOcean droplet, Ubuntu 24.04 LTS (assume fresh; verify and adapt if not).
- **Access:** SSH as root or a sudo user (confirm at start).
- **Resource profile:** Vaultwarden idles in ~10–50 MB RAM; the smallest droplet is sufficient. No database server needed — Vaultwarden uses SQLite.
- **Stack to install:** Docker Engine + Docker Compose plugin, Caddy (as a reverse proxy for automatic HTTPS), UFW, fail2ban, `sqlite3`, `age`, `zstd`, `rclone`.

## 3. Functional requirements (from the original brief)

| Requirement | How Vaultwarden satisfies it |
|---|---|
| Profiles for different authorized persons | One Vaultwarden account per person; shared secrets via an Organization + Collections |
| Securely store username/password pairs | Core function; client-side encrypted, server stores ciphertext only |
| Desktop + mobile access | Official Bitwarden clients connect to the self-hosted server unmodified |
| Old password history | Bitwarden items keep per-item password history automatically — no extra work |

### 3.1 Access & roles model

Each authorized person gets their **own separate account** (their own login + master password). There is **one super admin**, held by a single person wearing three hats:

1. **Their own normal user account** — a personal vault like everyone else's.
2. **Server admin** — holder of the `ADMIN_TOKEN`, which gates the `/admin` panel. Used to invite, disable, and delete accounts and configure the server. This is **token-based, not a role attached to a user account** — whoever holds the token is admin, so the token is a high-value secret.
3. **Sole Organization Owner** — the top role over all **shared** secrets. One Organization is created; the super admin is its only Owner and controls membership, Collections, and per-collection access. Everyone else is an org member granted access only to the Collections they need.

**Hard boundary — do not design around violating it:** no role in this system can read another user's **personal** vault. Vault items are encrypted client-side with a key derived from each user's master password; the server (and the admin panel) only ever hold ciphertext. The super admin manages *accounts* and *shared collections*, not the contents of individuals' personal vaults.

**Recovering an individual's personal vault** (someone leaves or loses their master password) is only possible via **Emergency Access**: each user voluntarily grants a chosen contact view or takeover rights, which activate after a user-set wait period. It cannot be forced server-side. If cross-user recovery of personal items is a real requirement, either (a) have every user grant the super admin Emergency Access, or (b) keep anything that must be recoverable in shared org Collections rather than personal vaults. See the decision in section 10.

## 4. Architecture

```
Internet ──443──▶ Caddy (TLS, Let's Encrypt) ──▶ vaultwarden:80  (internal Docker network)
                                                      │
                                                 ./vw-data (host volume: db.sqlite3, attachments, config, rsa keys)
```

- Caddy is the **only** container that publishes ports (80/443). Vaultwarden is never exposed directly to the public interface.
- All state lives in the `vw-data` bind-mount on the droplet's **main disk** (not an attached block volume — see gotcha in section 9).

## 5. Human prerequisites (must be done before/at deploy time)

1. A domain or subdomain (e.g. `vault.example.com`) with a **DNS A record pointing to the droplet's public IP**. Caddy cannot issue a certificate without this.
2. Enable **DigitalOcean droplet backups** in the control panel (see section 8).
3. Provide the values in section 10.

## 6. Implementation tasks (ordered)

Work in `/opt/vaultwarden`.

1. **Base hardening**
   - Update packages: `apt update && apt -y upgrade`.
   - Create a non-root deploy user (if only root exists) and use it for the deployment.
   - Configure UFW: allow `OpenSSH`, `80/tcp`, `443/tcp`; deny everything else inbound; enable.
2. **Install Docker** via the official convenience script / apt repo; enable the service; confirm `docker compose version` works.
3. **Create the project files** listed in section 7 under `/opt/vaultwarden`.
4. **Generate the admin token hash** (Argon2 PHC string):
   ```bash
   docker run --rm -it vaultwarden/server:1.36.0 /vaultwarden hash
   ```
   Store the resulting `$argon2...` string as `ADMIN_TOKEN`. **Escape every `$` as `$$`** when placing it in `docker-compose.yml` or a compose `.env` file, or Compose will treat it as variable interpolation.
5. **Bring it up:** `docker compose up -d`. Confirm Caddy obtains a certificate and the web vault loads at `https://<domain>`.
6. **Create the super admin's own account** first (register while signups are open), then create the single **Organization** and make that account its sole **Owner**. Build the Collections that shared secrets will live in.
7. **Lock down signups and add everyone by invitation:** set `SIGNUPS_ALLOWED=false` (optionally set `SIGNUPS_DOMAINS_WHITELIST`); leave `INVITATIONS_ALLOWED=true` (default) so invited addresses can still register even with open signups off. Then `docker compose up -d`. Add each remaining user via an **admin-panel invitation** and/or an **Organization invitation**, and grant each org member access only to the Collections they need (roles: Owner = super admin only; others = User / Manager as appropriate).
8. **Install fail2ban** with a jail for the Vaultwarden admin/login endpoints (parse the container logs) plus the standard sshd jail.
9. **Implement the backup job** (section 8) and run it once manually to confirm an encrypted archive lands off-site.
10. **Perform a test restore** (section 8) into a throwaway droplet/container and confirm the vault opens.
11. **Verify against the acceptance criteria** (section 9).

## 7. Configuration files

### `/opt/vaultwarden/docker-compose.yml`
```yaml
services:
  vaultwarden:
    image: vaultwarden/server:1.36.0   # pin; check Docker Hub for newer stable before deploy
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "https://vault.example.com"
      SIGNUPS_ALLOWED: "true"          # set "false" after accounts are created
      ADMIN_TOKEN: "REPLACE_WITH_ARGON2_HASH_ESCAPE_DOLLARS_AS_$$"
      # Optional SMTP (needed for org invites / password-hint emails):
      # SMTP_HOST: "smtp.example.com"
      # SMTP_FROM: "vault@example.com"
      # SMTP_PORT: "587"
      # SMTP_SECURITY: "starttls"
      # SMTP_USERNAME: "vault@example.com"
      # SMTP_PASSWORD: "..."
    volumes:
      - ./vw-data:/data
    networks: [ vw-net ]

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
    networks: [ vw-net ]

networks:
  vw-net:
```

### `/opt/vaultwarden/Caddyfile`
```
{
    email admin@example.com   # ACME contact for Let's Encrypt
}

vault.example.com {
    encode gzip
    reverse_proxy vaultwarden:80
}
```
Caddy provisions and renews the TLS certificate automatically. Vaultwarden's built-in WebSocket notifications are proxied over the same host, so no extra config is required.

## 8. Backup & recovery (layered)

Two independent layers. Neither replaces the other.

### Layer 1 — DigitalOcean droplet backups (human enables in control panel)
- Whole-machine, crash-consistent images; fast full-system recovery from OS corruption or a botched change.
- Pricing: **20% of droplet cost for weekly, 30% for daily**, or usage-based ($0.01/GiB) for intra-daily (every 12/6/4h). Choose **at least daily**; weekly leaves up to a week of newly added credentials at risk.
- **Not sufficient alone:** stored in the same data center on the same account (no protection against account loss/compromise) and it is a disk image, not an application-aware database backup. Hence Layer 2.

### Layer 2 — application-consistent, encrypted, off-site backup (Claude Code implements)
Runs daily via a systemd timer or cron. Requirements:
- Use SQLite's `.backup` (never a raw `cp` of `db.sqlite3`) for a consistent snapshot.
- Include the rest of `/data`: `attachments/`, `sends/`, `config.json`, and the `rsa_key*` files. (`icon_cache/` is disposable — exclude it.)
- Encrypt with `age` using a **public key whose private key is stored OFF the server**, so a server compromise cannot decrypt the backups.
- Push off DigitalOcean via `rclone` — a different provider is best; at minimum Spaces in a **different region**.
- Keep ~14 days locally, longer off-site.

Reference script `/opt/vaultwarden/backup.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="/opt/vaultwarden/vw-data"
BACKUP_DIR="/opt/vaultwarden/backups"
AGE_PUBKEY_FILE="/opt/vaultwarden/backup-age.pub"   # public key only lives here
RCLONE_REMOTE="offsite:vaultwarden-backups"          # configured via `rclone config`
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$(mktemp -d)"
mkdir -p "$BACKUP_DIR"

# 1. Consistent SQLite snapshot
sqlite3 "${DATA_DIR}/db.sqlite3" ".backup '${STAGE}/db.sqlite3'"

# 2. Everything else that matters
rsync -a \
  --exclude 'db.sqlite3' --exclude 'db.sqlite3-*' --exclude 'icon_cache' \
  "${DATA_DIR}/" "${STAGE}/data/"

# 3. Archive + compress + encrypt
ARCHIVE="${BACKUP_DIR}/vw-${STAMP}.tar.zst.age"
tar -C "${STAGE}" -cf - . | zstd -q | age -r "$(cat "$AGE_PUBKEY_FILE")" -o "$ARCHIVE"

# 4. Off-site copy
rclone copy "$ARCHIVE" "$RCLONE_REMOTE/"

# 5. Local retention (14 days)
find "$BACKUP_DIR" -name '*.age' -mtime +14 -delete
rm -rf "$STAGE"
```
Set up `age` (`age-keygen`, keep the private key off the server), `rclone config` for the off-site remote, and a daily timer/cron entry that runs `backup.sh`.

### Restore procedure
```bash
age -d -i /secure/offsite/backup-age.key vw-<stamp>.tar.zst.age | zstd -d | tar -x -C /restore
docker compose stop vaultwarden
# replace ./vw-data with restored db.sqlite3 + data/ contents
docker compose start vaultwarden
```

### Test restore (mandatory, do once at deploy)
Spin up a throwaway droplet/container, restore the latest off-site archive into it, and confirm the web vault opens and an account logs in. **A backup that has never been restored is only an assumption.**

## 9. Acceptance criteria

- [ ] `https://<domain>` serves the web vault with a valid Let's Encrypt certificate; HTTP redirects to HTTPS.
- [ ] An official Bitwarden mobile app and desktop app both connect using the self-hosted server URL.
- [ ] Multiple accounts exist; a shared Collection is accessible to the intended members and not to others.
- [ ] Changing a password on an item shows the previous value in that item's password history.
- [ ] `SIGNUPS_ALLOWED=false` after account creation; public registration is refused.
- [ ] Admin panel (`/admin`) requires the token and is not otherwise reachable.
- [ ] UFW shows only 22/80/443 inbound; fail2ban jails active for sshd and Vaultwarden.
- [ ] DigitalOcean droplet backups enabled (daily or better).
- [ ] `backup.sh` produces an encrypted archive that appears on the off-site remote.
- [ ] A test restore succeeded and the restored vault opened.

## 10. Open decisions for the human (fill these in)

- **Domain/subdomain** for the vault: `__________`
- **ACME contact email** (Caddy): `__________`
- **Off-site backup target** (provider + bucket) and credentials: `__________`
- **DO backup cadence:** daily (30%) vs usage-based intra-daily.
- **Backup retention:** local days / off-site days.
- **SMTP** for org invites & password-hint emails — configure now or skip? `__________`
- **Personal-vault recovery:** is it a requirement that the super admin can recover an individual's *personal* vault? If yes, choose the mechanism — every user grants the super admin **Emergency Access**, or keep recoverable secrets in shared org Collections. (The server admin alone cannot do this.) `__________`
- **Image pinning:** confirm the latest stable Vaultwarden tag on Docker Hub at deploy time (spec assumes `1.36.0`).

## 11. Notes & gotchas

- **HTTPS is mandatory.** Bitwarden clients refuse to connect over plain HTTP — the domain + valid cert is non-negotiable.
- **Keep `vw-data` on the droplet's main disk.** DigitalOcean droplet backups do **not** include attached block-storage volumes; putting the data on a mounted volume would silently exclude it from Layer 1.
- **Admin token `$` escaping:** the Argon2 PHC hash contains `$`; escape as `$$` in Compose or all logins to `/admin` will fail confusingly.
- **Don't auto-update blindly.** This is security-critical; pin the image and update deliberately after checking release notes rather than running an unattended auto-updater.
- **Private backup key never touches the server.** If it lives on the droplet, a server compromise exposes every historical backup.