# Build plan

Working outline for OC-Minecraft-Deployer. Records the decisions already made, the risks worth knowing about, and the order of work.

Last updated: 2026-10-02

---

## Decisions locked in

| Decision | Choice | Why |
|---|---|---|
| Scope | Configure a BYO instance | No OCI API keys, no Terraform state, no credential handling. The user creates the instance in the console; we own everything inside it. |
| Panel | Crafty Controller 4 | Official arm64 images, single service, no external DB or web stack, light enough for a 12 GB box. Pterodactyl would eat most of the RAM budget on MySQL + Redis + nginx + wings. |
| Flavors | Vanilla, Paper, Purpur, Fabric, NeoForge, Forge, plus Modrinth/CurseForge modpacks | Crafty covers most of this natively; modpack import is where we add real value. |
| Delivery | Single idempotent `bootstrap.sh`, run over SSH | Shareability was the stated priority. Ansible would force every user to install Ansible first; a `curl \| bash` line is something a non-technical friend can follow. |
| Runtime | Docker + Compose | Makes `uninstall` genuinely clean and makes the Java fix below tractable. |
| Panel access | Free hostname (DuckDNS, sslip.io fallback) + Caddy + Let's Encrypt | Real certificate, no purchase required, no click-through warning in front of a password prompt. |
| Panel auth | One shared generated admin password | User's call. Per-user accounts documented as the stricter option. |
| Reset | Two separate commands: per-server world wipe, and full uninstall to stock | They are different jobs with very different blast radii and should not share a command. |

## Hard constraints discovered during research

These are the two findings that would have broken the project if we had built from memory or from existing tutorials.

### 1. The free tier is half what every guide says

Oracle cut Always Free A1 from 4 OCPU / 24 GB to **2 OCPU / 12 GB effective 15 June 2026**, with no announcement, and began **terminating over-limit instances on 18 August 2026**.

Implications:

- Never hardcode a RAM figure. Compute allocations from `/proc/meminfo` at install time.
- The installer should refuse, loudly, to configure a server whose heap would leave under ~2.5 GB free.
- The README must actively contradict older tutorials, because following one gets the user's instance deleted.
- Verify this allowance again before release; Oracle changed it silently once and may again.

### 2. The stock Crafty image cannot run current Minecraft

The official Crafty 4 image ships **only Java 8, 11, and 17** (`/usr/lib/jvm/java-{8,11,17}-openjdk-arm64`). But:

| Minecraft | Needs |
|---|---|
| 26.x (current) | Java 25 |
| 1.20.5 – 1.21.11 | Java 21 |
| 1.17 – 1.20.4 | Java 17 |
| 1.16.5 | Java 11 |
| Older | Java 8 |

So out of the box the panel tops out at **1.20.4**. This is the central technical problem to solve.

