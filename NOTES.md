# Things I should be able to explain

Running list, one section per step. If I can't explain an item out loud in a minute or two, I haven't finished the step.

## Step 1: local cluster, CNI, namespace

- What a CNI plugin does, and why a node stays `NotReady` until one is installed.
- NetworkPolicy objects are accepted by the API server no matter which CNI is installed. Only a CNI that implements them enforces them. Why is that dangerous?
- How kind works: each node is a Docker container, and `kind create cluster` with no config gives one control-plane node plus the default CNI (kindnet).
- `networking.disableDefaultCNI` can only be set when the cluster is created. What are my options if I forget?
- What happened when two CNIs were installed together (kindnet + Cilium), and how I spotted it (`kindnet-*` pod in `kube-system`).
- The `cilium` CLI looks in `kube-system` by default. Why did my first install, into `switchyard`, make `cilium status` fail?
- A Helm release is recorded in the namespace it was installed into. Why can't I move one, and what do I do instead?
- Why one `cilium-operator` pod stayed `Pending` on a single-node cluster (replicas + anti-affinity).
- What `cilium connectivity test` proves, and what it doesn't.
- Why pin versions: the Helm chart (`--version`), the kind node image, the Cilium CLI.
- Project namespace vs system namespace: what belongs in `switchyard` and what belongs in `kube-system`.
- What `ipam.mode=kubernetes` means (pod CIDRs come from the node's `spec.podCIDR`, allocated by kube-controller-manager) and which other IPAM modes exist. Which one would EKS use?
- Who allocates a node's `spec.podCIDR` (the node IPAM controller inside kube-controller-manager) and how that differs from Cilium's own `cluster-pool` mode. Kind's pod network is `10.244.0.0/16`, split into one `/24` per node.
- Why `kubectl describe` needs a resource name, and why `-A` (not `-n all`) means all namespaces.
- Why `ProviderID` (`kind://docker/...`) on a Node has nothing to do with pod networking.
- Why `--set` flags typed on the command line are not infrastructure as code, and how a values file (`-f`) plus `helm upgrade --install` fixes that. `helm get values` shows what a release was installed with.
- Why `image.pullPolicy=IfNotPresent` is reasonable on a local kind cluster, and what you'd do in production (pinned tag or digest).
- Ansible comparison: security groups (enforced by AWS) vs NetworkPolicy (enforced by the CNI).

## Step 2: one Ollama Deployment, Service and PVC

- Labels vs selectors: pod template labels are the source of truth. The Deployment's `spec.selector` and the Service's `selector` must be subsets of them. A pod matches when **every** selector pair is on the pod; extra labels on the pod are ignored. The Deployment's own `metadata.labels` is not part of the matching.
- Why `spec.selector` of a Deployment is immutable, and why that makes `version` a bad selector label (use `app.kubernetes.io/name` and later `instance` for identity; keep `version` informational).
- A Service with no endpoints: compare selector against pod labels first (`get pods --show-labels`, `get endpointslices`), then readiness, then ports. A server dry run does not catch a selector that matches nothing.
- Self-healing vs rollout strategy: the ReplicaSet recreates a deleted pod (any strategy). `strategy` only governs how pods are replaced when the pod template changes. Why `Recreate` for a single replica with a `ReadWriteOnce` volume, and its cost (brief downtime).
- Requests vs limits: requests are used by the scheduler (Pending if nothing fits); limits are enforced at runtime (OOMKilled). `free` and `top` inside a container show the node's memory (the Docker Desktop VM), not the pod's limit; the cgroup files show the limit.
- PV, PVC and StorageClass in kind: `standard` is the local-path provisioner. The PV is a hostPath directory on one node with a `nodeAffinity` to that node, so the scheduler must place the pod there. If that node is unavailable the pod stays Pending. Reclaim policy `Delete` means deleting the PVC deletes the data. PVs and nodes are cluster-scoped (`-n` is ignored).
- Why pulling the model with `kubectl exec` is not repeatable, and the options for automating it (init container, `postStart` hook, Job calling the API, wrapper script). Any approach must be idempotent: check `ollama list` first, like the Ansible role did.
- Why pin image tags (`ollama/ollama:0.40.14`, not `:latest`) and verify the tag exists (`v0.40.14` did not).
- Why `Host Port: 0` in `kubectl describe pod` is normal (no `hostPort` set).
- `kubectl port-forward svc/...` tunnels through the API server to one pod behind the Service: a debugging tool, not a way to expose an app.
- `--dry-run=server` and `kubectl diff` before applying.

## Step 3: one Helm chart, three releases

- Chart vs release: the chart is the package (`Chart.yaml`, `values.yaml`, `templates/`); a release is one named install of it. The release name is the first argument to `helm install` and is exposed to templates as `.Release.Name`. It is not set in any file.
- Built-in objects (`.Release.Name`, `.Release.Namespace`, `.Chart.Name`) vs `.Values`: built-ins are filled in by Helm (like Ansible magic variables); `.Values` comes from `values.yaml`, `-f` files and `--set`.
- Where `{{ }}` works: only in `templates/`. In `Chart.yaml` and values files it is copied as literal text. Putting `{{ .Release.Name }}` in values caused an "invalid map key" error.
- Helm field names are case-sensitive: `.Release.name` renders as nothing (no error), `.Release.Name` works.
- Values precedence: chart `values.yaml` < `-f` files (later wins) < `--set`. Maps merge key by key, lists are replaced. `helm get values <release> [--all]` shows what a release used.
- Why one chart plus per-model values files beats three copies of the templates (and why three template files in one chart is the weak option).
- Pod `volumes[].name` must equal the container's `volumeMounts[].name`; `claimName` must equal the PVC's `metadata.name`. Two separate matches. Deriving both from `.Release.Name` in the template means they can't drift apart.
- Deployment `volumes:` is a pod-spec field, not a separate object. On kind you only need a PVC; the provisioner creates the PV (dynamic provisioning).
- PV vs PVC vs StorageClass: PV is the real disk, PVC is the request, StorageClass is the recipe for making PVs on demand. Pod -> volume -> PVC -> PV. Deleting the pod keeps the data; deleting the PVC removes it (reclaim policy `Delete`).
- Service vs Switchyard: the Service is a dumb L4 balancer over the pods its selector matches; Switchyard chooses the model/backend. One Service per model gives Switchyard a stable DNS name per backend. Identical labels across releases would make every Service match all three pods.
- Deleting a pod does not remove a Deployment's replica; delete the Deployment (the owner). A PVC held by a running pod stays `Terminating` (pvc-protection finalizer).
- Helm stores release state as a Secret in the `-n` namespace. Hardcoding `namespace:` in templates while forgetting `-n` split the release record (`default`) from the objects (`switchyard`). Use `.Release.Namespace` and always pass `-n`.
- `helm lint`, `helm template`, and `helm template ... | kubectl apply --dry-run=server -f -` as the check ladder. The editor's red squiggles on `{{ }}` in templates are a plain-YAML false alarm.
- Vendoring and pinning third-party charts (`helm pull --untar`), and when to choose Helm, Kustomize or raw YAML.
- Automated model pull with a `lifecycle.postStart` hook: it runs in the background (`( ... ) &`) so the container isn't blocked, waits for `ollama list` to work, and pulls only if the model isn't listed (idempotent, like the Ansible role). Weak points: a hook failure is easy to miss (check `/tmp/model-pull.log`), the pod is `Ready` before the model exists, and a hook has no retry. Alternatives: init container, Job calling the API.
- Why the model survives a pod restart (the PVC at `/root/.ollama`) but a `helm uninstall` followed by deleting the PVC loses it.
- `{{- if .Values.model }}` makes the hook optional: an empty `model` renders nothing.

## Step 4: Switchyard router (image, config, Service)

- The AWS design copied a hand-built binary into Ansible (`files/switchyard-server`). It had no recorded source version, and it is x86-64 Linux, so it fails with `exec format error` on an arm64 Mac and in arm64 kind nodes. Lesson: build artifacts from pinned source, for the target architecture.
- Upstream publishes no image that I found; it ships a Dockerfile (multi-stage: `rust` builder, then `debian:bookworm-slim` with only the binary, user 1000, port 4000, `ENTRYPOINT ["switchyard-server"]`, no `CMD`). Why multi-stage keeps the final image small.
- Image tag = upstream version + commit SHA (`0.4.0-rc.1-ef958a9a8`). Why not `latest` (moving target, and `imagePullPolicy: Always` by default, which fails for a local-only image) or my own `0.1.0` (implies my own release). Tags are mutable; digests are not.
- `kind load docker-image` copies the image into every node's containerd; the cluster can't pull from my local Docker. Use `imagePullPolicy: IfNotPresent` (or `Never`). Check with `docker exec <node> crictl images`.
- Container `ENTRYPOINT` vs pod `args`: the pod's `args` become the arguments to the entrypoint (`--config`, `--host 0.0.0.0`, `--port 4000`). `command` would replace the entrypoint.
- Release candidate (`rc.1`) in a lab vs production: what I'd want before running it for real.
- ConfigMap mounted as a file vs injected as env vars: a config *file* needs a `configMap` volume + `volumeMount` (names must match) and `args` pointing at `mountPath` + `items[].path`. Env vars are for key/value settings.
- `helm lint` and `helm template` do not check that the API kinds exist (`apps/v2` passed them). `kubectl apply --dry-run=server` does. Check ladder: lint, template, server dry-run, then run the real binary's `--dry-run` on the rendered config (`docker run -i ... --config /dev/stdin --dry-run`).
- Hyphens are subtraction in Helm: `.Values.model-llama` is `.Values.model` minus `llama`. Use nested maps (`.Values.model.llama`) or `index .Values "model-llama"`.
- Changing a shared values file (the `model` string became a map) broke the Ollama chart's hook (`ollama pull 'map[llama:...]'`). Check what else reads a key before changing its shape. Known gap: the model tags exist in `values/*.yaml` (Ollama) and in the gateway chart's `values.yaml` (drift risk).
- Probe failure: `HTTP probe failed with statuscode: 404` means the app is up but the path is wrong. Found the real path by `curl`ing candidates via port-forward and reading the app's startup log (`GET /health` = 200). A probe passes on 200 to 399.
- `/metrics` on the gateway is a Prometheus endpoint: the scrape target for Step 6.

## Step 5: load generator and stability

- `kubectl port-forward` binds to one pod and does not reconnect: when the gateway restarted, the loadgen got `http=000`. Port-forward is for the lab; real traffic goes through a Service or Ingress.
- Pod restarts under load had two causes: node-level OOM (the kind nodes share one Docker VM, and the scheduler can't see that RAM is shared) and probes with the default `timeoutSeconds: 1` on a starved CPU. Fixes: more Docker memory/CPU, explicit `timeoutSeconds` and `failureThreshold`. Requests vs limits: requests decide scheduling, limits decide OOMKill (exit 137).
- Liveness restarts a container; readiness only removes it from Service endpoints. A liveness probe that is too strict turns a slow pod into a restart loop.
- `/v1/stats` showed `stage_router ... fall_open`: the auto route always chose the efficient model (llama), in K8s and in AWS. The classifier doesn't seem to be used (inferred, not verified in the docs). Routing overhead: avg 0.83 ms, p99 4.24 ms, so the gateway is not the latency.
- CPU-only inference: per-request latency is about 2 s (llama3.2:1b), 48 s (qwen3:1.7b, a thinking model) and 66 s (gemma3:1b). Model size and type decide latency, not the router.

## Step 6: Prometheus, Grafana, dashboard as code

- kube-prometheus-stack = Operator + Prometheus + Grafana + kube-state-metrics + CRDs. Installed with `-f values/monitoring.yaml` and a pinned `--version`. Unknown values keys are silently ignored (`retention` belongs under `prometheus.prometheusSpec`).
- **Labels vs selectors:** labels are tags ON objects (under `metadata`), selectors are filters that LOOK for tags (under `spec`). Deployment `spec.selector.matchLabels` must match `template.metadata.labels` (and is immutable). Service `spec.selector` is a plain map and matches pod labels. ServiceMonitor `spec.selector.matchLabels` matches the Service's own `metadata.labels`. `metadata.name` is identity, not matched by selectors.
- **ServiceMonitor** is a note to the Operator, not a scraper. Flow: Operator turns it into Prometheus config, Prometheus asks the API server for the Service's endpoints (pod IPs) and scrapes each pod directly on a timer, not through the ClusterIP. The endpoint `port` matches the Service port *name*, not the number. No match = no error, just no target.
- `serviceMonitorSelectorNilUsesHelmValues: false` makes Prometheus pick up ServiceMonitors from outside the chart's own release.
- Ownership vs selection: Deployment owns ReplicaSet owns Pod (`ownerReferences`, why pod names look like `<deploy>-<hash>-<suffix>`). Labels/selectors connect things that *use* each other; ownership records who *created* what. Nothing in this project refers to the Deployment by name.
- Metric kinds: counters (`_total`, use `rate()`), histograms (`_bucket/_sum/_count`; average = `rate(sum)/rate(count)`), gauges. `sum by (label)` is why a metric's labels decide which panels you can build. Labelled series don't exist until the first request after a restart; counters reset on restart and `rate()` handles that.
- Three kinds of metrics in this cluster: the app's own `/metrics`, kubelet/cAdvisor (container CPU/memory), kube-state-metrics (object state).
- Dashboard as code: Grafana's sidecar loads any ConfigMap labelled `grafana_dashboard: "1"` (`searchNamespace: ALL`). Chart `charts/switchyard-dashboard` reads the exported **Classic** JSON with `.Files.Get` (files must be inside the chart folder; `.Files.Get` returns plain text, so `{{model}}` legends don't clash with Helm). Exported with "for sharing externally"; the data source uid `prometheus` matches the stack's. A same-uid dashboard saved in the UI conflicts, so delete it first. ConfigMap dashboards are read-only in the UI: edit the file, bump the chart version, upgrade.
- YAML trap: label values must be strings (`"1"`, not `1`). `helm lint` and `helm template` passed; only `kubectl apply --dry-run=server` caught the misplaced `labels`/`namespace` fields. Always run the full ladder.
- Empty dashboard after install was just the time range (`now-1h` with load from 2 hours ago). Check the data (a PromQL query), the data source uid and the time range before suspecting the chart.
- Habit that saved me: `git diff` before committing caught an edit to the wrong file (the gateway's ConfigMap name). Check the path in the editor tab before saving.

## Troubleshooting ladder (use this before asking anyone)

1. **Read the exact words.** `kubectl describe pod <pod>`, then the `Events` at the bottom. The message usually names the problem (`statuscode: 404`, `ErrImagePull`, `Insufficient memory`, `unknown field`).
2. **Find the stage the pod is stuck at.** Each stage has its own first command:
   - `Pending`: describe events (scheduler: resources, PVC, node affinity).
   - `ImagePullBackOff` or `ErrImageNeverPull`: image name and tag wrong, or not loaded into kind (`crictl images`).
   - `CrashLoopBackOff` or restarts rising: `kubectl logs <pod> --previous`, then the container's exit code in describe.
   - `Running` but `0/1 Ready`: probes (describe events) and ports.
   - Ready but no traffic: `kubectl get endpointslices`, then Service selector vs `--show-labels`, then ports.
3. **Get evidence instead of guessing.** Logs, `curl` through a port-forward, `kubectl exec ... cat /etc/...`, and the app's own `--help` and startup output.
4. **Change one thing, then re-check the same command.** Don't edit three files and rerun.
5. **Render before apply.** Lint, template, server dry-run. Errors found here cost seconds, not pod restarts.
