#!/usr/bin/env python3
"""The first start's Wi-Fi page (neon-firstboot, owner 2026-11-05).

A new atom with no network opens its setup Wi-Fi ("Neon Setup XXXX") before Neon is installed;
every name there leads here (NetworkManager's dnsmasq, neon-captive.conf), so a phone that joins
is shown this page: choose the Wi-Fi the atom should use, and it joins it and installs. Only the
Python standard library (Raspberry Pi OS Lite has Python for cloud-init); neond's panel takes over
once installed.

  python3 neon-firstwifi.py <wifi device> [port]

The hotspot itself is neon-firstboot's (it opens and closes it); this joins the chosen network:
/run/neon/joining while it does, /run/neon/joined when it did, the outcome in
/run/neon/firstwifi-status (shown on the page when the hotspot opens again).
"""
import html
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEV = sys.argv[1] if len(sys.argv) > 1 else "wlan0"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 80
RUN = os.environ.get("NEON_RUN", "/run/neon")
CON = "neon-setup"
SCAN = os.path.join(RUN, "wifi-scan.txt")
STATUS = os.path.join(RUN, "firstwifi-status")
JOINING = os.path.join(RUN, "joining")
JOINED = os.path.join(RUN, "joined")
LOCK = threading.Lock()
POST_LOCK = threading.Lock()
LOGO = os.environ.get("NEON_LOGO", "/opt/neon/image/neon_logo.svg")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def write(path, text):
    os.makedirs(RUN, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def networks():
    """The networks seen just before the hotspot opened (the radio cannot scan as an access point):
    by name, the strongest first, without hidden ones and the atom's own."""
    best = {}
    for line in read(SCAN).splitlines():
        parts = fields(line)
        # Without other atoms' own Wi-Fi (Neon XXXX, Neon Setup XXXX).
        if len(parts) < 3 or not parts[0] or re.fullmatch(r"Neon (Setup )?[0-9A-F]{4}", parts[0]):
            continue
        try:
            signal = int(parts[1])
        except ValueError:
            signal = 0
        name, secured = parts[0], parts[2] not in ("", "--")
        if name not in best or best[name][0] < signal:
            best[name] = (signal, secured)
    return sorted(best.items(), key=lambda kv: -kv[1][0])


def fields(line):
    """nmcli -t's fields: split by ":", a ":" or a backslash in a value escaped by a backslash."""
    out, cur, esc = [], "", False
    for c in line:
        if esc:
            cur, esc = cur + c, False
        elif c == "\\":
            esc = True
        elif c == ":":
            out, cur = out + [cur], ""
        else:
            cur += c
    return out + [cur]


def security(ssid):
    """The scan's security field for a network ("" when not seen)."""
    for line in read(SCAN).splitlines():
        f = fields(line)
        if len(f) >= 3 and f[0] == ssid:
            return f[2]
    return ""


def wifi_profiles():
    """The UUIDs of the Wi-Fi profiles saved now."""
    try:
        r = subprocess.run(["nmcli", "-t", "-f", "UUID,TYPE", "connection", "show"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return {f[0] for f in map(fields, r.stdout.splitlines()) if len(f) >= 2 and f[1] == "802-11-wireless"}


def nmcli(*args, timeout=60):
    try:
        r = subprocess.run(["nmcli", *args], capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, (r.stderr or r.stdout).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)


def join(ssid, password, hidden):
    """Closes the hotspot (one radio: it cannot be both) and joins; the page has answered first."""
    with LOCK:
        try:
            before = wifi_profiles()
            # Time to read the page (a phone closes it with the hotspot).
            time.sleep(12)
            nmcli("connection", "down", CON)
            time.sleep(2)
            ok, err = False, ""
            for _ in range(2):
                nmcli("device", "wifi", "rescan", "ifname", DEV)
                time.sleep(5)
                args = ["--wait", "45", "device", "wifi", "connect", ssid, "ifname", DEV]
                if password:
                    args += ["password", password]
                if hidden:
                    args += ["hidden", "yes"]
                ok, err = nmcli(*args, timeout=90)
                if ok:
                    break
            if ok:
                write(STATUS, f"Joined {ssid}.")
                write(JOINED, ssid)
            else:
                # A profile this join made (a wrong password would be tried again) goes; one saved
                # before (neon.txt, Imager) stays.
                for uuid in wifi_profiles() - before:
                    nmcli("connection", "delete", "uuid", uuid)
                why = "wrong password?" if re.search(r"secret|password|802-1x|auth", err, re.I) else err[-160:]
                write(STATUS, f"Could not join {ssid} ({why}). Choose it again or another one.")
        finally:
            try:
                os.remove(JOINING)
            except OSError:
                pass


# The panel's look (crates/neond/src/web: find.html's card, index.html's fields and buttons).
PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Neon atom setup</title>
<style>
:root{{--bg:#f6f9fb;--panel:#fff;--text:#18212a;--heading:#3c4a57;--muted:#617383;--line:#dfe6ec;
--accent:#cc3f1c;--on-accent:#fff;--ok:#0a8562;--warn:#b0580a;--chip:#eef2f5;
--m:16px;--s:8px;--xs:4px;--ctl-h:calc(14px * 1.45 + 2 * var(--s) + 2px);--radius:10px;--r-ctl:8px;
color-scheme:light dark;accent-color:var(--accent)}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0c1117;--panel:#131a22;--text:#eef4f8;--heading:#c6d3dd;
--muted:#8fa1b0;--line:#253039;--accent:#ff8a6b;--on-accent:#14100e;--ok:#6ff0c0;--warn:#ffc46b;--chip:#1b242e}}}}
*{{box-sizing:border-box}}
body{{margin:0;min-height:100vh;display:grid;place-items:center;padding:var(--m);background:var(--bg);color:var(--text);
font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}}
main{{width:100%;max-width:420px;background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);overflow:hidden}}
header{{padding:24px var(--m) var(--m);text-align:center}}
.logo{{height:26px;width:auto;display:block;margin:0 auto 12px;overflow:visible}}
.logo-1{{fill:var(--accent)}}.logo-2{{fill:var(--text)}}
h1{{margin:0;font-size:18px;color:var(--heading);font-weight:600}}
header p{{margin:var(--xs) 0 0;color:var(--muted)}}
section{{border-top:1px solid var(--line);padding:var(--m);display:grid;gap:var(--m)}}
section p{{margin:0}}.muted{{color:var(--muted)}}
.field{{display:grid;gap:var(--xs)}}
.field>span{{font-size:12px;color:var(--heading)}}
input,select{{width:100%;height:var(--ctl-h);padding:var(--s);border-radius:var(--r-ctl);border:1px solid var(--line);
background-color:var(--bg);color:var(--text);font:inherit}}
select{{appearance:none;-webkit-appearance:none;padding-right:calc(var(--s) * 2 + 10px);
background-image:linear-gradient(45deg,transparent 50%,var(--muted) 50%),linear-gradient(135deg,var(--muted) 50%,transparent 50%);
background-position:right calc(var(--s) + 5px) center,right var(--s) center;background-size:5px 5px;background-repeat:no-repeat}}
button{{width:100%;height:var(--ctl-h);border:0;border-radius:var(--r-ctl);background:var(--accent);color:var(--on-accent);
font:inherit;font-weight:600;cursor:pointer}}
.st{{padding:var(--s) var(--m);border-radius:var(--r-ctl);background:var(--chip);color:var(--warn);font-weight:600}}
.st.ok{{color:var(--ok)}}
.hidden{{display:none}}
</style></head><body><main>{body}</main></body></html>"""


def logo():
    """The Neon logo as the panel shows it (web.rs panel_logo), if the image has it."""
    svg = read(LOGO)
    if "<svg" not in svg:
        return ""
    svg = svg[svg.index("<svg"):]
    svg = re.sub(r"<style[\s\S]*?</style>", "", svg, count=1)
    return svg.replace("<svg ", '<svg class="logo" role="img" aria-label="NEON" ', 1)


def head(title, sub):
    return f"<header>{logo()}<h1>{title}</h1><p>{sub}</p></header>"


def form_page(name):
    last = read(STATUS)
    opts = "".join(
        f'<option value="{html.escape(n)}">{html.escape(n)}{"" if sec else " (open)"}</option>'
        for n, (_, sec) in networks()
    )
    status = ""
    if last:
        cls = "st ok" if last.startswith("Joined") else "st"
        status = f'<p class="{cls}">{html.escape(last)}</p>'
    return PAGE.format(body=head("Set up this atom", f"<b>{html.escape(name)}</b>") + f"""
<section>
<p class="muted">The first start installs Neon from the internet (up to 30 minutes). Choose the Wi-Fi this
atom should use.</p>
{status}
<form method="post" action="/join" style="display:grid;gap:var(--m)">
<label class="field"><span>Wi-Fi network</span>
<select id="ssid" name="ssid">{opts}<option value="">Another (hidden) network…</option></select></label>
<label class="field{'' if not opts else ' hidden'}" id="other"><span>Its name</span>
<input name="other" autocomplete="off" autocapitalize="none" spellcheck="false"></label>
<label class="field"><span>Password</span>
<input name="password" type="password" autocomplete="off" placeholder="Empty for an open network"></label>
<button type="submit">Join</button>
</form>
</section>
<section><p class="muted">Or plug in the network cable: the atom goes on by itself.</p></section>
<script>
const s=document.getElementById("ssid"),o=document.getElementById("other");
const f=()=>o.classList.toggle("hidden",s.value!=="");s.onchange=f;f();
</script>""")


def joining_page(name, ssid):
    return PAGE.format(body=head(f"Joining {html.escape(ssid)}", f"<b>{html.escape(name)}</b>") + f"""
<section>
<p>This Wi-Fi closes in a few seconds: put your phone back on your usual Wi-Fi if it does not go back by itself.</p>
<p>Note this atom's name: <b>{html.escape(name)}</b>.</p>
<p>The atom installs Neon (up to 30 minutes). Then open <b>neon.directory</b> on a phone or computer
on the same network as the atom to finish the setup (if it is not listed there after 30 minutes: <b>http://{html.escape(name)}.local</b> on the same network).</p>
<p class="muted">If it cannot join, <b>Neon Setup</b> comes back in a few minutes and says why.</p>
</section>""")


class Handler(BaseHTTPRequestHandler):
    server_version = "neon-firstwifi"

    def send(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    # Every address shows the page (phones look for a sign-in page this way).
    def do_GET(self):
        self.send(form_page(socket.gethostname()))

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()

    def do_POST(self):
        try:
            n = min(max(int(self.headers.get("Content-Length") or 0), 0), 4096)
        except ValueError:
            n = 0
        q = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"), keep_blank_values=True)
        # Names as they are (a space at either end is part of a name).
        ssid = (q.get("ssid") or [""])[0]
        hidden = not ssid
        ssid = ssid or (q.get("other") or [""])[0]
        password = (q.get("password") or [""])[0]
        name = socket.gethostname()
        sec = security(ssid)
        if not ssid.strip() or len(ssid.encode()) > 32:
            write(STATUS, "Choose a network (a name of at most 32 bytes).")
            return self.send(form_page(name))
        if "802.1X" in sec or "WEP" in sec:
            write(STATUS, f"{ssid} needs a kind of login this page cannot do: choose another network or plug in the cable.")
            return self.send(form_page(name))
        if password and not 8 <= len(password.encode()) <= 63 and not re.fullmatch(r"[0-9a-fA-F]{64}", password):
            write(STATUS, "A Wi-Fi password has 8 to 63 characters.")
            return self.send(form_page(name))
        # One join at a time (a second tap must not start another).
        with POST_LOCK:
            if os.path.exists(JOINING):
                return self.send(joining_page(name, read(JOINING) or ssid))
            write(JOINING, ssid)
        self.send(joining_page(name, ssid))
        threading.Thread(target=join, args=(ssid, password, hidden), daemon=True).start()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
