# OC-Minecraft-Deployer

Turn a free Oracle Cloud server into a Minecraft server you manage entirely from a web page.

One command sets up the whole machine. After that you never need the command line again — you create servers, pick versions, install modpacks, upload mods, read the console, and restart things from a web panel you can share with your friends.

> **Status: works, but not yet validated on a live instance.** Every step below is implemented and the logic is unit-tested, but the installer has not yet completed an end-to-end run on a real Oracle Cloud box. Treat the first run as a test, not as something to put a world you care about on. Items still unbuilt are marked **(planned)**. See the [roadmap](docs/ROADMAP.md).

---

## What you get

- A Minecraft server running 24/7 on hardware that costs **$0/month**
- A **web control panel** ([Crafty Controller](https://docs.craftycontrol.com/)) with a live console, file manager, player list, scheduled restarts, and backups
- **A real HTTPS address** like `https://yourname.duckdns.org` — a proper padlock, no certificate warnings, so handing the link and password to a friend is safe and not confusing
- **Any version, any flavor**: vanilla, Paper, Purpur, Fabric, NeoForge, Forge
- **One-click modpacks** from Modrinth and CurseForge
- **Nightly backups** with easy restore
- **One command to reset a world**, and **one command to put the machine back to stock** so you can start over without rebuilding anything in Oracle Cloud

## What it costs and what you actually get

Oracle's Always Free tier is genuinely free forever — no trial clock, no card charge — but **it got smaller in 2026 and almost every tutorial you will find online is now wrong.**

| | Always Free allowance (as of October 2026) |
|---|---|
| CPU | **2 OCPU** (ARM, Ampere A1) |
| Memory | **12 GB** |
| Storage | 200 GB total across all volumes |
| Outbound traffic | 10 TB/month |
| Cost | $0 |

On **15 June 2026** Oracle quietly halved this from 4 OCPU / 24 GB to 2 OCPU / 12 GB, with no announcement, and **from 18 August 2026 began terminating instances that were over the new limits**. If you follow an older guide that tells you to create a 4-core / 24 GB instance, your server will be deleted.

This project sizes everything for the real, current limits and warns you before you cross them.

**12 GB is still plenty for a friends-and-family server.** Rough guide:

| What you are running | Give Minecraft |
|---|---|
| Vanilla or Paper, 2–10 players | 4 GB |
| Paper with plugins, 10–20 players | 6 GB |
| Fabric / NeoForge, 50–150 mods | 6–8 GB |
| Large modpack, 200+ mods | 8–9 GB (tight — expect fewer players) |

Always leave at least ~2.5 GB for the operating system, the panel, and disk caching. The installer works this out for you.

### Two things that will bite you (and that this project handles)

**Oracle deletes servers that look idle.** If your instance averages under 20% CPU *and* under 20% network *and* under 20% memory across a 7-day window, Oracle may reclaim it. A Minecraft server nobody logs into for a week can trip all three. The installer sets up a lightweight activity floor and a monthly reminder so a quiet month does not cost you your world. **(planned)**

**"Out of host capacity" is normal, not a mistake you made.** Free ARM capacity in popular regions is heavily oversubscribed, and creating an instance often fails for days. The guide below explains how to work around it.

---

## How it fits together

```
        You, on Windows                     Your friends
              |                                   |
              | SSH (once, for setup)             | https://yourname.duckdns.org
              v                                   v
    +---------------------------------------------------------------+
    |   Ubuntu 24.04 LTS (ARM)  ·  Oracle Cloud Always Free         |
    |                                                               |
    |   [ Caddy :80 :443 ]  <-- free hostname + auto Let's Encrypt  |
    |          |                                                    |
    |          | reverse proxy (panel is NOT exposed directly)      |
    |          v                                                    |
    |   [ Crafty Controller :8443 ]  <-- the web panel              |
    |          |                                                    |
    |          +--> [ Minecraft server ]  :25565                    |
    |          +--> [ Minecraft server ]  :25566   (as many as fit) |
    |                                                               |
    |   [ nightly backups ]   [ mcd command-line helper ]           |
    +---------------------------------------------------------------+
            open to the internet: 80, 443, 25565-25575
```

Everything runs in Docker, which is what makes the "put it back to stock" command possible and reliable.

---

## Before you start

You need:

1. **An Oracle Cloud account.** Signing up requires a credit card for identity verification. You are not charged for Always Free resources, but be aware Oracle will try to upsell you to Pay As You Go — you can ignore it.
2. **An SSH key pair.** Windows 11 has this built in; instructions below.
3. **About 45 minutes**, most of which is waiting on Oracle.
4. *Optional but recommended:* a free [DuckDNS](https://www.duckdns.org/) account, which gives you a free hostname like `yourname.duckdns.org`. Takes 30 seconds, sign in with Google or GitHub. If you skip it, the installer falls back to an automatic hostname derived from your server's IP address, which also works but is ugly.

You do **not** need to know Linux. You will paste in one command.

---

## Part 1 — Create the server in Oracle Cloud

### 1. Make an SSH key on your PC

Open **PowerShell** (press Start, type `powershell`, hit Enter) and run:

```powershell
ssh-keygen -t ed25519 -C "minecraft-server"
```

Press Enter three times to accept the defaults. This creates two files in `C:\Users\<you>\.ssh\`:

- `id_ed25519` — your **private** key. Never share this with anyone, ever.
- `id_ed25519.pub` — your **public** key. This one is safe to share, and you will paste it into Oracle in a moment.

Show the public key so you can copy it:

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

Copy the whole line it prints, starting with `ssh-ed25519`.

### 2. Create the instance

In the Oracle Cloud console, go to **Compute → Instances → Create instance**, then set:

| Field | Value |
|---|---|
| Name | `minecraft` |
| Image | **Canonical Ubuntu 24.04** (click *Change image*) |
| Shape | **Ampere → VM.Standard.A1.Flex** (click *Change shape*) |
| OCPUs | **2** |
| Memory | **12 GB** |
| Boot volume | 50 GB is fine; up to 190 GB if you want room for backups |
| SSH keys | **Paste public keys** → paste the line you copied |

> **Do not set 4 OCPUs or 24 GB.** That exceeds the current free limits and Oracle will terminate the instance.

Click **Create**, and write down the **Public IP address** it gives you.

### 3. If you get "Out of host capacity"

This is the single most common problem and it is not your fault — free ARM capacity is simply full in most regions. Options, best first:

- **Just keep retrying.** Capacity frees up constantly. Try every few hours; evenings and weekends in your region's local time are often better.
- **Try a different availability domain** if your region has more than one (the dropdown on the create page).
- **Use a retry script** such as [oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity), which keeps asking for you until it succeeds.
- **Upgrade to Pay As You Go.** Counterintuitively this gets you much better capacity priority, and your Always Free resources *stay* free — you are only billed if you create something outside the free limits. This is the fastest fix, but only do it if you are confident you will not accidentally create paid resources.

### 4. Open the ports — **both** firewalls

**This is the step everyone gets wrong.** Oracle filters your traffic in two completely separate places, and opening only one leaves your server unreachable with no useful error message.

**Firewall 1 — the cloud security list.** In the console: **Networking → Virtual Cloud Networks → your VCN → Subnets → your subnet → Security Lists → Default Security List → Add Ingress Rules.** Add these:

| Source CIDR | Protocol | Destination port | What it is for |
|---|---|---|---|
| `0.0.0.0/0` | TCP | `80` | Certificate issuing and renewal |
| `0.0.0.0/0` | TCP | `443` | The web panel |
| `0.0.0.0/0` | TCP | `25565-25575` | Minecraft servers |
| `0.0.0.0/0` | UDP | `19132` | Bedrock / phone players (optional) |

**Firewall 2 — the one inside the server.** Oracle's Ubuntu images ship with `iptables` rules that block nearly everything except SSH, and they survive reboots. **The installer fixes this for you** — you do not need to do anything here, but this is why your server was unreachable if you ever tried setting one up manually before.

---

## Part 2 — Run the installer

Connect to your server from PowerShell, replacing the IP with yours:

```powershell
ssh ubuntu@203.0.113.42
```

Type `yes` when it asks about authenticity. Then paste this single line:

```bash
curl -fsSL https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main/bootstrap.sh | sudo bash
```

If you would rather read a script before running it as root — a good habit, and this one does ask for root — do it in two steps instead:

```bash
curl -fsSL https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main/bootstrap.sh -o bootstrap.sh
less bootstrap.sh
sudo bash bootstrap.sh
```

It will ask you a handful of plain-English questions — your DuckDNS name and token (or nothing, to use the automatic hostname), an email for certificate expiry notices, and how much memory to reserve for Minecraft. Then it takes roughly 5–10 minutes and prints:

```
  Panel:     https://yourname.duckdns.org
  Username:  admin
  Password:  <a long generated password, shown once>

  Save that password now. It is also kept at
  /opt/mcd/secrets/panel-creds.txt
```

The script is **idempotent** — safe to run again. It will not duplicate anything or wipe your worlds.

---

## Part 3 — Create your first Minecraft server

1. Open the panel link and log in as `admin`.
2. **Server → Create new server.**
3. Pick your flavor and version, or import a modpack (see below).
4. Set memory using the table above.
5. Click **Create**, then **Start**.
6. Your friends connect to `yourname.duckdns.org` (port `25565` is the default and usually does not need typing).

### Mods and modpacks

Three ways to get content onto a server, all from the browser — you never need SFTP or the command line:

- **Modrinth packs, automatically.** Paste a pack link or `.mrpack` and the loader, Minecraft version, and Java version are all resolved for you. **(planned)**
- **Upload a `.zip` yourself.** Works for CurseForge packs, a server you already have, or a pack from anywhere else. Use **Create new server → import from zip**, or upload the zip in the file manager and right-click → unzip. CurseForge is not automated because programmatic downloads from their API need a key that a public project cannot ship — so it is a manual zip, and that is a limitation of their terms, not of this tool.
- **Drop in individual mods or plugins.** Open the file manager, go to `mods/` or `plugins/`, and upload the `.jar` files. Restart the server from the panel.

### A note on versions

Minecraft changed how it numbers versions in 2026. The old `1.21.11` style ended in December 2025; releases are now `YY.D.H` — year, drop, hotfix. The current release is **26.3 "Wilderness Bound"** (15 September 2026).

This matters for two practical reasons:

- **Modded play lags behind.** Most mods and nearly all big modpacks still target `1.20.1` or `1.21.x`. If you want mods, expect to run an older version, and that is completely fine.
- **Newer Minecraft needs newer Java.** 26.x releases require **Java 25**; `1.20.5`–`1.21.11` need Java 21; older versions need 17, 11, or 8. The panel's stock Docker image only ships Java 8, 11, and 17, which means out of the box it **cannot run anything newer than 1.20.4**. This project supplies Java 21 and 25 as well and picks the right one for each server automatically, so you do not have to think about it. Crafty itself has no version ceiling — it supports Minecraft 1.8 through latest — so this is the only thing standing between you and the current release.

### A note on ARM

Your server is ARM (aarch64), not Intel or AMD. Java itself is completely fine with this, and the overwhelming majority of mods and plugins are pure Java and work perfectly. The rare exception is a mod or plugin shipping compiled native code for x86 only — if something fails to load with an `UnsatisfiedLinkError`, this is why, and there is usually an ARM-compatible alternative.

---

## Sharing with your friends

The panel uses **one shared admin password** by default — simple to hand out, and anyone who has it can do anything, including deleting worlds. That is the intended trade-off for a server among friends who trust each other.

```bash
sudo mcd creds        # show the credentials generated at install time
```

To change the password, do it in the panel under **Panel Config → Users**. Crafty owns its own user database and password hashing, so there is deliberately no way to set it from the command line — `mcd password` just prints these instructions.

If you later want to be stricter, Crafty supports individual accounts with per-server permissions (for example: can restart and read the console, cannot delete). Create them under **Panel Config → Users**. Worth doing if your circle grows past people you would trust with a world delete.

Your Minecraft server itself starts with **whitelist on** and **online-mode on**, so strangers who find your address cannot just walk in. Add friends under the panel's player management, or turn the whitelist off if you want it open.

### Keeping it secure

You are putting a control panel on the public internet, so two rules actually matter:

**Run `mcd update` regularly.** Crafty had a critical vulnerability ([CVE-2026-13716](https://cveawg.mitre.org/api/cve/CVE-2026-13716), CVSS 9.1) in versions 4.4.0 through 4.10.7: a path traversal in the file upload and server import features that allows writing files anywhere on the system, which means remote code execution. It is fixed in **4.10.8**. This project refuses to install anything older, but new issues will appear in future — updating is the whole defence.

That CVE needed only *a* valid login, not an admin one. So a limited account for a friend would not have protected you from it. Per-user accounts are good for limiting accidents and for revoking access cleanly; they are not a substitute for staying patched.

**Use a password you use nowhere else.** The generated one is fine — keep it. If you hand it to several people, treat it as semi-public and change it in the panel when someone leaves the group.

---

## Day-to-day commands

The installer provides a small helper called `mcd`. You can do nearly everything in the web panel instead — this is for the host side, which the panel cannot reach.

```bash
mcd status                  # running? memory, disk, DNS, certificate
mcd logs [crafty|caddy]     # recent logs
mcd creds                   # show the panel's initial admin credentials
mcd java                    # which Java path to use for which MC version

mcd backup                  # back up every server right now
mcd restore                 # list backups and restore one
mcd update                  # update the panel, this tool, and the system

mcd wipe-server [name]      # reset ONE server's world, keeping the panel,
                            #   users, mods, config and other servers
mcd uninstall               # remove everything and return the machine to a
                            #   stock Ubuntu box (keeps backups; --purge drops them)
```

### Backups

Nightly by default, kept for 7 days, stored at `/opt/mcd/backups`. Because they live on the same machine, they protect you from a bad plugin or a griefed world, **not** from losing the instance itself. For that, copy them off the box — Oracle gives you 20 GB of free Object Storage, and `mcd backup --remote` will push there. **(planned)**

### Wiping and starting over

Two different things, deliberately:

- **`mcd wipe-server survival`** — new season, fresh world. Everything else stays.
- **`mcd uninstall`** — removes Crafty, Caddy, Docker, all servers, the service files, and the firewall rules, leaving plain Ubuntu. Your backups are preserved unless you pass `--purge`. Re-run the installer afterwards for a clean slate without touching the Oracle Cloud console.

---

## Troubleshooting

<details>
<summary><b>My friends cannot connect to the Minecraft server</b></summary>

Almost always a firewall, and almost always the one you did not know about. Check in this order:

1. `mcd status` — is the server actually running?
2. Did you add the **ingress rules** in the Oracle security list (Part 1, step 4)?
3. Run `sudo iptables -L INPUT -n --line-numbers` — if you see `REJECT` rules near the top and the installer has not run, that is your problem; the installer fixes it.
4. Confirm they are using the right address and port, and that the server is on the port you opened.
</details>

<details>
<summary><b>The panel shows a certificate warning</b></summary>

Your hostname is not resolving to your server yet, so Let's Encrypt could not issue a certificate. Check that your DuckDNS record points at your current public IP, confirm port **80** is open in the security list (certificate issuing needs it, not just 443), then run `mcd logs` to see what Caddy reported.
</details>

<details>
<summary><b>A server will not start, with an "unsupported class file version" error</b></summary>

A Java version mismatch — the Minecraft version you picked needs a newer Java than the one being used. This is the problem described above; make sure you are on the latest image with `mcd update`.
</details>

<details>
<summary><b>The server randomly freezes or the panel becomes unresponsive</b></summary>

You have likely run out of memory. Run `mcd status` and compare the memory you gave Minecraft against the table near the top. On a 12 GB machine, leave at least 2.5 GB free. Lower the server's allocation in the panel and restart it.
</details>

<details>
<summary><b>My instance disappeared</b></summary>

Two possibilities. Either it was **over the free limits** (if you built it as 4 OCPU / 24 GB following an old guide, Oracle has been terminating these since August 2026), or it was **reclaimed as idle** after a week below 20% CPU, network, and memory. Check your email and the Oracle console's activity log. This is exactly why backups should live off the box.
</details>

---

## What this will not do

- It will not get you free ARM capacity — only Oracle controls that.
- It will not make a 12 GB ARM box behave like a dedicated host. Very large modpacks with many players will struggle, and that is a hardware limit, not a configuration one.
- It will not provision the Oracle Cloud resources for you. You create the instance in the console (Part 1); this configures it. Terraform-based provisioning is on the [roadmap](docs/ROADMAP.md).
- It does not do multi-machine clusters, cross-host proxy networks, or Bedrock/Java crossplay beyond what Crafty and Geyser already offer.

## Roadmap and contributing

Build plan and design decisions live in [docs/ROADMAP.md](docs/ROADMAP.md). Issues and pull requests are welcome — especially corrections from anyone who has hit an Oracle quirk I have not.

## Credits

Built on [Crafty Controller](https://docs.craftycontrol.com/), [Caddy](https://caddyserver.com/), and [Docker](https://www.docker.com/). Thanks to the people who publicly documented Oracle's 2026 free-tier reduction while Oracle itself said nothing.

## License

MIT — see [LICENSE](LICENSE).
