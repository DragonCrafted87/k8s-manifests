#!/usr/bin/env python3
"""Fixture for rpm-cache.py. The Pulp API is replaced in-process."""

import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("rpm_cache", HERE / "rpm-cache.py")
rpm_cache = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rpm_cache)


def fail(message):
    """Stop the fixture."""
    sys.exit(message)


class Api:
    """Record calls and answer the handful of objects a run needs."""

    def __init__(self, repos):
        self.repos_wanted = repos
        self.remotes = {}
        self.repositories = {}
        self.distributions = {}
        self.posts = []
        self.syncs = []
        self.refuse = set()
        self.fail_sync = set()

    def request(self, method, path, body=None):
        """Answer one Pulp call."""
        if method == "GET" and path.startswith(rpm_cache.REMOTES):
            return 200, {"results": list(self.remotes.values())}
        if method == "GET" and path.startswith(rpm_cache.REPOSITORIES):
            return 200, {"results": list(self.repositories.values())}
        if method == "GET" and path.startswith(rpm_cache.DISTRIBUTIONS):
            return 200, {"results": list(self.distributions.values())}
        if method == "POST" and path == rpm_cache.REMOTES:
            self.posts.append(("remote", body))
            remote = {
                "name": body["name"],
                "url": body["url"],
                "policy": body["policy"],
                "pulp_href": f"/pulp/api/v3/remotes/rpm/rpm/{body['name']}/",
            }
            self.remotes[body["name"]] = remote
            return 201, remote
        if method == "POST" and path == rpm_cache.REPOSITORIES:
            self.posts.append(("repository", body))
            repo = {
                "name": body["name"],
                "autopublish": body["autopublish"],
                "pulp_href": f"/pulp/api/v3/repositories/rpm/rpm/{body['name']}/",
            }
            self.repositories[body["name"]] = repo
            return 201, repo
        if method == "POST" and path == rpm_cache.DISTRIBUTIONS:
            self.posts.append(("distribution", body))
            dist = {
                "name": body["name"],
                "base_path": body["base_path"],
                "pulp_href": f"/pulp/api/v3/distributions/rpm/rpm/{body['name']}/",
            }
            self.distributions[body["name"]] = dist
            return 201, dist
        if method == "POST" and path.endswith("/sync/"):
            name = path.split("/")[-3]
            policy = body["sync_policy"]
            self.syncs.append((name, policy))
            if name in self.fail_sync and policy == "mirror_complete":
                return 202, {"task": f"/pulp/api/v3/tasks/{name}-fail/"}
            if name in self.refuse and policy == "mirror_complete":
                return 202, {"task": f"/pulp/api/v3/tasks/{name}-refuse/"}
            return 202, {"task": f"/pulp/api/v3/tasks/{name}-ok/"}
        if method == "GET" and "/tasks/" in path:
            if path.endswith("-refuse/"):
                return 200, {
                    "state": "failed",
                    "error": {
                        "description": "mirror_complete is not supported for this repository"
                    },
                }
            if path.endswith("-fail/"):
                return 200, {
                    "state": "failed",
                    "error": {"description": "connection timed out"},
                }
            return 200, {"state": "completed", "created_resources": []}
        if method == "PATCH":
            name = path.rstrip("/").split("/")[-1]
            self.posts.append(("patch", body))
            self.repositories[name]["autopublish"] = True
            return 200, self.repositories[name]
        fail(f"unexpected {method} {path}")


def use(api):
    """Point the script at this fake API."""
    rpm_cache.request = api.request
    rpm_cache.PASSWORD = "fixture"


def test_catalog():
    """The script lists the nineteen repositories the role enables."""
    if len(rpm_cache.REPOS) != 19:
        fail(f"expected 19 repositories, found {len(rpm_cache.REPOS)}")
    paths = {row[2] for row in rpm_cache.REPOS}
    for arch in ("znver1", "x86_64"):
        for tail in (
            "main/release",
            "main/updates",
            "extra/release",
            "extra/updates",
            "restricted/release",
            "restricted/updates",
            "non-free/release",
            "non-free/updates",
        ):
            base = f"rock/{arch}/{tail}"
            if base not in paths:
                fail(f"missing {base}")
    for base in ("brave/x86_64", "vscode", "adoptium/rhel/9/x86_64"):
        if base not in paths:
            fail(f"missing {base}")
    names = [row[0] for row in rpm_cache.REPOS]
    if len(names) != len(set(names)):
        fail("repository names are not unique")


