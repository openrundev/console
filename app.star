load("handler.star",
     "apps_data", "apps_detail_data", "apps_switch_handler", "apps_promote_handler",
     "apps_approve_handler", "apps_detail_reload_handler", "apps_detail_delete_handler",
     "apps_files_handler", "apps_files_download_handler",
     "apps_create_page_handler", "apps_create_submit_handler",
     "apps_update_page_handler", "apps_update_submit_handler", "apps_delete_handler",
     "apps_reload_handler", "apps_sync_handler",
     "apps_list_promote_handler", "apps_list_approve_handler",
     "syncs_data", "syncs_detail_data", "syncs_detail_run_handler",
     "syncs_detail_delete_handler", "syncs_create_page_handler",
     "syncs_create_submit_handler", "syncs_run_handler", "syncs_delete_handler",
     "audit_data",
     "config_data", "config_action_handler", "config_version_handler",
     "config_rbac_data", "config_rbac_action_handler",
     "config_entry_page_handler", "config_entry_submit_handler",
     "config_auth_data", "config_auth_action_handler",
     "config_git_data", "config_git_action_handler",
     "config_secrets_data", "config_secrets_action_handler",
     "config_system_data", "config_system_action_handler",
     "config_builder_data", "config_builder_action_handler",
     "config_group_page_handler", "config_group_submit_handler",
     "config_role_page_handler", "config_role_submit_handler",
     "config_grant_page_handler", "config_grant_submit_handler",
     "containers_data", "containers_lifecycle_handler", "containers_detail_data",
     "containers_detail_stats_handler", "containers_logs_stream_handler",
     "containers_detail_lifecycle_handler", "containers_k8s_stats_handler",
     "containers_detail_k8s_handler",
     "bindings_data", "bindings_create_page_handler", "bindings_create_submit_handler",
     "bindings_update_page_handler", "bindings_update_submit_handler",
     "bindings_delete_handler", "services_create_page_handler",
     "services_create_submit_handler", "services_delete_handler",
     "secrets_store_handler", "secrets_delete_handler",
     "builder_data", "builder_create_page_handler", "builder_create_submit_handler",
     "builder_detail_data", "builder_detail_action", "builder_delete_handler",
     "builder_publish_handler", "builder_unpublish_handler", "builder_promote_handler",
     "builder_events_handler", "builder_file_handler", "builder_rows_action",
     "builder_download_handler")

# OpenRun management console. Routes mirror the UI layout: one route per
# screen, each screen template defines a partial block which HTMX requests
# (filtering, auto-refresh) re-render on their own. Handlers live in
# handler.star, shared helpers in utils.star.

# Feature flags from params.star, set at app install time (openrun app
# create --param enable_all=true ...). The default install is a read-only
# console: write routes are not registered and the corresponding plugin
# permissions are not requested, so a disabled area needs no approval and
# cannot be invoked at all.
#   enable_updates:   the write switch: app/sync/binding/service changes,
#                     storing secrets, and - combined with the area flags -
#                     container start/stop and config/RBAC changes
#   enable_container: the containers screens; start/stop additionally needs
#                     enable_updates
#   enable_config:    the configuration screens; changes (restore, entry and
#                     RBAC edits) additionally need enable_updates
#   enable_all:       everything
ENABLE_UPDATES = param.enable_all or param.enable_updates
ENABLE_CONTAINER = param.enable_all or param.enable_container
ENABLE_CONFIG = param.enable_all or param.enable_config
ENABLE_BUILDER = param.enable_all or param.enable_builder


def error_handler(req, ret):
    # Framework fallback for handler crashes and plugin errors no handler
    # checked, instead of a raw 500. Explicitly handled errors render inline
    # on their own pages and never reach this. Must not call any plugin API
    # (the failed-call state may still be set, which would fail this too)
    data = {"Title": "Error", "Nav": "", "Error": ret["error"]}
    if req.IsPartial:
        # Render into the fixed toast target present on every page; the
        # error_toast define lives in base templates, referenced by name
        return ace.response(data, "error_toast",
                            retarget="#error-toast", reswap="innerHTML")
    return ace.response(data, "error.go.html")

