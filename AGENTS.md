# Plans and specs

Plans and specs are not part of this repository's history.
`docs/plans` and `docs/specs` point at the homelab parent when this
checkout is a submodule. A session does not commit them.

This repository uses Kobold Codex. Skills live in `.agents/skills/`.

## SQLite apps

An app that keeps its data in SQLite follows the Litestream pattern
of the Vikunja pilot. The database sits on the NFS volume, a
Litestream sidecar replicates it, and a backup CronJob runs beside
it. It does not use a local file claim. Copy the pilot's manifests
before writing new ones.

## Images

A Dockerfile, or any change to what an image installs, belongs in
the images repository (`docker-images`, the `images` submodule of
homelab). This repository only references the tag.
