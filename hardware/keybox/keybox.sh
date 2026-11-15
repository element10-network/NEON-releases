#!/bin/sh
# The key box (owner 2026-11-15): a Raspberry Pi at home that holds the NEON admin key and posts each
# epoch's root, and does nothing else. Nothing listens on it (no SSH, no web server: keybox-setup.sh
# removes the SSH server and drops every incoming connection); it only connects out, to the electrode
# (neon-post.sh fetches the pending epoch over SSH) and to the Solana RPC, and is run from its own
# screen and keyboard with this menu.
#
#   keybox.sh menu           the console menu (started on tty1 after logging in)
#   keybox.sh status         what it is doing, as text
#   keybox.sh update         install the newest signed release's neon-oracle, neon-token and scripts
#   keybox.sh import DIR     take post.conf, the admin key and the SSH key from DIR (a USB stick)
#   keybox.sh wipe DIR       erase those files from DIR once imported
#
# Updates come from the public element10-network/NEON-releases: tools.txt and scripts.txt, each
# checked against a release key built into this script (as into neond and setup.sh; a test keeps
# the list equal to hardware/release-keys.txt), never an older version than the one installed.
set -eu

GH_REPO=element10-network/NEON-releases
HOME_DIR=/opt/neon-keybox
POST_DIR=/opt/neon-post
STATE=/var/lib/neon-post
CONF=/etc/neon/post.conf
BIN=/usr/local/bin
USER_NAME=ne
keys="3uHOV7U6pfQy7JZS9oIVexR8+kdWJLvPlLEDz5ZnJhE="

die() { echo "ERROR: $*" >&2; exit 1; }
as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
# as_user CMD...: as the posting user (who owns the keys), from root or from that user.
as_user() {
    if [ "$(id -un)" = "$USER_NAME" ]; then "$@"
    elif [ "$(id -u)" = 0 ]; then runuser -u "$USER_NAME" -- "$@"
    else sudo -u "$USER_NAME" "$@"; fi
}

# signed FILE SIG: whether SIG is a release key's Ed25519 signature of FILE.
signed() {
    for key in $keys; do
        { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; echo "$key" | base64 -d; } > "$TMP/key.der"
        openssl pkeyutl -verify -pubin -keyform DER -inkey "$TMP/key.der" -rawin -in "$1" -sigfile "$2" >/dev/null 2>&1 && return 0
    done
    return 1
}
# vle A B: whether version A is at most B.
vle() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]; }

