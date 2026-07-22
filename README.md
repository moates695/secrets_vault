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

Vaultwarden runs on a **shared host** that already has an nginx reverse proxy
(fronted by Cloudflare in proxied mode) terminating TLS for other services. Rather
than run a second proxy, Vaultwarden integrates behind the existing one.

```
Internet ──▶ Cloudflare (proxied) ──443──▶ nginx-proxy (existing)
                                              │  TLS: wildcard Cloudflare Origin cert
                                              │  vhost: vault.<domain>
                                              ▼
                                         vaultwarden:80   (shared Docker network, no host ports)
                                              │
                                         ./vw-data (host bind-mount:
                                         db.sqlite3, attachments, config, rsa keys)
```

- **No bundled reverse proxy.** The Vaultwarden container publishes **no host
  ports**; it joins the existing proxy's Docker network and is reached by name.
- **TLS** is terminated at the existing nginx using a wildcard **Cloudflare Origin
  certificate**; the `vault.<domain>` record is **proxied (orange cloud)**.
- All persistent state lives in the `vw-data` bind-mount on the droplet's **main
  disk** (not an attached block volume — those are excluded from DigitalOcean
  droplet backups).

> A standalone variant (Caddy + Let's Encrypt, for a *dedicated* droplet) is
> described in [`docs/handoff.md`](docs/handoff.md); this repo implements the
> integrated variant for a shared host.

## Repository layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Vaultwarden service only; joins the existing proxy network |
| `.env.example` | Template for the git-ignored `.env` (copy & fill on the droplet) |
| `nginx/vault.moates.com.au.conf` | vhost block to append to the existing nginx template |
| `backup/backup.sh` | Daily app-consistent, `age`-encrypted, off-site backup |
| `backup/vaultwarden-backup.{service,timer}` | systemd units to run it daily |
| `fail2ban/jail.d/sshd.local` | Host SSH brute-force jail (the layer where iptables bans work) |
| `fail2ban/filter.d/*`, `jail.d/vaultwarden.local` | Reference filters; the HTTP jail is **not** used here (see file) |
| `docs/handoff.md` | Original full specification (standalone variant) |

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
# Docker Engine + Compose are assumed already present on the shared host.
# 1. Clone this repo into /opt/vaultwarden
git clone git@github.com:moates695/secrets_vault.git /opt/vaultwarden && cd /opt/vaultwarden

# 2. Create the real environment file (never committed)
cp .env.example .env
#    Generate the admin token hash and paste it into .env:
docker run --rm -it vaultwarden/server:1.36.0 /vaultwarden hash
nano .env            # set DOMAIN, ADMIN_TOKEN, ...

# 3. Bring up the Vaultwarden container (joins the existing proxy network, no host ports)
docker compose up -d

# 4. Add the vault vhost to the existing nginx and reload (zero-downtime):
#    append nginx/vault.moates.com.au.conf to the proxy's template, then
#    re-render + validate + reload inside the nginx container.

# 5. Register the super-admin account, create the Organization + Collections,
#    then set SIGNUPS_ALLOWED=false in .env and `docker compose up -d`.

# 6. Install fail2ban (sshd jail). The vault HTTP layer is protected by nginx
#    rate-limiting on the real client IP, not an iptables jail — see
#    fail2ban/jail.d/vaultwarden.local for why.
cp fail2ban/jail.d/sshd.local /etc/fail2ban/jail.d/
systemctl enable --now fail2ban && systemctl restart fail2ban

# 7. Install the backup timer (after `rclone config` + placing backup-age.pub)
cp backup/vaultwarden-backup.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now vaultwarden-backup.timer
```

**rclone off-site remote (`offsite:`).** On this shared host the remote reuses the
existing DigitalOcean Spaces key (bucket `gym-junkie-01`, region `syd1`) that the
gymjunkie DB backup already uses. That key is **bucket-scoped and cannot create
buckets**, so the remote **must** set `no_check_bucket = true` — otherwise rclone's
pre-flight bucket check issues a `CreateBucket` that Spaces rejects with
`403 AccessDenied` on *every* upload (the object PUT never runs). Minimum working
config (`/root/.config/rclone/rclone.conf`):

```ini
[offsite]
type = s3
provider = DigitalOcean
region = syd1
endpoint = syd1.digitaloceanspaces.com
no_check_bucket = true
access_key_id = <spaces key>
secret_access_key = <spaces secret>
```

Verify with `rclone copy <file> offsite:gym-junkie-01/vaultwarden-backups/` before
enabling the timer. If a future host mints a **dedicated** key with create rights,
`no_check_bucket` can be dropped.

### DNS / Cloudflare

Add an **A record** for `vault.<domain>` pointing at the droplet's public IP, set
to **Proxied (orange cloud)** to match the other services on this host. TLS is
handled at the origin by nginx using the existing wildcard **Cloudflare Origin
certificate**, which already covers this subdomain — no new certificate or ACME
flow is required.

## Design decisions worth calling out

- **Argon2 admin token `$` escaping.** The token hash is a PHC string full of `$`.
  This host's Docker Compose interpolates `env_file` values, so every `$` is
  **doubled to `$$`** in `.env`; after interpolation the container receives the
  original hash. This is verified at deploy time with
  `docker exec vaultwarden printenv ADMIN_TOKEN` (must be a valid 6-field
  `$argon2id$…` string). A plaintext token would avoid the escaping but is kept
  as a hash so a leak of `.env` never yields a usable admin credential.
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

See [`docs/handoff.md` §9](docs/handoff.md) (adapted for the integrated variant).
Highlights: `https://vault.<domain>` serves the web vault with a valid cert and
HTTP→HTTPS redirect; official mobile & desktop clients connect; shared Collection
visible only to intended members; per-item password history; signups closed after
setup; `/admin` gated by token; the existing sites (gymjunkie/chat/mcp) remain
unaffected; fail2ban jails active; both backup layers verified including a
successful test restore.
