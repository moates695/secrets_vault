# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a self-hosted **Vaultwarden** password vault on a single
DigitalOcean droplet. It contains **templates and documentation only** — no application
code, no build step, no test suite. Every file here is deployed to `/opt/vaultwarden`
on the droplet, where the real secrets (`.env`, `backup-age.key`, `rclone.conf`) live
and are never committed (see `.gitignore`).

There is nothing to build, lint, or run locally. "Development" means editing these
templates; "deployment" is the ordered runbook in `README.md` / `docs/handoff.md`.

## Validating changes

- **Compose:** `docker compose config` (renders + validates interpolation) before `up -d`.
- **nginx:** changes to `nginx/vault.moates.com.au.conf` are validated *inside the proxy
  container* with `nginx -t` and applied with `nginx -s reload` (zero-downtime). The vhost
  is **appended to the existing proxy's template**, not deployed standalone.
- **Shell:** `backup/backup.sh` runs `set -euo pipefail`; check with `shellcheck` and a
  manual `sudo systemctl start vaultwarden-backup.service` dry run on the droplet.

## Architecture (the parts that span files)

This is the **integrated / shared-host** variant. The droplet already runs an
nginx-proxy fronted by Cloudflare for other services (gymjunkie/moates — see the
`do-droplet-shared-prod` memory). Vaultwarden slots in behind that existing proxy rather
than bringing its own.

```
Cloudflare (proxied) ─443─▶ existing nginx-proxy ──▶ vaultwarden:80 ──▶ ./vw-data
   (WAF, rate-limit)         (TLS: CF Origin cert)   (no host ports)    (sqlite, keys)
```

- **No published host ports.** `docker-compose.yml` joins the *external* network
  `backend-prod_api-network` (created by the gym_junkie_server project) and the proxy
  reaches the container by name. Do not add `ports:`.
- **TLS terminates at the existing nginx** using a wildcard Cloudflare Origin cert that
  already covers the subdomain — no ACME/Let's Encrypt here.
- **All state is the `./vw-data` bind-mount on the droplet's main disk** (not a block
  volume — those are excluded from DO droplet backups).
- A standalone Caddy + Let's Encrypt variant is documented in `docs/handoff.md`; this repo
  implements the integrated variant. When editing, keep to the integrated design.

## Non-obvious constraints — read before editing

These are the things that will silently break a deploy if missed:

- **`ADMIN_TOKEN` `$` doubling.** This host's Compose interpolates `env_file` values, so
  the Argon2 PHC hash in `.env` must have **every `$` doubled to `$$`**. `DOMAIN` in `.env`
  is the **bare host** (no scheme); Compose prepends `https://`. Verify post-deploy with
  `docker exec vaultwarden printenv ADMIN_TOKEN` (must be a valid single-`$` `$argon2id$…`).
  Full rationale in `.env.example` and `README.md`.

- **fail2ban does NOT protect the HTTP layer here — this is intentional.** Because the
  service is Dockerised (DNAT bypasses the INPUT chain) *and* Cloudflare-proxied (packet
  source is the CF edge), an iptables jail would ban Cloudflare, not attackers. The HTTP
  layer is defended by nginx rate-limiting on the real client IP + the Cloudflare-only
  origin lock. Only the **sshd** jail (`fail2ban/jail.d/sshd.local`) is enabled. The
  `vaultwarden*` filters/jail are reference-only for a non-Cloudflare host — do not "fix"
  them by enabling them. See `fail2ban/jail.d/vaultwarden.local` for the full reasoning.

- **Cloudflare IP ranges appear twice in the nginx vhost** and must stay in sync: the
  `geo … $vault_from_cloudflare` origin-lock block *and* the `set_real_ip_from` list.
  Both carry a "ranges snapshot <date>" comment. When refreshing from cloudflare.com/ips-v4
  and /ips-v6, update **both** blocks and the dates together.

- **The nginx vhost is a marker-delimited managed block** (`# >>> vaultwarden vhost >>>`
  … `# <<< vaultwarden vhost <<<`). The deploy script replaces everything between the
  markers, so keep all vault config inside them.

- **The rclone `offsite:` remote needs `no_check_bucket = true`.** It reuses the
  shared, bucket-scoped DigitalOcean Spaces key (bucket `gym-junkie-01`, region
  `syd1`) that the gymjunkie DB backup uses. That key can't `CreateBucket`, so
  rclone's default pre-flight bucket check fails with `403 AccessDenied` on every
  upload until `no_check_bucket = true` is set. `backup.sh` calls `rclone copy`
  with no flags, so this lives in the remote config, not the script. Full config in
  `README.md` step 7.

- **Backups encrypt to a public age key** (`backup-age.pub`); the private key lives
  off-server so a full host compromise can't decrypt backup history. `backup.sh` aborts
  rather than write a plaintext backup if the pubkey is missing. It uses SQLite `.backup`
  (never `cp`) for a consistent snapshot. A backup is only real once a **test restore** has
  been done.

## Conventions

- Every template is heavily commented with *why* a choice was made — preserve that when
  editing; these comments are the operational runbook.
- Australian English spelling in prose/comments.