# OpenRun brand themes. Brand greens: light #00C200, dark #007700. The roles
# are the same in both modes: #00C200 is primary (with deep-green content
# text, it is too bright to carry white text), #007700 is secondary.
# Base surfaces are green-tinted.
OPENRUN_THEMES = {
    "openrun-light": {
        "color-scheme": "light",
        "--color-base-100": "#ffffff",  # cards, sidebar
        "--color-base-200": "#f1f6f1",  # page background, green-tinted
        "--color-base-300": "#dce8dc",  # borders, dividers
        "--color-base-content": "#142319",
        "--color-primary": "#00c200",  # brand light green, actions
        "--color-primary-content": "#012d01",
        "--color-secondary": "#007700",  # brand dark green, highlights
        "--color-secondary-content": "#d9ffd6",
        "--color-accent": "#009a66",
        "--color-accent-content": "#f0fff8",
        "--color-neutral": "#1e2b22",
        "--color-neutral-content": "#eef5ee",
        "--color-info": "#0b6bcb",
        "--color-info-content": "#f2f8ff",
        "--color-success": "#0f7d0f",  # 4.5:1+ on white and badge-soft
        "--color-success-content": "#f2fff2",
        "--color-warning": "#946000",  # dark amber, 4.5:1+ on white and badge-soft
        "--color-warning-content": "#fffaf0",
        "--color-error": "#d3302f",
        "--color-error-content": "#fff5f4",
        "--radius-selector": "0.5rem",
        "--radius-field": "0.5rem",
        "--radius-box": "0.75rem",
        "--size-selector": "0.25rem",
        "--size-field": "0.25rem",
        "--border": "1px",
        "--depth": "1",
        "--noise": "0",
    },
    "openrun-dark": {
        "color-scheme": "dark",
        "--color-base-100": "#17221a",  # cards, sidebar, lifted above page bg
        "--color-base-200": "#101a13",  # page background
        "--color-base-300": "#273b2c",  # borders, dividers
        "--color-base-content": "#d9e7db",
        "--color-primary": "#00c200",  # brand light green, actions
        "--color-primary-content": "#012d01",
        "--color-secondary": "#007700",  # brand dark green, fills
        "--color-secondary-content": "#d9ffd6",
        "--color-accent": "#00d98b",
        "--color-accent-content": "#00311d",
        "--color-neutral": "#22312a",
        "--color-neutral-content": "#d3e3d6",
        "--color-info": "#55a9ff",
        "--color-info-content": "#00203f",
        "--color-success": "#37d24c",
        "--color-success-content": "#003a0c",
        "--color-warning": "#ffbe3d",
        "--color-warning-content": "#402d00",
        "--color-error": "#ff6f65",
        "--color-error-content": "#400300",
        "--radius-selector": "0.5rem",
        "--radius-field": "0.5rem",
        "--radius-box": "0.75rem",
        "--size-selector": "0.25rem",
        "--size-field": "0.25rem",
        "--border": "1px",
        "--depth": "1",
        "--noise": "0",
    },
}

