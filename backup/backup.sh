#!/usr/bin/env bash
#
# Vaultwarden application-consistent, encrypted, off-site backup (Layer 2).
# Run daily via the accompanying systemd timer.
#
# Design notes:
#   * SQLite `.backup` (never a raw cp) for a consistent snapshot.
#   * Everything in /data except the disposable icon_cache is included.
#   * Encrypted with `age` to a PUBLIC key; the matching private key lives
#     OFF this server, so a host compromise cannot decrypt any backup.
#   * Pushed off DigitalOcean with rclone.
#
set -euo pipefail

DATA_DIR="/opt/vaultwarden/vw-data"
BACKUP_DIR="/opt/vaultwarden/backups"
AGE_PUBKEY_FILE="/opt/vaultwarden/backup-age.pub"    # public key only ever lives here
RCLONE_REMOTE="offsite:gym-junkie-01/vaultwarden-backups"  # bucket/prefix; remote configured via `rclone config`
LOCAL_RETENTION_DAYS=14

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$BACKUP_DIR"

# Fail loudly if the encryption key is missing — never write a plaintext backup.
if [[ ! -s "$AGE_PUBKEY_FILE" ]]; then
	echo "FATAL: age public key not found at $AGE_PUBKEY_FILE" >&2
	exit 1
fi

# 1. Consistent SQLite snapshot
sqlite3 "${DATA_DIR}/db.sqlite3" ".backup '${STAGE}/db.sqlite3'"

# 2. Everything else that matters (skip the live db files and disposable cache)
rsync -a \
	--exclude 'db.sqlite3' --exclude 'db.sqlite3-*' \
	--exclude 'icon_cache' --exclude 'vaultwarden.log' \
	"${DATA_DIR}/" "${STAGE}/data/"

# 3. Archive + compress + encrypt
ARCHIVE="${BACKUP_DIR}/vw-${STAMP}.tar.zst.age"
tar -C "${STAGE}" -cf - . | zstd -q | age -r "$(cat "$AGE_PUBKEY_FILE")" -o "$ARCHIVE"

# 4. Off-site copy
rclone copy "$ARCHIVE" "${RCLONE_REMOTE}/"

# 5. Local retention
find "$BACKUP_DIR" -name '*.age' -mtime "+${LOCAL_RETENTION_DAYS}" -delete

echo "Backup complete: ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1)) -> ${RCLONE_REMOTE}/"
