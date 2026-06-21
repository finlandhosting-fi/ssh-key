#!/bin/bash
set -e

echo "[+] SSH bootstrap starting..."

# -----------------------------
# ROOT CHECK
# -----------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi

# -----------------------------
# USER INPUT
# -----------------------------
USER="${1:-}"

if [ -z "$USER" ]; then
    read -p "Target user: " USER
fi

if [ -z "$USER" ]; then
    echo "No user provided"
    exit 1
fi

if ! id "$USER" &>/dev/null; then
    echo "User does not exist: $USER"
    exit 1
fi

echo "[+] User: $USER"

# -----------------------------
# PACKAGE MANAGER DETECT
# -----------------------------
if command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
else
    PKG="apt"
fi

# -----------------------------
# INSTALL SSH + CURL
# -----------------------------
if [ "$PKG" = "apt" ]; then
    apt-get update -y
    apt-get install -y openssh-server curl
    systemctl enable --now ssh || systemctl enable --now sshd
else
    $PKG install -y openssh-server curl
    systemctl enable --now sshd
fi

# -----------------------------
# SSH DIR SETUP
# -----------------------------
HOME_DIR=$(eval echo "~$USER")

mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

touch "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown -R "$USER:$USER" "$HOME_DIR/.ssh"

# -----------------------------
# FETCH KEYS REPO (FIXED - NO PIPE TAR)
# -----------------------------
TMP_DIR="/tmp/keys_repo"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

URL="https://github.com/finlandhosting-fi/ssh-key/archive/refs/heads/main.tar.gz"

echo "[+] Downloading keys repo..."

curl -fsSL --retry 3 -o /tmp/repo.tar.gz "$URL"

tar -xzf /tmp/repo.tar.gz -C "$TMP_DIR"
rm -f /tmp/repo.tar.gz

# -----------------------------
# SAFE KEY DIR RESOLVE (FIXED)
# -----------------------------
KEY_DIR=$(find "$TMP_DIR" -type d -path "*/keys" | head -n 1)

if [ -z "$KEY_DIR" ] || [ ! -d "$KEY_DIR" ]; then
    echo "No keys directory found"
    exit 1
fi

echo "[+] Installing keys..."

# -----------------------------
# ADD KEYS (IDEMPOTENT)
# -----------------------------
for keyfile in "$KEY_DIR"/*.pub; do
    [ -f "$keyfile" ] || continue

    while read -r key; do
        # skip empty / whitespace lines
        [ -z "$key" ] && continue

        grep -qxF "$key" "$HOME_DIR/.ssh/authorized_keys" || \
        echo "$key" >> "$HOME_DIR/.ssh/authorized_keys"
    done < "$keyfile"
done

chown "$USER:$USER" "$HOME_DIR/.ssh/authorized_keys"

# -----------------------------
# SSH SERVICE DETECT (FIXED)
# -----------------------------
if systemctl list-unit-files | grep -q "^sshd"; then
    SVC="sshd"
else
    SVC="ssh"
fi

# -----------------------------
# SAFE SSH VALIDATION
# -----------------------------
echo "[+] Validating SSH config..."

if sshd -t; then
    systemctl restart "$SVC"
    echo "[+] SSH ready 🔥"
else
    echo "SSH config broken - NOT restarting"
    exit 1
fi

echo "[+] Done"
