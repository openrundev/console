load("openrun.in", "openrun")
load("openrun_admin.in", "openrun_admin")
load("utils.star", "query_param", "get_perms", "params_to_text",
     "parse_lines", "short_sha", "short_age", "human_size", "pct_num", "nonzero_time", "sort_recent",
     "flash_result", "parse_kv_rows", "kv_rows", "raw_kv_rows",
     "path_domain_str", "sync_flags", "sync_result_summary", "review_from_dryrun",
     "needs_approval")

# Route handlers for the console. Each screen has a *_data function which
# builds the full page context; action handlers run the mutation and re-render
# the same context with a Flash/FlashError message. Mutation results must read
# ret.error BEFORE the *_data call: an unread plugin error fails the next
# plugin call. The error_handler in app.star is the fallback when that is
# missed.


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
                "git_sha": short_sha(stage["git_sha"]),
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
            "git_sha": short_sha(entry["git_sha"]),
            "git_message": entry["git_message"],
            "staging": staging,
            "created_by": entry.get("created_by") or "",
            "update_age": short_age(entry["update_age"]),
            "update_time": entry.get("update_time") or "",
            "update_user": entry.get("update_user") or "",
        })
    return rows


def apps_data(req):
    # Apps list page: apps grouped by their managing sync, plus unmanaged
    query = query_param(req, "query")
    filter = query_param(req, "filter")  # "", "declarative" or "imperative"

    # include_internal picks up staging/preview apps; staging entries are
    # folded into their main app's row instead of being listed separately
    all_apps = openrun.list_apps(query=query, include_internal=True).value

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
            "last_exec": nonzero_time(entry["status"]["last_execution_time"]),
        }

    grouped = {}  # sync id -> app rows, for apps last applied by a live sync
    unmanaged = []  # created/last updated imperatively
    total = 0
    declarative_count = 0
    for app in build_app_rows(all_apps):
        total += 1
        if app["is_declarative"]:
            declarative_count += 1
        if (filter == "declarative" and not app["is_declarative"]) or \
           (filter == "imperative" and app["is_declarative"]):
            continue

        if app["sync_id"] and app["sync_id"] in syncs:
            grouped.setdefault(app["sync_id"], []).append(app)
        else:
            unmanaged.append(app)

    # Most recently updated apps first, groups ordered by their most
    # recently updated app
    groups = []
    for sync_id in grouped:
        apps = sort_recent(grouped[sync_id], "update_time", "path")
        groups.append({
            "sync": syncs[sync_id],
            "apps": apps,
            "newest": apps[0]["update_time"] if apps else "",
            "repo": syncs[sync_id]["repo"],
        })

    return {
        "Title": "Apps",
        "Nav": "apps",
        "Query": query,
        "Filter": filter,
        "Groups": sort_recent(groups, "newest", "repo"),
        "Unmanaged": sort_recent(unmanaged, "update_time", "path"),
        "Total": total,
        "DeclarativeCount": declarative_count,
        "ImperativeCount": total - declarative_count,
        "Perms": get_perms(),
    }


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
            "create_time": nonzero_time(entry.get("CreateTime")),
            "git_sha": short_sha(vm.get("git_commit") or ""),
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


ENV_ORDER = {"prod": "0", "stage": "1", "preview": "2", "dev": "3"}


def app_container_sort_key(entry):
    # Sort containers: running first, then prod/stage/preview/dev, then name
    running = "0" if entry["state"] == "running" else "1"
    return running + ENV_ORDER.get(entry["env"], "9") + entry["name"]


def apps_detail_data(req):
    # App detail page: overview, params, permissions, containers, versions
    path = query_param(req, "path")
    data = {
        "Title": "App detail",
        "Nav": "apps",
        "Path": path,
        "Error": "",
        "App": None,
        "Containers": [],
        # Set after a staging-only reload/update, prompts for promotion
        "AskPromote": query_param(req, "staged"),
        # App permissions evaluated against this app, including the owner rule
        "Perms": get_perms(path),
    }

    ret = openrun.get_app(path)
    if ret.error:
        data["Error"] = ret.error
        return data

    app = ret.value
    data["App"] = app

    # Resolve the sync entry which manages this app, if any
    if app["applied_sync_id"]:
        sync_ret = openrun.list_sync()
        for entry in (sync_ret.value if not sync_ret.error else []):
            if entry["id"] == app["applied_sync_id"]:
                data["Sync"] = {
                    "repo": entry["path"],
                    "branch": entry["metadata"]["git_branch"],
                }

    data["ParamsText"] = params_to_text(app["params"])

    # Containers running (or recently run) for this app, current env first
    cont_ret = openrun.list_containers()
    if not cont_ret.error:
        containers = [c for c in cont_ret.value if c["app_path"] == path]
        data["Containers"] = sorted(containers, key=app_container_sort_key)

    # Audit the app's code for the plugin permissions it requests and whether
    # they are pending approval (audited against staging for prod apps)
    audit_ret = openrun.audit_app(path)
    if audit_ret.error:
        data["AuditError"] = audit_ret.error
    else:
        audit = audit_ret.value
        data["Audit"] = review_from_dryrun({"approve_results": [audit]})
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


