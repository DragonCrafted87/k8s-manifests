<!-- markdownlint-disable MD013 -->

# Etsy OAuth broker

The broker runs one consent for the Be Boldly Catholic Seller App. Caddy exposes `https://etsy.stealthdragonland.net/oauth/callback`. The pod writes the raw refresh token to Secret `etsy-refresh-token` in namespace `etsy` and keeps nothing else. Scott copies that value into Proton Pass and deletes the Secret. No assistant reads it.

`listings_w` can create and edit listings, including publication. `shops_w` can update the shop description, messages, and sections. Those are the scopes on the consent. The broker does not call the listing or shop endpoints. A later shop write is a separate approval.

The Secret is one Opaque object. Its only data key is `refresh-token`. The annotation `etsy.stealthdragonland.net/exported-at` is the export time in unix seconds. Anyone who can get Secrets in `etsy` can read it, and the API returns it base64-encoded. The broker account can create Secrets in the namespace and can get only this name. It cannot update, patch, delete, or list Secrets. `create` cannot be limited to one object name. The port-forward account cannot get Secrets. An assistant does not print the token, pass it on a command line, or put it in a log, a ticket, or this repository.

## Bounds

| Bound           | Value                              |
| --------------- | ---------------------------------- |
| Pending flows   | 3, in memory, 10 minutes           |
| Callbacks       | 30 in 60 seconds                   |
| Refresh Secret  | 1, named `etsy-refresh-token`      |
| Secret age      | 24 hours blocks a new flow         |
| Expiry deletion | off                                |
| Token response  | 64 KiB, 10 second exchange timeout |
| Replicas        | 1, Recreate                        |

A restart drops pending flows. It leaves the refresh Secret and the vault entry. A Secret that exists, including one at or past 24 hours or one whose shape is not the single refresh key, blocks `POST /flows` until Scott deletes it. The process does not delete it.

## Before apply

1. Merge and publish `ghcr.io/dragoncrafted87/etsy-oauth-broker:1.0.0` from the docker-images tag `etsy-oauth-broker-v1.0.0`. Put that digest on the Deployment before apply.
1. Create the keystring Secret from a shell that does not echo. Do not pass the value as an argument. Do not save a manifest of it. The shared secret stays out. Do not create `etsy-refresh-token` by hand. The broker creates it at the end of consent.

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

`kubectl port-forward` dials `127.0.0.1` inside the pod network namespace. Confirm the private `curl` works, and confirm `https://etsy.stealthdragonland.net:8091/flows` does not. Open the returned URL, signed in as the shop, and approve the four scopes. The browser should show `ok`. `GET /status` on the forwarded port reports `last_export` of `completed` and the Secret name, byte count, and age. It does not return the token.

Copy the Secret into Proton Pass from a keyboard. The first command prints the refresh token. Do not send that output to an assistant. Check the vault entry, then delete the Secret. An assistant does not run the get.

```bash
kubectl -n etsy get secret etsy-refresh-token -o jsonpath='{.data.refresh-token}' | base64 -d
kubectl -n etsy delete secret etsy-refresh-token
```

If the browser shows `error`, or status says `failed`, start a new flow. Do not retry the old callback. A denial, a timed-out exchange, and a failed write all consume that flow.

## Rollback

Restore the previous Caddy ConfigMap and restart `deployment/caddy`. Delete the `etsy` namespace when the Deployment should stop. That deletes the in-memory flows and both Secrets, and leaves the vault entry. Do not have an assistant get `etsy-refresh-token`. Revoking the Etsy grant is a separate approval. Create the keystring Secret again from stdin if the namespace is recreated.
