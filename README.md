# argo_ci

Reusable Argo Workflows + Argo Events CI templates for Go projects, plus a
`generate.sh` renderer. Scaffolds a live-confirmed pipeline: a Gitea push
webhook triggers Argo Events, which submits an Argo Workflow that
builds/vets/tests/lints the repo and reports a commit status back to Gitea
that branch protection can require.

For hands-off scaffolding into a new project, use the Claude Code skill at
`~/.claude/skills/argo-ci-scaffold/SKILL.md` instead of calling
`generate.sh` directly - it asks for the parameters below and writes the
files for you.

## Prerequisites (cluster-wide, install once, not per-project)

Argo Workflows and Argo Events must already be installed on the cluster.
This repo does not template that install - it's a one-time, cluster-wide
step, not something a new project repeats:

```bash
kubectl create namespace argo
kubectl apply --server-side --force-conflicts -n argo \
  -f https://github.com/argoproj/argo-workflows/releases/latest/download/install.yaml

kubectl create namespace argo-events
kubectl apply --server-side --force-conflicts -n argo-events \
  -f https://github.com/argoproj/argo-events/releases/latest/download/install.yaml
kubectl apply --server-side --force-conflicts -n argo-events \
  -f https://github.com/argoproj/argo-events/releases/latest/download/install-validating-webhook.yaml
```

`--server-side --force-conflicts` is required, not optional - see
TROUBLESHOOTING.md #1.

Also install the `argo` CLI locally if you want to submit/inspect workflows
by hand (`argo list`, `argo get`, `argo logs`).

## What's per-project vs. shared

| Resource | Scope |
|---|---|
| Argo Workflows / Argo Events controllers, CRDs | cluster-wide, install once |
| `EventBus` (`events/eventbus.yaml`) | one per events namespace, shared across all projects in it - re-applying for a second project is a harmless no-op |
| `gitea-credentials` Secret | one per Argo namespace, shared across projects that clone the same Gitea instance with the same token's access |
| Everything else (`workflow-template.yaml`, `rbac.yaml`, `events/eventsource.yaml`, `events/sensor.yaml`, `events/sensor-rbac.yaml`, `events/networkpolicy.yaml`, `.golangci.yml`) | one set per project, named after `PROJECT_NAME` so multiple projects coexist in the same namespaces without colliding |

## Parameters

See `params.example.env` for the full reference with defaults. Copy it,
fill in the required values, and render with:

```bash
./generate.sh --params my-project-params.env --out /path/to/my-project/ci
```

This writes `ci/workflow-template.yaml`, `ci/rbac.yaml`,
`ci/events/{eventsource,sensor,sensor-rbac,networkpolicy,eventbus}.yaml`,
and `.golangci.yml` (at `<out>/../.golangci.yml` by default - i.e. the
target project's repo root).

## Apply order for a new project

1. `gitea-credentials` Secret in the Argo namespace (skip if already
   created for another project sharing the same Gitea token):
   ```bash
   kubectl create secret generic gitea-credentials -n <namespace> \
     --from-literal=token=<GITEA_TOKEN_WITH_READ+WRITE_ACCESS>
   ```
2. `ci/rbac.yaml` - workflow executor RBAC (idempotent per namespace; only
   needs applying once per Argo namespace, but harmless to reapply):
   ```bash
   kubectl apply -n <namespace> -f ci/rbac.yaml
   ```
3. `ci/workflow-template.yaml`:
   ```bash
   kubectl apply -n <namespace> -f ci/workflow-template.yaml
   ```
   Re-run this `apply` any time this file changes later (e.g. adjusting
   `COVERAGE_THRESHOLD` and re-rendering with `generate.sh`) - committing/
   pushing the change alone does not update the live WorkflowTemplate the
   webhook submits against. See TROUBLESHOOTING.md #13.
4. `ci/events/eventbus.yaml` (skip if another project already applied one
   in this events namespace):
   ```bash
   kubectl apply -n <events-namespace> -f ci/events/eventbus.yaml
   ```
5. Sensor RBAC - spans two namespaces via each resource's own
   `metadata.namespace`, so apply it **without** `-n`:
   ```bash
   kubectl apply -f ci/events/sensor-rbac.yaml
   ```
6. EventSource and Sensor:
   ```bash
   kubectl apply -n <events-namespace> -f ci/events/eventsource.yaml
   kubectl apply -n <events-namespace> -f ci/events/sensor.yaml
   ```
7. Expose the webhook endpoint and print the settings to enter in Gitea:
   ```bash
   ./webhook-info.sh <project> <events-namespace>
   ```
   This patches `<project>-gitea-eventsource-svc` to `NodePort` and prints
   the Target URL/method/content-type to configure below. (Equivalent to
   `kubectl patch svc ... -p '{"spec":{"type":"NodePort"}}'` +
   `kubectl get svc ...` and reading the NodePort off `12000/TCP -> <port>`
   yourself, if you'd rather do it by hand.)
8. In Gitea: repo Settings → Webhooks → Add Webhook → Gitea, using the
   values `webhook-info.sh` printed:
   - Target URL: `http://<node-ip>:<nodePort>/push`
   - HTTP Method: `POST`, Content Type: `application/json`, Trigger On: Push
9. `ci/events/networkpolicy.yaml` (restricts the webhook endpoint to
   Gitea's IP - see TROUBLESHOOTING.md #9 on confirming your CNI enforces
   NetworkPolicy):
   ```bash
   kubectl apply -f ci/events/networkpolicy.yaml
   ```
10. Gitea branch protection: repo Settings → Branches → add/edit a rule for
    the branch, enable "Enable status check", enter the
    `COMMIT_STATUS_CONTEXT` value (default `argo-ci`) in "Status check
    patterns" - free-text field, not a dropdown (TROUBLESHOOTING.md #8).

## Verify

```bash
argo list -n <namespace>
argo get -n <namespace> @latest
argo logs -n <namespace> @latest
```

Or port-forward the UI: `kubectl -n <namespace> port-forward svc/argo-server 2746:2746`
then visit `https://localhost:2746`.

Push to the tracked branch and check the commit / PR view in Gitea for the
`COMMIT_STATUS_CONTEXT` status check. To trigger a run without changing any
files:

```bash
git commit --allow-empty -m "trigger ci" && git push
```

See TROUBLESHOOTING.md for gotchas if any of this doesn't work first try.