# Routes. Page actions are ace.fragment entries on their page: the fragment
# path appends to the page path and inherits the page's full template and
# partial block (overridable), so the template names are not repeated per
# action. Form subpages use a fragment with an empty path for their POST: it
# registers on the page path itself with the same template, only the handler
# differs. Write routes are added only when their feature flag is enabled;
# the read pages always register (with no action fragments when disabled)
def build_routes():
    routes = [
        ace.html("/", full="apps.go.html", partial="app_groups", handler=apps_data),
        # Apps list, with the row actions posting back to the list
        ace.html("/apps", full="apps.go.html", partial="app_groups", handler=apps_data,
                 fragments=[
                     ace.fragment("delete", method="POST", handler=apps_delete_handler),
                     ace.fragment("reload", method="POST", handler=apps_reload_handler),
                     ace.fragment("sync", method="POST", handler=apps_sync_handler),
                     # Row actions of the pending promotion / needs approval tabs
                     ace.fragment("promote", method="POST", handler=apps_list_promote_handler),
                     ace.fragment("approve", method="POST", handler=apps_list_approve_handler),
                 ] if ENABLE_UPDATES else []),
        # App detail, with the version/lifecycle actions re-rendering the
        # detail content
        ace.html("/apps/detail", full="app_detail.go.html", partial="detail_content", handler=apps_detail_data,
                 fragments=[
                     ace.fragment("switch", method="POST", handler=apps_switch_handler),
                     ace.fragment("promote", method="POST", handler=apps_promote_handler),
                     ace.fragment("approve", method="POST", handler=apps_approve_handler),
                     ace.fragment("reload", method="POST", handler=apps_detail_reload_handler),
                     ace.fragment("delete", method="POST", handler=apps_detail_delete_handler),
                 ] if ENABLE_UPDATES else []),
        ace.html("/apps/files", full="app_files.go.html", handler=apps_files_handler,
                 fragments=[
                     # Zip download of the version files (redirects to a
                     # single-access temp file url)
                     ace.fragment("download", handler=apps_files_download_handler),
                 ]),
        ace.html("/syncs", full="syncs.go.html", partial="sync_rows", handler=syncs_data,
                 fragments=[
                     ace.fragment("run", method="POST", handler=syncs_run_handler),
                     ace.fragment("delete", method="POST", handler=syncs_delete_handler),
                 ] if ENABLE_UPDATES else []),
        ace.html("/syncs/detail", full="sync_detail.go.html", partial="sync_content", handler=syncs_detail_data,
                 fragments=[
                     ace.fragment("run", method="POST", handler=syncs_detail_run_handler),
                     ace.fragment("delete", method="POST", handler=syncs_detail_delete_handler),
                 ] if ENABLE_UPDATES else []),
        ace.html("/audit", full="audit.go.html", partial="audit_rows", handler=audit_data),
        ace.html("/bindings", full="bindings.go.html", partial="binding_groups", handler=bindings_data,
                 fragments=[
                     ace.fragment("delete", method="POST", handler=bindings_delete_handler),
                     ace.fragment("services/delete", method="POST", handler=services_delete_handler),
                 ] if ENABLE_UPDATES else []),
    ]

    if ENABLE_UPDATES:
        # App/sync/binding/service write subpages
        routes += [
            ace.html("/apps/create", full="app_form.go.html", handler=apps_create_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=apps_create_submit_handler),
                     ]),
            ace.html("/apps/update", full="app_form.go.html", handler=apps_update_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=apps_update_submit_handler),
                     ]),
            ace.html("/syncs/create", full="sync_form.go.html", handler=syncs_create_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=syncs_create_submit_handler),
                     ]),
            ace.html("/bindings/services/create", full="service_form.go.html", handler=services_create_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=services_create_submit_handler),
                     ]),
            ace.html("/bindings/create", full="binding_form.go.html", handler=bindings_create_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=bindings_create_submit_handler),
                     ]),
            ace.html("/bindings/update", full="binding_form.go.html", handler=bindings_update_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=bindings_update_submit_handler),
                     ]),
        ]

    if ENABLE_CONFIG:
        # The configuration view pages: top level lists the config areas and
        # history; each area is a sub page. Config changes are writes: the
        # action fragments and the edit subpages additionally need
        # enable_updates
        routes += [
            ace.html("/config", full="config.go.html", partial="config_content", handler=config_data,
                     fragments=[
                         ace.fragment("action", method="POST", handler=config_action_handler),
                     ] if ENABLE_UPDATES else []),
            ace.html("/config/history", full="config_version.go.html", handler=config_version_handler),
            ace.html("/config/auth", full="config_page.go.html", partial="page_content", handler=config_auth_data,
                     fragments=[
                         ace.fragment("action", method="POST", handler=config_auth_action_handler),
                     ] if ENABLE_UPDATES else []),
            ace.html("/config/git", full="config_page.go.html", partial="page_content", handler=config_git_data,
                     fragments=[
                         ace.fragment("action", method="POST", handler=config_git_action_handler),
                     ] if ENABLE_UPDATES else []),
            ace.html("/config/secrets", full="config_page.go.html", partial="page_content", handler=config_secrets_data,
                     fragments=[
                         ace.fragment("action", method="POST", handler=config_secrets_action_handler),
                     ] if ENABLE_UPDATES else []),
            ace.html("/config/system", full="config_page.go.html", partial="page_content", handler=config_system_data,
                     fragments=[
                         ace.fragment("action", method="POST", handler=config_system_action_handler),
                     ] if ENABLE_UPDATES else []),
            ace.html("/config/builder", full="config_page.go.html", partial="page_content", handler=config_builder_data,
                     fragments=[
                         ace.fragment("action", method="POST", handler=config_builder_action_handler),
                     ] if ENABLE_UPDATES else []),
            ace.html("/config/rbac", full="config_rbac.go.html", partial="rbac_content", handler=config_rbac_data,
                     fragments=[
                         ace.fragment("action", method="POST", handler=config_rbac_action_handler),
                     ] if ENABLE_UPDATES else []),
        ]

    if ENABLE_CONFIG and ENABLE_UPDATES:
        # Config entry and RBAC edit subpages (config writes)
        routes += [
            ace.html("/config/entry", full="config_entry_form.go.html", handler=config_entry_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=config_entry_submit_handler),
                     ]),
            ace.html("/config/rbac/group", full="config_form.go.html", handler=config_group_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=config_group_submit_handler),
                     ]),
            ace.html("/config/rbac/role", full="config_form.go.html", handler=config_role_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=config_role_submit_handler),
                     ]),
            ace.html("/config/rbac/grant", full="config_form.go.html", handler=config_grant_page_handler,
                     fragments=[
                         ace.fragment("", method="POST", handler=config_grant_submit_handler),
                     ]),
        ]

    if ENABLE_BUILDER:
        # AI app builder: sessions list, new-app form and the session
        # workspace (chat + preview). Session mutations and publishing are
        # writes: those fragments additionally need enable_updates
        routes += [
            ace.html("/builder", full="builder.go.html", partial="builder_rows", handler=builder_data,
                     fragments=[
                         ace.fragment("stop", method="POST", handler=lambda req: builder_rows_action(req, "stop")),
                         ace.fragment("resume", method="POST", handler=lambda req: builder_rows_action(req, "resume")),
                         ace.fragment("delete", method="POST", handler=lambda req: builder_rows_action(req, "delete")),
                     ] if ENABLE_UPDATES else []),
            ace.html("/builder/detail", full="builder_session.go.html", partial="session_content", handler=builder_detail_data,
                     fragments=[
                         ace.fragment("message", method="POST", handler=lambda req: builder_detail_action(req, "message")),
                         ace.fragment("cancel", method="POST", handler=lambda req: builder_detail_action(req, "cancel")),
                         ace.fragment("stop", method="POST", handler=lambda req: builder_detail_action(req, "stop")),
                         ace.fragment("resume", method="POST", handler=lambda req: builder_detail_action(req, "resume")),
                         ace.fragment("approve", method="POST", handler=lambda req: builder_detail_action(req, "approve")),
                         ace.fragment("delete", method="POST", handler=builder_delete_handler),
                         ace.fragment("publish", method="POST", handler=builder_publish_handler),
                         ace.fragment("unpublish", method="POST", handler=builder_unpublish_handler),
                         # Promote the staging app after a local-mode publish
                         ace.fragment("promote", method="POST", handler=builder_promote_handler),
                     ] if ENABLE_UPDATES else []),
            # Event stream consumed by the <builder-chat> element
            ace.api("/builder/events", handler=builder_events_handler, type="TEXT"),
            # Raw workspace file content for the <builder-files> viewer
            ace.api("/builder/file", handler=builder_file_handler, type="TEXT"),
            # Source zip download: redirects to a single-access temp file url
            ace.html("/builder/download", full="builder_session.go.html", handler=builder_download_handler),
        ]
        if ENABLE_UPDATES:
            routes += [
                ace.html("/builder/create", full="builder_form.go.html", handler=builder_create_page_handler,
                         fragments=[
                             ace.fragment("", method="POST", handler=builder_create_submit_handler),
                         ]),
            ]

    if ENABLE_CONTAINER:
        # Containers list and detail; the stats/k8s fragments override the
        # partial block for their async HTMX loads. Start/stop (the
        # lifecycle fragments) additionally needs enable_updates
        routes += [
            ace.html("/containers", full="containers.go.html", partial="container_rows", handler=containers_data,
                     fragments=[
                         ace.fragment("k8s_stats", partial="k8s_stats", handler=containers_k8s_stats_handler),
                     ] + ([
                         ace.fragment("lifecycle", method="POST", handler=containers_lifecycle_handler),
                     ] if ENABLE_UPDATES else [])),
            ace.html("/containers/detail", full="container_detail.go.html", partial="container_content", handler=containers_detail_data,
                     fragments=[
                         ace.fragment("stats", partial="container_stats", handler=containers_detail_stats_handler),
                         ace.fragment("k8s", partial="container_k8s", handler=containers_detail_k8s_handler),
                     ] + ([
                         ace.fragment("lifecycle", method="POST", handler=containers_detail_lifecycle_handler),
                     ] if ENABLE_UPDATES else [])),
            ace.api("/containers/logs_stream", handler=containers_logs_stream_handler, type="TEXT"),
        ]

    if ENABLE_UPDATES:
        # Backs the secret-input component (console.js) used by the app/
        # binding/service and config forms: encrypts a value into the db
        # secrets provider and swaps the input's value with the returned
        # {{secret ...}} reference. The response template is a base-templates
        # define referenced by name (no page file)
        routes += [
            ace.html("/secrets/store", method="POST", full="secret_input_response", handler=secrets_store_handler),
            # Unlocking a stored field offers deleting the secret; the
            # response is the same component fragment (empty on success)
            ace.html("/secrets/delete", method="POST", full="secret_input_response", handler=secrets_delete_handler),
        ]

    return routes