def apps_switch_handler(req):
    # POST: switch the active version for prod or staging
    path = query_param(req, "path")
    env = query_param(req, "env") or "prod"
    version = query_param(req, "version")

    ret = openrun_admin.switch_version(resolve_env_path(path, env), version)
    error = ret.error
    return flash_result(apps_detail_data(req), error,
                        "Switched %s to v%s" % (env, version), "Version switch failed")


def require_app_path(req, data_fn):
    # The app write plugin APIs take path globs; a missing path must not
    # silently become an empty glob (which would match every app). Returns
    # (path, None) or ("", error page data)
    path = query_param(req, "path").strip()
    if not path:
        data = data_fn(req)
        data["FlashError"] = "App path is required"
        return "", data
    return path, None


def apps_promote_handler(req):
    # POST: promote the staging app to prod
    path, error_data = require_app_path(req, apps_detail_data)
    if error_data:
        return error_data
    ret = openrun_admin.promote_apps(path)
    error = ret.error
    data = apps_detail_data(req)
    if error:
        data["FlashError"] = "Promote failed: %s" % error
    elif not ret.value.get("promote_results"):
        data["Flash"] = "Nothing to promote, prod matches staging"
    else:
        data["Flash"] = "Promoted staging to prod"
    return data


def apps_approve_handler(req):
    # POST: approve the requested plugin permissions
    path, error_data = require_app_path(req, apps_detail_data)
    if error_data:
        return error_data
    # Approval applies to the staging app; promotion is asked as a next step
    ret = openrun_admin.approve_apps(path, promote=False)
    error = ret.error
    data = apps_detail_data(req)
    if error:
        data["FlashError"] = "Approve failed: %s" % error
    else:
        data["Flash"] = "Permissions approved on staging"
        data["AskPromote"] = "approve"
    return data


def reload_app_staging(path):
    # Staging-first reload: approval is requested only when the user holds
    # it (the approve flag hard-fails otherwise), promotion is a next step
    perms = get_perms(path)
    return openrun_admin.reload_apps(path, approve=bool(perms.get("app:approve")), promote=False)


def apps_detail_reload_handler(req):
    # POST: reload staging from source, staying on the detail page
    path, error_data = require_app_path(req, apps_detail_data)
    if error_data:
        return error_data
    ret = reload_app_staging(path)
    error = ret.error
    data = apps_detail_data(req)
    if error:
        data["FlashError"] = "Reload failed: %s" % error
    elif ret.value.get("skipped_results") and not ret.value.get("reload_results"):
        data["Flash"] = "%s is already up to date" % path
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
    # Version files page: the file listing of one app version
    path = query_param(req, "path")
    version = query_param(req, "version")
    env = query_param(req, "env") or "prod"

    data = {
        "Title": "Version files",
        "Nav": "apps",
        "Path": path,
        "Version": version,
        "Env": env,
        "Error": "",
        "Files": [],
        "TotalSize": "",
    }

    ret = openrun.list_version_files(resolve_env_path(path, env), version=version)
    if ret.error:
        data["Error"] = ret.error
        return data

    files = []
    total = 0
    for entry in ret.value["files"] or []:
        total += entry["Size"]
        files.append({
            "name": entry["Name"],
            "size": human_size(entry["Size"]),
            "etag": entry["Etag"][:12] if entry["Etag"] else "",
        })
    data["Files"] = sorted(files, key=lambda f: f["name"])
    data["TotalSize"] = human_size(total)
    return data


def apps_delete_handler(req):
    # POST: delete an app from the apps list
    path, error_data = require_app_path(req, apps_data)
    if error_data:
        return error_data
    ret = openrun_admin.delete_apps(path)
    error = ret.error
    return flash_result(apps_data(req), error, "Deleted %s" % path, "Delete failed")


def apps_reload_handler(req):
    # POST: reload staging from the apps list, then go to the detail page
    path, error_data = require_app_path(req, apps_data)
    if error_data:
        return error_data
    ret = reload_app_staging(path)

    if ret.error:
        data = apps_data(req)
        data["FlashError"] = "Reload failed: %s" % ret.error
        return data
    if ret.value.get("skipped_results") and not ret.value.get("reload_results"):
        data = apps_data(req)
        data["Flash"] = "%s is already up to date" % path
        return data

    # Staging reloaded; continue on the detail page to review and promote
    return ace.response(apps_data(req), block="app_groups",
                        redirect="%s/apps/detail?path=%s&staged=reload" % (req.AppPath, path))


