#!/bin/bash
set -e

echo "[+] SSH bootstrap starting..."

# root check
if [ "$EUID" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi

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

# deps
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
    $PKG install -y openssh-server curl
    systemctl enable --now sshd
fi

HOME_DIR=$(eval echo "~$USER")

mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chown -R "$USER:$USER" "$HOME_DIR/.ssh"

# -----------------------------
# PULL KEYS FROM /keys/
# -----------------------------
TMP_DIR="/tmp/keys_repo"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

echo "[+] Fetching keys repo..."

curl -fsSL https://github.com/finlandhosting-fi/ssh-key/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP_DIR"

KEY_DIR=$(find "$TMP_DIR" -type d -name "keys" | head -n 1)

if [ -z "$KEY_DIR" ]; then
    echo "No keys directory found"
    exit 1
fi

echo "[+] Installing keys..."

for keyfile in "$KEY_DIR"/*.pub; do
    [ -f "$keyfile" ] || continue

    while read -r key; do
        if [ -n "$key" ]; then
            grep -qxF "$key" "$HOME_DIR/.ssh/authorized_keys" || \
            echo "$key" >> "$HOME_DIR/.ssh/authorized_keys"
        fi
    done < "$keyfile"
done

chown "$USER:$USER" "$HOME_DIR/.ssh/authorized_keys"

# ssh service detect
if systemctl list-unit-files | grep -q sshd; then
    SVC="sshd"
else
    SVC="ssh"
fi

# safe restart
if sshd -t; then
    systemctl restart "$SVC"
    echo "[+] SSH ready"
else
    echo "SSH config broken - not restarting"
    exit 1
fi

echo "[+] Done 🔥"
