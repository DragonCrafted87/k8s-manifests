<!-- markdownlint-disable MD013 -->

# Etsy OAuth broker

The broker runs one consent for the Be Boldly Catholic Seller App. Caddy exposes `https://etsy.stealthdragonland.net/oauth/callback`. The pod writes the raw refresh token to `hoard-drake:/srv/data/etsy-oauth` and keeps nothing else. Scott copies that file into Proton Pass. No assistant reads the file.

`listings_w` can create and edit listings, including publication. `shops_w` can update the shop description, messages, and sections. Those are the scopes on the consent. The broker does not call the listing or shop endpoints. A later shop write is a separate approval.

The handoff uses the existing export `/srv/data` to `192.168.0.0/20` with `no_root_squash`. Root on a client in that range can read the file. The process does not open an existing handoff file. An assistant does not print the token, pass it on a command line, or put it in a log, a ticket, or this repository.

## Bounds

| Bound           | Value                              |
| --------------- | ---------------------------------- |
| Pending flows   | 3, in memory, 10 minutes           |
| Callbacks       | 30 in 60 seconds                   |
| Handoff files   | 1                                  |
| Handoff age     | 24 hours blocks a new flow         |
| Expiry deletion | off                                |
| Token response  | 64 KiB, 10 second exchange timeout |
| Replicas        | 1, Recreate                        |

A restart drops pending flows. It leaves handoff files, snapshots, and vault entries. A file at or past 24 hours, a second file, or a `.partial-` name blocks `POST /flows` until Scott removes it. The process does not delete those names.

## Before apply

1. Merge and publish `ghcr.io/dragoncrafted87/etsy-oauth-broker:1.0.0` from the docker-images tag `etsy-oauth-broker-v1.0.0`. Put that digest on the Deployment before apply.
1. Create the handoff directory on hoard-drake. The broker uid is 1000.

```bash
sudo install -d -o 1000 -g 1000 -m 0700 /srv/data/etsy-oauth
```

1. Create the keystring Secret from a shell that does not echo. Do not pass the value as an argument. Do not save a manifest of it. The shared secret stays out.

```bash
read -rs PW && printf %s "$PW" | kubectl -n etsy create secret generic etsy-keystring --from-file=keystring=/dev/stdin; unset PW
kubectl -n etsy get secret etsy-keystring -o jsonpath='{.data.keystring}' | base64 -d | wc -c
```

Compare the count with the keystring length. The second command prints the count only when the pipe ends at `wc`. Run it only where that count is the output you keep, and do not append the decoded value to a file.

1. Confirm house DNS. mist-dragon already has a dhcp domain for `etsy.stealthdragonland.net` at `192.168.8.11`. `dig @192.168.0.1 etsy.stealthdragonland.net` returns that address. Public DNS returns the VPN relay. Caddy obtains the certificate after the site block is loaded.
1. Apply `manifests/etsy/` and the Caddy ConfigMap. The Caddyfile is mounted with `subPath`, so restart `deployment/caddy` in `infrastructure` after the ConfigMap is applied. Validate the Caddyfile with `caddy:2.7.6-alpine` before that restart. Do not apply `later/`.

Caddy stays on `2.7.6`. Its error log includes `request.uri`. The global log block deletes the `code`, `state`, `error`, `error_description`, and `error_uri` query parameters from that field. Access logs stay off. The cluster does not enforce NetworkPolicy, so this change does not add one. The callback Service is ClusterIP. Port 8091 is bound to `127.0.0.1` in the pod and has no Service.

## Consent

Register `https://etsy.stealthdragonland.net/oauth/callback` on the Seller App before consent. The match is exact, including case and the absence of a trailing slash.

```bash
kubectl -n etsy port-forward deploy/etsy-oauth-broker 8091:8091
curl --silent --show-error -X POST http://127.0.0.1:8091/flows
```

`kubectl port-forward` dials `127.0.0.1` inside the pod network namespace. Confirm the private `curl` works, and confirm `https://etsy.stealthdragonland.net:8091/flows` does not. Open the returned URL, signed in as the shop, and approve the four scopes. The browser should show `ok`. `GET /status` on the forwarded port reports `last_export` of `completed` and the file name and size. It does not return the token.

On hoard-drake, as root, copy the file contents into Proton Pass, check the vault entry, then remove the file. Unlinking does not remove a snapshot or a backup of `/srv/data`. A terminal print of the token is not the handoff.

If the browser shows `error`, or status says `failed`, start a new flow. Do not retry the old callback. A denial, a timed-out exchange, and a failed write all consume that flow.

## Rollback

Restore the previous Caddy ConfigMap and restart `deployment/caddy`. Delete the `etsy` namespace when the Deployment should stop. That deletes the in-memory flows and leaves `/srv/data/etsy-oauth` and the vault entry. Do not have an assistant inspect the handoff file. Revoking the Etsy grant is a separate approval. The keystring Secret is deleted with the namespace. Create it again from stdin if the namespace is recreated.