def run_sync_action(req, data_fn):
    # Run a sync and show the detailed apply results on the current page
    ret = openrun_admin.run_sync(query_param(req, "sync_id"))
    error = ret.error
    data = data_fn(req)
    if error:
        data["FlashError"] = "Sync failed: %s" % error
    elif ret.value.get("error"):
        data["FlashError"] = "Sync failed: %s" % ret.value["error"]
    else:
        data["SyncResult"] = sync_result_summary(ret.value)
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
    # The git_auth entry names configured on the server, for private repos
    ret = openrun.list_git_auths()
    return ret.value if not ret.error else []


def form_values(req):
    # The form fields for the create/update subpages
    return {
        "path": query_param(req, "path"),
        "source_url": query_param(req, "source_url"),
        "spec": query_param(req, "spec"),
        "auth": query_param(req, "auth"),
        "git_branch": query_param(req, "git_branch"),
        "git_auth": query_param(req, "git_auth"),
        "params_rows": raw_kv_rows(req, "params"),
        "approve": query_param(req, "approve"),
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
        "GitAuthOptions": git_auth_options(),
        "Values": values,
        "Perms": get_perms(),
    }


def approve_step_data(req, values, review, error):
    # Create form context for the post-create approval step
    data = create_form_data(req, values, error)
    data["Step"] = "approve"
    data["Review"] = review
    return data


def apps_create_page_handler(req):
    # App create form page
    return create_form_data(req, form_values(req), "")


def apps_create_submit_handler(req):
    # POST: validate (dry run), create, or approve a new app
    values = form_values(req)
    action = query_param(req, "action")

    if action == "approve":
        # The app was created, approve its pending permissions
        ret = openrun_admin.approve_apps(values["path"])
        if ret.error:
            pending = openrun_admin.approve_apps(values["path"], dry_run=True)
            review = {"loads": [], "permissions": []}
            if not pending.error:
                review = review_from_dryrun({"approve_results": pending.value.get("staged_update_results")})
            return approve_step_data(req, values, review, ret.error)
        return ace.redirect(req.AppPath + "/apps")

    if not values["path"]:
        return create_form_data(req, values, "App path is required")
    if not values["source_url"]:
        return create_form_data(req, values, "Source url is required")

    params, err = parse_kv_rows(req, "params")
    if err:
        return create_form_data(req, values, err)

    auth = values["auth"] if values["auth"] != "default" else ""

    if action == "create":
        # Create the app without approval; if it requests permissions, ask
        # for the approval as the next step
        ret = openrun_admin.create_app(values["path"], values["source_url"],
                               approve=False, auth=auth,
                               spec=values["spec"], git_branch=values["git_branch"],
                               git_auth=values["git_auth"], params=params)
        if ret.error:
            return create_form_data(req, values, ret.error)
        if needs_approval(ret.value):
            return approve_step_data(req, values, review_from_dryrun(ret.value), "")
        return ace.redirect(req.AppPath + "/apps")

    # Validate: dry run to check the create and gather the requested
    # permissions, nothing is committed
    ret = openrun_admin.create_app(values["path"], values["source_url"],
                           approve=True, dry_run=True, auth=auth,
                           spec=values["spec"], git_branch=values["git_branch"],
                           git_auth=values["git_auth"], params=params)
    if ret.error:
        return create_form_data(req, values, ret.error)

    data = create_form_data(req, values, "")
    data["Validated"] = True
    data["Review"] = review_from_dryrun(ret.value)
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
        "Values": values,
        "Perms": get_perms(values.get("path", "")),
    }


def apps_update_page_handler(req):
    # App update form page, prefilled from the current app
    path = query_param(req, "path")
    ret = openrun.get_app(path)
    if ret.error:
        return update_form_data(req, None, {}, ret.error)

    app = ret.value
    values = {
        "path": app["path"],
        "auth": app["auth"] or "default",
        "params_rows": kv_rows(app["params"]),
    }
    return update_form_data(req, app, values, "")


def apps_update_submit_handler(req):
    # POST: apply param (staged) and auth (direct) changes
    path = query_param(req, "path")
    values = {
        "path": path,
        "auth": query_param(req, "auth"),
        "params_rows": raw_kv_rows(req, "params"),
    }

    ret = openrun.get_app(path)
    if ret.error:
        return update_form_data(req, None, values, ret.error)
    app = ret.value

    params, err = parse_kv_rows(req, "params")
    if err:
        return update_form_data(req, app, values, err)

    params_changed = params != app["params"]
    if params_changed:
        # Params apply to staging; promotion is asked on the detail page
        result = openrun_admin.update_params(path, params, promote=False)
        if result.error:
            return update_form_data(req, app, values, result.error)

    new_auth = values["auth"] or "default"
    if new_auth != (app["auth"] or "default"):
        # Auth is an app setting, not version controlled; applies directly
        result = openrun_admin.update_auth(path, new_auth)
        if result.error:
            return update_form_data(req, app, values, result.error)

    if params_changed:
        return ace.redirect("%s/apps/detail?path=%s&staged=update" % (req.AppPath, path))
    return ace.redirect("%s/apps/detail?path=%s" % (req.AppPath, path))


