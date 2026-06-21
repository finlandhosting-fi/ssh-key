#!/bin/bash
set -euo pipefail

echo "[+] SSH bootstrap starting..."

# -----------------------------
# ROOT CHECK
# -----------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Run as root (or sudo)"
    exit 1
fi

# -----------------------------
# TARGET USER
# -----------------------------
TARGET_USER="${SUDO_USER:-root}"

if ! id "$TARGET_USER" &>/dev/null; then
    echo "User does not exist: $TARGET_USER"
    exit 1
fi

echo "[+] Target user: $TARGET_USER"

# -----------------------------
# INSTALL DEPENDENCIES
# -----------------------------
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

# -----------------------------
# SSH DIR SETUP
# -----------------------------
HOME_DIR=$(eval echo "~$TARGET_USER")

mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.ssh"

# -----------------------------
# DOWNLOAD KEYS
# -----------------------------
TMP_DIR="/tmp/keys_repo"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

URL="https://github.com/finlandhosting-fi/ssh-key/archive/refs/heads/main.tar.gz"

echo "[+] Downloading keys repo..."

curl -fsSL --retry 3 -o /tmp/repo.tar.gz "$URL"
tar -xzf /tmp/repo.tar.gz -C "$TMP_DIR"
rm -f /tmp/repo.tar.gz

KEY_DIR=$(find "$TMP_DIR" -type d -path "*/keys" | head -n 1)

if [ -z "$KEY_DIR" ]; then
    echo "No keys directory found"
    exit 1
fi

# -----------------------------
# APPLY KEYS
# -----------------------------
echo "[+] Installing SSH keys..."

ADDED=0

for keyfile in "$KEY_DIR"/*.pub; do
    [ -f "$keyfile" ] || continue

    while IFS= read -r key || [ -n "$key" ]; do
        [ -z "$key" ] && continue

        if ! grep -qxF "$key" "$AUTH_KEYS"; then
            echo "$key" >> "$AUTH_KEYS"
            ADDED=$((ADDED + 1))
        fi
    done < "$keyfile"
done

echo "[+] Added $ADDED key(s)"

# -----------------------------
# SAFE SSH RESTART (REAL FIX)
# -----------------------------
echo "[+] Testing SSH config..."

if ! sshd -t 2>/dev/null; then
    echo "SSH config invalid - NOT restarting"
    exit 1
fi

echo "[+] Restarting SSH service..."

if systemctl is-active --quiet sshd; then
    systemctl restart sshd
elif systemctl is-active --quiet ssh; then
    systemctl restart ssh
else
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi

echo "[+] SSH ready 🔥"
echo "[+] Done"
