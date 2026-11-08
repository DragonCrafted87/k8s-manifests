<!-- markdownlint-disable MD013 -->

# Etsy OAuth broker

The broker keeps a shop consent for the Be Boldly Catholic Seller App. Caddy exposes `https://etsy.stealthdragonland.net/oauth/callback`. The pod stores the access token in Secret `etsy-access-token` and the refresh token in Secret `etsy-refresh-token`. It refreshes the access token before expiry and saves the rotated refresh token. Scott puts the `etsy-token-reader` kubeconfig in Proton Pass. The bot uses that account to read the access token. No assistant reads either Etsy token or the reader token.

`listings_w` can create and edit listings, including publication. `shops_w` can update the shop description, messages, and sections. Those are the scopes on the consent. The broker does not call the listing or shop endpoints. A later shop write is a separate approval.

`etsy-access-token` has one data key, `access-token`. `etsy-refresh-token` has one data key, `refresh-token`. Both carry `etsy.stealthdragonland.net/expires-at`. The reader account can get only `etsy-access-token`. The broker account can get and update those two names. It cannot list or delete Secrets, and it cannot get the keystring or the reader token. `create` cannot be limited to one object name. The port-forward account cannot get Secrets. An assistant does not print a token, pass it on a command line, or put it in a log, a ticket, or this repository.

## Bounds

| Bound          | Value                              |
| -------------- | ---------------------------------- |
| Pending flows  | 3, in memory, 10 minutes           |
| Callbacks      | 30 in 60 seconds                   |
| Access Secret  | `etsy-access-token`, kept current  |
| Refresh Secret | `etsy-refresh-token`, rotated      |
| Refresh lead   | 5 minutes before `expires_at`      |
| Token response | 64 KiB, 10 second exchange timeout |
| Replicas       | 1, Recreate                        |

A restart drops pending flows and leaves both token Secrets. The process refreshes again from the stored refresh token. A new consent replaces both Secrets. The process does not delete them.

## Before apply

1. Merge and publish `pulp.stealthdragonland.net/ghcr.io/dragoncrafted87/etsy-oauth-broker:1.1.0` from the docker-images tag `etsy-oauth-broker-v1.1.0`. Put that digest on the Deployment before apply. The Deployment already names the Pulp mirror.
1. Create the keystring Secret from a shell that does not echo. Do not pass the value as an argument. Do not save a manifest of it. The shared secret stays out. Do not create `etsy-refresh-token` by hand. The broker creates it at the end of consent.

```bash
read -rs PW && printf %s "$PW" | kubectl -n etsy create secret generic etsy-keystring --from-file=keystring=/dev/stdin; unset PW
kubectl -n etsy get secret etsy-keystring -o jsonpath='{.data.keystring}' | base64 -d | wc -c
```

Compare the count with the keystring length. The second command prints the count only when the pipe ends at `wc`. Run it only where that count is the output you keep, and do not append the decoded value to a file.

1. Confirm house DNS. mist-dragon already has a dhcp domain for `etsy.stealthdragonland.net` at `192.168.8.11`. `dig @192.168.0.1 etsy.stealthdragonland.net` returns that address. Public DNS returns the VPN relay. Caddy obtains the certificate after the site block is loaded.
1. Apply `manifests/etsy/`. `10_caddy_config.yml` is a full copy of the Caddyfile, including the callback site, and it replaces ConfigMap `caddy-configuration`. Keep it aligned with `manifests/01_infrastructure/caddy/10_config.yml`. The Caddyfile is mounted with `subPath`, so restart `deployment/caddy` in `infrastructure` after that ConfigMap is applied. Validate the Caddyfile with `caddy:2.7.6-alpine` before that restart. Do not apply `later/`.

Caddy stays on `2.7.6`. Its error log includes `request.uri`. The global log block deletes the `code`, `state`, `error`, `error_description`, `error_uri`, and `iss` query parameters from that field. Access logs stay off. The cluster does not enforce NetworkPolicy, so this change does not add one. The callback Service is ClusterIP. Port 8091 is bound to `127.0.0.1` in the pod and has no Service.

## Consent

Register `https://etsy.stealthdragonland.net/oauth/callback` on the Seller App before consent. The match is exact, including case and the absence of a trailing slash.

```bash
kubectl -n etsy port-forward deploy/etsy-oauth-broker 8091:8091
curl --silent --show-error -X POST http://127.0.0.1:8091/flows
```

`kubectl port-forward` dials `127.0.0.1` inside the pod network namespace. Confirm the private `curl` works, and confirm `https://etsy.stealthdragonland.net:8091/flows` does not. Open the returned URL, signed in as the shop, and approve the four scopes. The browser should show `ok`. `GET /status` on the forwarded port reports `last_export` of `completed` and token sizes and `expires_at`. It does not return a token.

Copy the reader credential into Proton Pass from a keyboard. This prints the ServiceAccount token, not the Etsy token. Do not send that output to an assistant. The bot kubeconfig uses that token, the cluster CA, and the API address. The account can get only `etsy-access-token`.

```bash
kubectl -n etsy get secret etsy-token-reader -o jsonpath='{.data.token}' | base64 -d
kubectl -n etsy get secret etsy-token-reader -o jsonpath='{.data.ca\.crt}' | base64 -d
```

If the browser shows `error`, or status says `failed`, start a new flow. Do not retry the old callback. A denial, a timed-out exchange, and a failed write all consume that flow.

## Rollback

Restore the previous Caddy ConfigMap and restart `deployment/caddy`. Delete the `etsy` namespace when the Deployment should stop. That deletes the in-memory flows, the token Secrets, and the reader token, and leaves the vault entry. Do not have an assistant get `etsy-access-token`, `etsy-refresh-token`, or `etsy-token-reader`. Revoking the Etsy grant is a separate approval. Create the keystring Secret again from stdin if the namespace is recreated.
