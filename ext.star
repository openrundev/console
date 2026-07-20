# SPDX-License-Identifier: Apache-2.0
# Extension point for optional feature packs (e.g. the Analytics feature in
# the console-pro distribution). The pro repo swaps this file WHOLESALE for
# one that returns its routes and plugin permissions - it is excluded from
# the pro sync, so the two versions are never merged. Keep the hook
# interface (ext_routes(ctx) / ext_permissions(ctx), ctx a dict of the
# ENABLE_* feature flags) stable: it is the only coupling between the
# console and pro repos. base_templates/ext.go.html carries the matching
# template hooks (ext_head / ext_brand / ext_nav).


def ext_routes(ctx):
    return []


def ext_permissions(ctx):
    return []
