load("openrun.in", "openrun")
load("openrun_admin.in", "openrun_admin")
load("utils.star", "query_param", "get_perms", "parse_params_text", "params_to_text",
     "parse_lines", "short_sha", "short_age", "human_size", "pct_num", "nonzero_time",
     "path_domain_str", "sync_flags", "sync_result_summary", "review_from_dryrun",
     "needs_approval")

# Route handlers for the console. Each screen has a *_data function which
# builds the full page context; action handlers run the mutation and re-render
# the same context with a Flash/FlashError message. Mutation results must read
# ret.error BEFORE the *_data call: an unread plugin error fails the next
# plugin call. The error_handler in app.star is the fallback when that is
# missed.


# ---------- Apps ----------


def apps_data(req):
    # Apps list page: apps grouped by their managing sync, plus unmanaged
    query = query_param(req, "query")
    filter = query_param(req, "filter")  # "", "declarative" or "imperative"

    # include_internal picks up staging/preview apps; staging entries are
    # folded into their main app's row instead of being listed separately
    all_apps = openrun.list_apps(query=query, include_internal=True).value

    staging_by_main = {}
    for entry in all_apps:
        if entry["is_stage"]:
            staging_by_main[entry["main_app"]] = entry

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
    for entry in all_apps:
        if entry["main_app"]:
            continue
        total += 1

        stage = staging_by_main.get(entry["id"])
        # The staging app carries the most recent sync state (prod picks it
        # up on promote); fall back to the prod app's value. get() keeps this
        # working against servers older than the applied_sync_id field
        sync_id = (stage.get("applied_sync_id", "") if stage else "") or entry.get("applied_sync_id", "")

        # Declarative means a sync source last applied the app. Git presence
        # is not the signal: image and proxy spec apps have no git source
        is_declarative = bool(sync_id)
        if is_declarative:
            declarative_count += 1
        if (filter == "declarative" and not is_declarative) or \
           (filter == "imperative" and is_declarative):
            continue

        staging = None
        if stage:
            staging = {
                "version": stage["version"],
                "git_sha": short_sha(stage["git_sha"]),
                "git_message": stage["git_message"],
                # staging has a version prod does not have yet
                "ahead": stage["version_mismatch"],
            }

        app = {
            "name": entry["name"],
            "path": entry["path"],
            "url": entry["url"],
            "auth": entry["auth"],
            "is_git": bool(entry["git_branch"]),
            "is_declarative": is_declarative,
            # "-" is the placeholder for apps with no source (image/proxy specs)
            "source": entry["source"] if entry["source"] != "-" else "",
            "source_url": entry["source_url"],
            "git_branch": entry["git_branch"],
            "version": entry["version"],
            "git_sha": short_sha(entry["git_sha"]),
            "git_message": entry["git_message"],
            "staging": staging,
            "created_by": entry.get("created_by") or "",
            "update_age": short_age(entry["update_age"]),
        }

        if sync_id and sync_id in syncs:
            grouped.setdefault(sync_id, []).append(app)
        else:
            unmanaged.append(app)

    groups = []
    for sync_id in grouped:
        groups.append({
            "sync": syncs[sync_id],
            "apps": sorted(grouped[sync_id], key=lambda app: app["path"]),
        })

    return {
        "Title": "Apps",
        "Nav": "apps",
        "Query": query,
        "Filter": filter,
        "Groups": sorted(groups, key=lambda group: group["sync"]["repo"]),
        "Unmanaged": sorted(unmanaged, key=lambda app: app["path"]),
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
    error = ret.error  # read before apps_detail_data, an unread plugin error fails the next call
    data = apps_detail_data(req)
    if error:
        data["FlashError"] = "Version switch failed: %s" % error
    else:
        data["Flash"] = "Switched %s to v%s" % (env, version)
    return data


def apps_promote_handler(req):
    # POST: promote the staging app to prod
    path = query_param(req, "path")
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
    path = query_param(req, "path")
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
    path = query_param(req, "path")
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
    path = query_param(req, "path")
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
    path = query_param(req, "path")
    ret = openrun_admin.delete_apps(path)
    error = ret.error
    data = apps_data(req)
    if error:
        data["FlashError"] = "Delete failed: %s" % error
    else:
        data["Flash"] = "Deleted %s" % path
    return data


def apps_reload_handler(req):
    # POST: reload staging from the apps list, then go to the detail page
    path = query_param(req, "path")
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
        "params_text": query_param(req, "params_text"),
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

    params, err = parse_params_text(values["params_text"])
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
        "params_text": params_to_text(app["params"]),
    }
    return update_form_data(req, app, values, "")


