# Troubleshooting

Non-obvious failure modes hit while building and debugging the reference
implementation this template was generalized from. Check here before
re-deriving these the hard way.

## 1. `kubectl apply` on Argo Workflows'/Argo Events' own CRDs fails with `metadata.annotations: Too long`

Their OpenAPI schemas are big enough that a plain `kubectl apply` stores a
`last-applied-configuration` annotation exceeding etcd's 262144-byte
annotation limit. Fix: always install/upgrade the CRDs with
`--server-side --force-conflicts` (see README.md prerequisites) - server-side
apply doesn't use that annotation.

## 2. Workflow steps fail immediately, executor can't create `workflowtaskresults`

The default Argo Workflows install grants no RBAC for the workflow
executor to create `workflowtaskresults`. Symptom: pods fail early with
permission errors on `workflowtaskresults.argoproj.io`. Fix: apply
`ci/rbac.yaml`, which grants the `default` ServiceAccount in the workflow's
namespace `create`/`patch`/`list`/`watch`/`delete` on that resource (plus
`pods`/`pods/log` access it also needs).

## 3. Manual `argo submit` works, but the live webhook path fails with `workflowtemplates.argoproj.io is forbidden`

A Sensor submitting via `workflowTemplateRef` needs its own RBAC to *read*
the WorkflowTemplate (`get`/`list`/`watch` on `workflowtemplates.argoproj.io`),
not just `create` on `Workflow` objects. This is easy to miss because a
manual `argo submit --from workflowtemplate/...` run works fine under your
own kubeconfig (typically broad permissions) - it only breaks once the live
webhook trigger exercises the Sensor's own narrower ServiceAccount. Fix:
`ci/events/sensor-rbac.yaml` grants both.

## 4. `kubectl apply -f ci/events/sensor-rbac.yaml` rejected with a namespace mismatch

That manifest spans two namespaces via each resource's own
`metadata.namespace` (ServiceAccount in the events namespace, Role/
RoleBinding in the Argo namespace). Apply it **without** `-n <namespace>` -
passing `-n` makes kubectl reject resources whose own `metadata.namespace`
doesn't match.

## 5. Gitea webhook delivery fails: `webhook can only call allowed HTTP servers`

Gitea refuses to deliver webhooks to private/internal IPs by default (its
own SSRF protection). Symptom in the delivery log:

```
webhook can only call allowed HTTP servers (check your webhook.ALLOWED_HOST_LIST setting), deny '<node-ip>(<node-ip>:<port>)'
```

This is a Gitea-side config fix, not anything wrong with the cluster. Edit
`app.ini` on the Gitea host (`/etc/gitea/app.ini`, or
`/data/gitea/conf/app.ini` for the Docker image):

```ini
[webhook]
ALLOWED_HOST_LIST = private
```

