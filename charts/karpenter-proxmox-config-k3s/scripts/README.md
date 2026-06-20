# build-ubuntu-k3s-template.sh

Builds a Proxmox VM — either as a plain template, or as a fully bootstrapped K3s node — from an Ubuntu cloud image. Run directly on a Proxmox host (it re-execs itself with `sudo` if needed).

This script covers two different jobs that often get conflated:

- **Building a template** for Karpenter (or any other clone-based provisioning) to use later — the VM is never meant to run anything itself, it just exists to be cloned (`-t`/`--template`).
- **Bootstrapping a real, running node** directly — a K3s server to start a new cluster, or a K3s agent to join one immediately (omit `-t`, optionally add `--k3s-start`).

The two are controlled independently: `--k3s-mode` decides *what gets installed*, `-t` decides *whether the result becomes a template or stays a bootable VM*. Any combination is valid — including, for instance, baking a ready-to-join agent **and** converting it to a template in one step (this is exactly what the `karpenter-proxmox-config-k3s` chart's "Strategy 2" does — see that chart's README for details).

---

## Prerequisites

- Run as root (or with `sudo`) on the Proxmox host
- `libguestfs-tools` (installed automatically if missing)
- Outbound internet access from the Proxmox host (to download the Ubuntu cloud image and, depending on `--k3s-mode`, the K3s install script at first boot)

---

## Scenario A — Plain Ubuntu template, no K3s at all

For use when K3s installation is fully delegated to Cloud-Init at provisioning time (e.g. `cloudInitTemplate.installK3sAgent: true` in the `karpenter-proxmox-config-k3s` chart).

```bash
./build-ubuntu-k3s-template.sh \
  -c noble \
  -i 9000 \
  -n ubuntu-noble-template \
  -b vmbr1 \
  -s storage-name \
  -d 10G \
  -t
```

`--k3s-mode` defaults to `none`, so nothing K3s-related is installed. `-t` converts the result into a template once the build finishes.

---

## Scenario B — Bootstrapping a new K3s cluster (server mode)

Use this to stand up the very first control-plane node of a new cluster. Omit `-t` so the result stays a regular, running VM rather than a template, and add `--k3s-start` so the server actually starts instead of being left disabled.

### B.1 — No token at all (let K3s generate one)

```bash
./build-ubuntu-k3s-template.sh \
  -c noble \
  -i 9100 \
  -n k3s-master-01 \
  -b vmbr1 \
  -s storage-name \
  -d 20G \
  -m server \
  --k3s-start
```

K3s generates its own random token at first boot. Retrieve it afterwards by connecting to the new server:

```bash
ssh <user>@<server-ip> sudo cat /var/lib/rancher/k3s/server/token
```

This is the value you'll need later as `--k3s-token` (server mode, scenario D) or `cloudInitValues.k3sToken` in the Helm chart, when joining agents to this cluster.

### B.2 — Providing a known agent-only token