# ---------- Bindings and services ----------


def bindings_data(req):
    # Bindings page: services table plus base/derived/auto binding tables
    query = query_param(req, "query").lower()

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
            "update_time": nonzero_time(entry["update_time"]),
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
            "update_time": nonzero_time(entry["update_time"]),
        })

    return {
        "Title": "Bindings",
        "Nav": "bindings",
        "Query": query,
        "Total": total,
        "Perms": get_perms(),
        "FlashError": list_error,
        "Services": sorted(services, key=lambda svc: svc["id"]),
        "ServicesError": services_error,
        # Most recently updated bindings first
        "Base": sort_recent(base, "update_time", "path"),
        "Derived": sort_recent(derived, "update_time", "path"),
        "Auto": sort_recent(auto, "update_time", "path"),
    }


def binding_form_values(req):
    # The form fields for the binding create/update subpages
    return {
        "path": query_param(req, "path"),
        "source": query_param(req, "source"),
        "grants_text": query_param(req, "grants_text"),
        "config_rows": raw_kv_rows(req, "config"),
    }


def binding_form_data(req, mode, values, error):
    # Page context for the binding create/update form
    return {
        "Title": "New binding" if mode == "create" else "Update binding",
        "Nav": "bindings",
        "Mode": mode,
        "Error": error,
        "Values": values,
        "Perms": get_perms(),
    }


def bindings_create_page_handler(req):
    # Binding create form page
    return binding_form_data(req, "create", binding_form_values(req), "")


def bindings_create_submit_handler(req):
    # POST: validate (dry run) or create a binding
    values = binding_form_values(req)
    action = query_param(req, "action")

    if not values["path"]:
        return binding_form_data(req, "create", values, "Binding path is required")
    if not values["source"]:
        return binding_form_data(req, "create", values, "Source is required")

    config, err = parse_kv_rows(req, "config")
    if err:
        return binding_form_data(req, "create", values, err)
    grants = parse_lines(values["grants_text"])

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
    return ace.redirect(req.AppPath + "/bindings")


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
    path = query_param(req, "path")
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
    path = query_param(req, "path")
    values = binding_form_values(req)
    values["path"] = path

    binding = find_binding(path)
    if not binding:
        return binding_form_data(req, "update", values, "binding %s not found" % path)

    current = binding["staged_metadata"]["grants"] or []
    wanted = parse_lines(values["grants_text"])
    add_grants = [g for g in wanted if g not in current]
    delete_grants = [g for g in current if g not in wanted]

    if not add_grants and not delete_grants:
        return ace.redirect(req.AppPath + "/bindings")

    ret = openrun_admin.update_binding(path, add_grants=add_grants,
                                     delete_grants=delete_grants, promote=True)
    if ret.error:
        data = binding_form_data(req, "update", values, ret.error)
        data["Binding"] = binding
        return data
    return ace.redirect(req.AppPath + "/bindings")


def bindings_delete_handler(req):
    # POST: delete a binding from the bindings list
    path = query_param(req, "path")
    ret = openrun_admin.delete_binding(path)
    error = ret.error
    return flash_result(bindings_data(req), error, "Deleted binding %s" % path, "Delete failed")


def service_form_data(req, values, error):
    # Page context for the service create form
    return {
        "Title": "New service",
        "Nav": "bindings",
        "Error": error,
        "Values": values,
        "Validated": False,
        "Perms": get_perms(),
    }


def services_create_page_handler(req):
    # Service create form page
    values = {"id": "", "config_rows": [], "is_default": False, "staging": ""}
    return service_form_data(req, values, "")


def services_create_submit_handler(req):
    # POST: validate (dry run) or create a service
    values = {
        "id": query_param(req, "id").strip(),
        "config_rows": raw_kv_rows(req, "config"),
        "is_default": query_param(req, "is_default") == "on",
        "staging": query_param(req, "staging").strip(),
    }
    action = query_param(req, "action")

    config, err = parse_kv_rows(req, "config")
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
    return ace.redirect(req.AppPath + "/bindings")


def services_delete_handler(req):
    # POST: delete a service from the bindings page
    id = query_param(req, "id")
    ret = openrun_admin.delete_service(id)
    error = ret.error
    return flash_result(bindings_data(req), error, "Deleted service %s" % id, "Service delete failed")


# ---------- Containers ----------


