#!/bin/sh
# The vault (owner 2026-11-15): a Raspberry Pi at home that holds the NEON admin key and posts each
# epoch's root, and does nothing else. Nothing listens on it (no SSH, no web server: vault-setup.sh
# removes the SSH server and drops every incoming connection); it only connects out, to the electrode
# (neon-post.sh fetches the pending epoch over SSH) and to the Solana RPC, and is run from its own
# screen and keyboard with this menu.
#
#   vault.sh menu           the console menu (started on tty1 after logging in)
#   vault.sh status         what it is doing, as text
#   vault.sh update [auto]  install the newest signed release's neon-oracle, neon-token and scripts
#                           (auto: only a newer one; neon-vault-update.timer, Automatic updates in the menu)
#   vault.sh import DIR     take post.conf, the admin key and the SSH key from DIR (a USB stick)
#   vault.sh wipe DIR       erase those files from DIR once imported
#   vault.sh monitor         the always-on screen: the vault and the network at a glance, every
#                            minute (neon-vault-monitor.service shows it on tty1 without a login;
#                            the menu is on the next console, Alt+F2)
#   vault.sh fetch USER@HOST [PORT]   import straight from the old posting machine over SSH (into
#                            memory only, then imported and wiped: no stick, nothing typed but the login)
#   vault.sh screens        the monitor on the first console, the menu on the others (as root)
#   vault.sh firewall       write and load the firewall from the settings (as root)
#
# Updates come from the public element10-network/NEON-releases: tools.txt and scripts.txt, each
# checked against a release key built into this script (as into neond and setup.sh; a test keeps
# the list equal to hardware/release-keys.txt), never an older version than the one installed.
set -eu

GH_REPO=element10-network/NEON-releases
HOME_DIR=/opt/neon-vault
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
    [ "$(id -u)" = 0 ] || { as_root "$0" update "${1:-}"; return; }
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
    # The timer's run: nothing to do on the same version (the menu's Update installs it again).
    if [ "${1:-}" = auto ] && [ "$have" = "$version" ]; then echo "release $version is installed: nothing to update"; return 0; fi
    asset() {
        url=$(jq -r --arg n "$1" '[.assets[]? | select(.name == $n) | .browser_download_url][0] // empty' "$TMP/latest.json")
        [ -n "$url" ] || return 1
        curl -fsSL --retry 3 -o "$2" "$url"
    }
    for f in tools scripts; do
        asset "$f.txt" "$TMP/$f.txt" || die "release $version has no $f.txt (released before the vault)"
        asset "$f.sig" "$TMP/$f.sig" || die "release $version has no $f.sig"
        signed "$TMP/$f.txt" "$TMP/$f.sig" || die "$f.txt is not signed by a release key: nothing installed"
        [ "$(sed -n 's/^version //p' "$TMP/$f.txt")" = "$version" ] || die "$f.txt is for another version"
        # The list it says it is (one key signs all three kinds).
        [ "$(head -n 1 "$TMP/$f.txt")" = "neon-$f/1" ] || die "$f.txt is not a $f list"
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
    # Files and folders only: a link is outside the hash and could point anywhere (review 2026-11-19).
    [ -z "$(cd "$TMP/src" && find hardware ! -type f ! -type d | head -n 1)" ] || die "the scripts at $tag hold a link: nothing installed"
    tree=$(cd "$TMP/src" && find hardware -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
    [ "$tree" = "$tree_want" ] || die "the scripts at $tag are not the ones scripts.txt signs: nothing installed"
    # Not while a posting run is going: it would use the old neon-oracle with the new neon-token.
    # Its own lock, held to the end (review 2026-11-19: a oneshot service is "activating" while it
    # runs, which is-active did not see; a run that starts meanwhile finds it taken and waits a day).
    mkdir -p "$STATE/epochs"
    # (Never through a link, as root; and the posting user's, who opens it too, review 2026-11-23.)
    [ ! -L "$STATE/epochs" ] && [ ! -L "$STATE/epochs/.lock" ] || die "$STATE/epochs or its .lock is a link: nothing installed"
    exec 8>>"$STATE/epochs/.lock"
    chown "$USER_NAME:$USER_NAME" "$STATE/epochs" "$STATE/epochs/.lock" 2>/dev/null || true
    flock -n 8 || die "a posting run or another update is going: update when it is over"
    # Everything checked: install.
    for tool in neon-oracle neon-token; do
        [ -f "$TMP/$tool" ] && install -m 755 "$TMP/$tool" "$BIN/$tool"
    done
    mkdir -p "$POST_DIR" "$HOME_DIR"
    install -m 755 "$TMP/src/hardware/scripts/neon-post.sh" "$POST_DIR/neon-post.sh"
    install -m 644 "$TMP/src/hardware/systemd/neon-post.service" "$TMP/src/hardware/systemd/neon-post.timer" /etc/systemd/system/
    # The automatic updates' units (turned on in the menu, off until then).
    for u in neon-vault-update.service neon-vault-update.timer; do
        [ -f "$TMP/src/hardware/systemd/$u" ] && install -m 644 "$TMP/src/hardware/systemd/$u" /etc/systemd/system/
    done
    [ -f "$TMP/src/hardware/systemd/neon-vault-monitor.service" ] &&
        install -m 644 "$TMP/src/hardware/systemd/neon-vault-monitor.service" /etc/systemd/system/
    install -m 755 "$TMP/src/hardware/vault/vault.sh" "$HOME_DIR/vault.sh"
    systemctl daemon-reload
    # The posting log kept across restarts too (journald writes to disk once this folder exists).
    if [ ! -d /var/log/journal ]; then
        mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
        journalctl --flush >/dev/null 2>&1 || true
    fi
    echo "$version" > "$HOME_DIR/version"
    # The NEON-token commit, only for a neon-token installed now (one kept keeps its own).
    [ -f "$TMP/neon-token" ] && sed -n 's/^token-commit //p' "$TMP/tools.txt" > "$HOME_DIR/token-commit"
    # The monitor on the first screen, the menu on the others (with this release's menu and unit).
    # (A failure there leaves the release installed: Update again, or vault.sh screens.)
    if [ -f /etc/systemd/system/neon-vault-monitor.service ]; then "$HOME_DIR/vault.sh" screens || true; fi
    echo "installed release $version (neon-oracle, neon-token, neon-post.sh, the vault's menu and monitor)"
}

# ---- import: settings and keys from a USB stick, made on the old posting machine ----
# The stick's folder holds post.conf, admin.json (the admin keypair), ssh/ (id_ed25519 and
# known_hosts) and epochs/ (the kept epochs): see docs/HUB.md "The vault".
import() {
    d=${1:?import DIR}
    [ "$(id -u)" = 0 ] || { as_root "$0" import "$d"; return; }
    for f in post.conf admin.json ssh/id_ed25519 ssh/known_hosts; do [ -s "$d/$f" ] || die "$d/$f is missing"; done
    mkdir -p /etc/neon "$STATE/ssh" "$STATE/epochs"
    # The paths on this machine; the rest as it was (the electrode, the treasury, the core hubs...).
    grep -v -E '^(NEON_TOKEN|NEON_ORACLE|KEYPAIR|SSH_KEY|LOCAL_EPOCHS)=' "$d/post.conf" > "$TMP/post.conf"
    printf 'NEON_TOKEN=%s\nNEON_ORACLE=%s\nKEYPAIR=%s\nSSH_KEY=%s\n' "$BIN/neon-token" "$BIN/neon-oracle" "$STATE/admin.json" "$STATE/ssh/id_ed25519" >> "$TMP/post.conf"
    # Readable by the poster only (an RPC address can carry an API key).
    install -m 640 -o root -g "$USER_NAME" "$TMP/post.conf" "$CONF"
    install -m 600 -o "$USER_NAME" -g "$USER_NAME" "$d/admin.json" "$STATE/admin.json"
    install -m 600 -o "$USER_NAME" -g "$USER_NAME" "$d/ssh/id_ed25519" "$STATE/ssh/id_ed25519"
    install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$d/ssh/known_hosts" "$STATE/ssh/known_hosts"
    # The epochs the old machine posted and kept (what a root does not cover, carried to the next
    # epoch; without them the first run takes the electrode's word and looks every hotspot up).
    if [ -d "$d/epochs" ]; then
        # With the marks of those that were the electrode's word (review 2026-11-16).
        for f in "$d"/epochs/epoch-*.json "$d"/epochs/epoch-*.json.from-electrode; do
            [ -f "$f" ] && install -m 644 "$f" "$STATE/epochs/"
        done
    fi
    chown -R "$USER_NAME:$USER_NAME" "$STATE"
    chmod 700 "$STATE" "$STATE/ssh"
    firewall
    echo "imported: $CONF, the admin key and the SSH key (in $STATE)."
    # (From a stick: its copies are wiped next. From the old machine over SSH, fetch wipes its own.)
    [ -n "${VAULT_FETCH:-}" ] || echo "Wipe the stick's copies next (menu: Import settings and keys..., Wipe the stick's copies)."
}

