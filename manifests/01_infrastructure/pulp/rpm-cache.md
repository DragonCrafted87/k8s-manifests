# RPM cache

<!-- markdownlint-disable MD013 -->

Pulp RPM has no pull-through distribution. Each repository the role
enables is one on-demand remote, one repository, and one
distribution. A sync stores metadata. The first client request for
an RPM downloads it into Pulp. The next request is served from that
copy.

`rpm-cache.py` is the source. `25_rpm_cache_job.yml` carries a copy
and creates the objects, then syncs once. `26_rpm_cache_cron.yml`
runs `python3 /opt/rpm-cache.py sync` every six hours and does not
create remotes. The password is `pulp-secret` key `admin-password`.
The user is `admin`.

Apply the Job file first. A second apply leaves the finished Job in
place. Run the script again only after deleting that Job. The
CronJob can stay applied.

A repository that refuses `mirror_complete` is retried as
`mirror_content_only` with autopublish. The client URL does not
change.

## Paths

The content host is `https://pulp.stealthdragonland.net/pulp/content/`.

Rock, znver1:

- `rock/znver1/main/release`
- `rock/znver1/main/updates`
- `rock/znver1/extra/release`
- `rock/znver1/extra/updates`
- `rock/znver1/restricted/release`
- `rock/znver1/restricted/updates`
- `rock/znver1/non-free/release`
- `rock/znver1/non-free/updates`

Rock, x86_64:

- `rock/x86_64/main/release`
- `rock/x86_64/main/updates`
- `rock/x86_64/extra/release`
- `rock/x86_64/extra/updates`
- `rock/x86_64/restricted/release`
- `rock/x86_64/restricted/updates`
- `rock/x86_64/non-free/release`
- `rock/x86_64/non-free/updates`

Other repositories:

- `brave/x86_64`
- `vscode`
- `adoptium/rhel/9/x86_64`

Upstream for Rock is `http://mirror.openmandriva.org` only.
`abf-downloads.openmandriva.org` is not a second remote. Cooker,
rolling, source, and debuginfo are not in this list. The homelab
repository at `homelab/` is not an on-demand remote.

## Check

After the Job succeeds, from a machine that resolves
`pulp.stealthdragonland.net`:

```sh
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://pulp.stealthdragonland.net/pulp/content/rock/znver1/main/release/repodata/repomd.xml
```

The code is 200. Repeat that check for `brave/x86_64`, `vscode`,
and `adoptium/rhel/9/x86_64`. Download one package from each tree
twice. The second download is served from Pulp.
