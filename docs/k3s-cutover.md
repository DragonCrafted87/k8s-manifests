# microk8s → k3s cutover (wipe and reprovision)

<!-- markdownlint-disable MD013 -->

Two of the current cluster boxes get a **new OS**, not an in-place upgrade. `192.168.0.54` (Ryzen 5, the workhorse) becomes the k3s server. `192.168.0.51` (old Intel NUC) becomes a dedicated Home Assistant OS box, not a k3s node. `192.168.0.53` (AMD Phenom II) is decommissioned and not reinstalled. The DL360p Gen8 is a separate chassis waiting on two 460 W supplies. Once that chassis and its RAID are up, it becomes the NFS server. It does not take `.53`, and it is not a k3s server. The k3s server's name is `roost-drake`. The NUC's name is `ward-drake`. The DL360p's name, when it takes NFS, is `hoard-drake`. Set the FQDN before the first install. OpenWrt work from Sep 2026 stays put if the VIP and the two surviving node IPs stay put.

Related: `router-rescue.md` and `network-rack-plan.md` in this directory. Specs, storage moves, and the drake hostnames are in `docs/plans/2026-10-03-k3s-and-image-consolidation.md`.

## What the router actually depends on

Not microk8s vs k3s. Not Calico vs Flannel. These three:

1. Stable node IPs (DHCP reservations).
1. MetalLB-style VIPs on `192.168.8.0/24` on the same L2 as LAN (`192.168.0.0/16` on the NIC).
1. Caddy still at **`192.168.8.11`** (socat target on mist-dragon).

| Piece                       | Must stay the same                                                                         |
| --------------------------- | ------------------------------------------------------------------------------------------ |
| Nodes                       | Server `192.168.0.54` only. `.51` is Home Assistant. `.53` is retired.                     |
| VIP pool                    | `192.168.8.0/24`                                                                           |
| Caddy LB                    | `192.168.8.11` TCP/UDP 80/443                                                              |
| Minecraft (if still DNATed) | `192.168.8.41` port 25565                                                                  |
| Node default route          | DHCP option 121 includes `0.0.0.0/0,192.168.0.1` plus `192.168.8.0/24` and `192.168.100.1` |
| Site DNS                    | Unbound `local-zone: stealthdragonland.net typetransparent` + dnsmasq `@domain` A records  |

Socat: bind `tun0` address → `192.168.8.11`. If Caddy moves off `.11`, change **one** line in `/etc/init.d/vpn-relay`.

## Freeze on OpenWrt during the wipe

Do **not** change while nodes are down:

- DHCP reservations for `.51` and `.54` (drop `.53` only once that host is powered off)
- option 121 / 249 on `dhcp.lan`
- Unbound + dnsmasq **site** names → `192.168.8.x`
- socat (`vpn-relay`), table 100, `ip rule from <tun0-ip> table 100 priority 140`
- `99-no-tun-default` (strip `0.0.0.0/1` so LAN default stays Starlink)
- LuCI on **8080 / 8443**
- HTTP/HTTPS VPN redirects **disabled**
- firewall rule `VPN-HTTP-S` accept tcp 80,443 from zone `vpn`

Update **hostnames** on the router **before** the first new node boots (next section).

## Hostnames: drop `.lan`, use stealthdragonland.net

Node name is taken at k3s join. Set FQDN on the new OS **before** installing k3s.

Suggested (short labels; keep old amd64nodeN if you prefer):

| IP           | Hardware      | FQDN                                | Role              |
| ------------ | ------------- | ----------------------------------- | ----------------- |
| 192.168.0.54 | Ryzen 5       | `roost-drake.stealthdragonland.net` | k3s server        |
| 192.168.0.51 | Intel NUC     | `ward-drake.stealthdragonland.net`  | Home Assistant OS |
| 192.168.0.53 | AMD Phenom II | none                                | off               |

Public DNS should **not** publish these as A records to `192.168.0.x`. Split-horizon on the router already maps `*.stealthdragonland.net` internally. External users keep hitting Caddy / the VPN IP, not node FQDNs.

### Router DNS (before first boot)

- `dhcp-host` `name=` → `roost-drake` on `.54` and `ward-drake` on `.51`, same MACs. `ward-drake` is not a k3s node name.
- `dhcp.@domain` A record for `roost-drake.stealthdragonland.net` → `192.168.0.54`, and for `ward-drake.stealthdragonland.net` → `192.168.0.51`.
- Remove `amd64node*.lan` domain entries only after `.51`, `.53`, and `.54` are powered off. Leave Unbound `local-zone: stealthdragonland.net transparent`.
- Do **not** set `local-zone: "stealthdragonland.net." static` (breaks AAAA / public names). Keep `typetransparent`.
- Drop extra `domain_insecure` / `private_domain` `'lan'` if nothing else uses `.lan`.
- `uci commit dhcp; service dnsmasq restart; service unbound restart`