wipe() {
    d=${1:?wipe DIR}
    # As root: a stick mounted without uid= holds files ne cannot remove.
    [ "$(id -u)" = 0 ] || { as_root "$0" wipe "$d"; return; }
    # Never the vault's own keys (review 2026-11-19: the same layout as a stick's folder), and not
    # through a linked folder.
    [ ! -L "$d" ] && [ ! -L "$d/ssh" ] || die "$d or its ssh folder is a link: not wiped"
    real=$(realpath -m "$d")
    case "$real/" in "$(realpath -m "$STATE")"/* | /etc/neon/* | /opt/neon-vault/* | /opt/neon-post/*)
        die "$d is the vault's own folder: not wiped" ;; esac
    for f in admin.json ssh/id_ed25519 ssh/id_ed25519.pub ssh/known_hosts post.conf; do
        # (Not through a link: shred would erase what it points to.)
        if [ -L "$d/$f" ]; then rm -f "$d/$f"; elif [ -f "$d/$f" ]; then shred -u "$d/$f"; fi
    done
    # (The epochs are public: removed, not shredded.)
    rm -rf "$d/epochs"
    rmdir "$d/ssh" "$d" 2>/dev/null || true
    sync
    if [ -n "${VAULT_FETCH:-}" ]; then
        echo "the copy in memory wiped"
    else
        echo "erased from $d (on a flash stick shred cannot reach every copy: keep the stick with the vault, or destroy it)"
    fi
}

# ---- firewall: nothing in; out only DNS, DHCP, time, HTTP(S) and the electrode's SSH port ----
firewall() {
    # The SSH port as neon-post.sh reads it (quoted or not), and any port an RPC address names.
    # A port is 1 to 65535: nft refuses the whole file otherwise (review 2026-11-19).
    port_ok() { case "$1" in "" | *[!0-9]*) return 1 ;; esac; [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
    ports=$(conf PORT)
    port_ok "$ports" || ports=22
    for u in "$(conf URL)" "$(conf HELIUM_RPC)" "$(conf EXPLORE)"; do
        p=$(url_port "$u")
        if port_ok "$p"; then ports="$ports, $p"; elif [ -n "$p" ]; then echo "not a port, left out of the firewall: $p" >&2; fi
    done
    # Written aside, checked, then loaded: a file nft refuses never replaces the rules in force
    # (a restart of nftables flushed them first and left none, review 2026-11-19).
    new=$(mktemp /etc/nftables.conf.XXXXXX)
    cat > "$new" <<EOF
#!/usr/sbin/nft -f
# The vault (vault.sh): nothing comes in; out only what posting needs.
flush ruleset
table inet vault {
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        # IPv6 neighbour discovery and router adverts (the network itself), nothing else.
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept
        # DHCPv6 answers to a solicit sent to multicast (conntrack does not pair them).
        udp sport 547 udp dport 546 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy drop;
        oif lo accept
        ct state established,related accept
        udp dport { 53, 67, 123, 547 } accept
        # 80: the OS's own updates (apt, its lists signed by Debian and Raspberry Pi).
        tcp dport { 53, 80, 443, $ports } accept
        icmp type echo-request accept
        icmpv6 type { echo-request, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } accept
    }
}
EOF
    if ! nft -c -f "$new"; then
        rm -f "$new"
        die "the firewall rules were refused: the ones in force are kept (check the ports in $CONF)"
    fi
    chmod 644 "$new" && mv -f "$new" /etc/nftables.conf
    systemctl enable -q nftables
    nft -f /etc/nftables.conf
}

# ---- status ----
conf() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1 | sed "s/^[\"']//; s/[\"']\$//"; }
# An address as shown on the screen: its scheme and host only (an RPC address can carry an API key in
# its path, query or user part; review 2026-11-19). A name such as devnet as it is.
# (The user part up to the last @ before the path: a password may hold an @ itself.)
url_host() { case "$1" in *://*) echo "$1" | sed -E 's|^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*@)?([^/?#@]*).*|\1\3|' ;; *) echo "$1" ;; esac; }
# url_port URL: the port an address names (none: nothing), past its user part, IPv6 too.
url_port() { echo "$1" | sed -En 's|^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*@)?(\[[^]]*\]\|[^]/?#@:]*):([0-9]+)([/?#].*)?$|\3|p'; }
# Text from elsewhere on the screen: no control characters (no escape sequences), one line, cut.
# (UTF-8's C1 controls too, \xc2\x80-\x9f: some terminals take them as escapes, review 2026-11-23.)
plain() { tr '\n' ' ' | LC_ALL=C sed 's/\xc2[\x80-\x9f]//g' | tr -d '\000-\037\177' | cut -c1-"${1:-200}"; }
# The electrode's address from the settings, only if it is one (never an ssh option, review 2026-11-23).
remote_ok() {
    case "$1" in "" | -* | *[!A-Za-z0-9@._-]*) return 1 ;; esac
    case "$2" in "" | *[!0-9]*) return 1 ;; esac
}
# The electrode over SSH, with nothing typed on the screen reaching it (-n) and a deadline for all of it.
ssh_electrode() {
    remote_ok "$remote" "${port:-22}" || return 1
    as_user timeout 40 ssh -n -i "$STATE/ssh/id_ed25519" -p "${port:-22}" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
        -o UserKnownHostsFile="$STATE/ssh/known_hosts" "$remote" "$@"
}
rpc_url() { case "$1" in devnet|"") echo https://api.devnet.solana.com ;; mainnet|mainnet-beta) echo https://api.mainnet-beta.solana.com ;; testnet) echo https://api.testnet.solana.com ;; *) echo "$1" ;; esac; }
status() {
    echo "Release      $(cat "$HOME_DIR/version" 2>/dev/null || echo 'none yet (Update)')"
    if systemctl is-enabled -q neon-vault-update.timer 2>/dev/null; then
        echo "Updates      automatic, next $(systemctl show neon-vault-update.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    else
        echo "Updates      by hand (menu: Update)"
    fi
    # (The DHCP clients' sockets, 68 and 546, are not services; the firewall drops all of it anyway.)
    open=$(ss -Htuln 2>/dev/null | awk '{print $5}' | grep -v -E '^(127\.|\[::1\]|.*%lo:)' | grep -v -E ':(68|546)$' | wc -l)
    echo "Listening    $open port(s) open to the network$( [ "$open" = 0 ] && echo ' (as it should be)')"
    # (nft prints the priority by name, "filter", and needs root to list.)
    if as_root nft list chain inet vault input 2>/dev/null | grep -q 'hook input .* policy drop'; then echo "Firewall     incoming dropped"; else echo "Firewall     NOT ON (Set up again)"; fi
    if [ ! -s "$CONF" ]; then echo "Settings     none yet (Import: from the old posting machine over SSH, or a USB stick)"; return 0; fi
    url=$(conf URL); remote=$(conf REMOTE); port=$(conf PORT)
    echo "Network      $(url_host "${url:-devnet}"), electrode ${remote:-?} (port ${port:-22})"
    if systemctl is-enabled -q neon-post.timer 2>/dev/null; then
        echo "Posting      timer on, next $(systemctl show neon-post.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    else
        echo "Posting      timer off (turn it on in the menu once the old machine's is off)"
    fi
    # From the file each run leaves (neon-post.sh --record-run), which a restart keeps; systemd's
    # own memory of it before that file existed.
    if [ -f "$STATE/last-run" ] && [ ! -L "$STATE/last-run" ] && read -r t r x < "$STATE/last-run" && case "$t" in "" | *[!0-9]*) false ;; *) true ;; esac; then
        r=$(printf '%s' "$r" | tr -cd 'a-z-'); x=$(printf '%s' "$x" | tr -cd '0-9A-Z?')
        echo "Last run     $(date -d "@$t" '+%a %Y-%m-%d %H:%M:%S %Z') (${r:-unknown}$( [ "$r" = success ] || echo ", exit ${x:-?}"))"
    else
        last=$(systemctl show neon-post.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
        echo "Last run     ${last:-never}${last:+ ($(systemctl show neon-post.service -p Result --value 2>/dev/null))}"
    fi
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
        # An empty list is an answer too (nothing waiting); no answer at all is a failed login or network.
        # The monitor asks every 10 minutes, not every minute (a login on the electrode each time).
        # (Not past a posting run since: what waited may be filed now, review 2026-11-23.)
        if [ -n "${VAULT_MONITOR:-}" ] && [ -f "${VAULT_CACHE:-$TMP}/waiting.line" ] && [ -n "$(find "${VAULT_CACHE:-$TMP}/waiting.line" -mmin -10 2>/dev/null)" ] \
            && ! [ "$STATE/last-run" -nt "${VAULT_CACHE:-$TMP}/waiting.line" ] && ! [ "$CONF" -nt "${VAULT_CACHE:-$TMP}/waiting.line" ]; then
            cat "${VAULT_CACHE:-$TMP}/waiting.line"
        elif ssh_electrode list > "$TMP/waiting" 2>/dev/null; then
            waiting=$(plain 120 < "$TMP/waiting")
            echo "On electrode ${waiting:-answers, nothing waiting}" | tee "${VAULT_CACHE:-$TMP}/waiting.line"
        else
            rm -f "${VAULT_CACHE:-$TMP}/waiting.line"
            echo "On electrode ? (no answer: the electrode, its port or the SSH key)"
        fi
    fi
}

# The stick's neon-vault folder: mounted at /mnt/stick (Raspberry Pi OS Lite mounts nothing itself).
stick() {
    for d in /mnt/stick/neon-vault /media/*/*/neon-vault /media/*/neon-vault; do [ -d "$d" ] && { echo "$d"; return; }; done
    dev=$(ls /dev/sd[a-z][0-9] 2>/dev/null | head -n 1)
    [ -n "$dev" ] || return 0
    as_root mkdir -p /mnt/stick && as_root mount -o uid="$(id -u "$USER_NAME")",gid="$(id -g "$USER_NAME")" "$dev" /mnt/stick 2>/dev/null ||
        as_root mount "$dev" /mnt/stick 2>/dev/null || return 0
    [ -d /mnt/stick/neon-vault ] && echo /mnt/stick/neon-vault
}

# ---- fetch: settings and keys straight from the old posting machine, over SSH ----
# As the posting user (it types the old machine's password or uses its own key). What comes over is
# kept in memory only (/dev/shm), imported and wiped at once; the SSH port is opened for this alone
# (the import writes the firewall again, without it, and so does a failure here).
fetch() {
    from=${1:-}
    port=${2:-22}
    case "$from" in *@*) ;; *) die "fetch USER@HOST [PORT]" ;; esac
    case "$from" in -* | *[!A-Za-z0-9@._-]*) die "not USER@HOST: $from" ;; esac
    case "$port" in "" | *[!0-9]*) die "not a port: $port" ;; esac
    [ "$(id -u)" != 0 ] || die "as the posting user ($USER_NAME), not root: it logs in to $from"
    dir=$(mktemp -d /dev/shm/neon-vault-fetch.XXXXXX)
    # Whatever happens: the copy wiped from memory, the firewall as the settings say.
    trap 'as_root "$0" wipe "$dir/neon-vault" >/dev/null 2>&1 || true; rm -rf "$dir" "$TMP"; as_root "$0" firewall >/dev/null 2>&1 || true' EXIT
    # (sh runs the EXIT trap on a signal only through exit: Ctrl+C wipes too, review 2026-11-19.)
    trap 'exit 130' INT TERM HUP
    as_root nft add rule inet vault output tcp dport "$port" accept 2>/dev/null || true
    echo "Logging in to $from (port $port): accept its host key if asked, then its password."
    # On the old machine too the copy is made in memory (/dev/shm) and shredded after.
    ssh -p "$port" "$from" 'set -e; . /etc/neon/post.conf; T=$(mktemp -d /dev/shm/neon-vault.XXXXXX 2>/dev/null || mktemp -d); trap "find $T -type f -exec shred -u {} + 2>/dev/null; rm -rf $T" EXIT; D=$T/neon-vault; mkdir -p "$D/ssh" "$D/epochs"; cp /etc/neon/post.conf "$D/"; cp "$KEYPAIR" "$D/admin.json"; cp "$SSH_KEY" "$D/ssh/id_ed25519"; cp /var/lib/neon-post/ssh/known_hosts "$D/ssh/"; for f in /var/lib/neon-post/epochs/epoch-*.json /var/lib/neon-post/epochs/epoch-*.json.from-electrode; do [ ! -f "$f" ] || cp "$f" "$D/epochs/"; done; tar -C "$T" -czf - neon-vault' |
        tar -C "$dir" --no-same-owner -xzf - || die "nothing copied from $from (see the messages above)"
    # Plain files and folders only (a link would make the import copy what it points to).
    [ -z "$(find "$dir" ! -type f ! -type d | head -n 1)" ] || die "the copy from $from holds something that is not a file: not imported"
    echo "Copied:"
    (cd "$dir/neon-vault" && find . -type f | sort)
    as_root env VAULT_FETCH=1 "$0" import "$dir/neon-vault"
    as_root env VAULT_FETCH=1 "$0" wipe "$dir/neon-vault"
    echo "Done: imported, the copy wiped from memory. Next: Status, then turn the old machine's posting timer off and this one's on."
}

# ---- screens: the monitor on the first console, the menu on the others (after a login) ----
screens() {
    [ "$(id -u)" = 0 ] || { as_root "$0" screens; return; }
    profile=/home/$USER_NAME/.bash_profile
    touch "$profile"
    # The key box's and the first vault's lines (the menu on tty1 only) go.
    # (And this function's own, written again below: never twice.)
    sed -i "/The key box's menu/d; /keybox.sh menu/d; /The vault's menu on its own screen/d; /vault.sh menu; fi/d; /The vault's menu after logging in/d; /vault.sh menu ;; esac/d" "$profile"
    grep -q '^\[ -f ~/.bashrc \]' "$profile" || echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> "$profile"
    cat >> "$profile" <<'EOF2'
# The vault's menu after logging in on a console (Alt+F2...; the first shows the monitor); "Shell" leaves it.
case "$(tty)" in /dev/tty[0-9]*) [ -z "${VAULT_SHELL:-}" ] && /opt/neon-vault/vault.sh menu ;; esac
EOF2
    chown -h "$USER_NAME:$USER_NAME" "$profile"
    # The first console: the monitor instead of a login (nothing can be typed there). Someone logged
    # in there (the menu that runs this update): not now, it would end that session and this update
    # with it (review 2026-11-19), but from the next start.
    systemctl disable getty@tty1.service >/dev/null 2>&1 || true
    systemctl mask getty@tty1.service >/dev/null 2>&1 || true
    systemctl enable -q neon-vault-monitor.service
    # (A login session there, by utmp or by logind: who alone may not list it, review 2026-11-19.)
    if who 2>/dev/null | awk '{print $2}' | grep -qx tty1 || loginctl list-sessions --no-legend 2>/dev/null | grep -qw tty1; then
        echo "the monitor takes the first screen at the next restart (someone is logged in there now)"
    else
        systemctl restart neon-vault-monitor.service
    fi
}

# ---- monitor: the vault and the network on its own screen (owner 2026-11-19) ----
# Read-only: what Status shows, the posting log's last lines, the machine's health, and the
# electrode's public explorer data (the same as its /explore page: nothing private). Run by
# neon-vault-monitor.service on tty1; nothing on it can be typed into.
MONITOR_EVERY=60
LOGO1='╭╮╭╮╭╮╭╮'
LOGO2='│││╯││││'
LOGO3='││╰ ╰╯││'
# The rounded corners only when the console's font has them (setfont's map of it lists U+256D);
# otherwise the square ones every console font has (owner 2026-11-23: no boxes or diamonds).
logo_for_console() {
    map="$TMP/fontmap"
    if setfont -ou "$map" 2>/dev/null && grep -qi 'U+256d' "$map"; then :; else
        LOGO1='┌┐┌┐┌┐┌┐'; LOGO2='│││┘││││'; LOGO3='││└ └┘││'
    fi
    rm -f "$map"
}
# The screen itself, in Python with curses (owner 2026-11-23: a real screen; the shell version below
# scrolled the top away and its column line broke up on the console): kept in this file, written out
# when the monitor starts, so one Update brings it.
monitor_py() {
    cat <<'VAULT_MONITOR_PY'
#!/usr/bin/env python3
# The vault's always-on screen (owner 2026-11-23: a real screen, with curses): the vault, the network
# and the world scanner in framed panels, drawn in place (nothing scrolls), the clock every second,
# the data every minute. Written by vault.sh monitor and run by neon-vault-monitor.service on tty1 as
# root. Read only: Status's lines (vault.sh status), the electrode's public explorer data, and the
# world scanner's newest packets through the vault's SSH key (neon-epoch-remote.sh scan). Nothing on
# it takes input.
import curses
import json
import locale
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.request

VAULT = "/opt/neon-vault/vault.sh"
CONF = "/etc/neon/post.conf"
STATE = "/var/lib/neon-post"
USER = "ne"
CACHE = "/run/neon-vault"
EVERY = 60
SCAN_EVERY = 120
MAX_BYTES = 2_000_000


def conf(key):
    """A setting from post.conf (KEY=VALUE, quoted or not; the last one counts)."""
    value = ""
    try:
        with open(CONF, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(key + "="):
                    value = line[len(key) + 1:].strip().strip("\"'")
    except OSError:
        pass
    return value


def clean(s):
    """Text from elsewhere, as one line without control or format characters."""
    if s is None:
        return ""
    s = str(s)
    # Printable characters only (no controls, format or line separators, unassigned ones), and no
    # variation selectors (an emoji's VS16 is drawn as a column of its own on some consoles).
    return "".join(" " if c in "\t\n\r" else c for c in s
                   if c in "\t\n\r" or (c.isprintable() and not 0xFE00 <= ord(c) <= 0xFE0F))


def cwidth(c):
    if unicodedata.category(c) in ("Mn", "Me") or unicodedata.combining(c):
        return 0
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1


def cut(s, w):
    """At most `w` columns of `s`."""
    out, n = [], 0
    for c in s:
        k = cwidth(c)
        if n + k > w:
            break
        out.append(c)
        n += k
    return "".join(out)


def col(s, w):
    """A table column: cut one short of its width, so the next always has a space before it."""
    return pad(s, w - 1) + " "


def tw(s):
    return sum(cwidth(c) for c in s)


def pad(s, w):
    s = cut(s, w)
    return s + " " * (w - tw(s))


def url_host(u):
    """An address as shown: its scheme and host only (an RPC address can carry an API key)."""
    m = re.match(r"^([A-Za-z][A-Za-z0-9+.-]*://)(?:[^/?#]*@)?([^/?#@]*)", u or "")
    return m.group(1) + m.group(2) if m else (u or "")


def run(cmd, timeout=40, env=None):
    """A command's exit code and its first MAX_BYTES of output. At the timeout, or past MAX_BYTES, the
    whole process group goes (review 2026-11-23: a stalled electrode's ssh outlived its shell, and a
    huge answer was read into memory whole)."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                             env=env, start_new_session=True)
    except OSError:
        return 1, ""

    def kill():
        # (TERM first, KILL two seconds later: a shell's EXIT trap still cleans its temporary folder.)
        for sig, wait in ((signal.SIGTERM, 2), (signal.SIGKILL, 0)):
            try:
                os.killpg(p.pid, sig)
            except OSError:
                return
            time.sleep(wait)
    timer = threading.Timer(timeout, kill)
    timer.start()
    try:
        data = p.stdout.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            kill()
            data = b""
        p.stdout.close()
        code = p.wait()
    except (OSError, ValueError):
        kill()
        code, data = 1, b""
    finally:
        timer.cancel()
        if p.poll() is None:
            kill()
            p.wait()
    return code, data.decode("utf-8", "replace")


def num(v):
    """A number from elsewhere, or 0 (none, not a number, infinite)."""
    try:
        x = float(v)
    except (TypeError, ValueError, OverflowError):
        return 0.0
    return x if math.isfinite(x) and abs(x) < 1e15 else 0.0


def ago(ms, now_ms):
    if not ms:
        return "?"
    m = max(0, int((now_ms - num(ms)) / 60000))
    return f"{m}m" if m < 60 else f"{m // 60}h" if m < 2880 else f"{m // 1440}d"


def logo():
    """The rounded corners only when the console's font has them (setfont's map lists U+256D)."""
    rounded = ("╭╮╭╮╭╮╭╮", "│││╯││││", "││╰ ╰╯││")
    square = ("┌┐┌┐┌┐┌┐", "│││┘││││", "││└ └┘││")
    try:
        with tempfile.NamedTemporaryFile() as f:
            code, _ = run(["setfont", "-ou", f.name], timeout=10)
            if code == 0 and b"u+256d" in open(f.name, "rb").read().lower():
                return rounded
    except OSError:
        pass
    return square


class Data:
    """What the screen shows, refreshed in the background (a slow electrode never stops the clock)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.status, self.machine, self.log = [], [], ""
        self.explore, self.explore_err, self.explore_host = None, "", ""
        self.scan, self.scan_t, self.scan_err = None, 0.0, ""
        self.updated = 0.0

    def refresh(self):
        # Each part on its own: one that fails keeps the others current (review 2026-11-23: one error
        # threw the whole minute away, and the screen showed old data as if current).
        time.tzset()

        def part(read, fallback):
            try:
                return read()
            except Exception:
                return fallback
        env = dict(os.environ, VAULT_MONITOR="1", VAULT_CACHE=CACHE)
        out = part(lambda: run(["sh", VAULT, "status"], env=env, timeout=120)[1], "")
        status = [clean(line) for line in out.splitlines() if line and not line.startswith("Admin key")]
        if not status:
            status = ["Status       no answer (vault.sh status)"]
        machine = part(self.read_machine, [])
        out = part(lambda: run(["journalctl", "-u", "neon-post", "-o", "cat", "--no-pager", "-n", "200"], timeout=20)[1], "")
        log = ""
        for line in out.splitlines():
            if re.search(r"posted:|filed|no epoch waiting|ERROR|not posted|NOT", line):
                log = clean(line)
        explore, err, host = part(self.read_explore, (None, "no answer", ""))
        scan, scan_t, scan_err = self.scan, self.scan_t, self.scan_err
        # (Every two minutes, answered or not, by the monotonic clock: a clock stepped back on a Pi
        # without a real-time clock no longer stopped it.)
        if scan_t == 0.0 or time.monotonic() - scan_t >= SCAN_EVERY:
            got, scan_err = part(self.read_scan, (None, "could not read the answer"))
            scan_t = time.monotonic()
            if got is not None:
                scan = got
        with self.lock:
            self.status, self.machine, self.log = status, machine, log
            self.explore, self.explore_err, self.explore_host = explore, err, host
            self.scan, self.scan_t, self.scan_err = scan, scan_t, scan_err
            self.updated = time.time()

    @staticmethod
    def read_machine():
        out = []
        try:
            up = float(open("/proc/uptime").read().split()[0])
            d, h, m = int(up // 86400), int(up % 86400 // 3600), int(up % 3600 // 60)
            out.append(f"up {d}d {h}h {m}m" if d else f"up {h}h {m}m")
        except (OSError, ValueError, IndexError):
            pass
        try:
            out.append(f"{int(open('/sys/class/thermal/thermal_zone0/temp').read()) / 1000:.0f} °C")
        except (OSError, ValueError):
            pass
        try:
            du = shutil.disk_usage("/")
            out.append(f"disk {du.used * 100 // du.total}% of {du.total // 2**30} GB")
        except OSError:
            pass
        try:
            mi = dict(line.split(":", 1) for line in open("/proc/meminfo") if ":" in line)
            total = int(mi["MemTotal"].split()[0]) // 1024
            avail = int(mi["MemAvailable"].split()[0]) // 1024
            out.append(f"memory {total - avail}/{total} MB")
        except (OSError, KeyError, ValueError):
            pass
        return out

    @staticmethod
    def read_explore():
        remote, url = conf("REMOTE"), conf("EXPLORE")
        if not url and remote:
            url = "https://" + remote.split("@")[-1] + "/api/explore"
        if not url:
            return None, "no electrode in the settings", ""
        host = url_host(url)
        if not url.lower().startswith("https://"):
            return None, "not an https address", host
        # curl under run(): a deadline for the whole answer (a trickle no longer held the refresh for
        # hours), https only, no redirects (review 2026-11-23).
        code, body = run(["curl", "-fsS", "-m", "25", "--proto", "=https", "--max-filesize", str(MAX_BYTES),
                          "--", url], timeout=30)
        if code != 0:
            return None, f"no answer (curl {code})", host
        try:
            j = json.loads(body)
            if not isinstance(j, dict) or not isinstance(j.get("figures"), dict):
                return None, "not the explorer's data", host
            return j, "", host
        except Exception as e:  # any failure is only "not the explorer's data" on the screen
            return None, "not the explorer's data (" + clean(type(e).__name__) + ")", host

    @staticmethod
    def read_scan():
        """The scanner's packets and, when there are none, why."""
        remote, port = conf("REMOTE"), conf("PORT") or "22"
        if not remote:
            return None, "no electrode in the settings"
        # (A REMOTE that ssh would read as an option, -oProxyCommand=..., is not run: review 2026-11-23.)
        if remote.startswith("-") or not re.fullmatch(r"[A-Za-z0-9@._-]+", remote) or not port.isdigit():
            return None, "REMOTE or PORT in the settings is not an address"
        code, out = run(["runuser", "-u", USER, "--", "ssh", "-i", f"{STATE}/ssh/id_ed25519", "-p", port,
                         "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                         "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                         "-o", f"UserKnownHostsFile={STATE}/ssh/known_hosts", remote, "scan"], timeout=40)
        if code != 0:
            return None, "no answer from the electrode (SSH)"
        try:
            j = json.loads(out)
        except Exception:  # (deep nesting raises RecursionError, not ValueError)
            return None, "not the scanner's data"
        items = j.get("items") if isinstance(j, dict) else None
        if not isinstance(items, list):
            return None, "not the scanner's data"
        # (At most 200: a huge list must not cost every frame, review 2026-11-23.)
        return [i for i in items[:200] if isinstance(i, dict)], ""


def refresher(data, stop):
    while not stop.is_set():
        try:
            data.refresh()
        except Exception:
            pass
        stop.wait(EVERY)


class Screen:
    def __init__(self, scr, data):
        self.scr, self.data, self.logo = scr, data, logo()
        curses.curs_set(0)
        curses.start_color()
        try:
            curses.use_default_colors()
            bg = -1
        except curses.error:
            bg = curses.COLOR_BLACK
        for i, c in enumerate((curses.COLOR_CYAN, curses.COLOR_GREEN, curses.COLOR_RED,
                               curses.COLOR_YELLOW, curses.COLOR_WHITE, curses.COLOR_BLUE), 1):
            curses.init_pair(i, c, bg)
        self.CYAN, self.GREEN, self.RED, self.YELLOW, self.WHITE, self.BLUE = (curses.color_pair(i) for i in range(1, 7))

    def put(self, win, y, x, parts, w):
        """`parts`: [(text, attr)], cut to `w` columns at (y, x)."""
        for text, attr in parts:
            if w <= 0:
                break
            t = cut(text, w)
            try:
                win.addstr(y, x, t, attr)
            except curses.error:
                pass
            x += tw(t)
            w -= tw(t)

    def box(self, y, x, h, w, title):
        """A framed panel; returns its inner area (y, x, h, w)."""
        if h < 3 or w < 6:
            return y, x, 0, 0
        s = self.scr
        try:
            s.attron(self.BLUE)
            s.addch(y, x, curses.ACS_ULCORNER)
            s.hline(y, x + 1, curses.ACS_HLINE, w - 2)
            s.addch(y, x + w - 1, curses.ACS_URCORNER)
            s.vline(y + 1, x, curses.ACS_VLINE, h - 2)
            s.vline(y + 1, x + w - 1, curses.ACS_VLINE, h - 2)
            s.addch(y + h - 1, x, curses.ACS_LLCORNER)
            s.hline(y + h - 1, x + 1, curses.ACS_HLINE, w - 2)
            # (The bottom right corner of the screen cannot take a character without scrolling.)
            try:
                s.addch(y + h - 1, x + w - 1, curses.ACS_LRCORNER)
            except curses.error:
                pass
            s.attroff(self.BLUE)
        except curses.error:
            pass
        self.put(s, y, x + 2, [(" " + title + " ", self.CYAN | curses.A_BOLD)], w - 4)
        return y + 1, x + 2, h - 2, w - 4

    def status_parts(self, line):
        label, value = line[:13], line[13:]
        attr = 0
        if re.search(r"as it should be|incoming dropped|timer on|\(success\)|answers", value):
            attr = self.GREEN
        if re.search(r"NOT ON|failed|exit-code|\? \(no answer|timeout|signal", value):
            attr = self.RED
        # A last run that did not succeed (oom-kill, core-dump, resources...): red whatever its word.
        if label.startswith("Last run") and "(" in value and "(success)" not in value:
            attr = self.RED
        if re.search(r"timer off", value):
            attr = self.YELLOW
        return [(label, curses.A_BOLD), (value, attr)]

    def draw(self):
        s = self.scr
        s.erase()
        H, W = s.getmaxyx()
        if H < 10 or W < 40:
            self.put(s, 0, 0, [("screen too small", self.RED)], W - 1)
            s.refresh()
            return
        with self.data.lock:
            d = self.data
            status, machine, log = list(d.status), list(d.machine), d.log
            ex, ex_err, ex_host = d.explore, d.explore_err, d.explore_host
            scan, scan_t, updated, scan_err = d.scan, d.scan_t, d.updated, d.scan_err
        now = time.time()
        # The header: the logo, the machine's name and the time.
        host = clean(os.uname().nodename)
        for i, row in enumerate(self.logo):
            self.put(s, i, 1, [(row, self.CYAN | curses.A_BOLD)], 10)
        self.put(s, 0, 13, [("vault", curses.A_BOLD), ("  " + host, 0)], W - 14)
        self.put(s, 1, 13, [(time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(now)), 0)], W - 14)
        self.put(s, 2, 13, [(time.strftime("%H:%M %Z local", time.localtime(now)), 0)], W - 14)
        note = ("data " + time.strftime("%H:%M:%S", time.localtime(updated))) if updated else "reading..."
        # (Old data says so in red: a refresh that hangs no longer looks current.)
        stale = updated and now - updated > 3 * EVERY
        if stale:
            note += " (old)"
        self.put(s, 0, max(13, W - tw(note) - 2), [(note, self.RED if stale else self.BLUE)], tw(note))
        top = 4
        split = W >= 120
        lw = (W * 3) // 5 if split else W
        rw = W - lw
        # Left: the vault (Status, the machine, the posting log), the network, the atoms.
        vlines = [self.status_parts(line) for line in status]
        if machine:
            vlines.append([("Machine      ", curses.A_BOLD), (", ".join(machine), 0)])
        if log:
            vlines.append([("Posting log  ", curses.A_BOLD), (log, 0)])
        if not vlines:
            vlines = [[("reading...", self.BLUE)]]
        # (The vault's own panel first: the network and the atoms give way on a short screen.)
        vh = max(3, min(len(vlines) + 2, H - top - 3))
        iy, ix, ih, iw = self.box(top, 0, vh, lw, "VAULT")
        for i, parts in enumerate(vlines[:ih]):
            self.put(s, iy + i, ix, parts, iw)
        y = top + vh
        nlines = self.safe(self.network_lines, ex, ex_err)
        nh = min(len(nlines) + 2, max(3, H - y - 3))
        iy, ix, ih, iw = self.box(y, 0, nh, lw, "NETWORK  " + (ex_host or ""))
        for i, parts in enumerate(nlines[:ih]):
            self.put(s, iy + i, ix, parts, iw)
        y += nh
        if H - y >= 3:
            iy, ix, ih, iw = self.box(y, 0, H - y, lw, "ATOMS")
            for i, parts in enumerate(self.safe(self.atom_lines, ex, iw)[:ih]):
                self.put(s, iy + i, ix, parts, iw)
        # Right: the world scanner.
        if split:
            iy, ix, ih, iw = self.box(top, lw, H - top, rw, "WORLD SCANNER")
            for i, parts in enumerate(self.safe(self.scan_lines, scan, scan_err, iw)[:ih]):
                self.put(s, iy + i, ix, parts, iw)
        s.refresh()

    def safe(self, lines, *args):
        """A panel's lines; data it cannot draw blanks only that panel (review 2026-11-23)."""
        try:
            return lines(*args)
        except Exception as e:
            return [[("could not draw this (" + clean(type(e).__name__) + ")", self.RED)]]

    def network_lines(self, ex, err):
        if not ex:
            return [[(err or "reading...", self.RED if err else self.BLUE)]]
        f = ex.get("figures") or {}

        def n(v):
            return "?" if v is None else clean(v)
        out = [[("Atoms        ", curses.A_BOLD), (f"{n(f.get('online'))} online", self.GREEN),
                (f" of {n(f.get('atoms'))}, {n(f.get('chip_verified'))} chip-verified, {n(f.get('electrodes'))} electrode(s)", 0)],
               [("Today        ", curses.A_BOLD),
                (f"{n(f.get('packets_today'))} packets, {n(f.get('confirmed_today'))} confirmed, {num(f.get('photons_today')):.2f} photons", 0)]]
        c = ex.get("connections")
        if isinstance(c, dict):
            v = c.get("versions") if isinstance(c.get("versions"), dict) else {}
            vs = ", ".join(f"{clean(k)} x{clean(x)}" for k, x in v.items())
            out.append([("Connected    ", curses.A_BOLD),
                        (f"{n(c.get('atoms'))} atoms, {n(c.get('behind_router'))} behind a router, {n(c.get('ipv6'))} over IPv6; versions {vs}", 0)])
        e = ex.get("epochs")
        if isinstance(e, list) and e and isinstance(e[0], dict):
            e = e[0]
            total = num(e.get("total")) / 1e6
            out.append([("Last epoch   ", curses.A_BOLD),
                        (f"{n(e.get('epoch'))} ({n(e.get('start'))} to {n(e.get('end'))}): {total:,.2f} NEON to {n(e.get('wallets'))} wallet(s)", 0)])
        return out

    def atom_lines(self, ex, w):
        if not ex:
            return []
        # (At most 500: a huge list must not cost every frame, review 2026-11-23.)
        atoms = [a for a in (ex.get("atoms") or [])[:500] if isinstance(a, dict)]
        atoms.sort(key=lambda a: (a.get("online") is not True, -num(a.get("photons_today"))))
        now_ms = time.time() * 1000
        out = [[(pad("", 4) + col("name", 22) + col("kind", 11) + col("version", 10) + col("today", 9) + "seen", curses.A_BOLD)]]
        for a in atoms:
            on = a.get("online") is True
            name = clean(a.get("name")) or clean(a.get("peer"))[:12]
            seen = "" if on else ("not seen" if not num(a.get("last_ms")) else ago(a.get("last_ms"), now_ms) + " ago")
            out.append([("on  " if on else "off ", self.GREEN if on else self.RED),
                        (col(name, 22) + col("electrode" if a.get("hub") is True else "atom", 11)
                         + col(clean(a.get("version")) or "?", 10) + col(f"{num(a.get('photons_today')):.1f}", 9) + seen, 0)])
        return out

    def scan_lines(self, scan, scan_err, w):
        if scan is None:
            return [[(scan_err or "nothing yet", self.RED if scan_err else self.BLUE)]]
        now_ms = time.time() * 1000
        out = [[(f"{len(scan)} packets, newest {ago(scan[0].get('t'), now_ms) if scan else '?'} ago", self.BLUE)]]
        kinds = {"text": "text", "position": "pos", "nodeinfo": "node", "telemetry": "tele", "advert": "advert"}
        for i in scan:
            mc = clean(i.get("net")) == "meshcore"
            who = clean(i.get("name")) or clean(i.get("from"))
            hm = time.strftime("%H:%M", time.localtime(num(i.get("t")) / 1000))
            k = kinds.get(clean(i.get("kind")), clean(i.get("kind")))
            heard = int(num(i.get("heard")))
            text = clean(i.get("text"))
            parts = [(hm + " ", 0), ("MC " if mc else "MT ", (self.YELLOW if mc else self.CYAN) | curses.A_BOLD),
                     (pad(who, 16) + " ", 0), (pad(k, 7), self.BLUE)]
            if heard > 1:
                parts.append((f"x{heard} ", self.BLUE))
            if text:
                parts.append((text, 0))
            out.append(parts)
        return out


def main(scr):
    data = Data()
    stop = threading.Event()
    threading.Thread(target=refresher, args=(data, stop), daemon=True).start()
    screen = Screen(scr, data)
    scr.timeout(1000)
    told = set()
    while True:
        try:
            screen.draw()
        except Exception as e:
            # (Once per kind of failure to the journal, not silently.)
            why = repr(e)[:200]
            if why not in told and len(told) < 50:
                told.add(why)
                print("vault monitor: drawing failed:", why, file=sys.stderr, flush=True)
        # A key does nothing; a resize is drawn at once.
        try:
            scr.getch()
        except curses.error:
            time.sleep(1)


if __name__ == "__main__":
    locale.setlocale(locale.LC_ALL, "")
    os.makedirs(CACHE, mode=0o700, exist_ok=True)
    # Raw: no Ctrl+C or Ctrl+S on an always-on screen.
    def run_main(scr):
        curses.raw()
        curses.noecho()
        main(scr)
    curses.wrapper(run_main)
VAULT_MONITOR_PY
}

monitor() {
    [ "$(id -u)" = 0 ] || die "as root (neon-vault-monitor.service runs it)"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import curses' 2>/dev/null; then
        monitor_py > "$HOME_DIR/vault-monitor.py.new" && mv -f "$HOME_DIR/vault-monitor.py.new" "$HOME_DIR/vault-monitor.py"
        # No screen blanking; UTF-8 mode on; the frames in Unicode box-drawing characters (every console
        # font has them), not the terminal's VT100 line set.
        setterm --blank 0 --powerdown 0 2>/dev/null || true
        printf '\033%%G'
        # Not exec'd: a screen that cannot start (a curses error, a file not written) falls back to the
        # plain-text one below instead of a blank screen restarted every 10 s (review 2026-11-23).
        started=$(date +%s)
        env LANG=C.UTF-8 LC_ALL=C.UTF-8 NCURSES_NO_UTF8_ACS=1 python3 "$HOME_DIR/vault-monitor.py" && exit 0
        # (One that ran a while and then died, killed or out of memory: systemd starts it again in 10 s;
        # one that cannot start at all: the plain-text screen, review 2026-11-23.)
        [ $(($(date +%s) - started)) -lt 30 ] || exit 1
        echo "the curses screen could not start: the plain-text one instead" >&2
    fi
    # Without Python's curses: the screen as plain text (each a line short of the screen: the last
    # newline would scroll the top away).
    bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
    green=$(tput setaf 2 2>/dev/null || true); red=$(tput setaf 1 2>/dev/null || true)
    yellow=$(tput setaf 3 2>/dev/null || true); cyan=$(tput setaf 6 2>/dev/null || true)
    # (linux's sgr0 ends with SI, \017: a byte the console shows nothing for, but one more to count.)
    off=$(tput sgr0 2>/dev/null | tr -d '\017' || true)
    VAULT_MONITOR=1
    # No cursor, no screen blanking, no keys (no Ctrl+C, Ctrl+S or echo): an always-on screen.
    # (UTF-8 mode on: a byte from the electrode's text that would be a control in the console's
    # other mode is then only part of a character, review 2026-11-19.)
    printf '\033%%G\033[?25l'; setterm --blank 0 --powerdown 0 2>/dev/null || true
    stty -isig -ixon -icanon -echo 2>/dev/null || true
    logo_for_console
    while :; do
        full=$(tput cols 2>/dev/null || echo 80); rows=$(tput lines 2>/dev/null || echo 25)
        # A wide screen in two columns (owner 2026-11-23): the vault and the network on the left, the
        # world scanner on the right; a narrow one, the left alone.
        if [ "$full" -ge 120 ]; then
            right=$((full * 2 / 5)); left=$((full - right - 3))
        else
            right=0; left=$full
        fi
        MON_COLS=$left monitor_screen > "$TMP/screen" 2>&1 || true
        [ "$right" -eq 0 ] || scan_column "$right" "$rows" > "$TMP/scan-col" 2>&1 || true
        printf '\033[H\033[2J'
        # Each line cut to its column's width (colours not counted), no more lines than the screen
        # has: a long line would wrap and scroll the top away.
        if [ "$right" -eq 0 ]; then
            fit "$left" < "$TMP/screen" | head -n $((rows - 1))
        else
            awk -v n="$rows" '{ print } END { for (i = NR; i < n; i++) print "" }' "$TMP/screen" | head -n "$rows" | fit "$left" pad > "$TMP/left"
            fit "$right" < "$TMP/scan-col" | head -n "$rows" > "$TMP/right"
            # (Joined at a control character no text on either side has: they are taken out.)
            paste -d "$(printf '\001')" "$TMP/left" "$TMP/right" | head -n $((rows - 1)) | sed "s/$(printf '\001')/ $dim│$off /"
        fi
        sleep "$MONITOR_EVERY"
    done
}

# fit COLS: each line cut to COLS characters, escape sequences (the colours) not counted.
# fit COLS [pad]: each line cut to COLS characters (and with pad, filled with spaces up to them), escape
# sequences (the colours) not counted, a UTF-8 character counted once (the logo, names: owner
# 2026-11-23, the screen in two columns lines them up).
fit() {
    LC_ALL=C awk -v w="$1" -v pad="${2:-}" -v off="$off" '
    BEGIN { for (i = 128; i < 192; i++) cont = cont sprintf("%c", i) }
    {
        s = $0; out = ""; n = 0; esc = 0; keep = 1
        while (s != "") {
            c = substr(s, 1, 1)
            if (c == "\033") {
                if (match(s, /^\033\[[0-9;?]*[A-Za-z]/) || match(s, /^\033[()][A-Za-z0-9]/)) {
                    out = out substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1); esc = 1; continue
                }
                s = substr(s, 2); continue
            }
            # (Another control character takes no column.)
            if (c < " ") { out = out c; s = substr(s, 2); continue }
            # (A UTF-8 continuation byte goes with the character before it.)
            if (index(cont, c)) { if (keep) out = out c; s = substr(s, 2); continue }
            keep = (n < w)
            if (keep) out = out c
            n++; s = substr(s, 2)
        }
        out = out (esc ? off : "")
        if (pad != "") while (n < w) { out = out " "; n++ }
        print out
    }'
}

# The world scanner's newest packets (eu1's, through the SSH key: neon-epoch-remote.sh `scan`), asked
# every two minutes, as the right column of the screen (owner 2026-11-23): time, network, sender,
# kind, text, and how many atoms heard it.
SCAN_EVERY_MIN=2
scan_column() {
    w=$1; rows=$2
    [ "$rows" -gt 3 ] 2>/dev/null || return 0
    remote=$(conf REMOTE); port=$(conf PORT)
    # (When it was last asked, answered or not: a stamp of its own, every two minutes either way.)
    if [ -n "$remote" ] && { [ ! -f "$TMP/scan.tried" ] || [ -z "$(find "$TMP/scan.tried" -mmin -"$SCAN_EVERY_MIN" 2>/dev/null)" ]; }; then
        touch "$TMP/scan.tried"
        if ssh_electrode scan 2>/dev/null | head -c 2000000 > "$TMP/scan.new" \
            && jq -e '.items | arrays' "$TMP/scan.new" >/dev/null 2>&1; then
            mv -f "$TMP/scan.new" "$TMP/scan.json"
        else
            rm -f "$TMP/scan.new"
            # (Kept: the last answer, until a newer one; marked old by its time.)
        fi
    fi
    rule() { printf '%s%s%s\n' "$dim" "$(printf '%*s' "$w" '' | tr ' ' '-')" "$off"; }
    printf '%sWORLD SCANNER%s\n' "$bold$cyan" "$off"
    if ! jq -e '.items | length > 0' "$TMP/scan.json" >/dev/null 2>&1; then
        rule
        printf '%snothing yet%s (the electrode answers once it runs this release)\n' "$dim" "$off"
        return 0
    fi
    jq -r --arg d "$dim" --arg o "$off" --argjson now "$(date +%s)000" '
        def num: if type == "number" then . else (tostring | tonumber? // 0) end;
        (.items | map(objects)) as $i | "\($d)\($i | length) packets, newest \((([$now - ($i[0].t | num), 0] | max) / 60000 | floor) as $m | if $m < 60 then "\($m)m" else "\($m / 60 | floor)h" end) ago, from the electrode\($o)"
    ' "$TMP/scan.json" 2>/dev/null
    rule
    # The newest first; the text from elsewhere without control characters (as the atoms list).
    jq -r --arg mt "$cyan" --arg mc "$yellow" --arg d "$dim" --arg o "$off" '
        def clean: if . == null then "" else tostring | gsub("\\p{Cc}"; "") end;
        def num: if type == "number" then . else (tostring | tonumber? // 0) end;
        def pad($n): .[0:$n] | . + (" " * ($n - length));
        .items[]? | objects |
        ((.t | num) / 1000 | floor | localtime | strftime("%H:%M")) as $hm |
        (if (.net | clean) == "meshcore" then $mc + "MC" else $mt + "MT" end) as $net |
        ((.name | clean) as $n | if $n == "" then (.from | clean) else $n end) as $who |
        ({"text": "text", "position": "pos", "nodeinfo": "node", "telemetry": "tele", "advert": "advert"}[(.kind | clean)] // (.kind | clean)) as $k |
        "\($hm) \($net)\($o) \($who | pad(14)) \($d)\($k | pad(6))\($o) \((.text | clean)[0:200])\(if (.heard | num) > 1 then " \($d)x\(.heard | num)\($o)" else "" end)"
    ' "$TMP/scan.json" 2>/dev/null | head -n $((rows - 3))
}

# One screen of the monitor (as text with colours): the fixed part, then as many atoms as fit.
monitor_screen() {
    cols=${MON_COLS:-$(tput cols 2>/dev/null || echo 80)}; rows=$(tput lines 2>/dev/null || echo 25)
    monitor_top > "$TMP/top" 2>&1 || true
    cat "$TMP/top"
    [ -s "$TMP/explore.json" ] || return 0
    room=$((rows - $(wc -l < "$TMP/top") - 1))
    [ "$room" -gt 0 ] || return 0
    # The online ones first, then by photons today.
    # (The electrode's data as text only: no control characters, numbers as numbers or 0, review 2026-11-19.)
    jq -r --arg g "$green" --arg r "$red" --arg o "$off" --argjson now "$(date +%s)000" '
        def clean: if . == null then "" else tostring | gsub("\\p{Cc}"; "") end;
        def num: if type == "number" then . else (tostring | tonumber? // 0) end;
        def pad($n): .[0:$n] | . + (" " * ($n - length));
        [.atoms[]? | objects] | sort_by([(if .online == true then 0 else 1 end), -(.photons_today | num)])[] |
        "\(if .online == true then $g + "on " else $r + "off" end)\($o) \((if (.name | clean) == "" then (.peer | clean)[0:12] else (.name | clean) end) | pad(18))  \(if .hub == true then "electrode" else "atom     " end)  \((.version | clean | if . == "" then "?" else . end) | pad(8))  \(((.photons_today | num) * 10 | round / 10) | tostring | pad(7)) today  \(if .online == true then "" else if (.last_ms | num) <= 0 then "not seen" else "seen " + ((([$now - (.last_ms | num), 0] | max) / 60000 | floor) as $m | if $m < 60 then "\($m)m" elif $m < 2880 then "\($m / 60 | floor)h" else "\($m / 1440 | floor)d" end) + " ago" end end)"
    ' "$TMP/explore.json" 2>/dev/null | head -n "$room"
}

monitor_top() {
    rule() { printf '%s%s%s\n' "$dim" "$(printf '%*s' "$cols" '' | tr ' ' '-')" "$off"; }
    title() { printf '%s%s%s\n' "$bold$cyan" "$1" "$off"; }
    # The logo (owner 2026-11-23), box-drawing bars so the n's meet their arches, with the name and
    # the time beside it.
    printf '%s%s%s   %svault%s  %s\n' "$bold$cyan" "$LOGO1" "$off" "$bold" "$off" "$(hostname)"
    printf '%s%s%s   %s UTC\n' "$bold$cyan" "$LOGO2" "$off" "$(date -u '+%Y-%m-%d %H:%M')"
    printf '%s%s%s   %s local\n' "$bold$cyan" "$LOGO3" "$off" "$(date '+%Y-%m-%d %H:%M %Z')"
    rule
    title "VAULT"
    # Status's own lines, a word coloured where it matters (the admin key's address left out).
    status 2>/dev/null | sed \
        -e "s/(as it should be)/${green}(as it should be)${off}/" \
        -e "s/incoming dropped/${green}incoming dropped${off}/" \
        -e "s/NOT ON/${red}NOT ON${off}/" \
        -e "s/timer on/${green}timer on${off}/" \
        -e "s/timer off/${yellow}timer off${off}/" \
        -e "s/(success)/${green}(success)${off}/" \
        -e "s/(exit-code)/${red}(failed)${off}/" \
        -e "s/(exit-code, exit \([^)]*\))/${red}(failed, exit \1)${off}/" \
        -e "s/(\(timeout\|signal\|core-dump\|oom-kill\|resources\)[^)]*)/${red}&${off}/" \
        -e "s/? (no answer[^)]*)/${red}&${off}/" \
        -e "/^Last run/{/(success)/!s/([a-z-]*, exit [^)]*)/${red}&${off}/}" \
        -e '/^Admin key/d'
    # The machine itself.
    temp=$(awk '{printf "%.0f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo '?')
    disk=$(df -h / 2>/dev/null | awk 'NR==2{print $5" used of "$2}')
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%d MB", $3, $2}')
    printf 'Machine      up %s, %s C, disk %s, memory %s\n' "$(uptime -p 2>/dev/null | sed 's/^up //')" "$temp" "$disk" "$mem"
    last=$(journalctl -u neon-post -o cat --no-pager -n 200 2>/dev/null | grep -E 'posted:|filed|no epoch waiting|ERROR|not posted|NOT' | tail -n 1)
    [ -n "$last" ] && printf 'Posting log  %s\n' "$(printf '%s' "$last" | plain $((cols - 13)))"
    rule
    # The network, from the electrode's public explorer data (its /explore page's).
    remote=$(conf REMOTE); explore=$(conf EXPLORE)
    [ -n "$explore" ] || explore="https://${remote#*@}/api/explore"
    title "NETWORK  ${dim}$(url_host "$explore")${off}"
    rm -f "$TMP/explore.json"
    if [ -n "$remote$(conf EXPLORE)" ] && curl -fsS -m 20 --max-filesize 2000000 --proto =https,http -o "$TMP/explore.json" "$explore" 2>/dev/null && jq -e '.figures | objects' "$TMP/explore.json" >/dev/null 2>&1; then
        jq -r --arg g "$green" --arg o "$off" '
            def n: if . == null then "?" else tostring | gsub("\\p{Cc}"; "") end;
            def neon: if type == "number" then ((. / 1000000) * 100 | round / 100 | tostring) else "?" end;
            .figures as $f |
            "Atoms        \($g)\($f.online|n) online\($o) of \($f.atoms|n), \($f.chip_verified|n) chip-verified, \($f.electrodes|n) electrode(s)",
            "Today        \($f.packets_today|n) packets, \($f.confirmed_today|n) confirmed, \(($f.photons_today | if type == "number" then . else 0 end) * 100 | round / 100) photons",
            (if (.connections | type) == "object" then .connections as $c |
                "Connected    \($c.atoms|n) atoms, \($c.behind_router|n) behind a router, \($c.ipv6|n) over IPv6; versions " +
                ([($c.versions | objects // {}) | to_entries[] | "\(.key|n) x\(.value|n)"] | join(", ")) else empty end),
            (if (.epochs | type) == "array" and (.epochs | length) > 0 and (.epochs[0] | type) == "object" then .epochs[0] as $e |
                "Last epoch   \($e.epoch|n) (\($e.start|n) to \($e.end|n)): \($e.total|neon) NEON to \($e.wallets|n) wallet(s)" else empty end)
        ' "$TMP/explore.json" 2>/dev/null
        rule
        title "ATOMS"
    else
        rm -f "$TMP/explore.json"
        printf '%sno answer from %s%s (the electrode, or this network)\n' "$red" "$(url_host "$explore")" "$off"
    fi
}

# ---- menu ----
menu() {
    command -v whiptail >/dev/null || die "whiptail missing (vault-setup.sh installs it)"
    while :; do
        c=$(whiptail --title "NEON vault" --notags --cancel-button "Shell" --menu \
            "$(hostname) · $(date -u '+%Y-%m-%d %H:%M UTC') · release $(cat "$HOME_DIR/version" 2>/dev/null || echo none)" 20 72 11 \
            status "Status" \
            post "Post now (what the electrode has waiting)" \
            log "Posting log" \
            update "Update (newest signed release)" \
            auto "Automatic updates on / off" \
            monitor "The monitor (on the first screen, Alt+F1; back here: Alt+F2)" \
            keys "Import settings and keys (old machine, USB stick)..." \
            timer "Posting timer on / off" \
            edit "Edit settings (post.conf)" \
            reboot "Restart" \
            off "Shut down" 3>&1 1>&2 2>&3) || { clear; echo "/opt/neon-vault/vault.sh menu brings the menu back."; VAULT_SHELL=1 exec "${SHELL:-/bin/bash}" -l; }
        case "$c" in
            status) status > /tmp/vault-status 2>&1 || true; whiptail --title "Status" --scrolltext --textbox /tmp/vault-status 22 78 || true ;;
            post) clear; as_root systemctl start neon-post.service || true; journalctl -u neon-post -n 30 -o cat --no-pager > /tmp/vault-log 2>&1 || true
                whiptail --title "Posting" --scrolltext --textbox /tmp/vault-log 22 78 || true ;;
            log) journalctl -u neon-post -n 300 -o short-iso --no-pager > /tmp/vault-log 2>&1 || true; whiptail --title "Posting log" --scrolltext --textbox /tmp/vault-log 22 78 || true ;;
            update) clear; "$0" update > /tmp/vault-update 2>&1 || true; whiptail --title "Update" --scrolltext --textbox /tmp/vault-update 20 78 || true ;;
            monitor) whiptail --msgbox "The monitor runs on the first screen all the time: Alt+F1 shows it, Alt+F2 comes back here. Nothing can be typed there." 10 60 || true ;;
            auto) if systemctl is-enabled -q neon-vault-update.timer 2>/dev/null; then
                    whiptail --yesno "Turn automatic updates off? Updates are then only installed with Update." 9 70 && as_root systemctl disable --now neon-vault-update.timer || true
                elif [ ! -f /etc/systemd/system/neon-vault-update.timer ]; then
                    whiptail --msgbox "Update once first (this release's timer is not installed yet)." 8 60 || true
                else
                    whiptail --yesno "Turn automatic updates on? Every day around 12:00 UTC the vault installs a newer release if there is one, with the same checks as Update (signed by a release key, never older), and never during a posting run." 11 72 && as_root systemctl enable --now neon-vault-update.timer || true
                fi ;;
            keys) keys_menu ;;
            timer) if systemctl is-enabled -q neon-post.timer 2>/dev/null; then
                    whiptail --yesno "Turn the posting timer off? Nothing is posted until it is on again." 9 70 && as_root systemctl disable --now neon-post.timer || true
                else
                    whiptail --yesno "Turn the posting timer on (daily 03:15 UTC)? First make sure the old posting machine's timer is off: two posters must never run." 10 72 && as_root systemctl enable --now neon-post.timer || true
                fi ;;
            # A port changed in the settings is opened at once.
            edit) as_root nano "$CONF" || true; as_root "$0" firewall > /tmp/vault-out 2>&1 || whiptail --title "Firewall" --scrolltext --textbox /tmp/vault-out 16 78 || true ;;
            reboot) whiptail --yesno "Restart the vault?" 8 40 && as_root systemctl reboot || true ;;
            off) whiptail --yesno "Shut the vault down? Nothing is posted while it is off." 8 64 && as_root systemctl poweroff || true ;;
        esac
    done
}

# The import's own menu (owner 2026-11-19): from the old posting machine over SSH, or from a USB
# stick (then its copies wiped and the stick unmounted). "Back" returns to the main menu.
keys_menu() {
    while :; do
        c=$(whiptail --title "Settings and keys" --notags --cancel-button "Back" --menu \
            "post.conf, the admin key and the SSH key, once, from the old posting machine" 14 72 4 \
            fetch "From the old posting machine (SSH)" \
            import "From a USB stick" \
            wipe "Wipe the stick's copies" \
            eject "Unmount the stick" 3>&1 1>&2 2>&3) || return 0
        case "$c" in
            fetch) h=$(whiptail --inputbox "The old posting machine, as USER@HOST (its address on this network works too)" 9 72 3>&1 1>&2 2>&3) || continue
                p=$(whiptail --inputbox "Its SSH port" 9 40 22 3>&1 1>&2 2>&3) || continue
                clear; "$0" fetch "$h" "$p" || true; printf '\nEnter to go back to the menu. '; read -r _ || true ;;
            import|wipe) d=$(whiptail --inputbox "The stick's neon-vault folder (plug the stick in first)" 9 72 "$(stick)" 3>&1 1>&2 2>&3) || continue
                clear; "$0" "$c" "$d" > /tmp/vault-out 2>&1 || true; whiptail --title "$c" --scrolltext --textbox /tmp/vault-out 16 78 || true ;;
            eject) sync; as_root umount /mnt/stick 2>/dev/null || true; whiptail --msgbox "The stick can be taken out." 7 40 || true ;;
        esac
    done
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
case "${1:-menu}" in
    menu) menu ;;
    status) status ;;
    update) update "${2:-}" ;;
    import) import "${2:-}" ;;
    wipe) wipe "${2:-}" ;;
    fetch) fetch "${2:-}" "${3:-}" ;;
    monitor) monitor ;;
    screens) screens ;;
    firewall) [ "$(id -u)" = 0 ] || die "as root"; firewall ;;
    *) die "vault.sh menu | status | update | import DIR | wipe DIR | fetch USER@HOST [PORT] | monitor | screens | firewall" ;;
esac
