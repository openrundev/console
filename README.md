<p align="center">
  <img src="https://openrun.dev/openrun.png" alt="OpenRun-logo" width="300" height="250"/>

  <p align="center">Deployment platform for code-first internal tools. Turn generated code into secure internal tools with GitOps, RBAC, and auditing. Easily deploy on a single node with Docker/Podman or onto a Kubernetes cluster.</p>
</p>

Console is a management UI for managing OpenRun.

Copyright 2026 ClaceIO, LLC

Released under the Apache License 2.0, see LICENSE file.

The Pro distribution (github.com/openrundev/console-pro, PolyForm Free
Trial licensed) adds the Analytics feature on top of this console. It plugs
in through the extension hooks in `ext.star` and
`base_templates/ext.go.html` — both files ship here as empty stubs and are
swapped wholesale by the pro repo's sync; keep their hook signatures and
define names stable.
