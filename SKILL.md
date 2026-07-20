---
name: argo-ci-scaffold
description: Scaffold the Argo Workflows + Argo Events CI pipeline (Gitea push -> build/vet/test/lint/coverage -> Gitea commit status) into a Go project. Use when the user asks to set up CI, add Argo CI, or wire up a Gitea webhook pipeline for a project, using the reusable templates in argo_ci.
metadata:
  version: "1.0.0"
---

# Argo CI scaffold

Scaffolds the CI setup documented in this repo's `README.md` into the
current project: an Argo WorkflowTemplate (build/vet/test/lint/coverage)
plus Argo Events EventSource/Sensor wiring a Gitea push webhook to it,
reporting results back to Gitea as a commit status.

All templates and the renderer live in the `argo_ci` repo (referred to
below as `$ARGOCI` - set this to wherever you cloned it, e.g.
`~/src/argo_ci`) - read `$ARGOCI/README.md` and
`$ARGOCI/TROUBLESHOOTING.md` if anything here is unclear or a step fails.

This skill only generates files and prints instructions. It does not run
`kubectl` or touch the cluster - those are the user's to run, per this
project's general policy of not proactively executing actions with
cluster/shared-system side effects.

## Instructions

1. **Check prerequisites are already met**, don't reinstall them: Argo
   Workflows and Argo Events must already be installed cluster-wide (see
   `$ARGOCI/README.md` "Prerequisites"). If unsure, ask the user or check
   with `kubectl get pods -n argo` / `kubectl get pods -n argo-events`. This
   skill only ever adds per-project resources, never the cluster-wide
   install.

2. **Gather parameters.** Ask the user for each of these (show the default
   in parens, skip asking if it can be confidently inferred from the repo -
   e.g. `GO_IMAGE` from the `go` line in `go.mod`, `GITEA_REPO` from the
   directory name or `git remote -v`, `GITEA_OWNER`/`GITEA_HOST` from an
   existing Gitea-style git remote URL):

   | Param | How to get it |
   |---|---|
   | `PROJECT_NAME` | short slug, defaults to the repo directory name |
   | `GITEA_HOST` | host:port, e.g. `192.0.2.10:3000` - check `git remote -v` |
   | `GITEA_IP` | bare IP, no port |
   | `GITEA_OWNER` | Gitea org/user path segment |
   | `GITEA_REPO` | Gitea repo slug |
   | `GO_IMAGE` | e.g. `golang:1.26.5-alpine` - match the `go` directive in `go.mod` |
   | `COVERAGE_THRESHOLD` | integer percent (default 70) |
   | `GIT_BRANCH` | default `main` |
   | `NAMESPACE` | default `argo` |
   | `EVENTS_NAMESPACE` | default `argo-events` |
   | `BUILD_TAG` | default `test` - ask whether the project has a second, build-tag-gated test suite (e.g. `//go:build test`); if not, pass an empty string to disable that step entirely |
   | `COMMIT_STATUS_CONTEXT` | default `argo-ci` |

   If another project already uses the same `NAMESPACE`/`EVENTS_NAMESPACE`,
   `PROJECT_NAME` must be different from that project's to avoid resource
   name collisions (WorkflowTemplate, EventSource, Sensor, ServiceAccount
   are all named from it).

3. **Render the templates.** Write a params env file (see
   `$ARGOCI/params.example.env` for the format) to a temp location, then run:

   ```bash
   $ARGOCI/generate.sh --params <params-file> --out <project>/ci
   ```

   This writes `<project>/ci/workflow-template.yaml`, `<project>/ci/rbac.yaml`,
   `<project>/ci/events/{eventsource,sensor,sensor-rbac,networkpolicy,eventbus}.yaml`,
   and `<project>/.golangci.yml`. If `<project>/.golangci.yml` already
   exists, show the user the diff and ask before overwriting - don't
   silently clobber an existing lint config.

4. **Print the apply/verify steps**, following `$ARGOCI/README.md`'s "Apply
   order for a new project" section, filled in with this project's actual
   namespace/project-name values (so the user can copy-paste directly
   rather than substitute placeholders themselves). Note which steps are
   one-time-per-namespace (the `gitea-credentials` Secret, `rbac.yaml`,
   `eventbus.yaml`) versus per-project, so the user doesn't redo shared
   setup unnecessarily if this isn't the first project in that namespace.
   For the webhook-exposure step, tell them to run
   `$ARGOCI/webhook-info.sh <project-name> <events-namespace>` rather than
   patching the Service and reading the NodePort by hand - it prints the
   exact Target URL/method/content-type to enter in Gitea.

5. **Proactively flag relevant gotchas** from `$ARGOCI/TROUBLESHOOTING.md`
   at the step they apply to, rather than as an appendix - e.g. mention
   `--server-side --force-conflicts` if the user says Argo isn't installed
   yet, mention the `ALLOWED_HOST_LIST` fix right after the webhook-URL
   step, mention the free-text "Status check patterns" field right after
   the branch-protection step. If the user reports a failure matching one
   of the documented symptoms (e.g. `workflowtemplates.argoproj.io is
   forbidden`, `metadata.annotations: Too long`, a Gitea delivery log
   error), point straight at the matching `TROUBLESHOOTING.md` entry rather
   than debugging from scratch.

## Output format

End with a concise summary: files written (with paths), and the numbered
apply/verify command sequence the user needs to run, in order.