# ---- update: the newest stable release's tools and scripts, checked ----
update() {
    [ "$(id -u)" = 0 ] || { as_root "$0" update; return; }
    arch=$(uname -m)
    case "$arch" in aarch64) target=aarch64-unknown-linux-gnu ;; x86_64) target=x86_64-unknown-linux-gnu ;; *) die "no tools for $arch" ;; esac
    curl -fsSL -H "Accept: application/vnd.github+json" -o "$TMP/latest.json" "https://api.github.com/repos/$GH_REPO/releases/latest" ||
        die "could not ask GitHub for the newest release (try again in an hour)"
    tag=$(jq -r '.tag_name // empty' "$TMP/latest.json")
    case "$tag" in v[0-9]*.[0-9]*.[0-9]*) ;; *) die "the newest release's tag is not a version: $tag" ;; esac
    case "$tag" in *[!v0-9.]*) die "the newest release's tag is not a version: $tag" ;; esac
    version=${tag#v}
    have=$(cat "$HOME_DIR/version" 2>/dev/null || echo 0.0.0)
    vle "$have" "$version" || die "the newest release ($version) is older than the one installed ($have): not installed"
    asset() {
        url=$(jq -r --arg n "$1" '[.assets[]? | select(.name == $n) | .browser_download_url][0] // empty' "$TMP/latest.json")
        [ -n "$url" ] || return 1
        curl -fsSL --retry 3 -o "$2" "$url"
    }
    for f in tools scripts; do
        asset "$f.txt" "$TMP/$f.txt" || die "release $version has no $f.txt (released before the key box)"
        asset "$f.sig" "$TMP/$f.sig" || die "release $version has no $f.sig"
        signed "$TMP/$f.txt" "$TMP/$f.sig" || die "$f.txt is not signed by a release key: nothing installed"
        [ "$(sed -n 's/^version //p' "$TMP/$f.txt")" = "$version" ] || die "$f.txt is for another version"
    done
    # The binaries, each of the size and hash tools.txt signs.
    for tool in neon-oracle neon-token; do
        line=$(grep "^file $target $tool-$target " "$TMP/tools.txt") || {
            [ "$tool" = neon-token ] && [ -x "$BIN/neon-token" ] && { echo "release $version has no neon-token: keeping the one installed"; continue; }
            die "release $version has no $tool for $target"; }
        name=$(echo "$line" | cut -d' ' -f3); size=$(echo "$line" | cut -d' ' -f4); sha=$(echo "$line" | cut -d' ' -f5)
        asset "$name" "$TMP/$tool" || die "could not download $name"
        [ "$(wc -c < "$TMP/$tool")" = "$size" ] || die "$name: wrong size"
        echo "$sha  $TMP/$tool" | sha256sum -c --quiet - || die "$name: wrong SHA-256"
        chmod 755 "$TMP/$tool"
    done
    # The scripts at the release's tag, as the hash scripts.txt signs.
    tree_want=$(sed -n 's/^tree \([0-9a-f]\{64\}\)$/\1/p' "$TMP/scripts.txt")
    [ -n "$tree_want" ] || die "scripts.txt names no tree"
    git clone -q --depth 1 --branch "$tag" "https://github.com/$GH_REPO.git" "$TMP/src" || die "could not fetch the scripts of $tag"
    tree=$(cd "$TMP/src" && find hardware -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
    [ "$tree" = "$tree_want" ] || die "the scripts at $tag are not the ones scripts.txt signs: nothing installed"
    # Everything checked: install.
    for tool in neon-oracle neon-token; do
        [ -f "$TMP/$tool" ] && install -m 755 "$TMP/$tool" "$BIN/$tool"
    done
    mkdir -p "$POST_DIR" "$HOME_DIR"
    install -m 755 "$TMP/src/hardware/scripts/neon-post.sh" "$POST_DIR/neon-post.sh"
    install -m 644 "$TMP/src/hardware/systemd/neon-post.service" "$TMP/src/hardware/systemd/neon-post.timer" /etc/systemd/system/
    install -m 755 "$TMP/src/hardware/keybox/keybox.sh" "$HOME_DIR/keybox.sh"
    systemctl daemon-reload
    echo "$version" > "$HOME_DIR/version"
    sed -n 's/^token-commit //p' "$TMP/tools.txt" > "$HOME_DIR/token-commit"
    echo "installed release $version (neon-oracle, neon-token, neon-post.sh, the key box's menu)"
}

# ---- import: settings and keys from a USB stick, made on the old posting machine ----
# The stick's folder holds post.conf, admin.json (the admin keypair) and ssh/ (id_ed25519 and
# known_hosts): see docs/HUB.md "The key box".
import() {
    d=${1:?import DIR}
    [ "$(id -u)" = 0 ] || { as_root "$0" import "$d"; return; }
    for f in post.conf admin.json ssh/id_ed25519 ssh/known_hosts; do [ -s "$d/$f" ] || die "$d/$f is missing"; done
    mkdir -p /etc/neon "$STATE/ssh" "$STATE/epochs"
    # The paths on this machine; the rest as it was (the electrode, the treasury, the core hubs...).
    grep -v -E '^(NEON_TOKEN|NEON_ORACLE|KEYPAIR|SSH_KEY|LOCAL_EPOCHS)=' "$d/post.conf" > "$TMP/post.conf"
    printf 'NEON_TOKEN=%s\nNEON_ORACLE=%s\nKEYPAIR=%s\nSSH_KEY=%s\n' "$BIN/neon-token" "$BIN/neon-oracle" "$STATE/admin.json" "$STATE/ssh/id_ed25519" >> "$TMP/post.conf"
    install -m 644 "$TMP/post.conf" "$CONF"
    install -m 600 -o "$USER_NAME" -g "$USER_NAME" "$d/admin.json" "$STATE/admin.json"
    install -m 600 -o "$USER_NAME" -g "$USER_NAME" "$d/ssh/id_ed25519" "$STATE/ssh/id_ed25519"
    install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$d/ssh/known_hosts" "$STATE/ssh/known_hosts"
    chown -R "$USER_NAME:$USER_NAME" "$STATE"
    chmod 700 "$STATE" "$STATE/ssh"
    firewall
    echo "imported: $CONF, the admin key and the SSH key (in $STATE). Wipe the stick's copies next (menu: Wipe the stick)."
}

wipe() {
    d=${1:?wipe DIR}
    for f in admin.json ssh/id_ed25519 ssh/id_ed25519.pub ssh/known_hosts post.conf; do
        [ -f "$d/$f" ] && shred -u "$d/$f"
    done
    rmdir "$d/ssh" "$d" 2>/dev/null || true
    sync
    echo "erased from $d (on a flash stick shred cannot reach every copy: keep the stick with the key box, or destroy it)"
}

# ---- firewall: nothing in; out only DNS, time, HTTPS and the electrode's SSH port ----
firewall() {
    port=$(sed -n 's/^PORT=\([0-9]*\).*/\1/p' "$CONF" 2>/dev/null | tail -n 1)
    [ -n "$port" ] || port=22
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# The key box (keybox.sh): nothing comes in; out only what posting needs.
flush ruleset
table inet keybox {
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        # IPv6 neighbour discovery and router adverts (the network itself), nothing else.
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy drop;
        oif lo accept
        ct state established,related accept
        udp dport { 53, 67, 123, 547 } accept
        tcp dport { 53, 443, $port } accept
        icmp type echo-request accept
        icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } accept
    }
}
EOF
    systemctl enable -q nftables
    systemctl restart nftables
}