(`private` covers RFC1918 ranges; scope tighter, e.g. `192.0.2.0/24`, if
that's too broad.) Restart Gitea, then use **Redeliver** on the failed
delivery rather than pushing a new commit to retest.

## 6. `golangci-lint` install fails with `hash_sha256_verify` checksum mismatch

The official `install.sh` can fail against some networks downloading from
GitHub's release CDN. The templated workflow avoids this entirely by
installing via the Go module proxy instead:

```bash
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
```

Note the required `/v2` in the module path for v2 releases - the older
`github.com/golangci/golangci-lint/cmd/golangci-lint` path (no `/v2`) some
docs/examples still show is for pre-v2 releases.

## 7. Gitea commit status lands on the wrong commit (or never appears)

The `report-status` exit handler needs the push's head commit SHA, which
only exists in the webhook payload (`body.after`) - it's not something the
Workflow can derive on its own. `ci/events/sensor.yaml`'s `parameters`
block patches the submitted Workflow's `commit-sha` argument from
`body.after` for exactly this reason. If a project's Sensor is missing that
patch, statuses either don't show up in Gitea or land on the wrong commit.

## 8. Gitea branch protection "Status check patterns" doesn't offer the check as a dropdown option

It's a free-text field (one pattern per line), not a list of previously-seen
checks - type the exact `COMMIT_STATUS_CONTEXT` value (default `argo-ci`)
in by hand. It won't autocomplete even after the check has run successfully
at least once.

## 9. NetworkPolicy on `ci/events/networkpolicy.yaml` has no effect

Not every CNI enforces `NetworkPolicy` - plain Flannel, for instance,
silently no-ops on `NetworkPolicy` resources instead of erroring. Confirm
your CNI actually enforces it (e.g. kube-router does, via iptables) before
relying on this as a real access control, and confirm the pod labels
matched by `podSelector` against the actual running pod:

```bash
kubectl get pods -n <events-namespace> -l eventsource-name=<project>-gitea --show-labels
```

## 10. `git push` to the tracked branch rejected: `Not allowed to push to protected branch main`

This is Gitea's protected-branch push guard, not the status check - it
fires the moment branch protection is enabled, regardless of whether any
`argo-ci` status has run yet:

```
remote: error: Not allowed to push to protected branch main
 ! [remote rejected] main -> main (pre-receive hook declined)
```

Enabling "Enable status check" in a branch protection rule (step 10 in
README.md) blocks *all* direct pushes to that branch by default, not just
ones with a failing check - Gitea requires you to separately opt back into
direct push access. Fix: repo Settings → Branches → edit the rule → check
**"Enable Push"** → add your own Gitea username to the push whitelist.

Worth noting: since the Sensor only fires on pushes to the tracked branch
itself (`refs/heads/<GIT_BRANCH>`), this setup reports status on commits
already on that branch after the fact, rather than blocking a bad commit
from landing there in the first place - it can't gate a PR branch that
never gets pushed directly. Routing changes through PRs still works for
"gating" purposes since Gitea fires a push event for the merge commit too,
but CI runs post-merge, not pre-merge.

## 11. `report-status` fails with `exit code 22`, no other detail

Curl's `-sf` flags in `report-status` (silent + fail-fast) mean any HTTP
4xx/5xx response from Gitea's commit-status API shows up in `argo logs`
as nothing more than:

```
main: Error (exit code 22)
```

with the actual status code and response body swallowed. To see what
Gitea actually said, replay the same POST by hand with `-i` (shows
headers/body instead of swallowing them):

```bash
curl -i -X POST \
  -H "Authorization: token <GITEA_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"state":"success","context":"argo-ci","description":"test"}' \
  "http://<gitea-host>/api/v1/repos/<owner>/<repo>/statuses/<a-real-commit-sha>"
```

Two concrete causes hit in practice, both diagnosable from that curl's
response:

**403, `token scope=read:repository` (needs `write:repository`)** - Gitea's
scoped API tokens are granular per-category (read/write on Repository,
Issue, Organization, ...). A token minted with only "Read" on Repository
can clone and read fine but can't POST a commit status - it needs "Read
and Write". This can bite even on a token that worked before: an older
"classic" full-access token can end up re-interpreted under narrower
scopes after a Gitea upgrade, or the token was simply minted read-only by
mistake in the first place. Since `gitea-credentials` is shared across
every project cloning through it, this failure (and the fix - regenerate
the token with `write:repository`, update the secret) affects all of them
at once, not just whichever project you noticed it on first.

**500, `GetCommit[<sha>]: object does not exist`** - the commit SHA being
reported against was never actually pushed to Gitea. Easy to hit while
testing manually with `-p commit-sha=$(git rev-parse HEAD)`: if that
command was run against an older local HEAD (before an amend/rebase, or
just before later commits), the captured SHA can go stale between when
you ran it and when you use it, even though your current HEAD really is
pushed. Confirm with `git rev-parse HEAD` and `git rev-parse origin/main`
(or your tracked branch) matching before assuming the endpoint itself is
broken.

## 12. `commit-sha` is always empty, even on a genuine webhook-triggered push

If `argo get` on a webhook-triggered run (not a manual `argo submit`) shows
an empty `commit-sha` under `Parameters`, and the Gitea delivery's raw
payload (Recent Deliveries → a delivery → Request Body) genuinely has a
correct top-level `"after": "<sha>"` field, the bug is in the Sensor's
trigger `parameters` placement, not Gitea or the payload.

Argo Events' `Trigger.Parameters` (a *sibling* of `template`) addresses
paths relative to the trigger **template** itself (`name`,
`k8s.source...`, etc.) - not the resource the trigger constructs. To patch
a field on the constructed `Workflow` resource (e.g.
`spec.arguments.parameters.1.value`), the `parameters` block must live
**inside** `template.argoWorkflow` (a sibling of `operation`/`source`),
where paths are resource-relative instead. At the wrong (outer) level, the
`dest` path just doesn't exist anywhere, so Argo Events' sensor controller
logs `"Successfully processed trigger"` with no error and silently no-ops
the patch - there's no error signal pointing at the actual mistake.

The Sensor logs alone won't catch this; the tell is that `commit-sha`
stays empty on every run regardless of whether the push payload itself is
correct. Confirmed against Argo Events' own examples
(`examples/sensors/special-workflow-trigger.yaml` in the argo-events repo)
- the working pattern nests `parameters` inside `argoWorkflow`, matching
what `ci/events/sensor.yaml.tmpl` now does.

## 13. Edited `ci/workflow-template.yaml` (or re-ran `generate.sh` with new params), but the workflow still runs with the old behaviour

The cluster only has whatever was last `kubectl apply`'d - regenerating the
file locally (e.g. bumping `COVERAGE_THRESHOLD`, tweaking the build steps)
or committing/pushing it does **not** update the live `WorkflowTemplate`
object. The Gitea webhook -> Sensor -> Workflow path only ever *submits new
Workflow runs against whatever WorkflowTemplate is already in the cluster*;
nothing in this pipeline watches the repo for changes to its own CI config
and re-syncs it. Concretely: pushing a commit that lowers the coverage
threshold in `ci/workflow-template.yaml` still fails with the *old*
threshold until you separately run:

```bash
kubectl apply -n <namespace> -f ci/workflow-template.yaml
```

Same applies to any other per-project manifest (`rbac.yaml`,
`events/eventsource.yaml`, `events/sensor.yaml`, etc.) - a change only takes
effect after its own `kubectl apply`, regardless of whether it's also
committed to git.

## 14. Argo Workflows UI login rejects every Bearer token with `token not valid`

Since v3.0, the Argo Server defaults to `client` auth mode (no `--auth-mode`
flag needed to get this - it's the default), which means the UI expects a
Kubernetes ServiceAccount Bearer token pasted into the login box. That
requires `argo-server`'s own ServiceAccount to call the Kubernetes API's
`TokenReview`/`SubjectAccessReview` endpoints to validate whatever token a
client presents. The plain upstream `install.yaml` this README has you
apply does not always wire that up - if the `argo-server` ServiceAccount
has no binding granting that permission (check with
`kubectl get clusterrolebinding -o wide | grep argo-server`; it should show
a binding to `system:auth-delegator` alongside the bundled
`argo-server-cluster-role`), *every* token gets rejected, valid or not, and
the browser console shows:

```
Uncaught (in promise) Error: {"code":16,"message":"token not valid. see https://argo-workflows.readthedocs.io/en/latest/faq/"}
```

The 401s on `/api/v1/info` and `/api/v1/userinfo` you'll see in
`kubectl -n argo logs deploy/argo-server` are misleading on their own -
they appear on every page load before login too, so don't assume they mean
your token is bad. Fix:

```bash
kubectl create clusterrolebinding argo-server-auth-delegator \
  --clusterrole=system:auth-delegator --serviceaccount=<argo-namespace>:argo-server
```

No restart needed - RBAC changes apply live.

To actually get a token to paste in, create a ServiceAccount and bind it to
a role (`admin` for convenience, or something narrower):

```bash
kubectl -n <argo-namespace> create serviceaccount argo-ui
kubectl -n <argo-namespace> create clusterrolebinding argo-ui --clusterrole=admin --serviceaccount=<argo-namespace>:argo-ui
kubectl -n <argo-namespace> create token argo-ui
```

Paste `Bearer <that output>` into the login box. Prefer `kubectl create
token` (Kubernetes 1.24+) over the older annotated-Secret method
(`kubectl create secret ... type=kubernetes.io/service-account-token`) -
the Secret's `.data.token` field populates asynchronously and can appear
empty if read immediately after creation.

If the token still gets rejected after the RBAC fix, verify server-side
auth is actually working before suspecting the token itself - test with
`curl` directly against the port-forwarded server rather than through the
browser:

```bash
kubectl -n <argo-namespace> port-forward svc/argo-server 2746:2746 &
TOKEN=$(kubectl -n <argo-namespace> create token argo-ui)
curl -sk -w '\nHTTP_STATUS:%{http_code}\n' -H "Authorization: Bearer ${TOKEN}" https://localhost:2746/api/v1/userinfo
```

A `200` with your ServiceAccount's identity back confirms the server side
is correct and any remaining failure is client-side - most likely a
corrupted token from copy/paste. Long Bearer tokens (800+ characters) that
get manually selected from wrapped terminal output, or copied out of a
chat/browser window that visually wraps long lines, are prone to picking
up a stray line break that silently breaks the token. Pipe the token
straight to the clipboard instead of ever displaying it somewhere it could
get mangled:

```bash
printf "Bearer %s" "$(kubectl -n <argo-namespace> create token argo-ui)" | xclip -selection clipboard   # or wl-copy on Wayland
```

Note `argo-server` only serves HTTPS on its port (self-signed cert) - a
plain `http://` request (or a client/tool that silently falls back from
HTTPS to HTTP, e.g. after failing certificate verification) gets a bare
`400 Bad Request` with no body. That's a protocol mismatch, not an auth
failure - don't mistake it for a bad token either.

## Not yet templated: signature verification

Argo Events' generic `webhook` EventSource type (used because Gitea isn't
one of its named provider types) has no built-in HMAC check against
Gitea's `X-Gitea-Signature` header. Anyone who can reach the NodePort can
trigger a CI run. `ci/events/networkpolicy.yaml` mitigates this by
restricting ingress to Gitea's own IP; for stronger protection, front the
endpoint with a small verifying proxy.