Note that this is purely a packaging gap, not a Crafty limitation: the [compatibility page](https://docs.craftycontrol.com/pages/getting-started/compatibility/) states Crafty is "tested on and works running MC Java versions 1.8 - latest". The application has no version ceiling. Only the container's bundled JVMs do.

**Approach — bind-mount Temurin JDKs from the host.** Install Temurin 21 and 25 (aarch64) to `/opt/mcd/java/` on the host, mount that read-only into the container, and set each server's Java executable path at creation time from a version-to-JVM mapping.

Why this over a derived image:

- The upstream image stays **stock**, which keeps us inside Crafty's support boundary — their matrix lists Docker as "limited support (Arcadia Images only)."
- Nothing to rebuild when Crafty publishes a new release; `mcd update` just pulls a new tag.
- A mounted JDK is unaffected by base-image changes, whereas a derived image must be rebuilt against every new upstream tag.
- Trivially removable, which serves the clean-uninstall requirement.

**Real risk:** glibc compatibility between the generic Temurin aarch64 tarball and the container's base distro. Low for a Debian-family image (the JVM paths above use Debian naming), but **verify at install time** with a `java -version` smoke test inside the container before declaring success.

**Fallback if that fails:** a thin derived image (`FROM registry.gitlab.com/crafty-controller/crafty-4:<pinned>`, add Temurin 21 and 25), rebuilt by `mcd update`. Costs a rebuild per upstream release but sidesteps glibc concerns entirely.

**Second fallback: native install instead of Docker.** Crafty's matrix rates native Linux installs "Full" support across Debian/Ubuntu/Arch and Raspberry Pi OS 11–12 (ARM), versus limited for Docker. Native also makes the Java problem vanish, since we control the system JDKs outright. Rejected as the default only because `docker compose down -v && rm -rf /opt/mcd` is a far more reliable teardown than unwinding an installer script, a Python venv, and a systemd unit — and clean uninstall is an explicit requirement. Revisit if Docker on ARM proves troublesome.

**Open question:** whether a newer Crafty release has added 21/25 to the image — check first, since that deletes this whole work item.

### 3. Crafty must be pinned at 4.10.8 or newer

[CVE-2026-13716](https://cveawg.mitre.org/api/cve/CVE-2026-13716) — CVSS 9.1, path traversal in server import and admin file upload (`fileName` header), affecting **4.4.0 through 4.10.7**, fixed in **4.10.8**. Arbitrary file write leading to RCE. A PoC exists.

This lands squarely on this project's design: we expose the panel publicly and the attack needs only `PR:L`, any authenticated user. Consequences for the build:

- Assert the running Crafty version at install time and **refuse to proceed below 4.10.8**.
- Pin an explicit known-good tag rather than tracking `:latest` blindly, but make `mcd update` the well-lit path so pinning does not become staleness.
- Note in the docs that limited per-user accounts do **not** mitigate this class of bug. Useful for accidents and revocation, not for privilege escalation.
- Worth a recurring check for new Crafty advisories before each release of this project.

### 4. Version numbering changed mid-2026

Releases moved from `1.x.y` to `YY.D.H` (year, drop, hotfix). Last `1.x` was 1.21.11 in December 2025. Then 26.1 "Tiny Takeover" (24 Mar), 26.2 "Chaos Cubed" (16 Jun), 26.3 "Wilderness Bound" (15 Sep).

Implications:

- Any version sorting must handle both schemes. Naive string or semver sorting puts `1.21.11` above `26.3`.
- Do not hardcode "latest" anywhere — read Mojang's version manifest.
- Modded content still overwhelmingly targets 1.20.1 / 1.21.x, so legacy versions are the common case for mods, not an edge case.

### 5. Idle reclamation is a real risk for this exact workload

Oracle may reclaim an Always Free instance when the 7-day 95th-percentile is under 20% on CPU **and** network **and** memory. A quiet Minecraft server can hit all three.

Mitigation to design: a minimal, honest activity floor (the JVM holding its heap already helps considerably on the memory axis) plus a monthly status email or notice. Not a CPU-burning fake load — that is wasteful and against the spirit of the thing.

## Risks still to resolve

- Caddy must reverse-proxy to Crafty's **HTTPS** listener on 8443, which uses a self-signed certificate. Needs `transport http { tls_insecure_skip_verify }`. Easy to miss, fails confusingly.
- Crafty's compose exposes a server port range (25500–25600). Decide on a narrower published range and keep the README, the host firewall, and the Oracle security list in agreement — a mismatch here is the top support issue.
- ~~sslip.io rate limit headroom.~~ **Resolved, and worse than assumed.** sslip.io and nip.io are NOT on the Public Suffix List, so Let's Encrypt treats each as one registered domain with a single budget shared by every user worldwide. Let's Encrypt has raised the ceiling for them (nip.io is at 250,000 per 7 days) so it works in practice, but there is no fallback if it is exhausted, and a rate-limit failure is indistinguishable from a misconfiguration. DuckDNS is therefore the preferred path and sslip.io is documented as best-effort. Use DuckDNS for test runs so a cert failure cannot be blamed on a shared bucket.
- DuckDNS hostnames need updating if the instance's public IP changes. Reserved public IPs on OCI are stable; confirm and document.
- ~~Modpack import: CurseForge API key problem.~~ **Resolved:** Modrinth automatic; CurseForge and anything else via user-supplied zip through the panel's import or file manager, documented as a deliberate limitation of CurseForge's terms. Crafty's file manager already supports upload, in-browser unzip, and server-import-from-zip, so manual mod and plugin `.jar` drops need no work from us.
- ARM: mods and plugins with x86-only native code will fail. Collect a known-bad list as it emerges.
- No swap on Oracle's Ubuntu images by default. On 12 GB, add a modest swapfile as an OOM cushion.

## Status

Phases 1–3 are written and the pure logic is unit-tested (`bash tests/unit.sh`,
32 assertions). **Nothing has been run end-to-end on a live Oracle instance
yet** — that is the next step, and until it happens every step below is
"implemented" rather than "working".

What exists:

| File | Does |
|---|---|
| `bootstrap.sh` | Stage 0 for `curl \| sudo bash`: fetches the repo, hands to `install.sh` |
| `install.sh` | Orchestrates the steps, parses flags, sets up logging |
| `lib/common.sh` | Paths, version floors, logging, tty-safe prompts, helpers |
| `lib/10-preflight.sh` | OS/arch checks, free-tier limit warning, disk, connectivity |
| `lib/20-host.sh` | Layout, packages, swapfile, swappiness, unattended-upgrades |
| `lib/30-docker.sh` | Docker CE + compose plugin from Docker's apt repo, log rotation |
| `lib/40-firewall.sh` | The INPUT and FORWARD fixes, plus a boot-time reassert unit |
| `lib/50-java.sh` | Temurin 21/25 install, version map, in-container verification |
| `lib/60-hostname.sh` | DuckDNS / custom / sslip.io, DNS pre-check, refresh timer |
| `lib/70-stack.sh` | Renders templates, CVE floor check, brings the stack up, waits for TLS |
| `lib/80-finalize.sh` | Installs `mcd`, backup timer, prints the handover summary |
| `bin/mcd` | status, logs, creds, java, backup, restore, update, wipe-server, uninstall |
| `templates/` | compose.yaml and Caddyfile |
| `tests/unit.sh` | Unit tests for the pure helpers |
| `.github/workflows/ci.yml` | shellcheck, CRLF guard, unit tests, template validation |

Deliberately not implemented yet: Modrinth modpack automation, off-box backups
to Object Storage, the idle-reclamation mitigation, Geyser, Terraform.

### Known-unverified assumptions

Each of these is a guess until the first live run proves or disproves it:

1. **Temurin aarch64 runs against the Crafty image's glibc.** The whole
   bind-mount approach rests on this. `verify_java_in_container` tests it
   explicitly and degrades loudly rather than silently.
2. **Oracle's FORWARD REJECT really does sit below Docker's chains** in
   practice. The code handles both orders, but only a live box confirms which
   one actually occurs.
3. **`default-creds.txt` format.** The parser in `80-finalize.sh` greps for
   username and password; if the real file is shaped differently it falls back
   to pointing at the file, but the summary will be less useful.
4. **Crafty accepts a per-server Java path** pointing outside `/usr/lib/jvm`.
   Expected to be a free-text field; needs confirming in the UI.
5. **`compose ps --status running --services`** flag support on the installed
   compose version.

## Order of work

### Phase 1 — a working server
1. `bootstrap.sh` skeleton: strict mode, root check, Ubuntu/arm64 detection, logging, re-run safety.
2. Host prep: non-root service user, `unattended-upgrades`, swapfile, SSH hardening.
3. **Fix the host iptables rules** and persist them. Single highest-value step — this is what breaks manual setups.
4. Install Docker CE + compose plugin from Docker's apt repo.
5. Solve Java: install Temurin 21 + 25 (aarch64) to `/opt/mcd/java`, mount read-only into a **stock** Crafty image pinned at **4.10.8 or newer**, assert the version at install time, and smoke-test `java -version` inside the container. Then boot an actual 26.x server on aarch64. **Nothing else matters until this works** — fall back to a derived image, then to a native install, if it does not.
6. Compose stack, volume layout under `/opt/mcd`, Crafty up and reachable on localhost:8443.

### Phase 2 — safe to share
7. Hostname: DuckDNS registration/update, sslip.io fallback.
8. Caddy with auto-TLS, reverse proxy to Crafty, HTTP→HTTPS redirect.
9. Generate the admin password, print once, store hashed. `mcd password` to rotate.
10. Memory sizing computed from actual available RAM, with a refusal path when it is too tight.
11. Sensible server defaults: whitelist on, online-mode on, Aikar's flags, scheduled restart.

### Phase 3 — the management story
12. `mcd` helper: `status`, `logs`, `update`, `backup`, `restore`.
13. Nightly backup timer with retention.
14. `mcd wipe-server <name>` — world reset, with a confirmation prompt and an automatic pre-wipe backup.
15. `mcd uninstall` — full teardown to stock, `--purge` to drop backups too. Test on a throwaway instance until re-bootstrapping after uninstall is reliable.

### Phase 4 — polish
16. Modpack import helper (Modrinth first).
17. Idle-reclamation mitigation and monthly notice.
18. Off-box backups to OCI Object Storage via rclone.
19. Geyser/Floodgate option for Bedrock players.
20. Test matrix: fresh Ubuntu 24.04 arm64, re-run idempotency, uninstall → re-bootstrap, one legacy 1.20.1 modded server and one current 26.x vanilla server.

### Later
- Terraform provisioning (the deliberately deferred half of the original idea).
- `shellcheck` in CI; ideally a real boot test against a disposable instance.

## Conventions

- Bash, `set -euo pipefail`, `shellcheck`-clean.
- Everything under `/opt/mcd`; nothing scattered in home directories.
- Every step idempotent — check before acting, never blindly append to config files.
- All destructive actions confirm by default, with `--yes` for automation.
- Error messages name the fix, not just the failure.

## Oracle Linux support

Not supported, and this matters more than it first appears: **Oracle Linux is
the default image in the OCI console**, so a user who clicks Create without
touching the image picker lands on an unsupported OS through no fault of their
own. First real-world encounter with this project hit exactly that.

Handled for now by failing in preflight with an explicit explanation and
rebuild instructions, plus a callout in the README next to the image row.

Supporting it properly would mean dnf instead of apt, firewalld instead of
iptables, SELinux contexts on the bind mounts, and a second full test matrix.
Worth reconsidering if people keep arriving on it, since being the console
default means they will.