# ---- status ----
conf() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1 | sed "s/^[\"']//; s/[\"']\$//"; }
rpc_url() { case "$1" in devnet|"") echo https://api.devnet.solana.com ;; mainnet|mainnet-beta) echo https://api.mainnet-beta.solana.com ;; testnet) echo https://api.testnet.solana.com ;; *) echo "$1" ;; esac; }
status() {
    echo "Release      $(cat "$HOME_DIR/version" 2>/dev/null || echo 'none yet (Update tools)')"
    # (The DHCP clients' sockets, 68 and 546, are not services; the firewall drops all of it anyway.)
    open=$(ss -Htuln 2>/dev/null | awk '{print $5}' | grep -v -E '^(127\.|\[::1\]|.*%lo:)' | grep -v -E ':(68|546)$' | wc -l)
    echo "Listening    $open port(s) open to the network$( [ "$open" = 0 ] && echo ' (as it should be)')"
    if nft list ruleset 2>/dev/null | grep -q 'hook input priority 0; policy drop'; then echo "Firewall     incoming dropped"; else echo "Firewall     NOT ON (Set up again)"; fi
    if [ ! -s "$CONF" ]; then echo "Settings     none yet (Import from a USB stick)"; return 0; fi
    url=$(conf URL); remote=$(conf REMOTE); port=$(conf PORT)
    echo "Network      ${url:-devnet}, electrode ${remote:-?} (port ${port:-22})"
    if systemctl is-enabled -q neon-post.timer 2>/dev/null; then
        echo "Posting      timer on, next $(systemctl show neon-post.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    else
        echo "Posting      timer off (turn it on in the menu once the old machine's is off)"
    fi
    last=$(systemctl show neon-post.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
    echo "Last run     ${last:-never}${last:+ ($(systemctl show neon-post.service -p Result --value 2>/dev/null))}"
    if [ -x "$BIN/neon-token" ]; then
        echo "Next epoch   $(timeout 30 "$BIN/neon-token" --url "${url:-devnet}" next-epoch 2>/dev/null || echo '? (no answer from the chain)') (on chain)"
    fi
    if [ -r "$STATE/admin.json" ] || as_root test -r "$STATE/admin.json"; then
        pub=$(as_root cat "$STATE/admin.json" | python3 -c 'import json,sys
b=bytes(json.load(sys.stdin)[32:64]); a="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; n=int.from_bytes(b,"big"); s=""
while n: n,r=divmod(n,58); s=a[r]+s
print("1"*(len(b)-len(b.lstrip(b"\0")))+s)')
        lam=$(curl -fsS -m 20 -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getBalance\",\"params\":[\"$pub\"]}" "$(rpc_url "$url")" 2>/dev/null | jq -r '.result.value // empty')
        echo "Admin key    $pub"
        echo "SOL          $( [ -n "$lam" ] && awk -v l="$lam" 'BEGIN{printf "%.4f", l/1e9}' || echo '? (no answer)')"
    fi
    if [ -s "$STATE/ssh/id_ed25519" ] || as_root test -s "$STATE/ssh/id_ed25519"; then
        waiting=$(as_user ssh -i "$STATE/ssh/id_ed25519" -p "${port:-22}" -o BatchMode=yes -o ConnectTimeout=15 \
            -o UserKnownHostsFile="$STATE/ssh/known_hosts" "$remote" list 2>/dev/null | tr '\n' ' ')
        echo "On electrode ${waiting:-? (no answer)}"
    fi
}

# The stick's neon-keybox folder: mounted at /mnt/stick (Raspberry Pi OS Lite mounts nothing itself).
stick() {
    for d in /mnt/stick/neon-keybox /media/*/*/neon-keybox /media/*/neon-keybox; do [ -d "$d" ] && { echo "$d"; return; }; done
    dev=$(ls /dev/sd[a-z][0-9] 2>/dev/null | head -n 1)
    [ -n "$dev" ] || return 0
    as_root mkdir -p /mnt/stick && as_root mount -o uid="$(id -u "$USER_NAME")",gid="$(id -g "$USER_NAME")" "$dev" /mnt/stick 2>/dev/null ||
        as_root mount "$dev" /mnt/stick 2>/dev/null || return 0
    [ -d /mnt/stick/neon-keybox ] && echo /mnt/stick/neon-keybox
}

# ---- menu ----
menu() {
    command -v whiptail >/dev/null || die "whiptail missing (keybox-setup.sh installs it)"
    while :; do
        c=$(whiptail --title "NEON key box" --notags --cancel-button "Shell" --menu \
            "$(hostname) · $(date -u '+%Y-%m-%d %H:%M UTC') · release $(cat "$HOME_DIR/version" 2>/dev/null || echo none)" 20 72 10 \
            status "Status" \
            post "Post now (what the electrode has waiting)" \
            log "Posting log" \
            update "Update tools (newest signed release)" \
            import "Import settings and keys from a USB stick" \
            wipe "Wipe the stick's copies" \
            eject "Unmount the stick" \
            timer "Posting timer on / off" \
            edit "Edit settings (post.conf)" \
            reboot "Restart" \
            off "Shut down" 3>&1 1>&2 2>&3) || { clear; echo "/opt/neon-keybox/keybox.sh menu brings the menu back."; KEYBOX_SHELL=1 exec "${SHELL:-/bin/bash}" -l; }
        case "$c" in
            status) status > /tmp/keybox-status 2>&1 || true; whiptail --title "Status" --scrolltext --textbox /tmp/keybox-status 22 78 ;;
            post) clear; as_root systemctl start neon-post.service || true; journalctl -u neon-post -n 30 -o cat --no-pager > /tmp/keybox-log 2>&1 || true
                whiptail --title "Posting" --scrolltext --textbox /tmp/keybox-log 22 78 ;;
            log) journalctl -u neon-post -n 300 -o short-iso --no-pager > /tmp/keybox-log 2>&1 || true; whiptail --title "Posting log" --scrolltext --textbox /tmp/keybox-log 22 78 ;;
            update) clear; "$0" update > /tmp/keybox-update 2>&1 || true; whiptail --title "Update" --scrolltext --textbox /tmp/keybox-update 20 78 ;;
            import|wipe) d=$(whiptail --inputbox "The stick's neon-keybox folder (plug the stick in first)" 9 72 "$(stick)" 3>&1 1>&2 2>&3) || continue
                clear; "$0" "$c" "$d" > /tmp/keybox-out 2>&1 || true; whiptail --title "$c" --scrolltext --textbox /tmp/keybox-out 16 78 ;;
            timer) if systemctl is-enabled -q neon-post.timer 2>/dev/null; then
                    whiptail --yesno "Turn the posting timer off? Nothing is posted until it is on again." 9 70 && as_root systemctl disable --now neon-post.timer
                else
                    whiptail --yesno "Turn the posting timer on (daily 03:15 UTC)? First make sure the old posting machine's timer is off: two posters must never run." 10 72 && as_root systemctl enable --now neon-post.timer
                fi ;;
            edit) as_root nano "$CONF" ;;
            eject) sync; as_root umount /mnt/stick 2>/dev/null; whiptail --msgbox "The stick can be taken out." 7 40 ;;
            reboot) whiptail --yesno "Restart the key box?" 8 40 && as_root systemctl reboot ;;
            off) whiptail --yesno "Shut the key box down? Nothing is posted while it is off." 8 64 && as_root systemctl poweroff ;;
        esac
    done
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
case "${1:-menu}" in
    menu) menu ;;
    status) status ;;
    update) update ;;
    import) import "${2:-}" ;;
    wipe) wipe "${2:-}" ;;
    firewall) [ "$(id -u)" = 0 ] || die "as root"; firewall ;;
    *) die "keybox.sh menu | status | update | import DIR | wipe DIR" ;;
esac
