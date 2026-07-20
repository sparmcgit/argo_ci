# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Not a Go project itself — it's a template/tooling repo that scaffolds an
Argo Workflows + Argo Events CI pipeline (Gitea push webhook → build/vet/
test/lint/coverage → Gitea commit status) into *other* Go projects. The
reference implementation this was generalized from is a separate private
project's working CI setup, which remains the live-confirmed source of
truth for behavior this repo's templates should match.

The companion Claude Code skill that drives scaffolding lives at
`~/.claude/skills/argo-ci-scaffold/SKILL.md`, with a vendored copy at
`SKILL.md` in this repo (keep both in sync when editing either).

## Commands

Render one project's manifests from a params file:

```bash
./generate.sh --params <params.env> --out <project>/ci
```

Writes `ci/workflow-template.yaml`, `ci/rbac.yaml`,
`ci/events/{eventsource,sensor,sensor-rbac,networkpolicy,eventbus}.yaml`,
and `.golangci.yml` (default location: `<out>/../.golangci.yml`, i.e. the
target project's repo root — override with `--golangci-out`).

Get the Gitea webhook Target URL for an already-applied project (patches
its EventSource Service to `NodePort` and reads the assigned port + a node
IP):

```bash
./webhook-info.sh <project-name> [events-namespace]
```

There is no build/test/lint for this repo itself (no Go code, no CI on
`argo_ci` — it *produces* CI configs for other repos). Validate template
changes by rendering with a test params file and checking the output:

```bash
./generate.sh --params params.example.env --out /tmp/test-out/ci   # will fail: PROJECT_NAME etc unset in the example file
```
Use a filled-in copy of `params.example.env`, not the example itself
(its required fields are intentionally blank). After rendering, check for
leftover placeholders and YAML validity:

```bash
grep -rn "__ARGOCI" /tmp/test-out
python3 -c "import yaml,glob; [yaml.safe_load_all(open(f)).__iter__().__next__() for f in glob.glob('/tmp/test-out/**/*.yaml', recursive=True)]"
```

## Architecture

**Templating mechanism**: plain-text placeholder substitution via `sed`,
not Helm or Kustomize. Placeholders are `__ARGOCI_XXX__` tokens (double
underscore, all-caps) — deliberately distinct from Argo's own `{{ }}`
templating syntax used inside `WorkflowTemplate`/`Workflow` resources
(`{{inputs.parameters.revision}}`, `{{workflow.status}}`), which a naive
`{{ }}`-based templating choice would collide with. Every `templates/*.tmpl`
file, including the seemingly-static `events/eventbus.yaml.tmpl`, goes
through the same `render()` substitution in `generate.sh` for consistency,
even though `EventBus` only substitutes `EVENTS_NAMESPACE`.

**`generate.sh` parameter defaults use two different bash idioms
deliberately**: `${VAR:=default}` (colon-equals) for params where empty
and unset should both fall back to the default (`GIT_BRANCH`, `NAMESPACE`,
`EVENTS_NAMESPACE`, `COMMIT_STATUS_CONTEXT`), vs. `${BUILD_TAG=default}`
(no colon) for `BUILD_TAG`, where an explicitly-empty value is a real,
distinct input meaning "this project has no build-tag-gated test suite,
disable that step" — `:=` would incorrectly collapse that to the default.
If adding a new optional parameter with a similar tri-state need (unset →
default vs. explicitly-empty → disable), use the same no-colon form.

**Per-project vs. cluster/namespace-shared resources** — this distinction
drives both the apply-order docs and the skill's behavior:
- Cluster-wide, install once, never templated: Argo Workflows/Events
  controllers and CRDs themselves (README.md documents the install
  commands as prerequisites, not as something this repo generates).
- Shared per namespace, safe to reapply: `EventBus` (`events/eventbus.yaml`),
  the `gitea-credentials` Secret, `rbac.yaml` (workflow executor RBAC).
- Per-project, named from `PROJECT_NAME` to coexist without collision in
  shared namespaces: `workflow-template.yaml`, `events/{eventsource,
  sensor,sensor-rbac,networkpolicy}.yaml`, `.golangci.yml`.

**Resource naming convention** (all derived from `PROJECT_NAME`, see
`templates/`): WorkflowTemplate/Sensor `<name>-ci`, EventSource
`<name>-gitea`, Sensor ServiceAccount `<name>-ci-sensor-sa`, Workflow
`generateName` `<name>-ci-`. Changing this convention means updating every
`.tmpl` file consistently, since names cross-reference each other (e.g.
`sensor.yaml.tmpl`'s `eventSourceName` must match `eventsource.yaml.tmpl`'s
`metadata.name`).

**Sensor triggers only on pushes to the tracked branch itself**
(`refs/heads/<GIT_BRANCH>` filter in `events/sensor.yaml.tmpl`), not on PR
branches. This means the pipeline reports status on commits already on the
branch (including merge commits, since Gitea fires a push event for those
too) rather than gating a PR before it lands — see TROUBLESHOOTING.md #10.
Any change to make this gate *before* merge would need a different Sensor
filter strategy (e.g. reacting to PR events instead of/in addition to push).

**Two coupled shell-script substitutions in
`templates/workflow-template.yaml.tmpl`** (`TAGGED_TEST_CMD`,
`LINT_BUILD_TAGS_FLAG`) exist because whether a project has a second,
build-tag-gated test suite is optional (`BUILD_TAG` param). `generate.sh`
computes both from the same `BUILD_TAG` value rather than having the
template conditionally branch — keeps the template itself
straight-line/unconditional, all the conditional logic lives in
`generate.sh`.

Read `README.md` for the full prerequisite/apply-order/parameter reference
and `TROUBLESHOOTING.md` for the non-obvious cluster/Gitea failure modes
this template already bakes in fixes or docs for — check there before
re-diagnosing a failure from scratch, especially anything involving
`--server-side --force-conflicts`, RBAC errors mentioning
`workflowtaskresults` or `workflowtemplates.argoproj.io`, or Gitea webhook
delivery/branch-protection behavior.