If you want agents to join using a separate, static credential — distinct from (and unaffected by) the server token — pass `--k3s-agent-token`. This is the [K3s "agent token"](https://docs.k3s.io/cli/token) mechanism: it's accepted independently of the server token, doesn't expire, and can be set before or after the server bootstraps.

```bash
./build-ubuntu-k3s-template.sh \
  -c noble \
  -i 9100 \
  -n k3s-master-01 \
  -b vmbr1 \
  -s storage-name \
  -d 20G \
  -m server \
  --k3s-agent-token "myStaticAgentToken" \
  --k3s-start
```

The server token itself is still auto-generated in this case (same retrieval step as B.1, if you also need it for something other than agent joins).

### B.3 — Providing a known server token

If you want the **server token** itself to be a value you control (rather than retrieving a generated one afterwards):

```bash
./build-ubuntu-k3s-template.sh \
  -c noble \
  -i 9100 \
  -n k3s-master-01 \
  -b vmbr1 \
  -s storage-name \
  -d 20G \
  -m server \
  --k3s-token "mySecretServerToken" \
  --k3s-start
```

A short-format token (just the password portion, no `K10<hash>::` prefix) works exactly as given. If you instead pass a **secure-format** token (`K10<ca-hash>::server:<password>`) — for instance because you copied it from an existing cluster's `/var/lib/rancher/k3s/server/token` — only the `<password>` portion is actually used by K3s when bootstrapping a brand-new server. This isn't a bug in the script: per the [K3s docs](https://docs.k3s.io/cli/token), the CA hash can't be known before the server generates its own self-signed CA, so only the short form is meaningful at this point. The script doesn't strip the prefix for you here — K3s itself does, silently, and the resulting server token (`/var/lib/rancher/k3s/server/token`) will show the short form.

> **Bonus:** if `--k3s-agent-token` is *not* set but `--k3s-token` is, the script automatically derives the agent token from `--k3s-token`'s password portion and configures it as `K3S_AGENT_TOKEN` as well — so agents have a working, static join credential without needing a separate flag in this case.

---

## Scenario C — Plain K3s agent template, joins later via Cloud-Init (dummy values)

This is "Strategy 2" from the `karpenter-proxmox-config-k3s` chart: K3s is pre-installed using placeholder join values, left disabled, and the *real* server URL/token is written later by Cloud-Init at provisioning time.

```bash
./build-ubuntu-k3s-template.sh \
  -c noble \
  -i 9000 \
  -n ubuntu-noble-k3s-agent \
  -b vmbr1 \
  -s storage-name \
  -d 10G \
  -m agent \
  -t
```

No `--k3s-url`, `--k3s-token`, or `--k3s-agent-token` are passed, so the script falls back to `K3S_URL=https://dummy:6443` and `K3S_TOKEN=dummy`. This is what makes the K3s installer create `k3s-agent.service` (agent mode) rather than `k3s.service` (server mode) — see the chart's README for why that distinction matters — while leaving the actual join to whatever writes the real config later.

---

## Scenario D — K3s agent that joins a real cluster immediately

Use this when you want a node that joins an existing cluster as soon as it boots — no Cloud-Init step needed afterwards. Omit `-t` to get a running VM rather than a template, and add `--k3s-start`.

```bash
./build-ubuntu-k3s-template.sh \
  -c noble \
  -i 9200 \
  -n k3s-worker-01 \
  -b vmbr1 \
  -s storage-name \
  -d 20G \
  -m agent \
  --k3s-url https://master.example.local:6443 \
  --k3s-token "mySecretServerToken" \
  --k3s-start
```

`--k3s-agent-token` works the same way if you'd rather join using an agent-only token instead of the server token:

```bash
  --k3s-url https://master.example.local:6443 \
  --k3s-agent-token "myStaticAgentToken" \
  --k3s-start
```

If both `--k3s-token` and `--k3s-agent-token` are given in agent mode, `--k3s-token` takes priority (a warning is printed).

---

## Reference: all options

| Flag | Description |
|---|---|
| `-c`, `--codename` | Ubuntu release codename, e.g. `noble`, `jammy`. |
| `-i`, `--vmid` | Proxmox VM ID. The script exits early if this ID is already in use. |
| `-n`, `--name` | Name of the resulting VM or template. Default: `ubuntu24-k3s-worker`. |
| `-t`, `--template` | Convert the VM into a Proxmox template after build. Omit to keep it as a regular, bootable VM (scenarios B and D). |
| `-s`, `--storage` | Proxmox storage name. Auto-detected (with an interactive prompt if multiple storages are available) if omitted. |
| `-v`, `--vlan` | VLAN tag for the NIC. Default: none. |
| `-d`, `--disk` | Disk size, e.g. `30G`. Default: `30G`. |
| `-b`, `--bridge` | Network bridge. Default: `vmbr0`. |
| `-m`, `--k3s-mode` | `agent`, `server`, or `none`. Default: `none`. |
| `-k`, `--k3sversion` | K3s version, e.g. `v1.35.2+k3s1`. Default: latest stable. |
| `--k3s-url` | (agent mode) Real server URL to join at first boot. Requires `--k3s-token` and/or `--k3s-agent-token`. Omit for dummy join values (scenario C). |
| `--k3s-token` | (server mode) Server token to bootstrap with — see scenario B.3 for secure- vs short-format caveats. (agent mode, with `--k3s-url`) Real server token to join with; takes priority over `--k3s-agent-token` if both are set. |
| `--k3s-agent-token` | (server mode) Separate, static agent-only token — see scenario B.2. If `--k3s-token` is set and this isn't, it's derived automatically from `--k3s-token`. (agent mode, with `--k3s-url`) Real agent token to join with, used only if `--k3s-token` isn't set. |
| `--k3s-start` | Start and enable the K3s service immediately after install, instead of leaving it disabled/stopped. Required for scenarios B and D; omit for scenario C (Karpenter/Cloud-Init starts the service itself once the real config is written). |
| `--cloudinit-drive` | Attach a Proxmox Cloud-Init drive (`scsi1`) to the template. Disabled by default — only enable this if you're **not** using a separate Cloud-Init ISO (e.g. Karpenter's) for networking/users/SSH, since running both at once is redundant and the two sources can conflict. |
| `--ciuser` | Cloud-Init user. Requires `--cloudinit-drive`. |
| `--cipassword` | Cloud-Init password hash, e.g. `$(openssl passwd -6 'secret')`. Requires `--cloudinit-drive`. Proxmox masks this with asterisks in `qm config` output. |
| `--sshkeys` | Public SSH key for Cloud-Init. Requires `--cloudinit-drive`. Accepts either a path to an existing public key file, or the key as a literal string (e.g. `"ssh-ed25519 AAAA... user@host"`) — a literal string is written to a temporary file before being passed to `qm set --sshkeys`, which only accepts a file path. **Always quote this argument** when passing a literal key or any variable holding one — an unquoted key containing spaces will be split into multiple, unrelated arguments by the shell. |

---

## Common pitfalls

- **Unquoted variables on the command line.** `--k3s-token $K3S_TOKEN` and `--sshkeys $ADM_SSH_KEY` (no quotes) are a frequent source of confusing failures — a key or token containing spaces gets word-split by the shell into multiple arguments, and everything after the first space is silently swallowed or misinterpreted as unrelated flags. Always quote: `--k3s-token "$K3S_TOKEN"`, `--sshkeys "$ADM_SSH_KEY"`. Quoting at `export` time does **not** protect a later unquoted use of the variable.
- **`--firstboot-command`, not `--run-command`, is used internally for all K3s install steps.** `virt-customize --run-command` runs while the disk is offline being customized — no network access — so `curl`/`apt` would silently fail. The script always uses `--firstboot-command` for this reason; if you're modifying the script itself, keep this in mind.
- **Server bootstrap and secure-format tokens.** See scenario B.3 — passing a secure-format token (`K10<hash>::server:<password>`) to a brand-new server only honors the `<password>` part. This is K3s behavior, not a script limitation.