def test_creates_on_demand():
    """A missing remote is created with policy on_demand."""
    row = rpm_cache.REPOS[0]
    rpm_cache.REPOS = (row,)
    api = Api((row,))
    use(api)
    rpm_cache.run(True)
    remote_posts = [body for kind, body in api.posts if kind == "remote"]
    if len(remote_posts) != 1:
        fail("missing remote was not created once")
    if remote_posts[0]["policy"] != "on_demand":
        fail("remote was not on_demand")
    if remote_posts[0]["url"] != row[1]:
        fail("remote URL drifted")
    if api.syncs != [(row[0], "mirror_complete")]:
        fail(f"sync policy drifted: {api.syncs}")


def test_existing_remote_stays():
    """An existing remote with the same URL is not posted again."""
    row = ("rock-znver1", "http://mirror.example/rock/", "rock/znver1/main/release")
    rpm_cache.REPOS = (row,)
    api = Api((row,))
    api.remotes[row[0]] = {
        "name": row[0],
        "url": row[1],
        "policy": "on_demand",
        "pulp_href": "/pulp/api/v3/remotes/rpm/rpm/rock-znver1/",
    }
    use(api)
    rpm_cache.run(True)
    if any(kind == "remote" for kind, _body in api.posts):
        fail("existing remote was created again")
    if api.syncs != [(row[0], "mirror_complete")]:
        fail("existing remote was not synced")


def test_url_mismatch_stops_before_sync():
    """A different URL stops the run before any sync."""
    row = ("rock-znver1", "http://mirror.example/rock/", "rock/znver1/main/release")
    rpm_cache.REPOS = (row,)
    api = Api((row,))
    api.remotes[row[0]] = {
        "name": row[0],
        "url": "http://somewhere.else/rock/",
        "policy": "on_demand",
        "pulp_href": "/pulp/api/v3/remotes/rpm/rpm/rock-znver1/",
    }
    use(api)
    try:
        rpm_cache.run(True)
    except SystemExit as err:
        if "somewhere.else" not in str(err):
            fail(f"unexpected stop: {err}")
    else:
        fail("URL mismatch did not stop the run")
    if api.syncs:
        fail("URL mismatch synced")
    if api.posts:
        fail("URL mismatch created an object")


def test_fallback_is_per_repository():
    """Only the repository that refuses mirror_complete changes policy."""
    first = ("rock-znver1", "http://mirror.example/a/", "rock/znver1/main/release")
    second = ("rock-x86_64", "http://mirror.example/b/", "rock/x86_64/main/release")
    rpm_cache.REPOS = (first, second)
    api = Api((first, second))
    api.refuse.add(first[0])
    use(api)
    rpm_cache.run(True)
    if api.syncs != [
        (first[0], "mirror_complete"),
        (first[0], "mirror_content_only"),
        (second[0], "mirror_complete"),
    ]:
        fail(f"fallback touched the wrong repository: {api.syncs}")
    if api.repositories[first[0]]["autopublish"] is not True:
        fail("refused repository did not turn autopublish on")
    if api.repositories[second[0]]["autopublish"] is not False:
        fail("the other repository changed autopublish")


def test_other_sync_error_does_not_fall_back():
    """A timeout is not treated as a mirror_complete refusal."""
    row = ("rock-znver1", "http://mirror.example/rock/", "rock/znver1/main/release")
    rpm_cache.REPOS = (row,)
    api = Api((row,))
    api.fail_sync.add(row[0])
    use(api)
    try:
        rpm_cache.run(True)
    except SystemExit as err:
        if "connection timed out" not in str(err):
            fail(f"unexpected stop: {err}")
    else:
        fail("sync error did not stop the run")
    if api.syncs != [(row[0], "mirror_complete")]:
        fail(f"timeout fell back: {api.syncs}")


def test_sync_mode_does_not_create():
    """The cron path does not create a missing remote."""
    row = rpm_cache.REPOS[0]
    rpm_cache.REPOS = (row,)
    api = Api((row,))
    use(api)
    try:
        rpm_cache.run(False)
    except SystemExit as err:
        if "missing" not in str(err):
            fail(f"unexpected stop: {err}")
    else:
        fail("sync mode created a missing remote")
    if api.posts or api.syncs:
        fail("sync mode posted or synced while an object was missing")


def main():
    """Run every branch, restoring the repository list afterward."""
    saved = rpm_cache.REPOS
    test_catalog()
    try:
        test_creates_on_demand()
        rpm_cache.REPOS = saved
        test_existing_remote_stays()
        test_url_mismatch_stops_before_sync()
        test_fallback_is_per_repository()
        test_other_sync_error_does_not_fall_back()
        rpm_cache.REPOS = saved
        test_sync_mode_does_not_create()
    finally:
        rpm_cache.REPOS = saved
    print("rpm cache ok")


if __name__ == "__main__":
    main()
