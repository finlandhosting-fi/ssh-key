#!/bin/bash
set -euo pipefail

# =====================================================================
# SSH bootstrap / key sync script
#
# Runs with no arguments by default. The set of users managed is
# derived from the *.pub filenames in the keys repo — NOT hardcoded
# here. To add or remove a person, just add/remove their <name>.pub
# in the keys/ folder of the repo. Nothing in this script needs
# editing, ever.
#
# Reconcile (removing stale keys not in the repo) is ON by default.
#
# Usage:
#   ./ssh-bootstrap.sh                  # sync + reconcile all users found in repo
#   ./ssh-bootstrap.sh --no-reconcile   # add-only, skip removals
#   ./ssh-bootstrap.sh --commit <sha>   # pin to a specific repo commit
#
# How user discovery works:
#   keys/arttu.pub  -> manages system user "arttu"
#   keys/oliver.pub -> manages system user "oliver"
#   A .pub file for a system user that doesn't exist on this box is
#   skipped with a warning (not an error) — useful since not every
#   server needs every account.
# =====================================================================

REPO_OWNER="finlandhosting-fi"
REPO_NAME="ssh-key"
COMMIT_REF="main"          # override with --commit <sha>
RECONCILE=1                # on by default; disable with --no-reconcile
LOG_FILE="/var/log/ssh-bootstrap-keys.log"

echo "[+] SSH bootstrap starting..."

# ---- root check ----
if [ "$EUID" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi

# ---- arg parsing ----
while [ $# -gt 0 ]; do
    case "$1" in
        --reconcile)
            RECONCILE=1
            shift
            ;;
        --no-reconcile)
            RECONCILE=0
            shift
            ;;
        --commit)
            COMMIT_REF="${2:-}"
            if [ -z "$COMMIT_REF" ]; then
                echo "Missing value for --commit"
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$COMMIT_REF" = "main" ]; then
    echo "[!] Warning: fetching from 'main' (not pinned). Pass --commit <sha> to pin a known-good state."
fi
if [ "$RECONCILE" -eq 1 ]; then
    echo "[!] Reconcile is ON: keys missing from the repo will be removed for matching users."
fi

# ---- deps ----
if command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
else
    PKG="apt"
fi

if [ "$PKG" = "apt" ]; then
    apt-get update -y
    apt-get install -y openssh-server curl
    systemctl enable --now ssh || systemctl enable --now sshd
else
    "$PKG" install -y openssh-server curl
    systemctl enable --now sshd
fi

# ---- pull keys repo ----
TMP_DIR="/tmp/keys_repo"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

echo "[+] Fetching keys repo (ref: $COMMIT_REF)..."
curl -fsSL "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${COMMIT_REF}.tar.gz" \
    | tar -xz -C "$TMP_DIR"

KEY_DIR=$(find "$TMP_DIR" -type d -name "keys" | head -n 1)
if [ -z "$KEY_DIR" ]; then
    echo "No keys directory found"
    exit 1
fi

# ---- discover users from *.pub filenames, validate each file's keys ----
shopt -s nullglob
PUB_FILES=("$KEY_DIR"/*.pub)
shopt -u nullglob

if [ ${#PUB_FILES[@]} -eq 0 ]; then
    echo "[!] No .pub files found in repo — refusing to continue (would wipe everyone if reconcile is on)."
    exit 1
fi

declare -A USER_VALID_KEYS   # username -> newline-separated valid keys

for keyfile in "${PUB_FILES[@]}"; do
    [ -f "$keyfile" ] || continue
    base="$(basename "$keyfile")"
    pub_user="${base%.pub}"

    valid_keys=""
    while IFS= read -r key || [ -n "$key" ]; do
        [ -z "$key" ] && continue
        if [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]]+.*)?$ ]]; then
            valid_keys+="$key"$'\n'
        else
            echo "[!] Skipping malformed line in $base: ${key:0:50}..."
        fi
    done < "$keyfile"

    if [ -z "$valid_keys" ]; then
        echo "[!] No valid keys found in $base — skipping $pub_user entirely (not touching their authorized_keys)."
        continue
    fi

    USER_VALID_KEYS["$pub_user"]="$valid_keys"
done

if [ ${#USER_VALID_KEYS[@]} -eq 0 ]; then
    echo "[!] No users with valid keys found — nothing to do."
    exit 1
fi

echo "[+] Users found in repo: ${!USER_VALID_KEYS[*]}"

# ---- per-user sync ----
for TARGET_USER in "${!USER_VALID_KEYS[@]}"; do
    echo "[+] --- User: $TARGET_USER ---"

    if ! id "$TARGET_USER" &>/dev/null; then
        echo "[!] System user does not exist on this box, skipping: $TARGET_USER"
        continue
    fi

    HOME_DIR=$(eval echo "~$TARGET_USER")
    mkdir -p "$HOME_DIR/.ssh"
    chmod 700 "$HOME_DIR/.ssh"
    touch "$HOME_DIR/.ssh/authorized_keys"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.ssh"

    AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"
    VALID_KEYS_FOR_USER="${USER_VALID_KEYS[$TARGET_USER]}"

    # add new keys
    ADDED=0
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        if ! grep -qxF "$key" "$AUTH_KEYS"; then
            echo "$key" >> "$AUTH_KEYS"
            ADDED=$((ADDED + 1))
            printf '%s added key for %s: %s...\n' "$(date -u +%FT%TZ)" "$TARGET_USER" "${key:0:50}" >> "$LOG_FILE"
        fi
    done <<< "$VALID_KEYS_FOR_USER"
    echo "[+] Added $ADDED new key(s) for $TARGET_USER."

    # reconcile: remove keys no longer in this user's .pub file
    if [ "$RECONCILE" -eq 1 ]; then
        REMOVED=0
        TMP_AUTH=$(mktemp)
        while IFS= read -r existing_key || [ -n "$existing_key" ]; do
            [ -z "$existing_key" ] && { echo "$existing_key" >> "$TMP_AUTH"; continue; }
            if grep -qxF "$existing_key" <<< "$VALID_KEYS_FOR_USER"; then
                echo "$existing_key" >> "$TMP_AUTH"
            else
                REMOVED=$((REMOVED + 1))
                printf '%s removed key for %s: %s...\n' "$(date -u +%FT%TZ)" "$TARGET_USER" "${existing_key:0:50}" >> "$LOG_FILE"
            fi
        done < "$AUTH_KEYS"
        mv "$TMP_AUTH" "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        echo "[+] Removed $REMOVED stale key(s) for $TARGET_USER."
    fi

    chown "$TARGET_USER:$TARGET_USER" "$AUTH_KEYS"
done

# ---- ssh service detect ----
if systemctl list-unit-files | grep -q sshd; then
    SVC="sshd"
else
    SVC="ssh"
fi

# ---- safe restart ----
if sshd -t; then
    systemctl restart "$SVC"
    echo "[+] SSH ready"
else
    echo "SSH config broken - not restarting"
    exit 1
fi

echo "[+] Done 🔥"