def apps_update_submit_handler(req):
    # POST: apply param (staged) and auth (direct) changes
    path = query_param(req, "path")
    values = {
        "path": path,
        "auth": query_param(req, "auth"),
        "params_text": query_param(req, "params_text"),
    }

    ret = openrun.get_app(path)
    if ret.error:
        return update_form_data(req, None, values, ret.error)
    app = ret.value

    params, err = parse_params_text(values["params_text"])
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

    by_path = lambda binding: binding["path"]
    return {
        "Title": "Bindings",
        "Nav": "bindings",
        "Query": query,
        "Total": total,
        "Perms": get_perms(),
        "FlashError": list_error,
        "Services": sorted(services, key=lambda svc: svc["id"]),
        "ServicesError": services_error,
        "Base": sorted(base, key=by_path),
        "Derived": sorted(derived, key=by_path),
        "Auto": sorted(auto, key=by_path),
    }


def binding_form_values(req):
    # The form fields for the binding create/update subpages
    return {
        "path": query_param(req, "path"),
        "source": query_param(req, "source"),
        "grants_text": query_param(req, "grants_text"),
        "config_text": query_param(req, "config_text"),
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

    config, err = parse_params_text(values["config_text"])
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
    data = bindings_data(req)
    if error:
        data["FlashError"] = "Delete failed: %s" % error
    else:
        data["Flash"] = "Deleted binding %s" % path
    return data


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
    values = {"id": "", "config_text": "", "is_default": False, "staging": ""}
    return service_form_data(req, values, "")


def services_create_submit_handler(req):
    # POST: validate (dry run) or create a service
    values = {
        "id": query_param(req, "id").strip(),
        "config_text": query_param(req, "config_text"),
        "is_default": query_param(req, "is_default") == "on",
        "staging": query_param(req, "staging").strip(),
    }
    action = query_param(req, "action")

    config, err = parse_params_text(values["config_text"])
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
    data = bindings_data(req)
    if error:
        data["FlashError"] = "Service delete failed: %s" % error
    else:
        data["Flash"] = "Deleted service %s" % id
    return data


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

    data["Containers"] = sorted(containers, key=lambda c: c["app_path"] + " " + c["name"])
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
    data = data_fn(req)
    if error:
        data["FlashError"] = "Container %s failed: %s" % (action, error)
    else:
        data["Flash"] = "Container %s requested" % action
    return data


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


def containers_detail_logs_handler(req):
    # Slow fragment: recent container logs
    id = query_param(req, "id")
    data = {"Id": id, "Logs": "", "LogsError": "", "LogsLoaded": True}
    logs = openrun.container_logs(id, tail=100)
    if logs.error:
        data["LogsError"] = logs.error
    else:
        data["Logs"] = logs.value
    return data


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


# ---------- Configuration (RBAC) ----------


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
    # Configuration page: live/staged RBAC tables and config history
    data = {
        "Title": "Configuration",
        "Nav": "config",
        "Error": "",
        "Perms": get_perms(),
        "History": [],
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
    # The tables show the draft when one exists; enforcement uses live
    data["View"] = rbac_section(cfg["staged"]) if cfg["has_staged"] else data["Live"]
    if cfg["has_staged"]:
        data["Diff"] = rbac_diff(cfg["rbac"], cfg["staged"])
        data["Draft"] = cfg["draft"]
        data["DraftVersion"] = cfg["draft"]["draft_version"]

    hist = openrun.list_config_history()
    if not hist.error:
        data["History"] = hist.value
    return data


def config_action_handler(req):
    # Publish / discard / toggle-enabled / restore actions on the config page
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
        ok = "RBAC %s in the staged config — publish to apply" % ("enabled" if enabled else "disabled")
    elif action == "restore":
        ret = openrun_admin.restore_config(query_param(req, "restore_version"), force=force)
        ok = "Configuration restored"
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
        data = config_data(req)
        data["FlashError"] = "unknown action %s" % action
        return data

    error = ret.error
    data = config_data(req)
    if error:
        data["FlashError"] = error
    else:
        data["Flash"] = ok
    return data


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
    return ace.redirect(req.AppPath + "/config")


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
    return ace.redirect(req.AppPath + "/config")


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
    return ace.redirect(req.AppPath + "/config")


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
    data = syncs_data(req)
    if error:
        data["FlashError"] = "Delete failed: %s" % error
    else:
        data["Flash"] = "Sync source removed"
    return data


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
