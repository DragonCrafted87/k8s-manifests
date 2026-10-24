# Container pull-through

<!-- markdownlint-disable MD013 -->

Pulp container pull-through is one remote and one distribution per
upstream registry. A client pull creates the local copy. Nothing is
synced ahead of time.

The calls are the ones in the container plugin guide:

<https://pulpproject.org/pulp_container/docs/admin/guides/pull-through-caching/>

`pulp-cli` 0.41.1 cannot create these objects. `pulp container remote create` requires `--upstream-name` and has no pull-through
type (<https://github.com/pulp/pulp-cli/issues/1034>).
`pull-through.py` calls the REST endpoints from that guide. The
password is `pulp-secret` key `admin-password`. The user is `admin`.

Applying `24_pull_through_job.yml` runs the script once. A second
apply leaves the finished Job in place. Run the script again only
after deleting that Job.

## Paths

`docker.io` base path `docker.io`, upstream
`https://registry-1.docker.io`.

`ghcr.io` base path `ghcr.io`, upstream `https://ghcr.io`.

Add another registry by appending one tuple in `pull-through.py` and
the ConfigMap in the Job, then deleting and applying the Job.

A Docker Hub official image is `library/<name>` under that base path.
The guide's example is
`podman pull <host>/docker-cache/library/busybox`.
Here the host is `pulp.stealthdragonland.net` and the base path is
`docker.io`:

```text
pulp.stealthdragonland.net/docker.io/library/mysql@sha256:76f0358884cb92d9a086d24e5671c38048d3fef40f2588703d73eb55392d6b69
pulp.stealthdragonland.net/docker.io/tuleap/tuleap-community-edition@sha256:cf76fdd71b720a202d94b1053ed4069a1c8fec14bf93c143ede2820c3cd67b51
pulp.stealthdragonland.net/ghcr.io/<owner>/<name>:<tag>
```

Caddy already sends `/v2/`, `/token/`, and `/extensions/v2/` on
`pulp.stealthdragonland.net` to the API port, and
`TOKEN_AUTH_DISABLED` is set. A pull of a name whose registry host
is `pulp.stealthdragonland.net` talks to that host directly.

k3s does not need a `registries.yaml` mirror for these names. A
mirror entry would matter only if a manifest still said `docker.io`
or `ghcr.io` and containerd had to rewrite that host. Do not edit
node `registries.yaml` for this change. The Pulp certificate is the
public Let's Encrypt certificate Caddy already serves, so the nodes
do not need an insecure-registry exception.

## Check

After the Job succeeds, from a machine that resolves
`pulp.stealthdragonland.net`:

```sh
docker pull pulp.stealthdragonland.net/docker.io/tuleap/tuleap-community-edition@sha256:cf76fdd71b720a202d94b1053ed4069a1c8fec14bf93c143ede2820c3cd67b51
```

The pull must report that digest. The same digest is what Docker Hub
publishes for `tuleap/tuleap-community-edition:latest`.
