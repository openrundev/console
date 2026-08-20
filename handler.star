# Copyright (c) ClaceIO, LLC
# SPDX-License-Identifier: Apache-2.0
load("openrun.in", "openrun")
load("openrun_admin.in", "openrun_admin")
load("build.in", "build")
load("utils.star", "utils")

# Route handlers for the console. Each screen has a *_data function which
# builds the full page context; action handlers run the mutation and re-render
# the same context with a Flash/FlashError message. Mutation results must read
# ret.error BEFORE the *_data call: an unread plugin error fails the next
# plugin call. The error_handler in app.star is the fallback when that is
# missed.


# ---------- Overview ----------


def ov_can(perms, perm):
    # True when the caller holds perm (or the admin super-user permission)
    return bool(perms.get(perm) or perms.get("admin"))


def ov_running(entries):
    # Count of container entries in the running state
    running = 0
    for entry in entries:
        if entry["state"] == "running":
            running += 1
    return running


def ov_uptime(secs):
    # Compact uptime for the stat tile: "42m", "3h 12m", "12d 4h"
    secs = int(secs)
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 86400:
        return "%dh %dm" % (secs // 3600, (secs % 3600) // 60)
    return "%dd %dh" % (secs // 86400, (secs % 86400) // 3600)


def ov_trim_time(t):
    # Timestamps are time.time values, passed through to the templates; the
    # go zero time (unset) maps to ""
    return utils.nonzero_time(t)


def ov_apps_tile(perms):
    # Big apps tile: totals, prod/dev/declarative split, pending promotion
    # count and a by-spec mini bar chart. Uses plain list_apps (the
    # check_approval audit sweep is too slow for a landing page; the
    # needs-approval chip lazy-loads via overview_approvals_handler).
    # Tiles the user cannot read return None and are OMITTED from the
    # page (overview shows only accessible info, unlike the
    # disabled-with-tooltip convention for action controls)
    if not ov_can(perms, "app:read"):
        return None
    ret = openrun.list_apps(include_internal=True)
    if ret.error:
        return {"Error": ret.error}
    rows = build_app_rows(ret.value)

    dev = 0
    promote = 0
    spec_counts = {}
    for row in rows:
        if row["is_dev"]:
            dev += 1
        if row["staging"] and row["staging"]["ahead"]:
            promote += 1
        spec = row["spec"] or "custom"
        spec_counts[spec] = spec_counts.get(spec, 0) + 1

    specs = sorted(spec_counts.items(), key=lambda kv: (-kv[1], kv[0]))
    top = specs[:4]
    other = 0
    for _, count in specs[4:]:
        other += count
    max_count = other
    for _, count in top:
        max_count = max(max_count, count)
    by_spec = []
    for name, count in top:
        by_spec.append({"label": name, "count": count,
                        "pct": count * 100 // max_count, "other": False})
    if other:
        by_spec.append({"label": "other", "count": other,
                        "pct": other * 100 // max_count, "other": True})

    return {
        "Total": len(rows),
        "Prod": len(rows) - dev,
        "Dev": dev,
        "Promote": promote,
        "BySpec": by_spec,
    }


def ov_syncs_tile(perms):
    # Sync health: one status dot per sync entry, failing entries first
    if not ov_can(perms, "sync:read"):
        return None
    ret = openrun.list_sync()
    if ret.error:
        return {"Error": ret.error}

    entries = []
    failing = 0
    disabled = 0
    for entry in ret.value:
        state = entry["status"]["state"]  # Enabled / Disabled / Failing
        if state == "Failing":
            failing += 1
        elif state == "Disabled":
            disabled += 1
        entries.append({
            "id": entry["id"],
            "repo": entry["path"],
            "state": state,
            "last_exec": ov_trim_time(entry["status"]["last_execution_time"]),
            "error": entry["status"].get("error") or "",
        })
    order = {"Failing": 0, "Enabled": 1, "Disabled": 2}
    entries = sorted(entries, key=lambda e: (order.get(e["state"], 3), e["repo"]))
    return {
        "Total": len(entries),
        "Failing": failing,
        "Disabled": disabled,
        "Ok": len(entries) - failing - disabled,
        "Syncs": entries[:12],
        "More": max(0, len(entries) - 12),
    }


def ov_services_tile(perms):
    # Services and bindings counts (tiny table scans)
    tile = {}
    if ov_can(perms, "service:read"):
        ret = openrun.list_services()
        if not ret.error:
            tile["Services"] = len(ret.value)
    if ov_can(perms, "binding:read"):
        ret = openrun.list_bindings()
        if not ret.error:
            bindings = ret.value
            auto = 0
            for b in bindings:
                if b["path"].startswith("/auto/"):
                    auto += 1
            tile["Bindings"] = len(bindings)
            tile["Auto"] = auto
    if "Services" not in tile and "Bindings" not in tile:
        return None
    return tile


def ov_server_tile(perms):
    # Server identity chips + metadata replication state, all in-memory
    # server-side (server_info never touches the DB or external services).
    # config:basic_read is implied by config:read, but get_permissions
    # reports held permissions literally, so both are checked
    if not (ov_can(perms, "config:basic_read") or perms.get("config:read")):
        return None
    ret = openrun.server_info()
    if ret.error:
        return {"Error": ret.error}
    info = ret.value
    repl = []
    for entry in info["metadata_replication"]:
        repl.append({
            "target": entry["target"],
            "state": entry["state"],
            "last_sync": ov_trim_time(entry.get("last_sync") or ""),
            "error": entry.get("error") or "",
        })
    commit = info["commit"]
    return {
        "Version": info["version"],
        # short_sha would mangle the "dev_build" placeholder of unreleased
        # binaries into "dev_bui"
        "Commit": commit if commit == "dev_build" else utils.short_sha(commit),
        "Uptime": ov_uptime(info["uptime_secs"]),
        "MetadataDB": info["metadata_db_type"],
        "AuditDB": info["audit_db_type"],
        "Runtime": info.get("container_runtime") or "",
        "IsLeader": info["is_leader"],
        "MetadataRepl": repl,
    }


def ov_activity_tile(perms, scope):
    # Recent activity ticker: the last few audit events. The default
    # "system" scope lists management operations only; "all" includes
    # http/action/custom events (the scope chips re-render via the
    # /overview/activity fragment)
    if not ov_can(perms, "audit:read"):
        return None
    event_type = "system" if scope != "all" else ""
    # start_date is a required arg in the plugin signature (empty = no
    # filter). 100 events, ~20 visible - the ticker box scrolls the rest
    ret = openrun.list_audit_events(event_type=event_type, start_date="", limit=100)
    if ret.error:
        return {"Error": ret.error}
    events = []
    for entry in ret.value:
        status = entry.get("status") or ""
        is_error = bool(status) and status != "Success" and \
            not status.startswith("2") and not status.startswith("3")
        events.append({
            "user": entry.get("user_id") or "",
            "operation": entry.get("operation") or entry.get("event_type") or "",
            "target": entry.get("target") or "",
            "time": ov_trim_time(entry.get("create_time") or ""),
            "is_error": is_error,
        })
    return {"Events": events, "Scope": "all" if scope == "all" else "system"}


def ov_repl_tile(perms, server):
    # Replication tile: the metadata state (from server_info, so visible
    # with config:basic_read) plus the lazy-loaded app binding rows
    # (app:read - the server filters rows to the caller's readable apps).
    # None - and no tile - when the user can see neither. The
    # "not configured" metadata note renders only when the caller could
    # actually read the metadata state (ShowMetadata), never as a guess
    show_bindings = ov_can(perms, "app:read")
    show_metadata = bool(server) and not server.get("Error")
    metadata = server["MetadataRepl"] if show_metadata else []
    if not show_metadata and not show_bindings:
        return None
    return {"Metadata": metadata, "ShowMetadata": show_metadata,
            "ShowBindings": show_bindings}


def overview_data(req):
    # Overview home page: fleet counts and health at a glance. Tiles the
    # user cannot read - or whose feature is disabled for this install -
    # are omitted entirely (each ov_*_tile returns None). Every plugin
    # call here must be cheap (in-memory or one small table read):
    # container state and binding replication cost external calls, so
    # those tiles lazy-load via the /overview/containers and
    # /overview/replication fragments
    perms = utils.get_perms()
    server = ov_server_tile(perms)
    data = {
        "Title": "Overview",
        "Nav": "overview",
        "Perms": perms,
        "Apps": ov_apps_tile(perms),
        "Syncs": ov_syncs_tile(perms),
        "ServicesTile": ov_services_tile(perms),
        "Server": server,
        "Repl": ov_repl_tile(perms, server),
        "Activity": ov_activity_tile(perms, "system"),
        "ShowContainers": bool(perms.get("feature:container") and
                               ov_can(perms, "container:read")),
    }
    data["Empty"] = not (data["Apps"] or data["Syncs"] or data["ServicesTile"] or
                         data["Server"] or data["Repl"] or data["Activity"] or
                         data["ShowContainers"])
    return data


def ov_container_kind_row(label, ctype):
    # One "X of Y running" stat row for a special container listing
    ret = openrun.list_containers(type=ctype)
    if ret.error:
        return {"label": label, "error": ret.error}
    return {"label": label, "running": ov_running(ret.value),
            "total": len(ret.value)}


def overview_containers_handler(req):
    # Lazy containers tile: list_containers shells out to the container
    # daemon, so it renders as a skeleton first and loads here
    perms = utils.get_perms()
    data = {"Perms": perms, "Loaded": True}
    if not perms.get("feature:container"):
        # Only reachable by a direct fragment request: the page does not
        # render the lazy loader when the container feature is disabled
        data["Error"] = "containers are disabled for this install"
        return data
    if not ov_can(perms, "container:read"):
        data["Error"] = "requires the container:read or admin permission"
        return data
    ret = openrun.list_containers()
    if ret.error:
        data["Error"] = ret.error
        return data

    # The managed list includes the litestream replication sidecars (they
    # carry the app.id label); split them out by their -ls name suffix -
    # the same heuristic the replication status API uses (ContainerInfo
    # does not expose labels)
    apps_total = 0
    apps_running = 0
    ls_total = 0
    ls_running = 0
    runtime = ""
    for entry in ret.value:
        runtime = entry["runtime"]
        is_running = entry["state"] == "running"
        if entry["name"].endswith("-ls"):
            ls_total += 1
            ls_running += 1 if is_running else 0
        else:
            apps_total += 1
            apps_running += 1 if is_running else 0
    data["Total"] = apps_total
    data["Running"] = apps_running

    rows = []
    if perms.get("feature:builder"):
        # Builder agent sandboxes and (on kubernetes) kaniko build pods:
        # one more daemon call each, fine in this lazy fragment
        rows.append(ov_container_kind_row("builder agents", "agent"))
        if runtime == "kubernetes":
            rows.append(ov_container_kind_row("kaniko builds", "kaniko"))
    rows.append({"label": "litestream sidecars", "running": ls_running,
                 "total": ls_total})
    data["Rows"] = rows
    return data


def overview_activity_handler(req):
    # Re-renders the activity tile when the System/All scope chips change
    perms = utils.get_perms()
    scope = utils.query_param(req, "scope") or "system"
    return {"Perms": perms, "Activity": ov_activity_tile(perms, scope)}


def overview_approvals_handler(req):
    # Lazy needs-approval chip on the apps tile: check_approval audits
    # staging per app (cached server-side by app version + binding
    # generation), too slow for the overview first paint
    perms = utils.get_perms()
    data = {"Perms": perms, "Loaded": True}
    if not ov_can(perms, "app:read"):
        return data
    ret = openrun.list_apps(include_internal=True, check_approval=True)
    if ret.error:
        return data
    approval = 0
    for row in build_app_rows(ret.value):
        if row["needs_approval"]:
            approval += 1
    data["Approval"] = approval
    return data


# Replication states that mean attention is needed; everything else
# (healthy, idle, syncing, pending) is a working or quiet-but-fine state
REPL_UNHEALTHY_STATES = ("sidecar_down", "misconfigured", "error")


def overview_replication_handler(req):
    # Lazy binding replication summary: replication_status sweeps the
    # replica store (S3) and the container daemon on a cache miss (30s
    # server-side cache), so the tile shows the free metadata state first
    # and this summary loads here. Only PROD app entries are counted
    # (staged replication state is on the app detail page); the server
    # filters entries per caller (app rows to readable apps via app:read,
    # metadata rows to config:basic_read) - metadata rows are dropped here
    # regardless, they already rendered with the server tile
    perms = utils.get_perms()
    data = {"Perms": perms, "Loaded": True}
    if not ov_can(perms, "app:read"):
        data["Error"] = "requires the app:read or admin permission"
        return data
    ret = openrun.replication_status()
    if ret.error:
        data["Error"] = ret.error
        return data
    # An app is unhealthy when ANY of its prod replication targets is in a
    # bad state (an app has at most one sqlite binding today, but keep the
    # fold safe if that changes)
    app_healthy = {}
    for entry in ret.value:
        if entry["kind"] != "app" or entry.get("env") != "prod":
            continue
        bad = entry["state"] in REPL_UNHEALTHY_STATES
        for app_path in entry.get("app_paths") or []:
            app_healthy[app_path] = app_healthy.get(app_path, True) and not bad
    healthy = len([1 for ok in app_healthy.values() if ok])
    unhealthy = len(app_healthy) - healthy
    data["Total"] = len(app_healthy)
    data["HealthyText"] = "%d app%s healthy" % (healthy, "" if healthy == 1 else "s")
    data["UnhealthyText"] = "%d app%s unhealthy" % (unhealthy, "" if unhealthy == 1 else "s")
    data["HasUnhealthy"] = unhealthy > 0
    return data


def replication_data(req):
    # Replication detail page (/replication, linked from the overview
    # replication tile): one row per PROD app replication target with the
    # full entry detail (state, sidecar, last sync, replica size, target
    # and the per-database file breakdown), searchable by app path. The
    # server filters entries to the caller's readable apps (app:read),
    # same as the overview tile; staged state stays on the app detail page
    query = utils.query_param(req, "query").lower()
    perms = utils.get_perms()
    data = {
        "Title": "Replication",
        "Nav": "overview",
        "Query": query,
        "Perms": perms,
        "Total": 0,
        "Unhealthy": 0,
        "Rows": [],
    }
    if not ov_can(perms, "app:read"):
        data["FlashError"] = "requires the app:read or admin permission"
        return data
    ret = openrun.replication_status()
    if ret.error:
        data["FlashError"] = ret.error
        return data

    # Resolve each prod app's litestream sidecar container for the row
    # drill-down (docker/podman: separate "-ls" containers, prod told apart
    # by app_prd_ in the name; none on kubernetes where the sidecar runs
    # inside the app pod). list_containers is only granted on container
    # feature installs - errors are ignored and the rows render without
    # the drill-down, matching the missing /containers routes
    sidecars = {}
    cont_ret = openrun.list_containers()
    cont_error = cont_ret.error
    if not cont_error:
        for c in cont_ret.value:
            if c["app_path"] and c["name"].endswith("-ls") and "app_prd_" in c["name"]:
                sidecars[c["app_path"]] = c["id"]

    rows = []
    for entry in ret.value:
        if entry["kind"] != "app" or entry.get("env") != "prod":
            continue
        # A target replicates one binding; apps sharing the binding share
        # the entry - render one row per app so the search works by app
        for app_path in entry.get("app_paths") or []:
            data["Total"] += 1
            bad = entry["state"] in REPL_UNHEALTHY_STATES
            if bad:
                data["Unhealthy"] += 1
            if query and query not in app_path.lower():
                continue
            files = []
            for f in entry.get("files") or []:
                files.append({
                    "path": f["path"],
                    "size": utils.human_size(int(f.get("size") or 0)),
                    "last_sync": ov_trim_time(f.get("last_sync") or ""),
                })
            sidecar = entry.get("sidecar_running")
            size = int(entry.get("replica_size") or 0)
            rows.append({
                "container_id": sidecars.get(app_path) or "",
                "app_path": app_path,
                "state": entry["state"],
                "unhealthy": bad,
                "target": entry["target"],
                "sidecar": "" if sidecar == None else ("running" if sidecar else "down"),
                "last_sync": ov_trim_time(entry.get("last_sync") or ""),
                "size": utils.human_size(size) if size else "",
                "files": files,
                "error": entry.get("error") or "",
            })
    # Failing targets first, then by app path
    data["Rows"] = sorted(rows, key=lambda r: (not r["unhealthy"], r["app_path"]))
    return data


# ---------- Apps ----------


def build_app_rows(all_apps):
    # Folds staging entries into their main app's row and returns the row
    # dicts rendered by the shared app_table template. all_apps must come
    # from list_apps with include_internal=True
    staging_by_main = {}
    for entry in all_apps:
        if entry["is_stage"]:
            staging_by_main[entry["main_app"]] = entry

    rows = []
    for entry in all_apps:
        if entry["main_app"]:
            continue

        stage = staging_by_main.get(entry["id"])
        # The staging app carries the most recent sync state (prod picks it
        # up on promote); fall back to the prod app's value. get() keeps this
        # working against servers older than the applied_sync_id field
        sync_id = (stage.get("applied_sync_id", "") if stage else "") or entry.get("applied_sync_id", "")

        staging = None
        if stage:
            staging = {
                "version": stage["version"],
                "git_sha": utils.short_sha(stage["git_sha"]),
                "git_message": stage["git_message"],
                # staging has a version prod does not have yet
                "ahead": stage["version_mismatch"],
            }

        rows.append({
            "name": entry["name"],
            "path": entry["path"],
            "url": entry["url"],
            "auth": entry["auth"],
            "is_dev": entry.get("is_dev") or False,
            # Only set when list_apps ran with check_approval=True (apps page);
            # the backend mirrors the staging app's audit onto the main app
            "needs_approval": entry.get("needs_approval") or False,
            "is_git": bool(entry["git_branch"]),
            # Declarative means a sync source last applied the app. Git
            # presence is not the signal: image/proxy spec apps have no git
            "sync_id": sync_id,
            "is_declarative": bool(sync_id),
            # "-" is the placeholder for apps with no source (image/proxy specs)
            "source": entry["source"] if entry["source"] != "-" else "",
            "source_url": entry["source_url"],
            "git_branch": entry["git_branch"],
            "spec": entry.get("spec") or "",
            "version": entry["version"],
            "git_sha": utils.short_sha(entry["git_sha"]),
            "git_message": entry["git_message"],
            "staging": staging,
            "created_by": entry.get("created_by") or "",
            "update_time": entry.get("update_time") or "",
            "update_user": entry.get("update_user") or "",
        })
    return rows


def apps_data(req):
    # Apps list page: apps grouped by their managing sync, plus unmanaged.
    # The promote/approval tabs show the apps waiting on that action as a
    # flat list, with the row action switched to Promote/Approve
    query = utils.query_param(req, "query")
    filter = utils.query_param(req, "filter")  # "", "declarative" or "imperative"
    tab = utils.query_param(req, "tab")  # "", "promote" or "approval"

    # include_internal picks up staging/preview apps; staging entries are
    # folded into their main app's row instead of being listed separately.
    # check_approval adds the needs_approval flag (cached server-side).
    # A search containing ":", starting with "/", or equal to "all"
    # switches to app path GLOB matching (domain:path form, e.g.
    # "example.com:/**", "/utils/**", "all" - the same globs the CLI
    # takes); anything else is a substring search over
    # name/path/source/user
    stripped = query.strip()
    glob = ""
    if ":" in stripped or stripped.startswith("/") or stripped.lower() == "all":
        glob = stripped
    list_ret = openrun.list_apps(query="" if glob else query, path=glob,
                                 include_internal=True, check_approval=True)
    list_error = list_ret.error
    all_apps = list_ret.value if not list_error else []

    # Sync entries the user can read. Apps whose sync entry is not visible
    # (no sync:read) are shown in the unmanaged section instead
    syncs = {}
    sync_ret = openrun.list_sync()
    for entry in (sync_ret.value if not sync_ret.error else []):
        syncs[entry["id"]] = {
            "id": entry["id"],
            "repo": entry["path"],
            "branch": entry["metadata"]["git_branch"],
            "state": entry["status"]["state"],  # Enabled / Disabled / Failing
            "last_exec": utils.nonzero_time(entry["status"]["last_execution_time"]),
        }

    grouped = {}  # sync id -> app rows, for apps last applied by a live sync
    unmanaged = []  # created/last updated imperatively
    tab_apps = []  # rows for the active promote/approval tab
    total = 0
    declarative_count = 0
    promote_count = 0
    approval_count = 0
    for app in build_app_rows(all_apps):
        total += 1
        if app["is_declarative"]:
            declarative_count += 1
        if (filter == "declarative" and not app["is_declarative"]) or \
           (filter == "imperative" and app["is_declarative"]):
            continue

        # The tab badge counts follow the active declarative/imperative
        # filter, matching what the tab tables list
        if app["staging"] and app["staging"]["ahead"]:
            promote_count += 1
        if app["needs_approval"]:
            approval_count += 1

        if tab == "promote" and app["staging"] and app["staging"]["ahead"]:
            tab_apps.append(app)
        elif tab == "approval" and app["needs_approval"]:
            tab_apps.append(app)

        if app["sync_id"] and app["sync_id"] in syncs:
            grouped.setdefault(app["sync_id"], []).append(app)
        else:
            unmanaged.append(app)

    # Most recently updated apps first, groups ordered by their most
    # recently updated app
    groups = []
    for sync_id in grouped:
        apps = utils.sort_recent(grouped[sync_id], "update_time", "path")
        groups.append({
            "sync": syncs[sync_id],
            "apps": apps,
            "newest": apps[0]["update_time"] if apps else "",
            "repo": syncs[sync_id]["repo"],
        })

    data = {
        "Title": "Apps",
        "Nav": "apps",
        "Query": query,
        "Filter": filter,
        "Tab": tab,
        "TabApps": utils.sort_recent(tab_apps, "update_time", "path"),
        "Groups": utils.sort_recent(groups, "newest", "repo"),
        "Unmanaged": utils.sort_recent(unmanaged, "update_time", "path"),
        "Total": total,
        "DeclarativeCount": declarative_count,
        "ImperativeCount": total - declarative_count,
        "PromoteCount": promote_count,
        "ApprovalCount": approval_count,
        "Perms": utils.get_perms(),
    }
    if list_error:
        # A malformed glob search (":" queries) renders the empty list with
        # the parse error instead of crashing to the error page
        data["FlashError"] = "Invalid app path glob: %s" % list_error
    return data


def load_versions(path):
    # Returns the version list for the app at path, newest first
    ret = openrun.list_versions(path)
    if ret.error:
        return [], ret.error

    versions = []
    for entry in ret.value["versions"] or []:
        vm = (entry.get("Metadata") or {}).get("version_metadata") or {}
        versions.append({
            "version": entry["Version"],
            "previous": entry.get("PreviousVersion") or 0,
            "active": entry.get("Active") or False,
            "user": entry.get("UserId") or "",
            "create_time": utils.nonzero_time(entry.get("CreateTime")),
            "git_sha": utils.short_sha(vm.get("git_commit") or ""),
            "git_message": vm.get("git_message") or "",
            "git_branch": vm.get("git_branch") or "",
        })
    return sorted(versions, key=lambda v: v["version"], reverse=True), ""


def resolve_env_path(path, env):
    # The prod app path is the external identifier; staging actions resolve
    # the linked staging app's path through get_app
    if env == "stage":
        app_ret = openrun.get_app(path)
        if not app_ret.error:
            return app_ret.value["stage_path"]
    return path


def version_options(path, app):
    # The env-qualified version choices for the Compare/Files selects:
    # staging versions first, newest first. Values are "env:version" specs;
    # also returns the active version per env
    options = []
    stage_versions, stage_err = load_versions(app["stage_path"])
    prod_versions, prod_err = load_versions(path)
    active = {"stage": 0, "prod": 0}
    for v in stage_versions:
        version = int(v["version"])
        if v["active"]:
            active["stage"] = version
        options.append({
            "value": "stage:%d" % version,
            "label": "v%d · staging%s" % (version, " (active)" if v["active"] else ""),
        })
    for v in prod_versions:
        version = int(v["version"])
        if v["active"]:
            active["prod"] = version
        options.append({
            "value": "prod:%d" % version,
            "label": "v%d · prod%s" % (version, " (active)" if v["active"] else ""),
        })
    return options, active, (stage_err or prod_err)


def version_spec_label(spec):
    # Display label for an "env:version" spec
    env, _, version = spec.partition(":")
    env_label = "staging" if env == "stage" else "prod"
    return ("v%s · %s" % (version, env_label)) if version else env_label


def diff_rows(diff):
    # Normalize export_app_diff rows for the template: line number 0 means
    # no line on that side (spacer row)
    rows = []
    for row in diff["rows"] or []:
        left_line = int(row["left_line"])
        right_line = int(row["right_line"])
        rows.append({
            "kind": row["kind"],
            "left_line": ("%d" % left_line) if left_line else "",
            "left_text": row["left_text"],
            "right_line": ("%d" % right_line) if right_line else "",
            "right_text": row["right_text"],
        })
    return rows


def export_lines(text):
    # Split an export output into display lines for the numbered pane
    return text.rstrip("\n").split("\n")


def detail_config_data(data, req):
    # Config tab: the prod export output. When staging runs a different
    # version, the view automatically becomes the prod <-> staging diff -
    # the one-look answer to what is pending promotion
    app = data["App"]
    path = data["Path"]
    cfg = {"Error": "", "Single": True, "Label": "", "Badge": "", "Lines": [],
           "Rows": [], "Changed": 0, "LeftLabel": "", "RightLabel": ""}
    data["Config"] = cfg

    if app["is_dev"]:
        ret = openrun.export_app(path)
        error = ret.error
        if error:
            cfg["Error"] = error
            return
        cfg["Label"] = "Dev app declaration"
        cfg["Lines"] = export_lines(ret.value)
        return

    prod_version = int(app["version"])
    if not app["staged_changes"]:
        ret = openrun.export_app(path)
        error = ret.error
        if error:
            cfg["Error"] = error
            return
        cfg["Label"] = "Prod · v%d · staging in sync" % prod_version
        cfg["Lines"] = export_lines(ret.value)
        return

    _, active, _ = version_options(path, app)
    ret = openrun.export_app_diff(path, "prod:", "stage:")
    error = ret.error
    if error:
        cfg["Error"] = error
        return
    stage_label = ("v%d" % active["stage"]) if active["stage"] else "version"
    if not int(ret.value["changed"]):
        # Staging is ahead but the declarative config is identical: the
        # pending change is source-only. Two identical panes would read as
        # a bug, so show the single config with an explaining badge
        prod_ret = openrun.export_app(path)
        prod_error = prod_ret.error
        if prod_error:
            cfg["Error"] = prod_error
            return
        cfg["Label"] = "Prod · v%d" % prod_version
        cfg["Badge"] = "staging %s is ahead - source changed, config identical" % stage_label
        cfg["Lines"] = export_lines(prod_ret.value)
        return
    cfg["Single"] = False
    cfg["Label"] = "Prod · v%d" % prod_version
    cfg["Badge"] = "staging %s differs - showing changes" % stage_label
    cfg["LeftLabel"] = "prod · v%d" % prod_version
    cfg["RightLabel"] = ("staging · v%d" % active["stage"]) if active["stage"] else "staging"
    cfg["Rows"] = diff_rows(ret.value)
    cfg["Changed"] = int(ret.value["changed"])


def detail_compare_data(data, req):
    # Compare tab: any two versions side by side as export outputs. Defaults
    # to prod active vs staging active when they differ, else the previous
    # prod version vs the active one
    app = data["App"]
    path = data["Path"]
    cmp = {"Error": "", "Options": [], "From": "", "To": "", "Rows": [],
           "Changed": 0, "Same": False, "LeftLabel": "", "RightLabel": ""}
    data["Compare"] = cmp

    options, active, err = version_options(path, app)
    if err and not options:
        cmp["Error"] = err
        return
    cmp["Options"] = options

    from_spec = utils.query_param(req, "from")
    to_spec = utils.query_param(req, "to")
    if not from_spec or not to_spec:
        if app["staged_changes"] and active["stage"]:
            from_spec = "prod:%d" % active["prod"]
            to_spec = "stage:%d" % active["stage"]
        else:
            prod_opts = [o["value"] for o in options if o["value"].startswith("prod:")]
            to_spec = prod_opts[0] if prod_opts else ""
            from_spec = prod_opts[1] if len(prod_opts) > 1 else to_spec
    cmp["From"] = from_spec
    cmp["To"] = to_spec
    if not from_spec or not to_spec:
        cmp["Error"] = "No versions to compare yet"
        return

    ret = openrun.export_app_diff(path, from_spec, to_spec)
    error = ret.error
    if error:
        cmp["Error"] = error
        return
    cmp["Rows"] = diff_rows(ret.value)
    cmp["Changed"] = int(ret.value["changed"])
    cmp["Same"] = cmp["Changed"] == 0
    cmp["LeftLabel"] = version_spec_label(from_spec)
    cmp["RightLabel"] = version_spec_label(to_spec)


def detail_files_data(data, req):
    # Files tab: one version's file tree with the builder-files explorer.
    # Defaults to the staging active version when it differs from prod
    app = data["App"]
    path = data["Path"]
    ft = {"Error": "", "Options": [], "Selected": "", "Label": "", "Tree": [],
          "Count": 0, "TotalSize": "", "DownloadUrl": "", "Endpoint": ""}
    data["FilesTab"] = ft

    options, active, err = version_options(path, app)
    if err and not options:
        ft["Error"] = err
        return
    ft["Options"] = options

    sel = utils.query_param(req, "v")
    if not sel:
        if app["staged_changes"] and active["stage"]:
            sel = "stage:%d" % active["stage"]
        elif active["prod"]:
            sel = "prod:%d" % active["prod"]
    ft["Selected"] = sel
    env, _, version = sel.partition(":")
    if env not in ("prod", "stage") or not version:
        ft["Error"] = "No version selected"
        return
    ft["Label"] = version_spec_label(sel)

    resolved = resolve_env_path(path, env)
    ret = openrun.list_version_files(resolved, version=version)
    error = ret.error
    if error:
        ft["Error"] = error
        return
    names = []
    total = 0
    for entry in ret.value["files"] or []:
        names.append(entry["Name"])
        total += int(entry["Size"])
    ft["Tree"] = build_file_tree(sorted(names))
    ft["Count"] = len(names)
    ft["TotalSize"] = utils.human_size(total)
    ft["DownloadUrl"] = "%s/apps/files/download?path=%s&version=%s&env=%s" % (
        req.AppPath, path, version, env)
    ft["Endpoint"] = "%s/apps/version_file?app=%s&env=%s&version=%s" % (
        req.AppPath, path, env, version)


def apps_detail_config_download_handler(req):
    # GET: the prod export output as an apply-ready .ace download
    path = utils.query_param(req, "path")
    ret = openrun.export_app(path)
    if ret.error:
        data = apps_detail_data(req)
        data["FlashError"] = "Export failed: %s" % ret.error
        return data
    header = ("# Declarative config for %s, generated by the OpenRun console\n" +
              "# Apply on an openrun instance with: openrun apply --approve <file>\n\n") % path
    name = path.strip("/").replace("/", "_").replace(":", "_") or "app"
    return ace.response(header + ret.value, download=name + ".star",
                        content_type="text/plain")


def apps_version_file_handler(req):
    # TEXT route: raw content of one version file, rendered by the Files
    # tab's <builder-files> viewer (client side syntax highlighting). The
    # component appends &path=<file> to the endpoint url
    app_path = utils.query_param(req, "app").strip()
    env = utils.query_param(req, "env").strip() or "prod"
    version = utils.query_param(req, "version").strip()
    name = utils.query_param(req, "path").strip()
    ret = openrun.get_version_file(resolve_env_path(app_path, env),
                                   version=version, name=name)
    if ret.error:
        return "error: %s" % ret.error
    return ret.value


ENV_ORDER = {"prod": "0", "stage": "1", "preview": "2", "dev": "3"}


def app_container_sort_key(entry):
    # Sort containers: running first, then prod/stage/preview/dev, then name
    running = "0" if entry["state"] == "running" else "1"
    return running + ENV_ORDER.get(entry["env"], "9") + entry["name"]


def apps_detail_data(req):
    # App detail page, a tabbed inspector: Overview (cards, params,
    # containers, versions), Config (export output, auto prod<->staging
    # diff), Compare (any two versions as export diffs) and Files (version
    # file explorer). Only the active tab's data is built
    path = utils.query_param(req, "path")
    tab = utils.query_param(req, "tab")
    if tab not in ("config", "compare", "files"):
        tab = "overview"
    data = {
        "Title": "App detail",
        "Nav": "apps",
        "Path": path,
        "Tab": tab,
        "Error": "",
        "App": None,
        "Containers": [],
        # Set after a staging-only reload/update, prompts for promotion
        "AskPromote": utils.query_param(req, "staged"),
        # App permissions evaluated against this app, including the owner rule
        "Perms": utils.get_perms(path),
        "HelpUrl": utils.docs_link("/docs/applications/lifecycle/"),
    }

    ret = openrun.get_app(path)
    if ret.error:
        data["Error"] = ret.error
        return data

    app = ret.value
    data["App"] = app

    if app["is_dev"] and tab in ("compare", "files"):
        # Dev apps have no versions; those tabs render disabled
        tab = "overview"
        data["Tab"] = tab
    if tab == "config":
        detail_config_data(data, req)
        return data
    if tab == "compare":
        detail_compare_data(data, req)
        return data
    if tab == "files":
        detail_files_data(data, req)
        return data

    # Resolve the sync entry which manages this app, if any
    if app["applied_sync_id"]:
        sync_ret = openrun.list_sync()
        for entry in (sync_ret.value if not sync_ret.error else []):
            if entry["id"] == app["applied_sync_id"]:
                data["Sync"] = {
                    "repo": entry["path"],
                    "branch": entry["metadata"]["git_branch"],
                }

    data["ParamsText"] = utils.params_to_text(app["params"])

    # Containers running (or recently run) for this app, current env first.
    # The litestream sidecars (-ls suffix) are excluded: they would render
    # as duplicate env chips, and the Replication row links to them instead
    cont_ret = openrun.list_containers()
    if not cont_ret.error:
        containers = [c for c in cont_ret.value
                      if c["app_path"] == path and not c["name"].endswith("-ls")]
        data["Containers"] = sorted(containers, key=app_container_sort_key)

    # Audit the app's code for the plugin permissions it requests and whether
    # they are pending approval (audited against staging for prod apps)
    audit_ret = openrun.audit_app(path)
    if audit_ret.error:
        data["AuditError"] = audit_ret.error
    else:
        audit = audit_ret.value
        data["Audit"] = utils.review_from_dryrun({"approve_results": [audit]})
        data["NeedsApproval"] = audit.get("needs_approval") or False

    if app["is_dev"]:
        # Dev apps serve directly from disk, no versions are tracked
        return data

    prod_versions, prod_err = load_versions(path)
    stage_versions, stage_err = load_versions(app["stage_path"])
    data["ProdVersions"] = prod_versions
    data["ProdVersionsError"] = prod_err
    data["StageVersions"] = stage_versions
    data["StageVersionsError"] = stage_err
    return data


def apps_detail_replication_handler(req):
    # Lazy replication status for the app detail Overview card:
    # replication_status sweeps the replica store on a server cache miss,
    # so it must not block the detail page's first paint. Renders nothing
    # when the app has no replicated sqlite binding
    path = utils.query_param(req, "path")
    data = {"Perms": utils.get_perms(path), "Loaded": True, "Path": path}
    ret = openrun.get_app(path)
    error = ret.error
    if error:
        # No access or app gone: render nothing (the page itself already
        # surfaced the error)
        return data
    stage_path = ret.value.get("stage_path") or ""

    rs = openrun.replication_status()
    error = rs.error
    if error:
        data["Error"] = error
        return data

    # The litestream sidecars are separate labeled containers on docker/
    # podman (-ls name suffix, prod vs staged told apart by the app id in
    # the container name); each status chip links to its sidecar's
    # container detail when one exists (on kubernetes the sidecar runs
    # inside the app pod, so there is no separate container to link)
    sidecars = {}
    cont_ret = openrun.list_containers()
    cont_error = cont_ret.error
    if not cont_error:
        for c in cont_ret.value:
            if c["app_path"] != path or not c["name"].endswith("-ls"):
                continue
            sidecars["prod" if "app_prd_" in c["name"] else "staged"] = c["id"]

    rows = []
    for entry in rs.value:
        if entry["kind"] != "app":
            continue
        env = entry.get("env") or ""
        paths = entry.get("app_paths") or []
        if (env == "prod" and path in paths) or \
           (env == "staged" and stage_path and stage_path in paths):
            rows.append({
                "env": "prod" if env == "prod" else "stage",
                "state": entry["state"],
                "last_sync": ov_trim_time(entry.get("last_sync") or ""),
                "error": entry.get("error") or "",
                "container_id": sidecars.get(env) or "",
            })
    # prod first, matching the containers chip order
    data["Rows"] = sorted(rows, key=lambda r: r["env"] != "prod")
    return data


def apps_switch_handler(req):
    # POST: switch the active version for prod or staging
    path = utils.query_param(req, "path")
    env = utils.query_param(req, "env") or "prod"
    version = utils.query_param(req, "version")

    ret = openrun_admin.switch_version(resolve_env_path(path, env), version)
    error = ret.error
    return utils.flash_result(apps_detail_data(req), error,
                        "Switched %s to v%s" % (env, version), "Version switch failed")


def require_app_path(req, data_fn):
    # The app write plugin APIs take path globs; a missing path must not
    # silently become an empty glob (which would match every app). Returns
    # (path, None) or ("", error page data)
    path = utils.query_param(req, "path").strip()
    if not path:
        data = data_fn(req)
        data["FlashError"] = "App path is required"
        return "", data
    return path, None


def promote_app_result(req, data_fn, path):
    # Promote the staging app to prod and re-render the page via data_fn
    # with the result flash. Shared by the detail page, the apps list
    # pending-promotion tab and the builder session page
    ret = openrun_admin.promote_apps(path)
    error = ret.error
    data = data_fn(req)
    if error:
        data["FlashError"] = "Promote failed: %s" % error
    elif not ret.value.get("promote_results"):
        data["Flash"] = "Nothing to promote, prod matches staging"
    else:
        data["Flash"] = "Promoted %s to prod" % path
    return data


def apps_promote_handler(req):
    # POST: promote the staging app to prod
    path, error_data = require_app_path(req, apps_detail_data)
    if error_data:
        return error_data
    return promote_app_result(req, apps_detail_data, path)


def approve_app_result(req, data_fn, path):
    # Approve the pending plugin permissions (applies to the staging app, or
    # directly for dev apps) and re-render the page via data_fn
    ret = openrun_admin.approve_apps(path, promote=False)
    error = ret.error
    data = data_fn(req)
    if error:
        data["FlashError"] = "Approve failed: %s" % error
    else:
        data["Flash"] = "Approved pending permissions for %s" % path
    return data


def apps_approve_handler(req):
    # POST: approve the requested plugin permissions; promotion is asked as
    # the next step
    path, error_data = require_app_path(req, apps_detail_data)
    if error_data:
        return error_data
    data = approve_app_result(req, apps_detail_data, path)
    if not data.get("FlashError"):
        data["AskPromote"] = "approve"
    return data


def reload_app_options(req, path):
    # Reload with the reload-dialog options. The dialog disables the approve
    # checkbox and promotion radios when the user lacks the permission, and
    # disabled inputs are not submitted: missing params mean no approval and
    # no promotion (the approve/promote flags hard-fail server-side without
    # the permission). promote_mode verify reloads app containers to verify
    # staging before promoting; a failed verification rolls everything back
    mode = utils.query_param(req, "promote_mode") or "none"
    return openrun_admin.reload_apps(path,
                                   approve=bool(utils.query_param(req, "approve")),
                                   promote=mode == "verify" or mode == "noverify",
                                   verify=mode == "verify")


def apps_detail_reload_handler(req):
    # POST: reload from source with the dialog options, staying on the
    # detail page. A staging-only reload prompts for promotion as the next
    # step; a promoting reload is done in one go
    path, error_data = require_app_path(req, apps_detail_data)
    if error_data:
        return error_data
    ret = reload_app_options(req, path)
    error = ret.error
    data = apps_detail_data(req)
    if error:
        data["FlashError"] = "Reload failed: %s" % error
    elif ret.value.get("skipped_results") and not ret.value.get("reload_results"):
        data["Flash"] = "%s is already up to date" % path
    elif ret.value.get("promote_results"):
        data["Flash"] = "Reloaded and promoted to prod"
    elif data.get("App") and data["App"].get("is_dev"):
        data["Flash"] = "Reloaded from source"
    else:
        data["Flash"] = "Staging reloaded from source"
        data["AskPromote"] = "reload"
    return data


def apps_detail_delete_handler(req):
    # POST: delete the app and return to the apps list
    path, error_data = require_app_path(req, apps_detail_data)
    if error_data:
        return error_data
    ret = openrun_admin.delete_apps(path)
    if ret.error:
        data = apps_detail_data(req)
        data["FlashError"] = "Delete failed: %s" % ret.error
        return data
    # The app is gone, go back to the apps list
    return ace.response(apps_detail_data(req), block="detail_content",
                        redirect=req.AppPath + "/apps")


def apps_files_handler(req):
    # The old version-files table page is retired: redirect to the detail
    # page's Files tab, translating the env/version params. The download
    # fragment on this route stays as the zip endpoint
    path = utils.query_param(req, "path")
    version = utils.query_param(req, "version")
    env = utils.query_param(req, "env") or "prod"
    target = "%s/apps/detail?path=%s&tab=files" % (req.AppPath, path)
    if version:
        target += "&v=%s:%s" % (env, version)
    return ace.redirect(target)


def apps_files_download_handler(req):
    # GET: bundle the version's files into a zip and stream it back to the
    # client as an attachment (chunked, no disk/db staging); errors re-render
    # the files page
    path = utils.query_param(req, "path")
    version = utils.query_param(req, "version")
    env = utils.query_param(req, "env") or "prod"

    ret = openrun.get_version_zip(resolve_env_path(path, env), version=version)
    if ret.error:
        data = apps_files_handler(req)
        data["FlashError"] = "Download failed: %s" % ret.error
        return data
    return ace.response(ret.value["content"], download=ret.value["name"],
                        content_type="application/zip")


def apps_delete_handler(req):
    # POST: delete an app from the apps list
    path, error_data = require_app_path(req, apps_data)
    if error_data:
        return error_data
    ret = openrun_admin.delete_apps(path)
    error = ret.error
    return utils.flash_result(apps_data(req), error, "Deleted %s" % path, "Delete failed")


def apps_reload_handler(req):
    # POST: reload from the apps list with the dialog options. A promoting
    # reload stays on the list with a flash; a staging-only reload continues
    # on the detail page to review and promote
    path, error_data = require_app_path(req, apps_data)
    if error_data:
        return error_data
    ret = reload_app_options(req, path)

    if ret.error:
        data = apps_data(req)
        data["FlashError"] = "Reload failed: %s" % ret.error
        return data
    if ret.value.get("skipped_results") and not ret.value.get("reload_results"):
        data = apps_data(req)
        data["Flash"] = "%s is already up to date" % path
        return data
    if ret.value.get("promote_results"):
        data = apps_data(req)
        data["Flash"] = "Reloaded %s and promoted to prod" % path
        return data

    # Staging reloaded; continue on the detail page to review and promote
    return ace.response(apps_data(req), block="app_groups",
                        redirect="%s/apps/detail?path=%s&staged=reload" % (req.AppPath, path))


def apps_list_promote_handler(req):
    # POST: promote staging to prod from the pending-promotion tab
    path, error_data = require_app_path(req, apps_data)
    if error_data:
        return error_data
    return promote_app_result(req, apps_data, path)


def apps_list_approve_handler(req):
    # POST: approve the pending plugin permissions from the approval tab; a
    # prod app then shows under pending promotion as the next step
    path, error_data = require_app_path(req, apps_data)
    if error_data:
        return error_data
    return approve_app_result(req, apps_data, path)


def run_sync_action(req, data_fn):
    # Run a sync and show the detailed apply results on the current page
    ret = openrun_admin.run_sync(utils.query_param(req, "sync_id"))
    error = ret.error
    data = data_fn(req)
    if error:
        data["FlashError"] = "Sync failed: %s" % error
    elif ret.value.get("error"):
        data["FlashError"] = "Sync failed: %s" % ret.value["error"]
    else:
        data["SyncResult"] = utils.sync_result_summary(ret.value)
    return data


def apps_sync_handler(req):
    # POST: run a sync from the apps list
    return run_sync_action(req, apps_data)


# ---------- App create / update forms ----------


def auth_options():
    # Valid app auth types from the server: built-ins (default/system/none)
    # plus the configured oauth, saml and client cert auth entries
    ret = openrun.list_auths()
    return ret.value if not ret.error else []


def git_auth_options():
    # The git_auth entries configured on the server plus the
    # security.default_git_auth entry name; the create forms preselect the
    # default. Errors degrade to no options and no default
    ret = openrun.list_git_auths()
    if ret.error:
        return {"entries": [], "default": ""}
    return ret.value


def binding_options():
    # The choices for the app form's service bindings dropdowns: service ids
    # (binding to a service creates an auto binding) and the base/derived
    # binding paths (an app's own auto bindings are not offered). Errors
    # (e.g. no binding:read access) degrade to empty lists
    services = []
    svc_ret = openrun.list_services()
    if not svc_ret.error:
        for entry in svc_ret.value:
            services.append(entry["service_type"] + "/" + entry["name"])

    bindings = []
    list_ret = openrun.list_bindings()
    if not list_ret.error:
        for entry in list_ret.value:
            if not entry["path"].startswith("/auto/"):
                bindings.append(entry["path"])

    return {"services": sorted(services), "bindings": sorted(bindings)}


def posted_bindings(req):
    # The bindings selected on the app form, in row order. Rows left on the
    # placeholder (empty value) are skipped
    return [ref for ref in utils.query_param_list(req, "bindings") if ref]


def app_binding_refs(app):
    # The app's current bindings as form dropdown values: an auto binding
    # path is mapped back to the service source it was created from (the
    # dropdown offers services, not auto binding paths); explicit binding
    # paths stay as-is
    refs = app.get("bindings") or []
    if not refs:
        return []
    sources = {}
    list_ret = openrun.list_bindings()
    if not list_ret.error:
        for entry in list_ret.value:
            sources[entry["path"]] = entry["source"]
    mapped = []
    for ref in refs:
        if ref.startswith("/auto/") and sources.get(ref):
            mapped.append(sources[ref])
        else:
            mapped.append(ref)
    return mapped


def form_values(req):
    # The form fields for the create/update subpages
    return {
        "path": utils.query_param(req, "path"),
        "source_url": utils.query_param(req, "source_url"),
        "spec": utils.query_param(req, "spec"),
        "auth": utils.query_param(req, "auth"),
        "git_branch": utils.query_param(req, "git_branch"),
        "git_auth": utils.query_param(req, "git_auth"),
        "params_rows": utils.raw_kv_rows(req, "params"),
        "bindings": posted_bindings(req),
        "approve": utils.query_param(req, "approve"),
    }


def create_form_data(req, values, error):
    # Page context for the app create form
    return {
        "Title": "New app",
        "Nav": "apps",
        "Mode": "create",
        "Step": "edit",
        "Error": error,
        "Specs": openrun.list_specs().value,
        "AuthOptions": auth_options(),
        "GitAuthOptions": git_auth_options()["entries"],
        "BindingOptions": binding_options(),
        "Values": values,
        "Perms": utils.get_perms(),
    }


def approve_step_data(req, values, review, error):
    # Create form context for the post-create approval step
    data = create_form_data(req, values, error)
    data["Step"] = "approve"
    data["Review"] = review
    return data


def apps_create_page_handler(req):
    # App create form page; git auth preselects the server's default entry
    # (error re-renders keep the submitted choice instead)
    values = form_values(req)
    if not values["git_auth"]:
        values["git_auth"] = git_auth_options()["default"]
    return create_form_data(req, values, "")


def apps_create_submit_handler(req):
    # POST: validate (dry run), create, or approve a new app
    values = form_values(req)
    action = utils.query_param(req, "action")

    if action == "approve":
        # The app was created, approve its pending permissions
        ret = openrun_admin.approve_apps(values["path"])
        if ret.error:
            pending = openrun_admin.approve_apps(values["path"], dry_run=True)
            review = {"loads": [], "permissions": []}
            if not pending.error:
                review = utils.review_from_dryrun({"approve_results": pending.value.get("staged_update_results")})
            return approve_step_data(req, values, review, ret.error)
        return form_redirect(req, req.AppPath + "/apps")

    if not values["path"]:
        return create_form_data(req, values, "App path is required")
    if not values["source_url"]:
        return create_form_data(req, values, "Source url is required")

    params, err = utils.parse_kv_rows(req, "params")
    if err:
        return create_form_data(req, values, err)

    auth = values["auth"] if values["auth"] != "default" else ""

    if action == "create":
        # Create the app without approval; if it requests permissions, ask
        # for the approval as the next step
        ret = openrun_admin.create_app(values["path"], values["source_url"],
                               approve=False, auth=auth,
                               spec=values["spec"], git_branch=values["git_branch"],
                               git_auth=values["git_auth"], params=params,
                               bindings=values["bindings"])
        if ret.error:
            return create_form_data(req, values, ret.error)
        if utils.needs_approval(ret.value):
            return approve_step_data(req, values, utils.review_from_dryrun(ret.value), "")
        return form_redirect(req, req.AppPath + "/apps")

    # Validate: dry run to check the create and gather the requested
    # permissions, nothing is committed
    ret = openrun_admin.create_app(values["path"], values["source_url"],
                           approve=True, dry_run=True, auth=auth,
                           spec=values["spec"], git_branch=values["git_branch"],
                           git_auth=values["git_auth"], params=params,
                           bindings=values["bindings"])
    if ret.error:
        return create_form_data(req, values, ret.error)

    data = create_form_data(req, values, "")
    data["Validated"] = True
    data["Review"] = utils.review_from_dryrun(ret.value)
    return data


def update_form_data(req, app, values, error):
    # Page context for the app update form
    return {
        "Title": "Update app",
        "Nav": "apps",
        "Mode": "update",
        "Step": "edit",
        "Error": error,
        "App": app,
        "AuthOptions": auth_options(),
        "BindingOptions": binding_options(),
        "Values": values,
        "Perms": utils.get_perms(values.get("path", "")),
    }


def update_form_source(app):
    # Edits are staged, so the update form prefills from and compares
    # against the STAGING app when one exists: prod values would silently
    # drop already-staged changes on the next submit (and make a staged
    # change impossible to revert from the form). Auth stays on the main
    # app - it is a setting, not staged
    if app["is_dev"] or not app.get("stage_path"):
        return app
    # Staging apps are internal; get_app skips them without the flag
    ret = openrun.get_app(app["stage_path"], include_internal=True)
    error = ret.error
    if error:
        return app
    return ret.value


def apps_update_page_handler(req):
    # App update form page, prefilled from the staged configuration
    path = utils.query_param(req, "path")
    ret = openrun.get_app(path)
    if ret.error:
        return update_form_data(req, None, {}, ret.error)

    app = ret.value
    source = update_form_source(app)
    values = {
        "path": app["path"],
        "auth": app["auth"] or "default",
        "params_rows": utils.kv_rows(source["params"]),
        "bindings": app_binding_refs(source),
    }
    return update_form_data(req, app, values, "")


def apps_update_submit_handler(req):
    # POST: apply param/binding (staged) and auth (direct) changes
    path = utils.query_param(req, "path")
    values = {
        "path": path,
        "auth": utils.query_param(req, "auth"),
        "params_rows": utils.raw_kv_rows(req, "params"),
        "bindings": posted_bindings(req),
    }

    ret = openrun.get_app(path)
    if ret.error:
        return update_form_data(req, None, values, ret.error)
    app = ret.value
    # Changed-detection runs against the staging app, the same source the
    # form prefilled from - updates land on staging
    source = update_form_source(app)

    params, err = utils.parse_kv_rows(req, "params")
    if err:
        return update_form_data(req, app, values, err)

    params_changed = params != source["params"]
    if params_changed:
        # Params apply to staging; promotion is asked on the detail page
        result = openrun_admin.update_params(path, params, promote=False)
        if result.error:
            return update_form_data(req, app, values, result.error)

    # Compare in dropdown-value space (auto binding paths mapped back to
    # their service source), same as the form prefill
    bindings_changed = values["bindings"] != app_binding_refs(source)
    if bindings_changed:
        # Bindings apply to staging like params; a single "-" clears them all
        result = openrun_admin.update_bindings(path, values["bindings"] or ["-"],
                                               promote=False)
        if result.error:
            return update_form_data(req, app, values, result.error)

    new_auth = values["auth"] or "default"
    if new_auth != (app["auth"] or "default"):
        # Auth is an app setting, not version controlled; applies directly
        result = openrun_admin.update_auth(path, new_auth)
        if result.error:
            return update_form_data(req, app, values, result.error)

    if (params_changed or bindings_changed) and not app.get("is_dev"):
        # Ask about promoting the staged change; dev apps apply directly
        # (they have no staging), so there is nothing to promote
        return form_redirect(req, "%s/apps/detail?path=%s&staged=update" % (req.AppPath, path))
    return form_redirect(req, "%s/apps/detail?path=%s" % (req.AppPath, path))


# ---------- Bindings and services ----------


def bindings_data(req):
    # Bindings page: services table plus base/derived/auto binding tables
    query = utils.query_param(req, "query").lower()

    # Map app id -> app path, to show which app an auto binding belongs to
    app_paths = {}
    for entry in openrun.list_apps(include_internal=True).value:
        app_paths[entry["id"]] = entry["path"]

    base = []
    derived = []
    auto = []
    total = 0
    list_error = ""
    list_ret = openrun.list_bindings()
    if list_ret.error:
        # No binding:read access, show the page with the error instead
        list_error = list_ret.error
    for entry in (list_ret.value if not list_error else []):
        total += 1
        path = entry["path"]
        derived_from = entry["derived_from"]

        created_by = entry.get("created_by") or ""
        # Search matches the binding path, the base binding's path and creator
        if query and query not in path.lower() and query not in derived_from.lower() and \
           query not in created_by.lower():
            continue

        metadata = entry["metadata"]
        staged = entry["staged_metadata"]

        grants = metadata["grants"] or []
        staged_grants = staged["grants"] or []
        config = metadata["config"] or {}
        staged_config = staged["config"] or {}

        binding = {
            "path": path,
            "created_by": created_by,
            "source": entry["source"],
            "service_type": entry["service_type"],
            "service_name": entry["service_name"],
            "derived_from": derived_from,
            "grants": grants,
            "staged_grants": staged_grants,
            # staging has grant/config changes which are not applied to prod yet
            "has_staged": staged_grants != grants or staged_config != config,
            "config_keys": sorted(config.keys()),
            "update_time": utils.nonzero_time(entry["update_time"]),
        }

        if path.startswith("/auto/"):
            # Auto bindings are created for app service references, path is
            # /auto/<app_id>/<service_type>
            app_id = path.split("/")[2] if len(path.split("/")) > 3 else ""
            binding["app_path"] = app_paths.get(app_id, app_id)
            auto.append(binding)
        elif derived_from:
            derived.append(binding)
        else:
            base.append(binding)

    # Service entries, shown above the binding tables. Search matches the
    # service type/name
    services = []
    services_error = ""
    svc_ret = openrun.list_services()
    if svc_ret.error:
        services_error = svc_ret.error
    for entry in (svc_ret.value if not services_error else []):
        service_id = entry["service_type"] + "/" + entry["name"]
        if query and query not in service_id.lower():
            continue
        services.append({
            "id": service_id,
            "service_type": entry["service_type"],
            "name": entry["name"],
            "is_default": entry["is_default"],
            "staging": entry["staging"],
            "config_keys": entry["config_keys"] or [],
            "update_time": utils.nonzero_time(entry["update_time"]),
        })

    return {
        "Title": "Bindings",
        "Nav": "bindings",
        "Query": query,
        "Total": total,
        "Perms": utils.get_perms(),
        "FlashError": list_error,
        "Services": sorted(services, key=lambda svc: svc["id"]),
        "ServicesError": services_error,
        # Most recently updated bindings first
        "Base": utils.sort_recent(base, "update_time", "path"),
        "Derived": utils.sort_recent(derived, "update_time", "path"),
        "Auto": utils.sort_recent(auto, "update_time", "path"),
    }


def bindings_health_data(req):
    # Card health indicator fragments for the bindings page: one aggregate
    # call checks every entry in the group (services / base / derived / auto
    # bindings). The checks dial the real backends, so the page renders a
    # skeleton and loads these async; the server caches results per target,
    # keeping the load-triggered refires on partial swaps cheap. Bindings are
    # checked on BOTH the prod and the staging account.
    group = utils.query_param(req, "group")
    if group == "services":
        ret = openrun.service_health()
    elif group == "base":
        ret = openrun.binding_health(kind="base")
    elif group == "derived":
        ret = openrun.binding_health(kind="derived")
    elif group == "auto":
        ret = openrun.binding_health(kind="auto")
    else:
        return {"Group": group, "Error": "unknown health group %s" % group}

    error = ret.error
    if error:
        return {"Group": group, "Error": error}

    value = ret.value
    total = int(value["total"])
    unhealthy = int(value["unhealthy"])

    # Auto bindings belong to an app (path is /auto/<app_id>/<service_type>);
    # resolve the owning app so failing entries can name and link it. Best
    # effort: without app read access the entries just render pathless.
    app_paths = {}
    if group == "auto" and unhealthy > 0:
        apps_ret = openrun.list_apps(include_internal=True)
        apps_error = apps_ret.error
        if not apps_error:
            for entry in apps_ret.value:
                app_paths[entry["id"]] = entry["path"]

    auto_app_path = lambda path: app_paths.get(
        path.split("/")[2] if len(path.split("/")) > 3 else "", "")

    failures = []
    for entry in value["results"]:
        if group == "services":
            if not entry["healthy"]:
                failures.append({"id": entry["id"], "env": "", "error": entry["error"], "app_path": ""})
        else:
            # A binding row can fail on either env; list each failing env
            app_path = auto_app_path(entry["path"]) if group == "auto" else ""
            if not entry["healthy"]:
                failures.append({"id": entry["path"], "env": "prod", "error": entry["error"],
                                 "app_path": app_path})
            if not entry["staging_healthy"]:
                failures.append({"id": entry["path"], "env": "staging", "error": entry["staging_error"],
                                 "app_path": app_path})

    return {
        "Group": group,
        "Error": "",
        "Empty": total == 0,
        "HasFailures": len(failures) > 0,
        "UnhealthyText": "%d unhealthy" % unhealthy,
        "HealthyTip": "%d checked, all healthy" % total,
        "Failures": failures,
    }


def binding_form_values(req):
    # The form fields for the binding create/update subpages
    return {
        "path": utils.query_param(req, "path"),
        "source": utils.query_param(req, "source"),
        "grants_text": utils.query_param(req, "grants_text"),
        "config_rows": utils.raw_kv_rows(req, "config"),
    }


def binding_form_data(req, mode, values, error):
    # Page context for the binding create/update form
    return {
        "Title": "New binding" if mode == "create" else "Update binding",
        "Nav": "bindings",
        "Mode": mode,
        "Error": error,
        "Values": values,
        "Perms": utils.get_perms(),
    }


def bindings_create_page_handler(req):
    # Binding create form page
    return binding_form_data(req, "create", binding_form_values(req), "")


def bindings_create_submit_handler(req):
    # POST: validate (dry run) or create a binding
    values = binding_form_values(req)
    action = utils.query_param(req, "action")

    if not values["path"]:
        return binding_form_data(req, "create", values, "Binding path is required")
    if not values["source"]:
        return binding_form_data(req, "create", values, "Source is required")

    config, err = utils.parse_kv_rows(req, "config")
    if err:
        return binding_form_data(req, "create", values, err)
    grants = utils.parse_lines(values["grants_text"])

    if action == "validate":
        ret = openrun_admin.create_binding(values["path"], values["source"],
                                         grants=grants, config=config, dry_run=True)
        if ret.error:
            return binding_form_data(req, "create", values, ret.error)
        data = binding_form_data(req, "create", values, "")
        data["Validated"] = True
        return data

    ret = openrun_admin.create_binding(values["path"], values["source"],
                                     grants=grants, config=config)
    if ret.error:
        return binding_form_data(req, "create", values, ret.error)
    return form_redirect(req, req.AppPath + "/bindings")


def find_binding(path):
    # Look up one binding by path from the bindings list
    ret = openrun.list_bindings()
    if ret.error:
        return None
    for entry in ret.value:
        if entry["path"] == path:
            return entry
    return None


def bindings_update_page_handler(req):
    # Binding update form page, prefilled with the staged grants
    path = utils.query_param(req, "path")
    binding = find_binding(path)
    if not binding:
        return binding_form_data(req, "update", {"path": path}, "binding %s not found" % path)

    # Updates apply to staging first, edit the staged grants
    staged_grants = binding["staged_metadata"]["grants"] or []
    values = {
        "path": path,
        "source": binding["source"],
        "grants_text": "\n".join(staged_grants),
    }
    data = binding_form_data(req, "update", values, "")
    data["Binding"] = binding
    return data


def bindings_update_submit_handler(req):
    # POST: apply the grant additions/removals from the textarea diff
    path = utils.query_param(req, "path")
    values = binding_form_values(req)
    values["path"] = path

    binding = find_binding(path)
    if not binding:
        return binding_form_data(req, "update", values, "binding %s not found" % path)

    current = binding["staged_metadata"]["grants"] or []
    wanted = utils.parse_lines(values["grants_text"])
    add_grants = [g for g in wanted if g not in current]
    delete_grants = [g for g in current if g not in wanted]

    if not add_grants and not delete_grants:
        return form_redirect(req, req.AppPath + "/bindings")

    ret = openrun_admin.update_binding(path, add_grants=add_grants,
                                     delete_grants=delete_grants, promote=True)
    if ret.error:
        data = binding_form_data(req, "update", values, ret.error)
        data["Binding"] = binding
        return data
    return form_redirect(req, req.AppPath + "/bindings")


def bindings_delete_handler(req):
    # POST: delete a binding from the bindings list
    path = utils.query_param(req, "path")
    ret = openrun_admin.delete_binding(path)
    error = ret.error
    return utils.flash_result(bindings_data(req), error, "Deleted binding %s" % path, "Delete failed")


def service_form_data(req, values, error):
    # Page context for the service create form
    return {
        "Title": "New service",
        "Nav": "bindings",
        "Error": error,
        "Values": values,
        "Validated": False,
        "Perms": utils.get_perms(),
    }


def services_create_page_handler(req):
    # Service create form page
    values = {"id": "", "config_rows": [], "is_default": False, "staging": ""}
    return service_form_data(req, values, "")


def services_create_submit_handler(req):
    # POST: validate (dry run) or create a service
    values = {
        "id": utils.query_param(req, "id").strip(),
        "config_rows": utils.raw_kv_rows(req, "config"),
        "is_default": utils.query_param(req, "is_default") == "on",
        "staging": utils.query_param(req, "staging").strip(),
    }
    action = utils.query_param(req, "action")

    config, err = utils.parse_kv_rows(req, "config")
    if err:
        return service_form_data(req, values, err)

    dry_run = action == "validate"
    ret = openrun_admin.create_service(values["id"], config=config,
                                       is_default=values["is_default"],
                                       staging=values["staging"], dry_run=dry_run)
    if ret.error:
        return service_form_data(req, values, ret.error)

    if dry_run:
        data = service_form_data(req, values, "")
        data["Validated"] = True
        return data
    return form_redirect(req, req.AppPath + "/bindings")


def services_delete_handler(req):
    # POST: delete a service from the bindings page
    id = utils.query_param(req, "id")
    ret = openrun_admin.delete_service(id)
    error = ret.error
    return utils.flash_result(bindings_data(req), error, "Deleted service %s" % id, "Service delete failed")


# ---------- Containers ----------


def containers_data(req):
    # Containers page: managed containers with state/search filters, plus
    # the app builder's agent containers, (on Kubernetes) kaniko image
    # build pods and the litestream replication sidecars as their own views
    query = utils.query_param(req, "query").lower()
    # running / exited / all / agent / kaniko / litestream
    filter = utils.query_param(req, "filter") or "running"

    data = {
        "Title": "Containers",
        "Nav": "containers",
        "Query": query,
        "Filter": filter,
        "Total": 0,
        "Running": 0,
        "Runtime": "",
        "Containers": [],
        "Perms": utils.get_perms(),
    }

    ret = openrun.list_containers()
    if ret.error:
        data["FlashError"] = ret.error
        return data
    app_containers = ret.value

    if filter in ("agent", "kaniko"):
        # Runtime and counts still come from the managed list (drives the
        # header and the kaniko tab visibility); litestream sidecars are
        # excluded from the header counts like on the app-container views
        for entry in app_containers:
            if entry["name"].endswith("-ls"):
                continue
            data["Total"] += 1
            data["Runtime"] = entry["runtime"]
            if entry["state"] == "running":
                data["Running"] += 1
        special = openrun.list_containers(type=filter)
        error = special.error
        if error:
            data["FlashError"] = error
            return data
        containers = []
        for entry in special.value:
            if query and query not in entry["name"].lower() and \
               query not in entry["app_path"].lower() and query not in entry["id"].lower():
                continue
            containers.append(entry)
        data["Containers"] = sorted(containers, key=lambda c: c["name"])
        return data

    containers = []
    for entry in app_containers:
        # Replication sidecars are part of the managed list (they carry the
        # app.id label), identified by their -ls name suffix (same heuristic
        # as the replication status API). They have their own tab and are
        # excluded from the app-container views AND the header counts
        is_sidecar = entry["name"].endswith("-ls")
        running = entry["state"] == "running"
        if not is_sidecar:
            data["Total"] += 1
            data["Runtime"] = entry["runtime"]
            if running:
                data["Running"] += 1
        if filter == "litestream":
            if not is_sidecar:
                continue
        elif is_sidecar or (filter == "running" and not running) or (filter == "exited" and running):
            continue
        if query and query not in entry["name"].lower() and \
           query not in entry["app_path"].lower() and query not in entry["image"].lower() and \
           query not in entry["id"].lower():
            continue
        containers.append(entry)

    # Most recently created containers first (containers are recreated on
    # app updates, so creation time is the update time). Stable two-pass
    # sort: app path/name ascending as the tie break
    containers = sorted(containers, key=lambda c: c["app_path"] + " " + c["name"])
    data["Containers"] = sorted(containers, key=lambda c: c.get("created_at") or "", reverse=True)
    return data


def container_lifecycle_action(req, data_fn):
    # Start or stop a container, re-rendering the given page
    id = utils.query_param(req, "id")
    action = utils.query_param(req, "action")
    if action == "start":
        ret = openrun_admin.start_container(id)
    else:
        ret = openrun_admin.stop_container(id)
    error = ret.error
    return utils.flash_result(data_fn(req), error, "Container %s requested" % action,
                        "Container %s failed" % action)


def containers_lifecycle_handler(req):
    # POST: container start/stop from the containers list
    return container_lifecycle_action(req, containers_data)


def containers_detail_lifecycle_handler(req):
    # POST: container start/stop from the detail page
    return container_lifecycle_action(req, containers_detail_data)


def containers_detail_data(req):
    # Fast path: basic info only. Stats, disk usage and logs are slow to
    # collect and are filled in asynchronously via the fragment routes
    id = utils.query_param(req, "id")
    data = {
        "Title": "Container detail",
        "Nav": "containers",
        "Id": id,
        "Error": "",
        "Container": None,
        "Perms": utils.get_perms(),
        "HelpUrl": utils.docs_link("/docs/container/overview/"),
    }

    ret = openrun.get_container(id, stats=False)
    if ret.error:
        data["Error"] = ret.error
        return data

    c = dict(ret.value.items())
    c["started_at"] = utils.nonzero_time(c.get("started_at"))
    data["Container"] = c
    return data


def containers_detail_stats_handler(req):
    # Slow fragment: live resource stats and disk usage
    id = utils.query_param(req, "id")
    data = {"Id": id, "Container": None, "StatsError": "", "StatsLoaded": True}

    ret = openrun.get_container(id)
    if ret.error:
        data["StatsError"] = ret.error
        return data

    c = dict(ret.value.items())
    c["size_rw_human"] = utils.human_size(c.get("size_rw") or 0)
    c["size_root_human"] = utils.human_size(c.get("size_root_fs") or 0)
    if c.get("stats"):
        stats = dict(c["stats"].items())
        stats["cpu_num"] = utils.pct_num(stats.get("cpu_percent"))
        stats["mem_num"] = utils.pct_num(stats.get("mem_percent"))
        c["stats"] = stats
    data["Container"] = c
    return data


def containers_k8s_stats_handler(req):
    # Async fragment on the container list: pod stats of the kubernetes
    # namespaces (system and apps). Renders nothing for the other runtimes
    ret = openrun.kubernetes_stats()
    if ret.error:
        return {"K8s": None, "K8sError": ret.error}
    return {"K8s": ret.value if ret.value["enabled"] else None, "K8sError": ""}


def containers_detail_k8s_handler(req):
    # Async fragment on the container detail page: kubernetes specific pod
    # status (conditions, container states, recent events)
    id = utils.query_param(req, "id")
    data = {"Id": id, "K8s": None, "K8sError": ""}
    ret = openrun.container_kubernetes_status(id)
    if ret.error:
        data["K8sError"] = ret.error
        return data
    data["K8s"] = ret.value
    return data


def containers_logs_stream_handler(req):
    # Streaming TEXT route: the last tail lines of the container logs,
    # optionally following new output (follow=1) until the client
    # disconnects. Rendered by the <log-tail> element on the detail page
    id = utils.query_param(req, "id")
    tail = utils.query_param(req, "tail")
    tail_int = int(tail) if tail.isdigit() else 500
    if tail_int > 10000:
        tail_int = 10000
    follow = utils.query_param(req, "follow") == "1"

    ret = openrun.container_logs_stream(id, tail=tail_int, follow=follow)
    if ret.error:
        return "error: %s" % ret.error
    # Return the stream response object itself; the framework streams it
    return ret


# ---------- Audit logs ----------


AUDIT_FILTERS = ["app_glob", "event_type", "operation", "target", "user_id",
                 "status", "start_date", "end_date", "rid"]


def audit_data(req):
    # Audit logs page: filtered events with keyset-paged infinite scroll
    filters = {}
    for key in AUDIT_FILTERS:
        filters[key] = utils.query_param(req, key)
    before = utils.query_param(req, "before_timestamp")

    data = {
        "Title": "Audit Logs",
        "Nav": "audit",
        "Filters": filters,
        "Events": [],
        "Apps": [],
        "Operations": [],
        "NextPage": "",
        "Perms": utils.get_perms(),
    }

    ret = openrun.list_audit_events(app_glob=filters["app_glob"], user_id=filters["user_id"],
                                    event_type=filters["event_type"], operation=filters["operation"],
                                    target=filters["target"], status=filters["status"],
                                    start_date=filters["start_date"], end_date=filters["end_date"],
                                    rid=filters["rid"], before_timestamp=before)
    if ret.error:
        data["FlashError"] = ret.error
        return data

    data["IsMore"] = bool(before)

    events = []
    for entry in ret.value:
        e = dict(entry.items())
        status = e.get("status") or ""
        if status == "Success" or status.startswith("2") or status.startswith("3"):
            e["status_style"] = "ok"
        elif status:
            e["status_style"] = "error"
        else:
            e["status_style"] = ""
        events.append(e)
    data["Events"] = events

    # Keyset pagination for the infinite scroll: the next page starts before
    # the oldest event on this page
    if events:
        parts = []
        for key in AUDIT_FILTERS:
            parts.append(key + "=" + filters[key])
        parts.append("before_timestamp=" + events[-1]["create_time_epoch"])
        data["NextPage"] = req.AppPath + "/audit?" + "&".join(parts)

    # Filter dropdown contents are only needed for the full page render
    if not before:
        apps_ret = openrun.list_all_apps()
        if not apps_ret.error:
            data["Apps"] = sorted([entry["path"] for entry in apps_ret.value])
        ops_ret = openrun.list_operations()
        if not ops_ret.error:
            data["Operations"] = ops_ret.value
    return data


# ---------- Configuration ----------

# Config entry sections shown on the sub pages. Each descriptor drives one
# entry table and the generic entry form; the backend API is generic (any
# named-entry section of openrun.toml), so adding a section here requires no
# backend change. Field kinds: text (default), secret, bool, list (one value
# per line). Sections with "kv": True have free-form properties instead of
# fixed fields, edited as key/value rows. Secret fields round-trip as the
# "<redacted>" placeholder, which the backend swaps for the stored value.
# Fields with "secretable": True render as a secret-input component (the
# value can be encrypted into the secrets store with one click, using the
# section's "secret_prefix" for generated names); "file": True additionally
# offers storing a picked file's content
REDACTED_VALUE = "<redacted>"

CONFIG_SECTIONS = [
    {
        "section": "git_auth",
        "title": "Git auth",
        "desc": "SSH keys for private git repo access",
        "name_help": "the name used as git_auth in app create and sync setup",
        "secret_prefix": "gitauth",
        "fields": [
            {"name": "user_id", "label": "User id", "secretable": True, "help": "ssh user, defaults to git"},
            {"name": "private_key", "label": "Private key", "kind": "secret", "secretable": True, "file": True,
             "help": "the private key contents; pick the key file to store it encrypted in the secrets store"},
            {"name": "key_file_path", "label": "Key file path", "help": "path to the private key file on the server, when the key is not set inline"},
            {"name": "password", "label": "Key password", "kind": "secret", "secretable": True, "help": "password for the private key file, if any"},
        ],
    },
    {
        "section": "auth",
        "title": "OAuth / OIDC accounts",
        "desc": "login providers, usable as app auth",
        "name_help": "provider type, optionally with a _suffix: github, google_mycorp, oidc_okta, auth0, okta, gitlab, ...",
        "secret_prefix": "oauth",
        "fields": [
            {"name": "key", "label": "Client id", "secretable": True},
            {"name": "secret", "label": "Client secret", "kind": "secret", "secretable": True},
            {"name": "org_url", "label": "Org URL", "help": "required for okta"},
            {"name": "domain", "label": "Domain", "help": "required for auth0"},
            {"name": "discovery_url", "label": "Discovery URL", "help": "required for oidc"},
            {"name": "hosted_domain", "label": "Hosted domain", "help": "google workspace domain restriction"},
            {"name": "scopes", "label": "Scopes", "kind": "list", "help": "one oauth scope per line"},
        ],
    },
    {
        "section": "saml",
        "title": "SAML accounts",
        "desc": "SAML identity providers, used as saml_<name> app auth",
        "name_help": "used as saml_<name> in app auth settings",
        "fields": [
            {"name": "metadata_url", "label": "Metadata URL", "help": "the IdP metadata url"},
            {"name": "groups_attr", "label": "Groups attribute", "help": "SAML attribute carrying the group list"},
            {"name": "use_post", "label": "Use POST binding", "kind": "bool"},
            {"name": "force_authn", "label": "Force authn", "kind": "bool"},
            {"name": "sp_key_file", "label": "SP key file", "help": "path on the server"},
            {"name": "sp_cert_file", "label": "SP cert file", "help": "path on the server"},
        ],
    },
    {
        "section": "secret",
        "title": "Secrets managers",
        "desc": "secret providers, used by {{secret ...}} templates in config and params",
        "name_help": "provider type, optionally with a _suffix: asm, ssm, vault, env, prop, kubernetes (e.g. asm_prod)",
        "kv": True,
        "kv_label": "Properties",
        "kv_help": "provider specific properties (e.g. region for asm). " +
                   "Values are parsed as numbers/booleans when possible; use \"quotes\" to force a string",
        "secret_prefix": "secretmgr",
        "fields": [],
    },
    {
        "section": "builder_agent",
        "title": "Agent configs",
        "desc": "AI agent configurations for the app builder",
        "name_help": "agent type with optional _suffix: opencode, opencode_dev, claude, codex, pi, " +
                     "or custom_<name> (custom needs dockerfile + command). The type comes from the name",
        "fields": [
            {"name": "dockerfile", "label": "Dockerfile path",
             "help": "server path to a Dockerfile overriding the embedded one; required for custom_* agents"},
            {"name": "command", "label": "ACP command", "kind": "list",
             "help": "command speaking ACP on stdio, one argument per line; required for custom_* " +
                     "agents, overrides the type default otherwise"},
            {"name": "env", "label": "Container env", "kind": "kvtable",
             "help": "environment variables set in the agent sandbox (API keys go here; " +
                     "use the lock button to store a value as a {{secret ...}} reference)"},
            {"name": "config_files", "label": "Config file mounts", "kind": "list",
             "help": "host:container[:ro] mounts for agent config/auth files, one per line"},
            {"name": "model", "label": "Model",
             "help": "model passed to the agent at session start, in the agent's naming " +
                     "(e.g. anthropic/claude-fable-5); empty uses the agent's default"},
            {"name": "effort", "label": "Effort level",
             "help": "reasoning effort passed to the agent at session start (e.g. low, medium, high); " +
                     "empty uses the agent's default"},
        ],
    },
    {
        "section": "builder_profile",
        "title": "Builder profiles",
        "desc": "how builder apps are built and published: agent config, git target, publish " +
                "destination, default spec and prompt. With none configured, the built-in default " +
                "applies (opencode, local publish, publish anywhere); with several, the new-app " +
                "form asks which to use",
        "name_help": "short name shown in the new-app form (e.g. internal_tool, dashboard)",
        "fields": [
            {"name": "agent", "label": "Agent config", "kind": "select", "options": "builder_agent",
             "required": True,
             "help": "builder_agent entry sessions created with this profile run (required)"},
            {"name": "git_config", "label": "Git target", "kind": "select", "options": "builder_git",
             "empty_label": "none (publish locally)",
             "help": "builder_git entry apps publish to; empty publishes locally to $OPENRUN_HOME/app_src"},
            {"name": "publish_mode", "label": "Publish destination type", "kind": "select",
             "options_list": ["subdomain", "path", "glob"],
             "empty_label": "anywhere (no restriction)",
             "help": "shapes the publish dialog: subdomain - the user types a subdomain of the " +
                     "target domain; path - the user types an app name under the target path prefix; " +
                     "glob - the user types a full path matching the target glob"},
            {"name": "publish_target", "label": "Publish destination",
             "help": "subdomain: the parent domain, ending in . appends the server default_domain " +
                     "(\".\" alone = subdomain of the default domain); path: the path prefix (e.g. " +
                     "/teams); glob: the app path glob (e.g. /teams/* or example.com:/**)"},
            {"name": "spec", "label": "Default spec", "kind": "select", "options": "specs",
             "empty_label": "none (plain OpenRun app)",
             "help": "framework scaffold new sessions start from; empty builds a plain server-rendered app"},
            {"name": "services", "label": "Bindable services", "kind": "checklist",
             "options": "builder_services",
             "help": "services the new-app form offers for auto binding: pick specific services, " +
                     "\"defaults\" to offer the default service of each type, or none to offer " +
                     "no services. The app gets one auto binding per chosen service (one per type)"},
            {"name": "prompt", "label": "Prompt", "kind": "textarea",
             "help": "instructions for the agent; appended to the system prompt, or replacing it when Replace is set"},
            {"name": "replace", "label": "Replace the system prompt", "kind": "bool",
             "help": "when set this profile's prompt replaces the system prompt entirely instead of being appended"},
            {"name": "description", "label": "Description",
             "help": "shown next to the profile in the new-app form"},
        ],
    },
    {
        "section": "builder_git",
        "title": "Git targets",
        "desc": "named git repos builder apps publish to; a builder profile picks one via " +
                "Git target; no choice publishes locally",
        "name_help": "short name for this repo (e.g. tools, prod)",
        "fields": [
            {"name": "repo", "label": "Repo",
             "help": "git repo url for publish commits (e.g. github.com/org/apps)"},
            {"name": "branch", "label": "Branch",
             "help": "branch for publish commits; empty means main"},
            {"name": "auth", "label": "Git auth", "kind": "select", "options": "git_auths",
             "empty_label": "none (public repo)", "default_from": "git_auth_default",
             "help": "git_auth entry for this repo; empty for public/unauthenticated"},
            {"name": "apps_file", "label": "Apps file",
             "help": "declarative file relative to the repo root; empty means apps.star"},
            {"name": "source_dir", "label": "Source directory",
             "help": "repo directory for published app sources; empty means apps"},
        ],
    },
]


def config_section_meta(section):
    for meta in CONFIG_SECTIONS:
        if meta["section"] == section:
            return meta
    return None


# Config sub pages under /config. Each page groups entry sections (tables of
# named entries) and settings (individual fields of the struct sections,
# set through set_config_value). Setting kinds: text (default), select, bool,
# int. select options come from the named source resolved in
# config_setting_options. All changes on these pages are live immediately
CONFIG_PAGES = [
    {
        "page": "auth",
        "title": "Authentication",
        "desc": "login providers and the default app authentication",
        "entry_sections": ["auth", "saml"],
        "settings": [
            {"section": "security", "key": "app_default_auth_type",
             "label": "Default app auth", "kind": "select", "options": "auths",
             "help": "auth used for apps set to 'default': none/system, or any oauth, saml or client cert auth (cert auths are configured in openrun.toml)"},
        ],
    },
    {
        "page": "git",
        "title": "Git auth",
        "desc": "git credentials for private repos and the default entry",
        "entry_sections": ["git_auth"],
        "settings": [
            {"section": "security", "key": "default_git_auth",
             "label": "Default git auth", "kind": "select", "options": "git_auths",
             "help": "git auth entry used when an app or sync does not name one"},
        ],
    },
    {
        "page": "secrets",
        "title": "Secrets",
        "desc": "secret manager providers",
        "entry_sections": ["secret"],
        "settings": [],
    },
    {
        "page": "system",
        "title": "System",
        "desc": "server level defaults, app config and node config overrides",
        "entry_sections": [],
        "settings": [
            {"section": "system", "key": "default_domain", "label": "Default domain",
             "help": "domain used for apps created without a domain"},
            {"section": "system", "key": "stage_at", "label": "Stage at",
             "help": "staging mode for new prod apps: domain, path, or a staging domain name"},
            {"section": "system", "key": "list_apps_title", "label": "List apps title",
             "help": "title of the app listing page"},
            {"section": "system", "key": "show_hosted_with", "label": "Show \"Hosted with OpenRun\"",
             "kind": "bool", "help": "footer on the app listing page"},
        ],
        "kv_sections": [
            {"section": "app_config",
             "title": "App config defaults",
             "help": "defaults applied to all apps on their next reload - dotted keys like " +
                     "cors.allow_origin or container.health_timeout_secs. Values are parsed as " +
                     "numbers/booleans when possible; use \"quotes\" to force a string",
             "placeholder": "cors.allow_origin"},
            {"section": "node_config",
             "title": "Node config",
             "help": "values apps read with the config() builtin, applied on their next " +
                     "reload - free form keys. Values are parsed as numbers/booleans when " +
                     "possible; use \"quotes\" to force a string",
             "placeholder": "key_name"},
        ],
    },
    {
        "page": "builder",
        "title": "App builder",
        "desc": "agent configs, git targets, builder profiles and builder settings",
        "entry_sections": ["builder_agent", "builder_git", "builder_profile"],
        "settings": [
            {"section": "app_builder", "key": "enabled", "label": "Enabled", "kind": "bool",
             "help": "the AI app builder (Builder tab); needs a docker/podman runtime, not supported on Kubernetes"},
            {"section": "app_builder", "key": "default_builder_profile", "label": "Default builder profile",
             "kind": "select", "options": "builder_profile",
             "help": "builder_profile entry used when the user does not pick one; empty auto-uses a " +
                     "single profile, or the built-in opencode default when none are configured"},
            {"section": "app_builder", "key": "preview_path", "label": "Preview path prefix", "advanced": True,
             "help": "where draft preview apps are mounted"},
            {"section": "app_builder", "key": "max_sessions", "label": "Max live sessions", "kind": "int",
             "advanced": True,
             "help": "concurrent agent sandboxes; further creates ask to stop an idle session"},
            {"section": "app_builder", "key": "session_idle_mins", "label": "Session idle minutes", "kind": "int",
             "advanced": True,
             "help": "stop the agent sandbox after this idle time (the draft and transcript remain)"},
            {"section": "app_builder", "key": "system_prompt", "label": "System prompt", "kind": "textarea",
             "advanced": True,
             "help": "replaces the embedded base prompt sent to the agent; leave empty for the built-in default"},
        ],
    },
]


def config_page_meta(page):
    for meta in CONFIG_PAGES:
        if meta["page"] == page:
            return meta
    return None


def config_page_for_section(section):
    # The sub page owning an entry section, for redirects after entry edits
    for meta in CONFIG_PAGES:
        if section in meta["entry_sections"]:
            return meta["page"]
    return ""


def config_setting_options(source):
    # Resolve a select setting's option list by source name (shared by the
    # settings rows and the entry-form select fields)
    if source == "auths":
        ret = openrun.list_auths()
        # "default" is what the setting resolves, exclude it from the choices
        return [a for a in (ret.value if not ret.error else []) if a != "default"]
    if source == "git_auths":
        ret = openrun.list_git_auths()
        return list(ret.value["entries"]) if not ret.error else []
    if source == "specs":
        ret = openrun.list_specs()
        error = ret.error
        return sorted([s for s in (ret.value or []) if s != "dummy"]) if not error else []
    if source == "builder_services":
        # "defaults" plus the live service ids, for the profile services
        # checklist
        ret = openrun.list_services()
        error = ret.error
        options = ["defaults"]
        if not error:
            for entry in ret.value:
                options.append(entry["service_type"] + "/" + entry["name"])
        return options
    if source in ("builder_agent", "builder_git", "builder_profile"):
        # Config entry names of the section, dynamic and static merged
        ret = openrun.get_config_entries([source])
        error = ret.error
        if error:
            return []
        names = {}
        for entry in ret.value["sections"].get(source) or []:
            names[entry["name"]] = True
        return sorted(names.keys())
    return []


def parse_config_value(raw):
    # Free-form config values: booleans and numbers are typed, "quotes" force
    # a string, everything else stays a string
    raw = raw.strip()
    if len(raw) >= 2 and raw.startswith('"') and raw.endswith('"'):
        return raw[1:-1]
    if raw == "true":
        return True
    if raw == "false":
        return False
    if raw.lstrip("-").isdigit() and raw.lstrip("-"):
        return int(raw)
    intpart = raw.lstrip("-")
    if intpart.count(".") == 1:
        left, right = intpart.split(".")
        if left.isdigit() and right.isdigit():
            return float(raw)
    return raw


def rbac_permission_groups():
    # The canonical permission list, grouped by resource type, from the
    # server (types.RBACPermissionGroups). Ordered list of
    # {resource, permissions} entries
    ret = openrun.list_rbac_permissions()
    return ret.value if not ret.error else []


def rbac_section(rbac):
    # Massage one RBAC config (live or draft) for display
    groups = []
    for name in sorted((rbac.get("groups") or {}).keys()):
        groups.append({"name": name, "users": rbac["groups"][name] or []})
    roles = []
    for name in sorted((rbac.get("roles") or {}).keys()):
        roles.append({"name": name, "permissions": rbac["roles"][name] or []})
    grants = []
    for i, grant in enumerate(rbac.get("grants") or []):
        grants.append({
            "index": i,
            "description": grant.get("description") or "",
            "users": grant.get("users") or [],
            "roles": grant.get("roles") or [],
            "targets": grant.get("targets") or [],
        })
    return {
        "enabled": rbac.get("enabled") or False,
        "groups": groups,
        "roles": roles,
        "grants": grants,
    }


def rbac_diff(live, draft):
    # Names of entities that differ between live and draft, per category
    def dict_diff(a, b):
        changed = []
        for name in sorted(dict(a.items() + b.items()).keys()):
            if a.get(name) != b.get(name):
                changed.append(name)
        return changed

    diff = {
        "groups": dict_diff(live.get("groups") or {}, draft.get("groups") or {}),
        "roles": dict_diff(live.get("roles") or {}, draft.get("roles") or {}),
        "grants": len(draft.get("grants") or []) != len(live.get("grants") or []) or
                  (live.get("grants") or []) != (draft.get("grants") or []),
        "enabled": (live.get("enabled") or False) != (draft.get("enabled") or False),
    }
    diff["any"] = bool(diff["groups"] or diff["roles"] or diff["grants"] or diff["enabled"])
    return diff


def config_data(req):
    # Top-level configuration page: one card per config area (RBAC and the
    # sub pages) and the config history
    data = {
        "Title": "Configuration",
        "Nav": "config",
        "Error": "",
        "Perms": utils.get_perms(),
        "History": [],
        "Pages": [],
    }

    ret = openrun.get_rbac_config()
    if ret.error:
        data["Error"] = ret.error
        return data

    cfg = ret.value
    live = rbac_section(cfg["rbac"])
    data["VersionId"] = cfg["version_id"]
    data["RBAC"] = {
        "enabled": live["enabled"],
        "groups": len(live["groups"]),
        "roles": len(live["roles"]),
        "grants": len(live["grants"]),
        "has_staged": cfg["has_staged"],
        "staged_by": cfg["draft"]["updated_by"] if cfg["has_staged"] else "",
    }

    all_sections = []
    for meta in CONFIG_PAGES:
        all_sections.extend(meta["entry_sections"])
    entries = openrun.get_config_entries(all_sections)
    if entries.error:
        data["Error"] = entries.error
        return data
    values = openrun.get_config_values()
    if values.error:
        data["Error"] = values.error
        return data

    for meta in CONFIG_PAGES:
        entry_count = 0
        for section in meta["entry_sections"]:
            for entry in entries.value["sections"].get(section) or []:
                if not (entry["source"] == "static" and entry["overridden"]):
                    entry_count += 1
        # One count per managed setting key that has a dynamic override, plus
        # all keys of the page's free-form kv sections
        dynamic_count = 0
        for setting in meta["settings"]:
            section_values = values.value["sections"].get(setting["section"]) or {}
            if setting["key"] in (section_values.get("dynamic") or {}):
                dynamic_count += 1
        for kv in meta.get("kv_sections") or []:
            kv_values = values.value["sections"].get(kv["section"]) or {}
            dynamic_count += len(kv_values.get("dynamic") or {})
        data["Pages"].append({
            "page": meta["page"],
            "title": meta["title"],
            "desc": meta["desc"],
            "entry_count": entry_count,
            "has_entries": len(meta["entry_sections"]) > 0,
            "dynamic_count": dynamic_count,
        })

    hist = openrun.list_config_history()
    if not hist.error:
        data["History"] = hist.value
    return data


def _has_static(entries, name):
    for entry in entries:
        if entry["name"] == name and entry["source"] == "static":
            return True
    return False


def entry_summary(meta, values):
    # Compact "field: value" display line for an entry card row, secrets and
    # empty fields skipped. Free-form kv entries list all their properties
    # (values arrive redacted from the server)
    parts = []
    if meta.get("kv"):
        for key in sorted(values.keys()):
            parts.append("%s: %s" % (key, values[key]))
        return "  ·  ".join(parts)
    for field in meta["fields"]:
        kind = field.get("kind") or "text"
        value = values.get(field["name"])
        if kind == "secret" or value == None or value == "" or value == False or value == []:
            continue
        if kind == "list":
            value = ", ".join([str(v) for v in value])
        parts.append("%s: %s" % (field["name"], value))
    return "  ·  ".join(parts)


def config_action_handler(req):
    # Top-level page action: history restore, live immediately
    action = utils.query_param(req, "action")
    force = utils.query_param(req, "force") == "true"

    if action == "restore":
        ret = openrun_admin.restore_config(utils.query_param(req, "restore_version"), force=force)
        ok = "Configuration restored"
    else:
        data = config_data(req)
        data["FlashError"] = "unknown action %s" % action
        return data

    error = ret.error
    return utils.flash_result(config_data(req), error, ok)


def config_page_data(req, page):
    # A config sub page: the page's settings (with effective values and
    # dynamic badges), entry section tables and the app_config key/value table
    meta = config_page_meta(page)
    data = {
        "Title": meta["title"] + " configuration",
        "Nav": "config",
        "Error": "",
        "Perms": utils.get_perms(),
        "Page": meta["page"],
        "PageTitle": meta["title"],
        "PageDesc": meta["desc"],
        "Settings": [],
        "AdvancedSettings": [],
        "Sections": [],
        "KVs": [],
    }

    ret = openrun.get_rbac_config()
    if ret.error:
        data["Error"] = ret.error
        return data
    data["VersionId"] = ret.value["version_id"]

    sections = [s["section"] for s in meta["settings"]]
    for kv in meta.get("kv_sections") or []:
        sections.append(kv["section"])
    values = {"sections": {}}
    if sections:
        ret = openrun.get_config_values(sections)
        if ret.error:
            data["Error"] = ret.error
            return data
        values = ret.value

    for setting in meta["settings"]:
        section_values = values["sections"].get(setting["section"]) or {}
        dynamic = section_values.get("dynamic") or {}
        static = section_values.get("static") or {}
        is_dynamic = setting["key"] in dynamic
        value = dynamic[setting["key"]] if is_dynamic else static.get(setting["key"])
        row = dict(setting)
        row["kind"] = setting.get("kind") or "text"
        row["value"] = value if value != None else ""
        row["is_dynamic"] = is_dynamic
        row["static_value"] = static.get(setting["key"])
        if row["kind"] == "select":
            row["option_list"] = config_setting_options(setting.get("options") or "")
        # advanced settings render in a collapsed section, hidden by default
        if setting.get("advanced"):
            data["AdvancedSettings"].append(row)
        else:
            data["Settings"].append(row)

    for kv in meta.get("kv_sections") or []:
        dynamic = (values["sections"].get(kv["section"]) or {}).get("dynamic") or {}
        rows = []
        for key in sorted(dynamic.keys()):
            rows.append({"key": key, "value": dynamic[key]})
        data["KVs"].append({
            "section": kv["section"],
            "title": kv.get("title") or kv["section"],
            "help": kv.get("help") or "",
            "placeholder": kv.get("placeholder") or "",
            "rows": rows,
        })

    if meta["entry_sections"]:
        entries = openrun.get_config_entries(meta["entry_sections"])
        if entries.error:
            data["Error"] = entries.error
            return data
        for section in meta["entry_sections"]:
            section_meta = config_section_meta(section)
            section_entries = []
            for entry in entries.value["sections"].get(section) or []:
                # A static entry shadowed by a dynamic one is not listed; the
                # dynamic entry shows the "overrides static" badge
                if entry["source"] == "static" and entry["overridden"]:
                    continue
                overrides = entry["source"] == "dynamic" and _has_static(entries.value["sections"][section], entry["name"])
                section_entries.append({
                    "name": entry["name"],
                    "source": entry["source"],
                    "overrides": overrides,
                    "summary": entry_summary(section_meta, entry["values"]),
                })
            data["Sections"].append({
                "section": section,
                "title": section_meta["title"],
                "desc": section_meta["desc"],
                "entries": section_entries,
            })
    return data


def _page_kv_section(meta, section):
    # The kv section from the form must be one this page manages
    for kv in meta.get("kv_sections") or []:
        if kv["section"] == section:
            return section
    return ""


def config_page_action_handler(req, page):
    # Sub page actions: set/reset a settings field, delete a dynamic entry,
    # set/delete an app_config key. All take effect immediately
    meta = config_page_meta(page)
    action = utils.query_param(req, "action")
    version_id = utils.query_param(req, "version_id")
    section = utils.query_param(req, "section")
    key = utils.query_param(req, "key")

    if action == "set_value":
        kind = utils.query_param(req, "kind")
        raw = utils.query_param(req, "value")
        if kind == "bool":
            ret = openrun_admin.set_config_value(section, key, raw == "on", version_id)
            ok = "Set %s %s - change is live" % (section, key)
        elif raw.strip() == "":
            # Clearing the field resets to the static config value
            if utils.query_param(req, "is_dynamic") == "true":
                ret = openrun_admin.delete_config_value(section, key, version_id)
                ok = "Reset %s %s to the static config value" % (section, key)
            else:
                data = config_page_data(req, page)
                data["FlashError"] = "no value provided for %s %s" % (section, key)
                return data
        elif kind == "int":
            if not raw.strip().lstrip("-").isdigit():
                data = config_page_data(req, page)
                data["FlashError"] = "%s %s must be a number" % (section, key)
                return data
            ret = openrun_admin.set_config_value(section, key, int(raw.strip()), version_id)
            ok = "Set %s %s - change is live" % (section, key)
        else:
            ret = openrun_admin.set_config_value(section, key, raw.strip(), version_id)
            ok = "Set %s %s - change is live" % (section, key)
    elif action == "delete_value":
        ret = openrun_admin.delete_config_value(section, key, version_id)
        ok = "Reset %s %s to the static config value" % (section, key)
    elif action == "delete_entry":
        name = utils.query_param(req, "name")
        ret = openrun_admin.delete_config_entry(section, name, version_id)
        ok = "Deleted %s entry %s - change is live" % (section, name)
    elif action == "kv_set":
        kv_section = _page_kv_section(meta, utils.query_param(req, "kv_section"))
        kv_key = utils.query_param(req, "key").strip()
        if not kv_section or not kv_key:
            data = config_page_data(req, page)
            data["FlashError"] = "key cannot be empty" if kv_section else "unknown kv section"
            return data
        value = parse_config_value(utils.query_param(req, "value"))
        ret = openrun_admin.set_config_value(kv_section, kv_key, value, version_id)
        ok = "Set %s %s - applies on the next app reload" % (kv_section, kv_key)
    elif action == "kv_delete":
        kv_section = _page_kv_section(meta, utils.query_param(req, "kv_section"))
        if not kv_section:
            data = config_page_data(req, page)
            data["FlashError"] = "unknown kv section"
            return data
        ret = openrun_admin.delete_config_value(kv_section, utils.query_param(req, "key"), version_id)
        ok = "Removed %s %s" % (kv_section, utils.query_param(req, "key"))
    else:
        data = config_page_data(req, page)
        data["FlashError"] = "unknown action %s" % action
        return data

    error = ret.error
    return utils.flash_result(config_page_data(req, page), error, ok)


def config_auth_data(req):
    return config_page_data(req, "auth")


def config_auth_action_handler(req):
    return config_page_action_handler(req, "auth")


def config_git_data(req):
    return config_page_data(req, "git")


def config_git_action_handler(req):
    return config_page_action_handler(req, "git")


def config_secrets_data(req):
    return config_page_data(req, "secrets")


def config_secrets_action_handler(req):
    return config_page_action_handler(req, "secrets")


def config_system_data(req):
    return config_page_data(req, "system")


def config_system_action_handler(req):
    return config_page_action_handler(req, "system")


def config_builder_data(req):
    return config_page_data(req, "builder")


def config_builder_action_handler(req):
    return config_page_action_handler(req, "builder")


def config_rbac_data(req):
    # RBAC sub page: live/staged groups/roles/grants tables with the staged
    # draft publish workflow
    data = {
        "Title": "RBAC configuration",
        "Nav": "config",
        "Error": "",
        "Perms": utils.get_perms(),
    }

    ret = openrun.get_rbac_config()
    if ret.error:
        data["Error"] = ret.error
        return data

    cfg = ret.value
    data["VersionId"] = cfg["version_id"]
    data["HasStaged"] = cfg["has_staged"]
    data["DraftVersion"] = ""
    data["Live"] = rbac_section(cfg["rbac"])
    # The tables show the draft when one exists; enforcement uses live.
    # ?view=live switches to a read-only view of the live config while a
    # draft is pending (no-op without a draft, the tables show live anyway)
    data["ViewLive"] = cfg["has_staged"] and utils.query_param(req, "view") == "live"
    if cfg["has_staged"] and not data["ViewLive"]:
        data["View"] = rbac_section(cfg["staged"])
    else:
        data["View"] = data["Live"]
    if cfg["has_staged"]:
        data["Diff"] = rbac_diff(cfg["rbac"], cfg["staged"])
        data["Draft"] = cfg["draft"]
        data["DraftVersion"] = cfg["draft"]["draft_version"]
    return data


def config_rbac_action_handler(req):
    # Publish / discard / toggle-enabled / delete actions on the RBAC page.
    # All of these edit the staged draft except publish/discard
    action = utils.query_param(req, "action")
    draft_version = utils.query_param(req, "draft_version")
    force = utils.query_param(req, "force") == "true"

    if action == "publish":
        ret = openrun_admin.publish_rbac_config(draft_version, force=force)
        ok = "Published RBAC configuration"
    elif action == "discard":
        ret = openrun_admin.discard_rbac_draft(draft_version)
        ok = "Discarded staged changes"
    elif action == "toggle_enabled":
        enabled = utils.query_param(req, "enabled") == "true"
        ret = openrun_admin.update_rbac_enabled(enabled, draft_version)
        ok = "RBAC %s in the staged config - publish to apply" % ("enabled" if enabled else "disabled")
    elif action == "delete_group":
        ret = openrun_admin.delete_rbac_group(utils.query_param(req, "name"), draft_version)
        ok = "Deleted group %s from the staged config" % utils.query_param(req, "name")
    elif action == "delete_role":
        ret = openrun_admin.delete_rbac_role(utils.query_param(req, "name"), draft_version)
        ok = "Deleted role %s from the staged config" % utils.query_param(req, "name")
    elif action == "delete_grant":
        ret = openrun_admin.delete_rbac_grant(int(utils.query_param(req, "index")), draft_version)
        ok = "Deleted grant from the staged config"
    else:
        data = config_rbac_data(req)
        data["FlashError"] = "unknown action %s" % action
        return data

    error = ret.error
    return utils.flash_result(config_rbac_data(req), error, ok)


# Documentation page per config section, for the entry form help link;
# sections without an entry link the configuration overview
CONFIG_SECTION_DOCS = {
    "auth": "/docs/configuration/authentication/",
    "saml": "/docs/configuration/authentication/",
    "git_auth": "/docs/configuration/security/",
    "secret": "/docs/configuration/secrets/",
}


def config_entry_form_data(req, meta, name, values, is_edit, source, error):
    # Page context for the generic config entry form
    ret = openrun.get_rbac_config()
    version_id = ret.value["version_id"] if not ret.error else ""
    field_options = {}
    for field in meta["fields"]:
        if field.get("kind") in ("select", "checklist"):
            # options_list is a fixed choice list; options names a dynamic
            # source resolved by config_setting_options
            if field.get("options_list"):
                field_options[field["name"]] = field["options_list"]
            else:
                field_options[field["name"]] = config_setting_options(field.get("options") or "")
    return {
        "Title": "Configuration",
        "Nav": "config",
        "Meta": meta,
        "Name": name,
        "Values": values,
        "IsEdit": is_edit,
        "Source": source,
        "Error": error,
        "FieldOptions": field_options,
        "VersionId": version_id,
        "Perms": utils.get_perms(),
        "ReturnPath": "/config/" + config_page_for_section(meta["section"]),
        "HelpUrl": utils.docs_link(CONFIG_SECTION_DOCS.get(meta["section"], "/docs/configuration/overview/")),
    }


def config_entry_page_handler(req):
    # Generic entry form page (any CONFIG_SECTIONS section). With a name, the
    # form edits the dynamic entry, or overrides the static entry of that name
    section = utils.query_param(req, "section")
    name = utils.query_param(req, "name")
    meta = config_section_meta(section)
    if not meta:
        return ace.redirect(req.AppPath + "/config")

    values = {}
    source = ""
    if name:
        ret = openrun.get_config_entries([section])
        if ret.error:
            return config_entry_form_data(req, meta, name, values, False, "", ret.error)
        # Prefer the dynamic entry; fall back to the static one so an
        # override form starts prefilled with the static values
        for entry in ret.value["sections"].get(section) or []:
            if entry["name"] == name and (entry["source"] == "dynamic" or not source):
                values = entry["values"]
                source = entry["source"]
    if meta.get("kv"):
        # Free-form entries edit as key/value rows; secret-ish values arrive
        # redacted and round-trip through the placeholder
        values = {"properties_rows": utils.kv_rows(values)}
    for field in meta["fields"]:
        # kvtable fields edit their dict value as key/value rows
        if field.get("kind") == "kvtable":
            values[field["name"] + "_rows"] = utils.kv_rows(values.get(field["name"]) or {})
        # New-entry forms preselect declared field defaults (the builder_git
        # auth select starts on the server's default git auth)
        if not name and field.get("default_from") == "git_auth_default":
            values[field["name"]] = git_auth_options()["default"]
    return config_entry_form_data(req, meta, name, values, source == "dynamic", source, "")


def config_entry_submit_handler(req):
    # POST: save one dynamic config entry. The change is validated and takes
    # effect immediately (config entries are not staged, unlike RBAC)
    section = utils.query_param(req, "section")
    meta = config_section_meta(section)
    if not meta:
        return form_redirect(req, req.AppPath + "/config")

    name = utils.query_param(req, "name").strip()
    is_edit = utils.query_param(req, "is_edit") == "true"
    values = {}
    if meta.get("kv"):
        rows = utils.raw_kv_rows(req, "properties")
        parsed, error = utils.parse_kv_rows(req, "properties")
        if error:
            return config_entry_form_data(req, meta, name, {"properties_rows": rows},
                                          is_edit, utils.query_param(req, "source"), error)
        for key in parsed:
            values[key] = parse_config_value(parsed[key])
        ret = openrun_admin.set_config_entry(section, name, values, utils.query_param(req, "version_id"))
        if ret.error:
            return config_entry_form_data(req, meta, name, {"properties_rows": rows},
                                          is_edit, utils.query_param(req, "source"), ret.error)
        return form_redirect(req, req.AppPath + "/config/" + config_page_for_section(section))
    for field in meta["fields"]:
        kind = field.get("kind") or "text"
        raw = utils.query_param(req, field["name"])
        if kind == "bool":
            if raw == "on":
                values[field["name"]] = True
        elif kind == "list":
            lines = utils.parse_lines(raw)
            if lines:
                values[field["name"]] = lines
        elif kind == "checklist":
            picked = [v.strip() for v in utils.query_param_list(req, field["name"]) if v.strip()]
            if picked:
                values[field["name"]] = picked
        elif kind == "textarea":
            # multi-line text, newlines preserved
            if raw.strip():
                values[field["name"]] = raw
        elif kind == "kvtable":
            # key/value rows (kv_table template); the _rows key is for form
            # re-render only and is stripped before the entry is saved
            values[field["name"] + "_rows"] = utils.raw_kv_rows(req, field["name"])
            parsed, error = utils.parse_kv_rows(req, field["name"])
            if error:
                return config_entry_form_data(req, meta, name, values, is_edit,
                                              utils.query_param(req, "source"),
                                              "%s: %s" % (field["label"], error))
            if parsed:
                values[field["name"]] = parsed
        elif kind == "secret":
            if raw:
                values[field["name"]] = raw
            elif is_edit and utils.query_param(req, field["name"] + "__keep") == "true":
                # Blank on edit keeps the stored secret via the placeholder
                values[field["name"]] = REDACTED_VALUE
        elif raw.strip():
            values[field["name"]] = raw.strip()

    submit_values = {k: values[k] for k in values.keys() if not k.endswith("_rows")}
    ret = openrun_admin.set_config_entry(section, name, submit_values, utils.query_param(req, "version_id"))
    if ret.error:
        return config_entry_form_data(req, meta, name, values, is_edit, utils.query_param(req, "source"), ret.error)
    return form_redirect(req, req.AppPath + "/config/" + config_page_for_section(section))


def load_rbac_config():
    # The form pages edit the staged config when a draft exists, else live
    ret = openrun.get_rbac_config()
    if ret.error:
        return {"error": ret.error, "rbac": {}, "draft_version": ""}
    cfg = ret.value
    return {
        "error": "",
        "rbac": cfg["staged"] if cfg["has_staged"] else cfg["rbac"],
        "draft_version": cfg["draft"]["draft_version"] if cfg["has_staged"] else "",
        "builtin_roles": cfg.get("builtin_roles") or [],
    }


def config_form_data(req, kind, values, error, cfg=None):
    # Page context shared by the group/role/grant forms
    cfg = cfg or load_rbac_config()
    rbac = cfg["rbac"]
    return {
        "Title": "Configuration",
        "Nav": "config",
        "Kind": kind,
        "Error": error,
        "Values": values,
        "Perms": utils.get_perms(),
        "PermGroups": rbac_permission_groups(),
        "DraftVersion": cfg["draft_version"],
        # Built-in roles (admin + openrun-*) are selectable in grants too
        "RoleNames": sorted((rbac.get("roles") or {}).keys()) + cfg.get("builtin_roles", []),
        "GroupNames": sorted((rbac.get("groups") or {}).keys()),
    }


def config_group_page_handler(req):
    # RBAC group form page, prefilled when editing
    name = utils.query_param(req, "name")
    cfg = load_rbac_config()
    values = {"name": name, "users_text": "", "is_edit": bool(name)}
    if name:
        values["users_text"] = "\n".join((cfg["rbac"].get("groups") or {}).get(name) or [])
    return config_form_data(req, "group", values, "", cfg)


def config_group_submit_handler(req):
    # POST: save a group to the staged config
    values = {
        "name": utils.query_param(req, "name").strip(),
        "users_text": utils.query_param(req, "users_text"),
        "is_edit": utils.query_param(req, "is_edit") == "true",
    }
    users = utils.parse_lines(values["users_text"])
    ret = openrun_admin.set_rbac_group(values["name"], users, utils.query_param(req, "draft_version"))
    if ret.error:
        return config_form_data(req, "group", values, ret.error)
    return form_redirect(req, req.AppPath + "/config/rbac")


def config_role_page_handler(req):
    # RBAC role form page, prefilled when editing
    name = utils.query_param(req, "name")
    cfg = load_rbac_config()
    values = {"name": name, "selected": {}, "custom_text": "", "is_edit": bool(name)}
    if name:
        # Split the role's entries into the known permission checkboxes and
        # free-form custom entries (globs, role references)
        known = {}
        for group in rbac_permission_groups():
            for p in group["permissions"]:
                known[p] = True
        custom = []
        for perm in (cfg["rbac"].get("roles") or {}).get(name) or []:
            if known.get(perm):
                values["selected"][perm] = True
            else:
                custom.append(perm)
        values["custom_text"] = "\n".join(custom)
    return config_form_data(req, "role", values, "", cfg)


def config_role_submit_handler(req):
    # POST: save a role (checkboxes + custom entries) to the staged config
    name = utils.query_param(req, "name").strip()
    perms = req.Form.get("permissions") or []
    custom_text = utils.query_param(req, "custom_text")
    values = {"name": name, "selected": {}, "custom_text": custom_text,
              "is_edit": utils.query_param(req, "is_edit") == "true"}
    for p in perms:
        values["selected"][p] = True
    all_perms = list(perms) + utils.parse_lines(custom_text)
    ret = openrun_admin.set_rbac_role(name, all_perms, utils.query_param(req, "draft_version"))
    if ret.error:
        return config_form_data(req, "role", values, ret.error)
    return form_redirect(req, req.AppPath + "/config/rbac")


def config_grant_page_handler(req):
    # RBAC grant form page, prefilled when editing by index
    index = utils.query_param(req, "index")
    cfg = load_rbac_config()
    values = {"index": index, "description": "", "users_text": "",
              "roles": {}, "targets_text": "", "is_edit": index != ""}
    grants = cfg["rbac"].get("grants") or []
    if index != "" and int(index) >= 0 and int(index) < len(grants):
        grant = grants[int(index)]
        values["description"] = grant.get("description") or ""
        values["users_text"] = "\n".join(grant.get("users") or [])
        values["targets_text"] = "\n".join(grant.get("targets") or [])
        for role in grant.get("roles") or []:
            values["roles"][role] = True
    return config_form_data(req, "grant", values, "", cfg)


def config_grant_submit_handler(req):
    # POST: add or update a grant in the staged config
    index = utils.query_param(req, "index")
    roles = req.Form.get("roles") or []
    values = {
        "index": index,
        "description": utils.query_param(req, "description").strip(),
        "users_text": utils.query_param(req, "users_text"),
        "roles": {},
        "targets_text": utils.query_param(req, "targets_text"),
        "is_edit": index != "",
    }
    for r in roles:
        values["roles"][r] = True

    users = utils.parse_lines(values["users_text"])
    targets = utils.parse_lines(values["targets_text"])
    draft_version = utils.query_param(req, "draft_version")
    if index != "":
        ret = openrun_admin.update_rbac_grant(int(index), values["description"], users,
                                              list(roles), targets, draft_version)
    else:
        ret = openrun_admin.add_rbac_grant(values["description"], users, list(roles),
                                           targets, draft_version)
    if ret.error:
        return config_form_data(req, "grant", values, ret.error)
    return form_redirect(req, req.AppPath + "/config/rbac")


def config_version_handler(req):
    # Config history page: one snapshot rendered as formatted json
    version = utils.query_param(req, "version")
    data = {
        "Title": "Config version",
        "Nav": "config",
        "Version": version,
        "Error": "",
        "Json": "",
        "Perms": utils.get_perms(),
    }
    ret = openrun.get_config_version(version)
    if ret.error:
        data["Error"] = ret.error
    else:
        data["Json"] = ret.value["json"]
    return data


# ---------- Syncs ----------


def syncs_data(req):
    # Syncs page: all sync entries with state and last run info
    query = utils.query_param(req, "query").lower()

    data = {
        "Title": "Syncs",
        "Nav": "syncs",
        "Query": query,
        "Total": 0,
        "Perms": utils.get_perms(),
        "Syncs": [],
    }

    ret = openrun.list_sync()
    if ret.error:
        data["FlashError"] = ret.error
        return data

    syncs = []
    for entry in ret.value:
        data["Total"] += 1
        # Search matches the sync file path and the creator
        if query and query not in entry["path"].lower() and \
           query not in (entry["user_id"] or "").lower():
            continue
        status = entry["status"]
        metadata = entry["metadata"]

        syncs.append({
            "id": entry["id"],
            "repo": entry["path"],
            "user": entry["user_id"] or "",
            "branch": metadata["git_branch"],
            "is_scheduled": entry["is_scheduled"],
            "schedule_frequency": metadata["schedule_frequency"],
            "flags": utils.sync_flags(metadata),
            "state": status["state"],  # Enabled / Disabled / Failing
            "clobber": metadata["clobber"],
            "commit": utils.short_sha(status["commit_id"]),
            "last_exec": utils.nonzero_time(status["last_execution_time"]),
            "error": status["error"],
            "failure_count": status["failure_count"],
        })

    data["Syncs"] = sorted(syncs, key=lambda s: s["repo"])
    return data


def syncs_create_page_handler(req):
    # Sync create form page. Promote (without verification) defaults on when
    # the user holds app:promote somewhere; approve is opt-in and the form
    # renders the options disabled without the matching permission. Git auth
    # preselects the server's default entry
    values = sync_form_values(req)
    perms = utils.get_perms()
    if perms.get("app:promote"):
        values["promote_mode"] = "noverify"
    if not values["git_auth"]:
        values["git_auth"] = git_auth_options()["default"]
    return sync_form_data(req, values, "")


def sync_form_values(req):
    # The form fields for the sync create subpage. promote_mode is the
    # promotion choice: none, verify (promote with verification) or noverify
    return {
        "path": utils.query_param(req, "path"),
        "git_branch": utils.query_param(req, "git_branch"),
        "git_auth": utils.query_param(req, "git_auth"),
        "minutes": utils.query_param(req, "minutes"),
        "promote_mode": utils.query_param(req, "promote_mode") or "none",
        "approve": utils.query_param(req, "approve"),
    }


def sync_form_data(req, values, error):
    # Page context for the sync create form
    return {
        "Title": "Add sync source",
        "Nav": "syncs",
        "Mode": "create",
        "Error": error,
        "Values": values,
        "GitAuthOptions": git_auth_options()["entries"],
        "Perms": utils.get_perms(),
    }


def syncs_create_submit_handler(req):
    # POST: validate (dry run) or create a sync entry
    values = sync_form_values(req)
    action = utils.query_param(req, "action")

    if not values["path"]:
        return sync_form_data(req, values, "Source path is required")

    minutes = 0
    if values["minutes"]:
        if not values["minutes"].isdigit():
            return sync_form_data(req, values, "Schedule minutes must be a number")
        minutes = int(values["minutes"])

    dry_run = action == "validate"
    mode = values["promote_mode"]
    ret = openrun_admin.create_sync(values["path"], git_branch=values["git_branch"],
                                  git_auth=values["git_auth"], minutes=minutes,
                                  promote=mode == "verify" or mode == "noverify",
                                  verify=mode == "verify",
                                  approve=bool(values["approve"]), dry_run=dry_run)
    if ret.error:
        return sync_form_data(req, values, ret.error)

    if dry_run:
        data = sync_form_data(req, values, "")
        data["Validated"] = True
        return data
    return form_redirect(req, req.AppPath + "/syncs")


def syncs_delete_handler(req):
    # POST: delete a sync entry from the syncs list
    sync_id = utils.query_param(req, "sync_id")
    ret = openrun_admin.delete_sync(sync_id)
    error = ret.error
    return utils.flash_result(syncs_data(req), error, "Sync source removed", "Delete failed")


def syncs_run_handler(req):
    # POST: run a sync from the syncs list
    return run_sync_action(req, syncs_data)


def syncs_detail_data(req):
    # Sync detail page: settings, status and the last invocation results
    id = utils.query_param(req, "id")
    data = {
        "Title": "Sync detail",
        "Nav": "syncs",
        "Id": id,
        "Error": "",
        "Sync": None,
        "Perms": utils.get_perms(),
        "HelpUrl": utils.docs_link("/docs/applications/overview/"),
    }

    ret = openrun.list_sync()
    if ret.error:
        data["Error"] = ret.error
        return data

    entry = None
    for candidate in ret.value:
        if candidate["id"] == id:
            entry = candidate
            break
    if not entry:
        data["Error"] = "sync entry %s not found" % id
        return data

    status = entry["status"]
    metadata = entry["metadata"]
    last_exec = utils.nonzero_time(status["last_execution_time"])

    data["Sync"] = {
        "id": entry["id"],
        "repo": entry["path"],
        "branch": metadata["git_branch"],
        "git_auth": metadata["git_auth"],
        "reload": metadata["reload"],
        "is_scheduled": entry["is_scheduled"],
        "schedule_frequency": metadata["schedule_frequency"],
        "webhook_url": metadata["webhook_url"],
        "flags": utils.sync_flags(metadata),
        "state": status["state"],
        "commit": status["commit_id"],
        "commit_short": utils.short_sha(status["commit_id"]),
        "last_exec": last_exec,
        "error": status["error"],
        "failure_count": status["failure_count"],
        "user": entry["user_id"],
        "create_time": utils.nonzero_time(entry["create_time"]),
    }
    if last_exec:
        # Details of what the last invocation applied
        data["LastResult"] = utils.sync_result_summary(status)

    # Apps last applied by this sync, filtered server side by sync_id
    apps_ret = openrun.list_apps(sync_id=id, include_internal=True)
    if apps_ret.error:
        data["AppsError"] = apps_ret.error
        data["Apps"] = []
    else:
        data["Apps"] = sorted(build_app_rows(apps_ret.value), key=lambda app: app["path"])
    return data


def syncs_detail_run_handler(req):
    # POST: run the sync from its detail page
    sync_id = utils.query_param(req, "id")
    ret = openrun_admin.run_sync(sync_id)
    error = ret.error
    data = syncs_detail_data(req)
    if error:
        data["FlashError"] = "Sync failed: %s" % error
    elif ret.value.get("error"):
        data["FlashError"] = "Sync failed: %s" % ret.value["error"]
    else:
        # The Last invocation card re-renders with the fresh stored status
        data["Flash"] = "Sync completed"
    return data


def syncs_detail_delete_handler(req):
    # POST: delete the sync and return to the syncs list
    sync_id = utils.query_param(req, "id")
    ret = openrun_admin.delete_sync(sync_id)
    if ret.error:
        data = syncs_detail_data(req)
        data["FlashError"] = "Delete failed: %s" % ret.error
        return data
    return ace.response(syncs_detail_data(req), block="sync_content",
                        redirect=req.AppPath + "/syncs")


# ---------- Secrets ----------


def secret_input_data(req):
    # Common re-render context for the secret-input component fragments: the
    # component echoes its rendering attributes (field, prefix, masked, ...)
    # so the response fragment can reproduce the element
    perms = utils.get_perms()
    return {
        "Name": utils.query_param(req, "field"),
        "AppPath": req.AppPath,
        "Prefix": utils.query_param(req, "prefix"),
        "InputId": utils.query_param(req, "input_id"),
        "Placeholder": utils.query_param(req, "placeholder"),
        "Masked": utils.query_param(req, "masked") == "true",
        "File": utils.query_param(req, "file") == "true",
        "Small": utils.query_param(req, "small") == "true",
        "Description": utils.query_param(req, "description"),
        "CanCreate": perms.get("secret:create", False),
        "CanDelete": perms.get("secret:delete", False),
    }


def secrets_store_handler(req):
    # POST from the secret-input component (console.js): encrypt the value
    # (or uploaded file content) into the db secrets provider and re-render
    # the component with the {{secret ...}} reference as its value. The
    # store dialog names the secret: store_key is an exact name (fails if it
    # already exists), else store_prefix (the dialog's edited prefix,
    # falling back to the field's default) generates the name
    data = secret_input_data(req)

    value = utils.query_param(req, "value").strip()
    value_b64 = utils.query_param(req, "value_b64")
    store_key = utils.query_param(req, "store_key").strip()
    store_prefix = utils.query_param(req, "store_prefix").strip() or data["Prefix"]
    if not store_key and not store_prefix:
        data["Error"] = "no secret name prefix is configured for this field"
        data["Value"] = value
        return data
    if not value and not value_b64:
        data["Error"] = "enter a value to store as a secret"
        return data

    if store_key:
        ret = openrun_admin.create_secret(
            value=value_b64 if value_b64 else value,
            name=store_key,
            encoding="base64" if value_b64 else "",
            description=data["Description"],
            source_file=utils.query_param(req, "source_file"))
    else:
        ret = openrun_admin.create_secret(
            value=value_b64 if value_b64 else value,
            prefix=store_prefix,
            encoding="base64" if value_b64 else "",
            description=data["Description"],
            source_file=utils.query_param(req, "source_file"))
    if ret.error:
        # The field goes back to the plain (unencrypted) value with the
        # error shown inline, e.g. when the exact name already exists
        data["Error"] = ret.error
        data["Value"] = value
        return data
    data["Value"] = ret.value["secret_ref"]
    return data


def secrets_delete_handler(req):
    # POST from the secret-input component when the user unlocks a stored
    # field and chooses to also delete the secret from the database. The
    # component parses the {{secret ...}} reference into name/provider and
    # echoes the original ref so a failure re-renders the locked state
    data = secret_input_data(req)

    name = utils.query_param(req, "name").strip()
    if not name:
        data["Error"] = "no secret name to delete"
        data["Value"] = utils.query_param(req, "ref")
        return data

    ret = openrun_admin.delete_secret(name=name, provider=utils.query_param(req, "provider"))
    error = ret.error
    if error:
        data["Error"] = error
        data["Value"] = utils.query_param(req, "ref")
        return data
    # Deleted: the field goes back to accepting a plain value
    data["Value"] = ""
    return data


# ---------- Builder ----------


def form_redirect(req, target):
    # Success navigation for the narrow-target op-forms: the htmx submit
    # (partial) needs HX-Redirect - a plain 303 would be followed by htmx
    # and swapped INTO the form slot. The no-JS fallback posts (and the API
    # tests) get a real 303
    if req.IsPartial:
        return ace.response({}, block="op_redirect", redirect=target)
    return ace.redirect(target)


def slugify(name):
    # App-name slug from a free-form session name: lowercase alnum runs
    # joined by single dashes ("Tip Calculator" -> "tip-calculator")
    out = ""
    pending_dash = False
    for ch in name.strip().lower().elems():
        if ch.isalnum():
            if pending_dash and out:
                out += "-"
            out += ch
            pending_dash = False
        else:
            pending_dash = True
    return out


def builder_publish_prefill(session_name, dest_mode, dest_target):
    # The publish dialog input prefill, derived from the session name and
    # shaped by the profile's destination mode
    slug = slugify(session_name)
    if dest_mode in ("subdomain", "path"):
        return slug
    if dest_mode == "glob":
        # prefill the fixed part of the glob plus the app name
        if "*" in dest_target:
            return dest_target.split("*")[0].rstrip("/") + "/" + slug
        return dest_target
    return "/" + slug


def builder_publish_target_path(req, config):
    # Compose the publish target from the dialog input based on the session
    # profile's destination mode. Republishes target the existing path
    if utils.query_param(req, "publish_choice").strip() == "__same__":
        return utils.query_param(req, "current_path").strip()
    value = utils.query_param(req, "publish_input").strip()
    if not value:
        return ""
    mode = config["publish_mode"]
    target = config["publish_target"]
    if mode == "subdomain":
        # The target stays RAW: a trailing "." keeps the app declaration
        # relative (portable across instances; the server resolves it to
        # this instance's default domain when operating on the app)
        if target == ".":
            return value.strip(".") + ".:/"
        return value.strip(".") + "." + target + ":/"
    if mode == "path":
        return target.rstrip("/") + "/" + value.strip("/")
    return value  # glob and unrestricted: the full path is typed


def builder_services_offer(config, profile_name):
    # The new-app Services checklist offer for a profile choice: the
    # profile's services list ("defaults" offers the default service of
    # every type, empty offers none, bare types offer the type's default
    # service), intersected with live services. profile_name "" is the
    # implicit default profile = defaults
    profile = None
    for entry in config["profiles"]:
        if entry["name"] == profile_name:
            profile = entry
    allow_defaults = profile == None
    allowed = {}
    if profile != None:
        lst = profile.get("services") or []
        if not lst:
            return []
        for e in lst:
            if e == "defaults":
                allow_defaults = True
            allowed[e] = True
    offer = []
    for svc in config["all_services"]:
        if allowed.get(svc["id"]) or (svc["is_default"] and (allow_defaults or allowed.get(svc["type"]))):
            offer.append(svc)
    return offer


def builder_effective_profile(config, chosen):
    # The profile whose services offer the create form shows initially:
    # the submitted choice, else the configured default, else the single
    # profile, else the first option the browser would select, else the
    # implicit default ("")
    if chosen:
        return chosen
    if config["default_builder_profile"]:
        return config["default_builder_profile"]
    profiles = config["profiles"]
    if len(profiles) >= 1:
        return profiles[0]["name"]
    return ""


def builder_publish_config(session_id=""):
    # Publish setup (mode, publish restriction, builder profiles). Returns
    # (config, error); config is None when the builder is not enabled server
    # side. With session_id the mode/git/publish fields reflect that
    # session's resolved builder profile
    ret = build.get_publish_config(session_id=session_id)
    error = ret.error
    if error:
        return None, error
    return ret.value, None


def builder_data(req):
    # Builder sessions list (/builder), filtered by the search query. Other
    # users' sessions are included when the caller holds the admin permission
    # (the backend enforces this; the perms map only picks the request shape)
    perms = utils.get_perms()
    query = utils.query_param(req, "query").strip().lower()
    data = {"Title": "Builder", "Nav": "builder", "Perms": perms, "Query": utils.query_param(req, "query"),
            "Sessions": [], "Enabled": False, "Flash": "", "FlashError": ""}

    if perms.get("feature:system_blocked"):
        # The build plugin rejects anonymous callers with a hard error (not
        # a ret.error), which would crash the handler into the error page -
        # losing the sidebar (and its sign-in notice), which then jumps
        # between pages. Render the page shell instead; the sidebar notice
        # explains the blocked state
        data["FlashError"] = "The builder is unavailable: management operations are disabled for anonymous users"
        return data

    config, error = builder_publish_config()
    if error:
        data["FlashError"] = error
        return data
    data["Enabled"] = config["enabled"]
    data["PublishMode"] = config["mode"]
    if not config["enabled"]:
        return data

    if perms.get("admin"):
        ret = build.list_sessions(all_users=True)
    else:
        ret = build.list_sessions()
    error = ret.error
    if error:
        data["FlashError"] = error
        return data
    sessions = ret.value
    if query:
        sessions = [s for s in sessions
                    if query in s["name"].lower() or query in s["status"].lower() or
                    query in s["preview_path"].lower() or query in s["publish_path"].lower() or
                    query in s["agent"].lower() or query in s["user_id"].lower()]
    data["Sessions"] = sessions
    return data


def builder_rows_action(req, action):
    # Row actions on the sessions list re-render the list with a flash
    id = utils.query_param(req, "id").strip()
    if not id:
        return builder_data(req)
    if action == "stop":
        ret = build.stop_session(id)
    elif action == "resume":
        ret = build.resume_session(id)
    else:
        ret = build.delete_session(id)
    error = ret.error
    data = builder_data(req)
    if error:
        data["FlashError"] = error
    else:
        data["Flash"] = "Session %s %s" % (id, "deleted" if action == "delete" else action + (
            "ped" if action == "stop" else "d"))
    return data


def builder_create_page_handler(req):
    # New app form (/builder/create): name + what the app should do, plus a
    # Builder Profile choice when two or more profiles are configured (one
    # profile applies silently; none uses the built-in default). With
    # ?edit=<path> the session modifies an existing builder-published app
    # (source only, no declaration change)
    data = {"Title": "Builder", "Nav": "builder", "Perms": utils.get_perms(),
            "Profiles": [], "Values": {},
            "EditApp": utils.query_param(req, "edit").strip()}
    config, error = builder_publish_config()
    if error:
        data["Error"] = error
        return data
    data["Enabled"] = config["enabled"]
    data["Profiles"] = config["profiles"]
    data["DefaultProfile"] = config["default_builder_profile"]
    data["ServicesOffer"] = builder_services_offer(
        config, builder_effective_profile(config, data["Values"].get("profile") or ""))
    data["ServicesChecked"] = {}

    if data["EditApp"]:
        # The workspace is seeded from the app. Apps published by the
        # builder are edited in place; other apps fork - publish creates a
        # new app with the original's settings copied
        ret = openrun.get_app(data["EditApp"])
        error = ret.error
        if error:
            data["Error"] = error
        else:
            data["EditPublished"] = ret.value.get("builder_published")
    return data


def builder_create_services_handler(req):
    # Fragment: the Services checklist re-rendered for the selected profile
    # (the create form refreshes it when the profile select changes)
    data = {"ServicesOffer": [], "ServicesChecked": {}}
    config, error = builder_publish_config()
    if not error and config["enabled"]:
        profile = utils.query_param(req, "profile").strip()
        data["ServicesOffer"] = builder_services_offer(
            config, builder_effective_profile(config, profile))
    return ace.response(data, block="builder_services_checklist")


def builder_create_submit_handler(req):
    # Create the session and go to its workspace; generation continues
    # asynchronously and streams into the chat
    data = builder_create_page_handler(req)
    name = utils.query_param(req, "name").strip()
    prompt = utils.query_param(req, "prompt").strip()
    profile = utils.query_param(req, "profile").strip()
    edit_app = utils.query_param(req, "edit_app").strip()
    services = [v.strip() for v in utils.query_param_list(req, "services") if v.strip()]
    data["EditApp"] = edit_app
    data["Values"] = {"name": name, "prompt": prompt, "profile": profile}
    checked = {}
    for svc in services:
        checked[svc] = True
    data["ServicesChecked"] = checked
    if not name or not prompt:
        data["Error"] = "Name and app description are required"
        return data

    ret = build.create_session(name=name, prompt=prompt, profile=profile, edit_app=edit_app,
                               services=services)
    error = ret.error
    if error:
        data["Error"] = error
        return data
    # Plain form post: a real redirect, not HX-Redirect
    return form_redirect(req, "%s/builder/detail?id=%s" % (req.AppPath, ret.value["id"]))


def builder_detail_data(req):
    # Session workspace (/builder/detail?id=...): transcript, preview and
    # publish state. The chat pane live-updates over the event stream; this
    # page render is the durable transcript
    id = utils.query_param(req, "id").strip()
    data = {"Title": "Builder", "Nav": "builder", "Perms": utils.get_perms(), "Id": id,
            "Flash": "", "FlashError": "", "PublishResult": None,
            # Publish dialog re-render state (set by builder_publish_form_error)
            "PublishError": "", "PublishInput": "", "PublishCommitMsg": "",
            # No dedicated builder docs page yet, link the docs root
            "HelpUrl": utils.docs_link("/docs/")}
    if not id:
        data["Error"] = "session id is required"
        return data
    if data["Perms"].get("feature:system_blocked"):
        # See builder_data: the gated build plugin would crash the handler
        data["Error"] = "The builder is unavailable: management operations are disabled for anonymous users"
        return data

    config, error = builder_publish_config(session_id=id)
    if error:
        data["Error"] = error
        return data
    data["PublishMode"] = config["mode"]
    # The session profile's publish restriction shapes the dialog input:
    # subdomain label, app name under a prefix, or a full path (glob /
    # unrestricted)
    data["PublishDestMode"] = config["publish_mode"]
    data["PublishDestTarget"] = config["publish_target"]
    data["PublishDestResolved"] = config["publish_target_resolved"]
    data["PublishDestDesc"] = config["publish_desc"]
    data["GitRepo"] = config["git_repo"]

    ret = build.get_session(id)
    error = ret.error
    if error:
        data["Error"] = error
        return data
    data["Session"] = ret.value
    data["PublishPrefill"] = builder_publish_prefill(
        ret.value["name"], config["publish_mode"], config["publish_target"])

    ret = build.get_messages(id)
    error = ret.error
    if error:
        data["Error"] = error
        return data
    # Fold runs of consecutive tool calls into one line of chips (read ×2,
    # write, edit ...) and consecutive lifecycle rows into one muted line,
    # so tool bursts and restart churn do not pad the transcript
    merged = []
    for msg in ret.value["messages"]:
        if msg["kind"] in ("tool_call", "lifecycle") and merged and merged[-1]["kind"] == msg["kind"]:
            parts = merged[-1]["parts"]
            if parts[-1]["text"] == msg["content"]:
                parts[-1]["count"] += 1
            else:
                parts.append({"text": msg["content"], "count": 1})
        else:
            entry = dict(msg)
            entry["count"] = 1
            if msg["kind"] in ("tool_call", "lifecycle"):
                entry["parts"] = [{"text": msg["content"], "count": 1}]
            merged.append(entry)
    data["Messages"] = merged
    data["IsLive"] = ret.value["is_live"]
    data["TurnActive"] = ret.value["turn_active"]
    data["Partial"] = ret.value["partial"]

    ret = build.list_files(id)
    error = ret.error
    data["Files"] = [] if error else ret.value
    data["FileTree"] = build_file_tree(data["Files"])

    # Link the chat header to the sandbox's container detail page (the
    # builder container list carries the session id in app_path). Needs the
    # containers screens enabled and a live sandbox
    data["SandboxContainerId"] = ""
    if data["IsLive"] and data["Perms"].get("feature:container"):
        ret = openrun.list_containers(type="agent")
        error = ret.error
        if not error:
            for entry in ret.value:
                if entry["app_path"] == id:
                    data["SandboxContainerId"] = entry["id"]

    # Explain a missing preview: no app.star means OpenRun cannot load the
    # workspace; a failed creation attempt is in the activity log
    data["HasAppStar"] = "app.star" in data["Files"]
    data["PreviewError"] = ""
    if not data["Session"]["preview_path"]:
        for msg in data["Messages"]:
            if msg["kind"] == "error" and "preview app" in msg["content"]:
                data["PreviewError"] = msg["content"]
    return data


def builder_detail_action(req, action):
    # Session workspace actions re-render the workspace with a flash
    id = utils.query_param(req, "id").strip()
    flash = ""
    error = None
    if action == "message":
        message = utils.query_param(req, "message").strip()
        if message:
            ret = build.send_message(id, message=message)
            if ret.error:
                # The composer posts with hx-swap=none (the transcript is
                # SSE-driven), so a discarded error looks like a hang.
                # Retarget the error into the chat's error slot instead
                return ace.response({"SendError": "Message not sent: " + ret.error}, block="bc_send_error",
                                    retarget="#bc-send-error", reswap="innerHTML")
    elif action == "cancel":
        # The Stop button posts with hx-swap=none too: an error dropped with
        # the body reads as a dead button (it is reachable while the sandbox
        # is still launching, when cancel_turn rejects with guidance).
        # builderchat.js places the retargeted error and shows a "Stopping"
        # status when the response carries no HX-Retarget
        ret = build.cancel_turn(id)
        if ret.error:
            return ace.response({"SendError": "Not stopped: " + ret.error}, block="bc_send_error",
                                retarget="#bc-send-error", reswap="innerHTML")
        return ace.response({"SendError": ""}, block="bc_send_error")
    elif action == "stop":
        ret = build.stop_session(id)
        error = ret.error
        flash = "Sandbox stopped"
    elif action == "resume":
        ret = build.resume_session(id)
        error = ret.error
        flash = "Sandbox resuming"
    elif action == "approve":
        ret = build.get_session(id)
        error = ret.error
        if not error and ret.value["preview_path"]:
            approve_ret = openrun_admin.approve_apps(ret.value["preview_path"])
            error = approve_ret.error
            flash = "Preview app permissions approved"
        elif not error:
            error = "no preview app yet"

    data = builder_detail_data(req)
    if error:
        data["FlashError"] = error
    elif flash:
        data["Flash"] = flash
    return data


def builder_delete_handler(req):
    # Delete the draft (workspace, preview app, sandbox) and go back to the
    # list. Published entries stay until unpublished; the dialog says so
    id = utils.query_param(req, "id").strip()
    ret = build.delete_session(id)
    error = ret.error
    if error:
        data = builder_detail_data(req)
        data["FlashError"] = error
        return data
    data = {"Title": "Builder", "Nav": "builder", "Perms": utils.get_perms()}
    return ace.response(data, "builder_session.go.html",
                        redirect=req.AppPath + "/builder")


def builder_publish_form_error(req, error):
    # A failed publish re-renders JUST the dialog form (retargeted,
    # outerHTML swap): the dropdown stays open with the submitted values and
    # the error inline, instead of a page flash after the dialog closed
    data = builder_detail_data(req)
    data["PublishError"] = error
    data["PublishInput"] = utils.query_param(req, "publish_input").strip()
    data["PublishCommitMsg"] = utils.query_param(req, "commit_msg").strip()
    return ace.response(data, block="publish_form",
                        retarget="#publish-form", reswap="outerHTML")


def builder_publish_handler(req):
    # Publish: the dialog's single input composed per the profile's
    # destination mode (subdomain label / app name / full path)
    id = utils.query_param(req, "id").strip()
    commit_msg = utils.query_param(req, "commit_msg").strip()

    config, error = builder_publish_config(session_id=id)
    if error:
        return builder_publish_form_error(req, error)
    path = builder_publish_target_path(req, config)
    if not path:
        return builder_publish_form_error(req, "Enter a publish destination")
    ret = build.publish_app(id, path=path, commit_msg=commit_msg)
    error = ret.error
    if error:
        return builder_publish_form_error(req, error)
    data = builder_detail_data(req)
    # PublishResult renders its own success alert (with mode + commit); a
    # Flash here would be a redundant second success message
    data["PublishResult"] = ret.value
    # Local publishes land on staging (except a first publish, whose initial
    # version is live on create): offer promotion as the next step. App
    # operations use the RESOLVED path (a relative-domain declaration
    # expands to this instance's default domain)
    if ret.value.get("mode") == "local":
        app_ret = openrun.get_app(ret.value.get("resolved_path"))
        if not app_ret.error and app_ret.value.get("staged_changes"):
            data["AskPromotePath"] = ret.value.get("resolved_path")
    return data


def builder_publish_check_handler(req):
    # Validate the publish destination without publishing: the same
    # normalization, profile restriction and app RBAC checks as the real
    # publish, rendered into the dialog's #publish-check-result slot
    id = utils.query_param(req, "id").strip()
    result = {"CheckError": "", "CheckPath": "", "CheckExists": False}
    config, error = builder_publish_config(session_id=id)
    if error:
        result["CheckError"] = error
        return ace.response(result, block="publish_check_result")
    path = builder_publish_target_path(req, config)
    if not path:
        result["CheckError"] = "Enter a publish destination"
        return ace.response(result, block="publish_check_result")
    ret = build.check_publish_path(id, path=path)
    error = ret.error
    if error:
        result["CheckError"] = error
        return ace.response(result, block="publish_check_result")
    result["CheckPath"] = ret.value["path"]
    result["CheckResolved"] = ret.value["resolved"]
    result["CheckExists"] = ret.value["exists"]
    return ace.response(result, block="publish_check_result")


def builder_promote_handler(req):
    # POST: promote the just-published staging app to prod
    path, error_data = require_app_path(req, builder_detail_data)
    if error_data:
        return error_data
    return promote_app_result(req, builder_detail_data, path)


def builder_unpublish_handler(req):
    id = utils.query_param(req, "id").strip()
    ret = build.unpublish_app(id)
    error = ret.error
    data = builder_detail_data(req)
    if error:
        data["FlashError"] = error
        return data
    data["Flash"] = "Unpublished " + ret.value["publish_path"]
    return data


def build_file_tree(files):
    # Flatten the sorted file list into explorer rows: directory header rows
    # for each new directory prefix, then file rows, both carrying the
    # nesting depth for indentation
    rows = []
    seen_dirs = {}
    for path in sorted(files):
        parts = path.split("/")
        for i in range(1, len(parts)):
            dir_path = "/".join(parts[:i])
            if dir_path not in seen_dirs:
                seen_dirs[dir_path] = True
                rows.append({"name": parts[i - 1], "path": dir_path, "depth": i - 1, "is_dir": True})
        rows.append({"name": parts[-1], "path": path, "depth": len(parts) - 1, "is_dir": False})
    return rows


def builder_file_handler(req):
    # Streaming TEXT route: raw content of one workspace file, rendered by
    # the <builder-files> viewer (client side syntax highlighting)
    id = utils.query_param(req, "id").strip()
    path = utils.query_param(req, "path").strip()
    ret = build.read_file(id, path)
    if ret.error:
        return "error: %s" % ret.error
    return ret.value


def builder_download_handler(req):
    # Bundle the workspace source into a zip and stream it back to the client
    # as an attachment (chunked, no disk/db staging); errors render the
    # session page with a flash
    ret = build.get_source_zip(utils.query_param(req, "id").strip())
    error = ret.error
    if error:
        data = builder_detail_data(req)
        data["FlashError"] = "Source download failed: " + error
        return data
    return ace.response(ret.value["content"], download=ret.value["name"],
                        content_type="application/zip")


def builder_events_handler(req):
    # Streaming TEXT route: session events as JSON lines, consumed by the
    # <builder-chat> element until the sandbox stops or the client leaves
    id = utils.query_param(req, "id").strip()
    ret = build.session_events(id)
    if ret.error:
        return "error: %s" % ret.error
    return ret
