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
