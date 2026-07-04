load("openrun.in", "openrun")

# Shared helpers for the console handlers: parsing/formatting utilities and
# the permission lookup used by every page.


def query_param(req, key):
    # req.Form merges url query and form body values
    return req.Form.get(key)[0] if req.Form.get(key) else ""


def get_perms(path=""):
    # Management API permissions held by the current user, as a lookup dict.
    # When RBAC enforcement is not active, all permissions are returned. With
    # a path, app permissions are evaluated against that app (owner rule)
    ret = openrun.get_permissions(path=path) if path else openrun.get_permissions()
    perms = {}
    if not ret.error:
        for perm in ret.value:
            perms[perm] = True
    return perms


def parse_params_text(text):
    # Parse a "KEY=value" per line textarea into a dict
    params = {}
    for line in text.split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            return None, 'invalid parameter line "%s", expected KEY=value' % line
        parts = line.split("=", 1)
        key = parts[0].strip()
        if not key:
            return None, 'invalid parameter line "%s", key is empty' % line
        params[key] = parts[1].strip()
    return params, ""


def params_to_text(params):
    # Render a params dict back into KEY=value lines, sorted by key
    lines = []
    for key in sorted(params.keys()):
        lines.append("%s=%s" % (key, params[key]))
    return "\n".join(lines)


def parse_lines(text):
    # Split a textarea into trimmed, non-empty lines
    lines = []
    for line in text.split("\n"):
        line = line.strip()
        if line:
            lines.append(line)
    return lines


def short_sha(sha):
    # Abbreviate a git sha for display
    return sha[:7] if sha else ""


def short_age(age):
    # Keep the most significant unit: "105 days 3 hours ago" -> "105 days ago"
    parts = age.split(" ")
    if len(parts) > 3:
        return " ".join(parts[:2]) + " ago"
    return age


def human_size(size):
    # Format a byte count as B / KB / MB
    if size < 1024:
        return "%d B" % size
    if size < 1024 * 1024:
        return "%d.%d KB" % (size // 1024, (size % 1024) * 10 // 1024)
    mb = 1024 * 1024
    return "%d.%d MB" % (size // mb, (size % mb) * 10 // mb)


def pct_num(text):
    # "12.3%" -> 12, for radial progress values
    text = (text or "").strip().rstrip("%")
    if not text:
        return 0
    parts = text.split(".")
    return int(parts[0]) if parts[0].isdigit() else 0


def nonzero_time(t):
    # The APIs emit the go zero time ("0001-01-01...") for unset timestamps
    t = t or ""
    return "" if t.startswith("0001-") else t


def path_domain_str(pd):
    # Format an AppPathDomain struct as domain:path
    if not pd:
        return ""
    domain = pd.get("Domain") or ""
    path = pd.get("Path") or ""
    return "%s:%s" % (domain, path) if domain else path


def sync_flags(metadata):
    # The boolean options enabled on a sync entry, as display labels
    flags = []
    for flag in ["promote", "approve", "verify", "clobber", "force_reload"]:
        if metadata[flag]:
            flags.append(flag.replace("_", " "))
    return flags


def sync_result_summary(status):
    # Detailed results of a sync run, from the apply response
    apply = status.get("app_apply_response") or {}

    def path_list(key):
        return [path_domain_str(entry) for entry in apply.get(key) or []]

    result = {
        "commit": short_sha(apply.get("commit_id") or ""),
        "skipped_apply": apply.get("skipped_apply") or False,
        "total": len(apply.get("filtered_apps") or []),
        "created": [path_domain_str(entry.get("app_path_domain")) for entry in apply.get("create_results") or []],
        "updated": path_list("update_results"),
        "reloaded": path_list("reload_results"),
        "promoted": path_list("promote_results"),
        "skipped": path_list("skipped_results"),
        "approved": [path_domain_str(entry.get("app_path_domain")) for entry in apply.get("approve_results") or []],
        "bindings_created": apply.get("create_binding_results") or [],
        "bindings_updated": apply.get("update_binding_results") or [],
        "bindings_promoted": apply.get("promote_binding_results") or [],
    }
    result["changed"] = bool(result["created"] or result["updated"] or
                             result["reloaded"] or result["promoted"] or
                             result["approved"] or result["bindings_created"] or
                             result["bindings_updated"] or result["bindings_promoted"])
    return result


def review_from_dryrun(result):
    # Collect the plugins loaded and permissions requested, reported by the
    # dry run's approval results
    loads = []
    permissions = []
    for approval in result.get("approve_results") or []:
        for plugin_load in approval.get("new_loads") or []:
            if plugin_load not in loads:
                loads.append(plugin_load)
        for perm in approval.get("new_permissions") or []:
            is_read = perm.get("is_read")
            entry = {
                "plugin": perm["plugin"],
                "method": perm["method"],
                "arguments": ", ".join(perm.get("arguments") or []),
                # "" when the plugin's default access type is used
                "access": ("read" if is_read else "write") if is_read != None else "",
            }
            if entry not in permissions:  # prod and stage report the same perms
                permissions.append(entry)
    return {"loads": loads, "permissions": permissions}


def needs_approval(result):
    # True when any app in the result has unapproved permissions
    for approval in result.get("approve_results") or []:
        if approval.get("needs_approval"):
            return True
    return False