def containers_data(req):
    # Containers page: managed containers with state/search filters
    query = query_param(req, "query").lower()
    filter = query_param(req, "filter") or "running"  # running / exited / all

    data = {
        "Title": "Containers",
        "Nav": "containers",
        "Query": query,
        "Filter": filter,
        "Total": 0,
        "Running": 0,
        "Runtime": "",
        "Containers": [],
        "Perms": get_perms(),
    }

    ret = openrun.list_containers()
    if ret.error:
        data["FlashError"] = ret.error
        return data

    containers = []
    for entry in ret.value:
        data["Total"] += 1
        data["Runtime"] = entry["runtime"]
        running = entry["state"] == "running"
        if running:
            data["Running"] += 1
        if (filter == "running" and not running) or (filter == "exited" and running):
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
    id = query_param(req, "id")
    action = query_param(req, "action")
    if action == "start":
        ret = openrun_admin.start_container(id)
    else:
        ret = openrun_admin.stop_container(id)
    error = ret.error
    return flash_result(data_fn(req), error, "Container %s requested" % action,
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
    id = query_param(req, "id")
    data = {
        "Title": "Container detail",
        "Nav": "containers",
        "Id": id,
        "Error": "",
        "Container": None,
        "Perms": get_perms(),
    }

    ret = openrun.get_container(id, stats=False)
    if ret.error:
        data["Error"] = ret.error
        return data

    c = dict(ret.value.items())
    c["started_at"] = nonzero_time(c.get("started_at"))
    data["Container"] = c
    return data


def containers_detail_stats_handler(req):
    # Slow fragment: live resource stats and disk usage
    id = query_param(req, "id")
    data = {"Id": id, "Container": None, "StatsError": "", "StatsLoaded": True}

    ret = openrun.get_container(id)
    if ret.error:
        data["StatsError"] = ret.error
        return data

    c = dict(ret.value.items())
    c["size_rw_human"] = human_size(c.get("size_rw") or 0)
    c["size_root_human"] = human_size(c.get("size_root_fs") or 0)
    if c.get("stats"):
        stats = dict(c["stats"].items())
        stats["cpu_num"] = pct_num(stats.get("cpu_percent"))
        stats["mem_num"] = pct_num(stats.get("mem_percent"))
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
    id = query_param(req, "id")
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
    id = query_param(req, "id")
    tail = query_param(req, "tail")
    tail_int = int(tail) if tail.isdigit() else 500
    if tail_int > 10000:
        tail_int = 10000
    follow = query_param(req, "follow") == "1"

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
        filters[key] = query_param(req, key)
    before = query_param(req, "before_timestamp")

    data = {
        "Title": "Audit Logs",
        "Nav": "audit",
        "Filters": filters,
        "Events": [],
        "Apps": [],
        "Operations": [],
        "NextPage": "",
        "Perms": get_perms(),
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
        # Normalize the timestamp: the API emits fractional seconds
        # ("...05.123Z") which the template date parsing does not accept
        t = e.get("create_time") or ""
        if "." in t:
            e["create_time"] = t.split(".")[0] + "Z"
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
    # Resolve a select setting's option list by source name
    if source == "auths":
        ret = openrun.list_auths()
        # "default" is what the setting resolves, exclude it from the choices
        return [a for a in (ret.value if not ret.error else []) if a != "default"]
    if source == "git_auths":
        ret = openrun.list_git_auths()
        return list(ret.value) if not ret.error else []
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
        "Perms": get_perms(),
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
    action = query_param(req, "action")
    force = query_param(req, "force") == "true"

    if action == "restore":
        ret = openrun_admin.restore_config(query_param(req, "restore_version"), force=force)
        ok = "Configuration restored"
    else:
        data = config_data(req)
        data["FlashError"] = "unknown action %s" % action
        return data

    error = ret.error
    return flash_result(config_data(req), error, ok)


def config_page_data(req, page):
    # A config sub page: the page's settings (with effective values and
    # dynamic badges), entry section tables and the app_config key/value table
    meta = config_page_meta(page)
    data = {
        "Title": meta["title"] + " configuration",
        "Nav": "config",
        "Error": "",
        "Perms": get_perms(),
        "Page": meta["page"],
        "PageTitle": meta["title"],
        "PageDesc": meta["desc"],
        "Settings": [],
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
    action = query_param(req, "action")
    version_id = query_param(req, "version_id")
    section = query_param(req, "section")
    key = query_param(req, "key")

    if action == "set_value":
        kind = query_param(req, "kind")
        raw = query_param(req, "value")
        if kind == "bool":
            ret = openrun_admin.set_config_value(section, key, raw == "on", version_id)
            ok = "Set %s %s - change is live" % (section, key)
        elif raw.strip() == "":
            # Clearing the field resets to the static config value
            if query_param(req, "is_dynamic") == "true":
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
        name = query_param(req, "name")
        ret = openrun_admin.delete_config_entry(section, name, version_id)
        ok = "Deleted %s entry %s - change is live" % (section, name)
    elif action == "kv_set":
        kv_section = _page_kv_section(meta, query_param(req, "kv_section"))
        kv_key = query_param(req, "key").strip()
        if not kv_section or not kv_key:
            data = config_page_data(req, page)
            data["FlashError"] = "key cannot be empty" if kv_section else "unknown kv section"
            return data
        value = parse_config_value(query_param(req, "value"))
        ret = openrun_admin.set_config_value(kv_section, kv_key, value, version_id)
        ok = "Set %s %s - applies on the next app reload" % (kv_section, kv_key)
    elif action == "kv_delete":
        kv_section = _page_kv_section(meta, query_param(req, "kv_section"))
        if not kv_section:
            data = config_page_data(req, page)
            data["FlashError"] = "unknown kv section"
            return data
        ret = openrun_admin.delete_config_value(kv_section, query_param(req, "key"), version_id)
        ok = "Removed %s %s" % (kv_section, query_param(req, "key"))
    else:
        data = config_page_data(req, page)
        data["FlashError"] = "unknown action %s" % action
        return data

    error = ret.error
    return flash_result(config_page_data(req, page), error, ok)


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


def config_rbac_data(req):
    # RBAC sub page: live/staged groups/roles/grants tables with the staged
    # draft publish workflow
    data = {
        "Title": "RBAC configuration",
        "Nav": "config",
        "Error": "",
        "Perms": get_perms(),
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
    data["ViewLive"] = cfg["has_staged"] and query_param(req, "view") == "live"
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
    action = query_param(req, "action")
    draft_version = query_param(req, "draft_version")
    force = query_param(req, "force") == "true"

    if action == "publish":
        ret = openrun_admin.publish_rbac_config(draft_version, force=force)
        ok = "Published RBAC configuration"
    elif action == "discard":
        ret = openrun_admin.discard_rbac_draft(draft_version)
        ok = "Discarded staged changes"
    elif action == "toggle_enabled":
        enabled = query_param(req, "enabled") == "true"
        ret = openrun_admin.update_rbac_enabled(enabled, draft_version)
        ok = "RBAC %s in the staged config - publish to apply" % ("enabled" if enabled else "disabled")
    elif action == "delete_group":
        ret = openrun_admin.delete_rbac_group(query_param(req, "name"), draft_version)
        ok = "Deleted group %s from the staged config" % query_param(req, "name")
    elif action == "delete_role":
        ret = openrun_admin.delete_rbac_role(query_param(req, "name"), draft_version)
        ok = "Deleted role %s from the staged config" % query_param(req, "name")
    elif action == "delete_grant":
        ret = openrun_admin.delete_rbac_grant(int(query_param(req, "index")), draft_version)
        ok = "Deleted grant from the staged config"
    else:
        data = config_rbac_data(req)
        data["FlashError"] = "unknown action %s" % action
        return data

    error = ret.error
    return flash_result(config_rbac_data(req), error, ok)


def config_entry_form_data(req, meta, name, values, is_edit, source, error):
    # Page context for the generic config entry form
    ret = openrun.get_rbac_config()
    version_id = ret.value["version_id"] if not ret.error else ""
    return {
        "Title": "Configuration",
        "Nav": "config",
        "Meta": meta,
        "Name": name,
        "Values": values,
        "IsEdit": is_edit,
        "Source": source,
        "Error": error,
        "VersionId": version_id,
        "Perms": get_perms(),
        "ReturnPath": "/config/" + config_page_for_section(meta["section"]),
    }


def config_entry_page_handler(req):
    # Generic entry form page (any CONFIG_SECTIONS section). With a name, the
    # form edits the dynamic entry, or overrides the static entry of that name
    section = query_param(req, "section")
    name = query_param(req, "name")
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
        values = {"properties_rows": kv_rows(values)}
    return config_entry_form_data(req, meta, name, values, source == "dynamic", source, "")


def config_entry_submit_handler(req):
    # POST: save one dynamic config entry. The change is validated and takes
    # effect immediately (config entries are not staged, unlike RBAC)
    section = query_param(req, "section")
    meta = config_section_meta(section)
    if not meta:
        return ace.redirect(req.AppPath + "/config")

    name = query_param(req, "name").strip()
    is_edit = query_param(req, "is_edit") == "true"
    values = {}
    if meta.get("kv"):
        rows = raw_kv_rows(req, "properties")
        parsed, error = parse_kv_rows(req, "properties")
        if error:
            return config_entry_form_data(req, meta, name, {"properties_rows": rows},
                                          is_edit, query_param(req, "source"), error)
        for key in parsed:
            values[key] = parse_config_value(parsed[key])
        ret = openrun_admin.set_config_entry(section, name, values, query_param(req, "version_id"))
        if ret.error:
            return config_entry_form_data(req, meta, name, {"properties_rows": rows},
                                          is_edit, query_param(req, "source"), ret.error)
        return ace.redirect(req.AppPath + "/config/" + config_page_for_section(section))
    for field in meta["fields"]:
        kind = field.get("kind") or "text"
        raw = query_param(req, field["name"])
        if kind == "bool":
            if raw == "on":
                values[field["name"]] = True
        elif kind == "list":
            lines = parse_lines(raw)
            if lines:
                values[field["name"]] = lines
        elif kind == "secret":
            if raw:
                values[field["name"]] = raw
            elif is_edit and query_param(req, field["name"] + "__keep") == "true":
                # Blank on edit keeps the stored secret via the placeholder
                values[field["name"]] = REDACTED_VALUE
        elif raw.strip():
            values[field["name"]] = raw.strip()

    ret = openrun_admin.set_config_entry(section, name, values, query_param(req, "version_id"))
    if ret.error:
        return config_entry_form_data(req, meta, name, values, is_edit, query_param(req, "source"), ret.error)
    return ace.redirect(req.AppPath + "/config/" + config_page_for_section(section))


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
        "Perms": get_perms(),
        "PermGroups": rbac_permission_groups(),
        "DraftVersion": cfg["draft_version"],
        "RoleNames": sorted((rbac.get("roles") or {}).keys()),
        "GroupNames": sorted((rbac.get("groups") or {}).keys()),
    }


def config_group_page_handler(req):
    # RBAC group form page, prefilled when editing
    name = query_param(req, "name")
    cfg = load_rbac_config()
    values = {"name": name, "users_text": "", "is_edit": bool(name)}
    if name:
        values["users_text"] = "\n".join((cfg["rbac"].get("groups") or {}).get(name) or [])
    return config_form_data(req, "group", values, "", cfg)


def config_group_submit_handler(req):
    # POST: save a group to the staged config
    values = {
        "name": query_param(req, "name").strip(),
        "users_text": query_param(req, "users_text"),
        "is_edit": query_param(req, "is_edit") == "true",
    }
    users = parse_lines(values["users_text"])
    ret = openrun_admin.set_rbac_group(values["name"], users, query_param(req, "draft_version"))
    if ret.error:
        return config_form_data(req, "group", values, ret.error)
    return ace.redirect(req.AppPath + "/config/rbac")


def config_role_page_handler(req):
    # RBAC role form page, prefilled when editing
    name = query_param(req, "name")
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
    name = query_param(req, "name").strip()
    perms = req.Form.get("permissions") or []
    custom_text = query_param(req, "custom_text")
    values = {"name": name, "selected": {}, "custom_text": custom_text,
              "is_edit": query_param(req, "is_edit") == "true"}
    for p in perms:
        values["selected"][p] = True
    all_perms = list(perms) + parse_lines(custom_text)
    ret = openrun_admin.set_rbac_role(name, all_perms, query_param(req, "draft_version"))
    if ret.error:
        return config_form_data(req, "role", values, ret.error)
    return ace.redirect(req.AppPath + "/config/rbac")


def config_grant_page_handler(req):
    # RBAC grant form page, prefilled when editing by index
    index = query_param(req, "index")
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
    index = query_param(req, "index")
    roles = req.Form.get("roles") or []
    values = {
        "index": index,
        "description": query_param(req, "description").strip(),
        "users_text": query_param(req, "users_text"),
        "roles": {},
        "targets_text": query_param(req, "targets_text"),
        "is_edit": index != "",
    }
    for r in roles:
        values["roles"][r] = True

    users = parse_lines(values["users_text"])
    targets = parse_lines(values["targets_text"])
    draft_version = query_param(req, "draft_version")
    if index != "":
        ret = openrun_admin.update_rbac_grant(int(index), values["description"], users,
                                              list(roles), targets, draft_version)
    else:
        ret = openrun_admin.add_rbac_grant(values["description"], users, list(roles),
                                           targets, draft_version)
    if ret.error:
        return config_form_data(req, "grant", values, ret.error)
    return ace.redirect(req.AppPath + "/config/rbac")


def config_version_handler(req):
    # Config history page: one snapshot rendered as formatted json
    version = query_param(req, "version")
    data = {
        "Title": "Config version",
        "Nav": "config",
        "Version": version,
        "Error": "",
        "Json": "",
        "Perms": get_perms(),
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
    query = query_param(req, "query").lower()

    data = {
        "Title": "Syncs",
        "Nav": "syncs",
        "Query": query,
        "Total": 0,
        "Perms": get_perms(),
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
            "flags": sync_flags(metadata),
            "state": status["state"],  # Enabled / Disabled / Failing
            "clobber": metadata["clobber"],
            "commit": short_sha(status["commit_id"]),
            "last_exec": nonzero_time(status["last_execution_time"]),
            "error": status["error"],
            "failure_count": status["failure_count"],
        })

    data["Syncs"] = sorted(syncs, key=lambda s: s["repo"])
    return data


def syncs_create_page_handler(req):
    # Sync create form page, promote/approve default on
    values = sync_form_values(req)
    values["promote"] = "on"
    values["approve"] = "on"
    return sync_form_data(req, values, "")


def sync_form_values(req):
    # The form fields for the sync create subpage
    return {
        "path": query_param(req, "path"),
        "git_branch": query_param(req, "git_branch"),
        "git_auth": query_param(req, "git_auth"),
        "minutes": query_param(req, "minutes"),
        "promote": query_param(req, "promote"),
        "approve": query_param(req, "approve"),
    }


def sync_form_data(req, values, error):
    # Page context for the sync create form
    return {
        "Title": "Add sync source",
        "Nav": "syncs",
        "Mode": "create",
        "Error": error,
        "Values": values,
        "GitAuthOptions": git_auth_options(),
        "Perms": get_perms(),
    }


def syncs_create_submit_handler(req):
    # POST: validate (dry run) or create a sync entry
    values = sync_form_values(req)
    action = query_param(req, "action")

    if not values["path"]:
        return sync_form_data(req, values, "Source path is required")

    minutes = 0
    if values["minutes"]:
        if not values["minutes"].isdigit():
            return sync_form_data(req, values, "Schedule minutes must be a number")
        minutes = int(values["minutes"])

    dry_run = action == "validate"
    ret = openrun_admin.create_sync(values["path"], git_branch=values["git_branch"],
                                  git_auth=values["git_auth"], minutes=minutes,
                                  promote=bool(values["promote"]),
                                  approve=bool(values["approve"]), dry_run=dry_run)
    if ret.error:
        return sync_form_data(req, values, ret.error)

    if dry_run:
        data = sync_form_data(req, values, "")
        data["Validated"] = True
        return data
    return ace.redirect(req.AppPath + "/syncs")


def syncs_delete_handler(req):
    # POST: delete a sync entry from the syncs list
    sync_id = query_param(req, "sync_id")
    ret = openrun_admin.delete_sync(sync_id)
    error = ret.error
    return flash_result(syncs_data(req), error, "Sync source removed", "Delete failed")


def syncs_run_handler(req):
    # POST: run a sync from the syncs list
    return run_sync_action(req, syncs_data)


def syncs_detail_data(req):
    # Sync detail page: settings, status and the last invocation results
    id = query_param(req, "id")
    data = {
        "Title": "Sync detail",
        "Nav": "syncs",
        "Id": id,
        "Error": "",
        "Sync": None,
        "Perms": get_perms(),
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
    last_exec = nonzero_time(status["last_execution_time"])

    data["Sync"] = {
        "id": entry["id"],
        "repo": entry["path"],
        "branch": metadata["git_branch"],
        "git_auth": metadata["git_auth"],
        "reload": metadata["reload"],
        "is_scheduled": entry["is_scheduled"],
        "schedule_frequency": metadata["schedule_frequency"],
        "webhook_url": metadata["webhook_url"],
        "flags": sync_flags(metadata),
        "state": status["state"],
        "commit": status["commit_id"],
        "commit_short": short_sha(status["commit_id"]),
        "last_exec": last_exec,
        "error": status["error"],
        "failure_count": status["failure_count"],
        "user": entry["user_id"],
        "create_time": nonzero_time(entry["create_time"]),
    }
    if last_exec:
        # Details of what the last invocation applied
        data["LastResult"] = sync_result_summary(status)

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
    sync_id = query_param(req, "id")
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
    sync_id = query_param(req, "id")
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
    perms = get_perms()
    return {
        "Name": query_param(req, "field"),
        "AppPath": req.AppPath,
        "Prefix": query_param(req, "prefix"),
        "InputId": query_param(req, "input_id"),
        "Placeholder": query_param(req, "placeholder"),
        "Masked": query_param(req, "masked") == "true",
        "File": query_param(req, "file") == "true",
        "Small": query_param(req, "small") == "true",
        "Description": query_param(req, "description"),
        "CanCreate": perms.get("secret:create", False),
        "CanDelete": perms.get("secret:delete", False),
    }


def secrets_store_handler(req):
    # POST from the secret-input component (console.js): encrypt the value
    # (or uploaded file content) into the db secrets provider and re-render
    # the component with the generated {{secret ...}} reference as its value
    data = secret_input_data(req)

    value = query_param(req, "value").strip()
    value_b64 = query_param(req, "value_b64")
    if not data["Prefix"]:
        data["Error"] = "no secret name prefix is configured for this field"
        data["Value"] = value
        return data
    if not value and not value_b64:
        data["Error"] = "enter a value to store as a secret"
        return data

    ret = openrun_admin.create_secret(
        value=value_b64 if value_b64 else value,
        prefix=data["Prefix"],
        encoding="base64" if value_b64 else "",
        description=data["Description"],
        source_file=query_param(req, "source_file"))
    if ret.error:
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

    name = query_param(req, "name").strip()
    if not name:
        data["Error"] = "no secret name to delete"
        data["Value"] = query_param(req, "ref")
        return data

    ret = openrun_admin.delete_secret(name=name, provider=query_param(req, "provider"))
    error = ret.error
    if error:
        data["Error"] = error
        data["Value"] = query_param(req, "ref")
        return data
    # Deleted: the field goes back to accepting a plain value
    data["Value"] = ""
    return data
