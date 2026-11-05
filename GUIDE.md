# Your Neon atom: a short guide

Thank you for testing the Neon Network. Your **atom** is a converted Helium hotspot: it listens to
Meshtastic radios around it, passes their messages on, and earns **photons** for the coverage it gives.
Atoms talk to each other over the internet through the **Plasma**, and to the network's **electrodes**
(the servers that count photons). This is a test network: things may change, and the NEON token is not
on the main Solana network yet.

## 1. Plug it in

1. Connect the antenna before the power (a radio without its antenna can be damaged).
2. Connect a network cable to your router, then the power.
3. Wait 5 to 10 minutes the first time.

No cable? After 2 minutes without a network the atom opens its own Wi-Fi called **Neon Setup …**. Join it
with your phone: a page opens by itself. Under **Connect with** choose **Wi-Fi**, then your home network. The atom
joins it and the Neon Setup network goes away; reconnect your phone to your home Wi-Fi.

## 2. Set it up

1. On a computer or phone on the same network, open **neon.directory**: it lists the atoms on your
   network. A new atom shows "Getting its certificate" for a few minutes, then **Open**.
2. The setup page is one page: **Network connection** (Cable or Wi-Fi), **your name** (the atom names
   itself), the **Meshtastic preset**, a **panel password**, then **Payout wallet** and **Position**. The preset must be the one the
   Meshtastic users near you use: it often differs from region to region (in Poland from one area to the
   next), so ask your local Meshtastic group. With the wrong one the atom hears nothing. You can change it
   later under **Settings → Meshtastic → Radio**.
3. **Payout wallet:** **Connect wallet** (a Solana wallet such as Solflare or Phantom in your browser) and
   sign the message it shows (free: nothing is sent to the blockchain). The photons your atom earns go to
   that wallet. Later: **Settings → Plasma → Payout**.
4. **Position:** drop the pin where the atom stands. The network map shows it rounded to about 1 km unless
   you choose otherwise. Later: **Settings → Plasma → Position** or **Reach → Coverage map**.
5. **Save and start.** The atom restarts and asks for the password.

A printable sheet to keep with the atom (setup in short and a test checklist): [SHEET.html](SHEET.html)
(open it in a browser and print it on both sides of one A4 sheet).

## 3. Day to day

- **Atom** page: photons today and this week, and **Claim NEON** once an epoch is out (weekly).
- **Plasma** page: messages with other operators, the # Earth channel, photos, voice notes and GIFs.
- **Community** page: votes on what the network should do. Each atom with a hotspot chip has one vote, and
  can open a vote of its own. Votes are public.
- **Meshtastic** page: what your atom hears on the radio.
- **Updates install by themselves** at night (03:00 to 05:00 UTC). You can turn that off under
  **Settings → Updates**, and install by hand there.
- Leave it on and online: when an atom goes silent for 30 minutes, the electrode sends its operator a
  message on the Plasma.

## 4. What your atom shares

- **With the electrodes:** reports of the radio packets it hears (a fingerprint and the signal, not the
  messages' contents), its position as you chose to share it, and its wallet.
- **With every atom:** its name, software version, the position as shared, its wallet, and your profile
  picture and words if you set them.
- **Messages:** direct messages between operators are end-to-end encrypted; channels are encrypted with
  their key, and # Earth can be read by every atom. Meshtastic direct messages pass through unread.
- **Help neighbours** (on by default, **Settings → Meshtastic → Node**): tells other operators how well your atom hears
  theirs. Turn it off to keep that to yourself.

Your panel password and wallet keys never leave your devices. Questions or a request to delete what the
network holds about you: write to **neon-testers@enzyme42.com**.

## 5. Giving it back or passing it on

**Settings → Reset atom**, type RESET and confirm, with the atom online. It retires its key on the
network, wipes your settings, messages, wallet and Wi-Fi, and starts as new.

## If something is wrong

- The atom is not listed at neon.directory: wait 20 minutes after power-up (the first start installs
  it), check that the phone or computer is on the same network, then look again.
- No internet (neon.directory does not open): the atom still works on your own network. On a phone or
  computer on that network open **http://*atom name*.local** (e.g. `http://sunny-curly-cougar.local`;
  if that does not open either, the atom's address from your router with `:8080`).
- The **Meshtastic** page stays empty for an hour although there are Meshtastic users nearby: check the
  Meshtastic preset (**Settings → Meshtastic → Radio**) with your local group.
- **Meshtastic** stays grey in the bottom bar (the packet forwarder is not connected): restart the atom from the power button at the
  top right of the panel, or unplug the power for 10 seconds.
- Anything else: send a screenshot of the page to **neon-testers@enzyme42.com**.