Optional Unbound extras (same file as dishy, inside `server:`):

```yml
local-data: "roost-drake.stealthdragonland.net. 3600 IN A 192.168.0.54"
local-data: "ward-drake.stealthdragonland.net. 3600 IN A 192.168.0.51"
```

DHCP search domain is already `stealthdragonland.net`, so short names resolve on LAN.

### New OS on each node

```sh
# on .54
hostnamectl set-hostname roost-drake.stealthdragonland.net
# /etc/hosts
127.0.1.1 roost-drake.stealthdragonland.net roost-drake
# on .51, Home Assistant OS, not k3s
# hostname: ward-drake.stealthdragonland.net
hostname -f   # must be the FQDN
```

Keep the NIC `/16` (or take the same DHCP lease). After first lease:

```sh
ip route | grep default          # via 192.168.0.1
ip route | grep 192.168.8        # via 192.168.0.1 from option 121
```

Same MAC → same reservation. If a NIC is replaced, update `dhcp-host` MAC.

## Snapshot before wipe (workstation)

```sh
kubectl get svc -A -o wide
kubectl get ipaddresspools.metallb.io -A -o yaml
kubectl get l2advertisements.metallb.io -A -o yaml
kubectl get nodes -o wide
kubectl get ingress -A
```

Also copy off-box:

- Manifests / Helm values / secrets (git if already there)
- Exact LoadBalancer IPs per Service
- Caddy certs / PVC data if they only live on-cluster
- Any hostPath data still needed

Do **not** bother copying kubeconfig, Calico state, or the microk8s snap.

Known LB IPs from the old cluster (re-pin these):

| Service               | IP           |
| --------------------- | ------------ |
| caddy-tcp / caddy-udp | 192.168.8.11 |
| home-assistant        | 192.168.8.20 |
| mqtt                  | 192.168.8.21 |
| weather               | 192.168.8.22 |
| jellyfin-tcp          | 192.168.8.30 |
| prayers-tcp           | 192.168.8.31 |
| minecraft-vpp (+ udp) | 192.168.8.41 |
| minecraft-redstone    | 192.168.8.42 |
| kimai-tcp             | 192.168.8.50 |

Spare VIP `192.168.8.10` can run a second Caddy if old and new clusters overlap for an hour; flip socat when ready.

## k3s choices that would force router rework

Avoid these:

- Enabling k3s **Traefik** (it will fight for 80/443 on the nodes). Use `--disable traefik`.
- Enabling k3s **ServiceLB** *and* MetalLB on the same IPs. MetalLB only, same `IPAddressPool`.
- Shrinking the NIC to `/24` without option 121 for `192.168.8.0/24`.
- Renaming nodes after join.
- Pointing kubeconfig or apps at the old ClusterIP `10.152.183.1`. Use `https://roost-drake.stealthdragonland.net:6443`.

CNI change (Calico `10.1.0.0/16` + ClusterIP `10.152.183.0/24` → Flannel `10.42.0.0/16` + `10.43.0.0/16`) is **on-node only**. The router never routed those prefixes. Nodes still need `default via 192.168.0.1`.

## Cutover order

1. Router hostname/DNS updates; OpenWrt VPN/socat/121 left alone.
1. Copy data off old disks.
1. Wipe boxes, install OS, set FQDN, confirm DHCP + default + `192.168.8.0/24` route.
1. Install one k3s server on `.54` (`--disable traefik`, `--disable servicelb`, default datastore). Install Home Assistant OS on `.51` and do not join it to k3s. All three current nodes are microk8s dqlite masters, so leave `.51` and `.53` up until this same window. Power `.53` off then and remove its reservation. The enclosure disks are wiped into calligraphy-wyrm's JBOD after that. Their Greyhole copies already live on that host. Leave the DL360p out until both PSUs have passed a pull test. NFS stays on castellan through this step. Leave MQTT, weather, speedtest, and starlink off until the Home Assistant config is converted.
1. MetalLB with the old pool; recreate Services with `spec.loadBalancerIP` (Caddy `.11` first).
1. From runewyrm: `nslookup roost-drake.stealthdragonland.net`, `curl -vk https://foundry.stealthdragonland.net/`, then phone LTE.
1. Only if `.11` is wrong, edit socat target.

## Post-cutover checks

```sh
nslookup roost-drake.stealthdragonland.net # A 192.168.0.54, no SERVFAIL
nslookup ward-drake.stealthdragonland.net  # A 192.168.0.51, no SERVFAIL
nslookup foundry.stealthdragonland.net   # A 192.168.8.11
ping -c2 192.168.8.11
curl -vk --connect-timeout 5 https://foundry.stealthdragonland.net/
```

On mist-dragon: `ip rule` has `from <tun0-ip> lookup 100`; `netstat -lnt` shows socat on that IP `:80`/`:443`; phone SYN-ACK visible on `tcpdump -ni tun0 port 443`.