# Plugin permissions. The read APIs backing the always-on pages are always
# requested; write APIs only when their feature flag is enabled, so a
# read-only install approves no write permission at all
def build_permissions():
    permissions = [
        ace.permission("openrun.in", "list_apps"),
        ace.permission("openrun.in", "list_all_apps"),
        ace.permission("openrun.in", "list_operations"),
        ace.permission("openrun.in", "list_audit_events"),
        ace.permission("openrun.in", "list_sync"),
        ace.permission("openrun.in", "list_bindings"),
        ace.permission("openrun.in", "list_specs"),
        ace.permission("openrun.in", "get_app"),
        ace.permission("openrun.in", "get_permissions"),
        ace.permission("openrun.in", "system_plugins_allowed"),
        ace.permission("openrun.in", "list_auths"),
        ace.permission("openrun.in", "list_git_auths"),
        ace.permission("openrun.in", "list_versions"),
        ace.permission("openrun.in", "list_version_files"),
        ace.permission("openrun.in", "get_version_zip"),
        ace.permission("openrun.in", "audit_app"),
        ace.permission("openrun.in", "list_services"),
    ]

    if ENABLE_UPDATES:
        permissions += [
            ace.permission("openrun_admin.in", "create_app"),
            ace.permission("openrun_admin.in", "delete_apps"),
            ace.permission("openrun_admin.in", "update_params"),
            ace.permission("openrun_admin.in", "update_auth"),
            ace.permission("openrun_admin.in", "reload_apps"),
            ace.permission("openrun_admin.in", "approve_apps"),
            ace.permission("openrun_admin.in", "switch_version"),
            ace.permission("openrun_admin.in", "promote_apps"),
            ace.permission("openrun_admin.in", "create_sync"),
            ace.permission("openrun_admin.in", "run_sync"),
            ace.permission("openrun_admin.in", "delete_sync"),
            ace.permission("openrun_admin.in", "create_binding"),
            ace.permission("openrun_admin.in", "update_binding"),
            ace.permission("openrun_admin.in", "delete_binding"),
            ace.permission("openrun_admin.in", "create_service"),
            ace.permission("openrun_admin.in", "delete_service"),
        ]

    if ENABLE_CONFIG:
        permissions += [
            ace.permission("openrun.in", "get_rbac_config"),
            ace.permission("openrun.in", "get_config_entries"),
            ace.permission("openrun.in", "get_config_values"),
            ace.permission("openrun.in", "list_config_history"),
            ace.permission("openrun.in", "get_config_version"),
            ace.permission("openrun.in", "list_rbac_permissions"),
        ]

    if ENABLE_CONFIG and ENABLE_UPDATES:
        # Config changes are writes: need both flags
        permissions += [
            ace.permission("openrun_admin.in", "update_rbac_enabled"),
            ace.permission("openrun_admin.in", "set_rbac_group"),
            ace.permission("openrun_admin.in", "delete_rbac_group"),
            ace.permission("openrun_admin.in", "set_rbac_role"),
            ace.permission("openrun_admin.in", "delete_rbac_role"),
            ace.permission("openrun_admin.in", "add_rbac_grant"),
            ace.permission("openrun_admin.in", "update_rbac_grant"),
            ace.permission("openrun_admin.in", "delete_rbac_grant"),
            ace.permission("openrun_admin.in", "publish_rbac_config"),
            ace.permission("openrun_admin.in", "discard_rbac_draft"),
            ace.permission("openrun_admin.in", "restore_config"),
            ace.permission("openrun_admin.in", "set_config_entry"),
            ace.permission("openrun_admin.in", "delete_config_entry"),
            ace.permission("openrun_admin.in", "set_config_value"),
            ace.permission("openrun_admin.in", "delete_config_value"),
        ]

    if ENABLE_BUILDER:
        permissions += [
            ace.permission("build.in", "list_sessions"),
            ace.permission("build.in", "get_session"),
            ace.permission("build.in", "get_messages"),
            ace.permission("build.in", "session_events"),
            ace.permission("build.in", "list_files"),
            ace.permission("build.in", "read_file"),
            ace.permission("build.in", "get_source_zip"),
            ace.permission("build.in", "get_publish_config"),
            ace.permission("build.in", "list_activity"),
        ]

    if ENABLE_BUILDER and ENABLE_UPDATES:
        # Builder session and publish actions are writes: need both flags
        permissions += [
            ace.permission("build.in", "create_session"),
            ace.permission("build.in", "send_message"),
            ace.permission("build.in", "cancel_turn"),
            ace.permission("build.in", "stop_session"),
            ace.permission("build.in", "resume_session"),
            ace.permission("build.in", "delete_session"),
            ace.permission("build.in", "publish_app"),
            ace.permission("build.in", "unpublish_app"),
        ]

    if ENABLE_CONTAINER:
        permissions += [
            ace.permission("openrun.in", "list_containers"),
            ace.permission("openrun.in", "get_container"),
            ace.permission("openrun.in", "kubernetes_stats"),
            ace.permission("openrun.in", "container_kubernetes_status"),
            ace.permission("openrun.in", "container_logs_stream"),
        ]

    if ENABLE_CONTAINER and ENABLE_UPDATES:
        # Container start/stop is a write: needs both flags
        permissions += [
            ace.permission("openrun_admin.in", "start_container"),
            ace.permission("openrun_admin.in", "stop_container"),
        ]

    if ENABLE_UPDATES:
        permissions += [
            ace.permission("openrun_admin.in", "create_secret"),
            ace.permission("openrun_admin.in", "delete_secret"),
        ]

    return permissions


app = ace.app(param.name,
              custom_layout=True,
              routes=build_routes(),
              permissions=build_permissions(),
              style=ace.style("daisyui",
                              light="openrun-light",
                              dark="openrun-dark",
                              custom_themes=OPENRUN_THEMES))
