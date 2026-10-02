# OC-Minecraft-Deployer

**Run a Minecraft server for free, and manage it from a web page.**

Oracle Cloud gives away a small ARM server forever, at no cost and with no trial clock. This turns one into a Minecraft host with a proper web control panel — create servers, pick any version, install modpacks, upload mods, read the live console, restart things — all from a browser you can share with your friends.

One command does the whole setup. After that you never need the command line again.

```bash
curl -fsSL https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main/bootstrap.sh | sudo bash
```

You need an Oracle Cloud account and about 45 minutes, most of it waiting. You do **not** need to know Linux.

---

## What you end up with

- A Minecraft server running 24/7 for **$0/month**
- A web panel at **`https://yourname.duckdns.org`** with a real certificate — safe to hand to friends
- **Any version**: vanilla, Paper, Purpur, Fabric, NeoForge, Forge, and modpacks
- Current Minecraft works, including **26.x**, which needs Java 25 that the panel doesn't ship on its own
- **Nightly backups**, one-command world resets, and one command to wipe the machine back to stock

---

## Step 1 — Make an SSH key

On Windows, open **PowerShell** and run:

```powershell
ssh-keygen -t ed25519 -C "minecraft"
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

Press Enter three times at the prompts. Copy the line it prints, starting with `ssh-ed25519` — that's your **public** key, and it's safe to share. On macOS or Linux the same commands work, with `cat ~/.ssh/id_ed25519.pub` instead.

## Step 2 — Create the server

In the Oracle Cloud console: **Compute → Instances → Create instance**.

Set the **shape before the image**, or you'll be offered images that don't fit an ARM machine.

| Field | Value |
|---|---|
| Name | `minecraft` |
| Shape (*Change shape*) | **Ampere → VM.Standard.A1.Flex**, **2 OCPUs**, **12 GB** |
| Image (*Change image*) | **Canonical Ubuntu 24.04** |
| Boot volume | leave default (~50 GB) |
| SSH keys | **Paste public keys** → the line from step 1 |

Three things that catch people out:

> **The image picker defaults to Oracle Linux.** You must change it to Ubuntu. Oracle Linux uses different package management and a different firewall, and the installer will refuse to run on it.

> **Don't go above 2 OCPUs / 12 GB.** Oracle halved the free allowance in June 2026 and has been deleting instances that exceed it since August. Older guides still say 4 OCPU / 24 GB — following one gets your server terminated.

> **Don't set the boot volume to 200 GB** either, however many guides tell you to. You get 200 GB in total across everything; the default ~50 GB is correct.

Click **Create** and note the **Public IP address**.

If you get **"Out of host capacity"**, that's Oracle, not you — free ARM capacity is heavily contended. Retry every few hours, or try a different availability domain.

## Step 3 — Open the ports

Oracle has a firewall in the cloud console that's entirely separate from the one on the server. **The installer fixes the one on the server; only you can do this one.**

**Networking → Virtual Cloud Networks → your VCN → Subnets → your subnet → Security Lists → Default Security List → Add Ingress Rules.** Source `0.0.0.0/0` for each:

| Protocol | Port | For |
|---|---|---|
| TCP | `80` | getting the certificate |
| TCP | `443` | the web panel |
| TCP | `25565-25575` | Minecraft |
| UDP | `19132` | Bedrock / phone players (optional) |

Skipping port 80 is the most common mistake — certificates can't be issued without it.

## Step 4 — Get a free hostname

Browsers won't show a padlock for a bare IP address, and Let's Encrypt won't issue a certificate for one. So grab a free name:

1. Go to [duckdns.org](https://www.duckdns.org/) and sign in with Google or GitHub
2. Register any subdomain, e.g. `yourname`
3. Put your instance's public IP in the box and hit **update**
4. Copy the **token** from the top of the page

*You can skip this — the installer will fall back to an automatic name derived from your IP. It works, but it's shared infrastructure and uglier.*

## Step 5 — Install

Connect, replacing the IP with yours:

```bash
ssh ubuntu@203.0.113.42
```

Type `yes` when asked about authenticity. Then:

```bash
curl -fsSL https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main/bootstrap.sh | sudo bash
```

It asks a few plain questions up front — hostname method (pick **1** for DuckDNS), your subdomain, your token, and an email for certificate reminders — then works for roughly 8 minutes and prints:

```
  Panel:     https://yourname.duckdns.org
  Username:  admin
  Password:  <generated, shown once>
```

**Save that password.** It's also kept at `/opt/mcd/secrets/panel-creds.txt`.

Re-running the installer is safe at any time; it won't duplicate anything or touch your worlds.

## Step 6 — Create your Minecraft server

1. Open the panel link, log in as `admin`
2. **Server → Create new server**
3. Pick your flavour and version, or import a modpack
4. Memory: **9216 MB** on a 12 GB instance
5. Port: anything in **25565–25575**
6. For Minecraft **26.x**, set the server's Java path to `/opt/java/jdk-25/bin/java` (`mcd java` lists them all)
7. **Create**

## Step 7 — Accept the Minecraft EULA

Every Minecraft server refuses to run until you agree to [Mojang's EULA](https://aka.ms/MinecraftEULA). Start the server once — it will stop immediately and write an `eula.txt`. Open that file in the panel's **file manager**, change `eula=false` to `eula=true`, save, and start it again.

Nothing can tick that box for you; it's a licence agreement.

**Your friends now connect to `yourname.duckdns.org`.**

---

## Looking after it

Mostly you'll use the web panel. These are for the rest:

```bash
mcd status              # running? memory, disk, DNS, certificate
mcd backup              # back up every server now
mcd restore             # list backups and restore one
mcd update              # update the panel, this tool and the system
mcd logs caddy          # when the certificate misbehaves
mcd restart             # restart the panel and proxy

mcd wipe-server         # new season: reset one world, keep everything else
mcd uninstall           # remove everything, back to a stock Ubuntu box
```

Your server starts with the **whitelist on**, so strangers who find the address can't wander in. Add friends in the panel.

## If something goes wrong

**Friends can't connect** — almost always the Oracle security list in step 3. Check `25565-25575` is open there and that your server's port is in that range.

**Certificate warning in the browser** — your hostname isn't pointing at the server yet, or port 80 is closed. Run `mcd status`, then `mcd logs caddy`.

**A server won't start, "unsupported class file version"** — the Minecraft version needs a newer Java. Set the Java path as in step 6.

**Everything froze** — probably out of memory. `mcd status` shows what's free; lower the server's allocation and restart it.

The [full reference](DETAILS.md) has a longer troubleshooting section, the memory sizing table, how the pieces fit together, and the free-tier details.

---

## More

- **[DETAILS.md](DETAILS.md)** — full reference: architecture, free-tier limits, every option, troubleshooting
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — design decisions, what's been verified on real hardware, what's next

Built on [Crafty Controller](https://docs.craftycontrol.com/), [Caddy](https://caddyserver.com/) and [Docker](https://www.docker.com/). MIT licensed — see [LICENSE](LICENSE).

Issues and pull requests welcome, especially from anyone who hits an Oracle quirk that isn't documented here yet.
