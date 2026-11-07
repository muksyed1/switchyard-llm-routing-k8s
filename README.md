# switchyard-llm-routing-k8s

An LLM routing lab on Kubernetes. A [Switchyard](https://github.com/NVIDIA-NeMo/Switchyard) router sits in front of three small [Ollama](https://ollama.com) model servers and decides which one answers each request. It runs on a local [kind](https://kind.sigs.k8s.io) cluster with [Cilium](https://cilium.io) as the CNI, and every piece is installed with Helm.

This is a migration of an earlier AWS project (Terraform + Ansible on EC2) to Kubernetes, built as a hands-on way to learn production Kubernetes. It is a lab, not a production deployment. See [Known issues](#known-issues).

## Architecture

```
 you (curl / loadgen)
        |  kubectl port-forward  (localhost:4000)
        v
 +--------------------------- kind cluster (1 control plane + 3 workers, Cilium) ---------------------------+
 |  namespace: switchyard                                                                                    |
 |                                                                                                           |
 |   Service switchyard-server :4000                                                                         |
 |        |                                                                                                  |
 |   Deployment switchyard-server  <-- ConfigMap switchyard-server-routes (routes.toml, mounted as a file)   |
 |        |  picks a route/target per request                                                                |
 |        +--> Service demo-model-llama     :11434 --> Deployment + PVC  (llama3.2:1b)                       |
 |        +--> Service demo-model-nemotron  :11434 --> Deployment + PVC  (gemma3:1b)                         |
 |        +--> Service demo-model-qwen      :11434 --> Deployment + PVC  (qwen3:1.7b)                        |
 +-----------------------------------------------------------------------------------------------------------+
```

- **Gateway:** Switchyard (`switchyard-server`), one replica, configured by a `routes.toml` in a ConfigMap.
- **Models:** three Ollama releases of the same Helm chart. Each has its own Service (a stable DNS name for the router), its own PVC (so a pulled model survives pod restarts), and pulls its model automatically on start.
- **Routes** callers can request in the `model` field: `switchyard` (auto: easy prompts go to the efficient target, hard ones to the capable target), and passthrough routes `demo-model-llama`, `demo-model-nemotron`, `demo-model-qwen`.

| Release | Service DNS name | Model |
|---|---|---|
| `demo-model-llama` | `demo-model-llama:11434` | `llama3.2:1b` |
| `demo-model-nemotron` | `demo-model-nemotron:11434` | `gemma3:1b` |
| `demo-model-qwen` | `demo-model-qwen:11434` | `qwen3:1.7b` |
| `switchyard-server` | `switchyard-server:4000` | (router) |

The release names matter: the Service name equals the Helm release name, and `routes.toml` refers to those Service names.

## Status

| Step | What | State |
|---|---|---|
| 1 | kind cluster, NetworkPolicy-enforcing CNI (Cilium), `switchyard` namespace | Done |
| 2 | One Ollama Deployment + ClusterIP Service + PVC (raw manifests in [`ollama/`](ollama/)) | Done |
| 3 | One Helm chart, installed three times, automatic model pull | Done |
| 4 | Switchyard image, `routes.toml` in a ConfigMap, gateway chart | Done |
| 5 | Load generator through a port-forward | Script in [`loadgen/`](loadgen/); a stable run is pending (see Known issues) |
| 6 | kube-prometheus-stack, ServiceMonitor, Grafana dashboard | Planned |
| 7 | NetworkPolicy: default deny, allow gateway to models | Planned |
| 8 | EKS with Terraform, then GPU | Later |

## Repository layout

```
kind/kind-config.yaml          4-node kind cluster, default CNI disabled
docs/installation.md           cluster + Cilium install guide
charts/ollama/                 Helm chart: one Ollama model server (Deployment, Service, PVC)
charts/switchyard-server/      Helm chart: the router (Deployment, Service, ConfigMap)
values/{llama,nemotron,qwen}.yaml   per-model values for the Ollama chart (one line each)
ollama/                        Step 2 raw manifests, kept for reference
loadgen/loadgen.sh             load generator (curl + jq)
NOTES.md                       running list of concepts I should be able to explain
```

## Requirements

- macOS or Linux with Docker Desktop (or Docker Engine), `kind`, `kubectl`, `helm`, `curl`, `jq`. The [`cilium` CLI](docs/installation.md#cilium-cli) is needed for the connectivity test.
- **Docker needs at least 6 GiB of memory** for the whole stack. With 4 GiB (the Docker Desktop default here) the pods were OOM-killed and restarted under load. Give it 8 GiB if you can, and consider limiting Docker's CPUs: CPU-only inference will use every core it can get.
- Models are pulled from the Ollama registry on first start, about 3.5 GB in total.

## Quick start

All commands run from the repository root.

### 1. Cluster and CNI

Full explanation and troubleshooting: [docs/installation.md](docs/installation.md).

```bash
kind create cluster --config kind/kind-config.yaml

helm repo add cilium https://helm.cilium.io
helm repo update
helm install cilium cilium/cilium --version 1.20.4 \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes

cilium status --wait
kubectl create namespace switchyard
```

The nodes show `NotReady` until Cilium is up. That is expected, because `disableDefaultCNI` is set.

### 2. Build the Switchyard image and load it into kind

Upstream publishes no image that I found, only a Dockerfile, so build it from a pinned tag. The image is built natively for your machine's architecture (arm64 on Apple Silicon).

```bash
# in a separate directory, outside this repo
git clone https://github.com/NVIDIA-NeMo/Switchyard.git
cd Switchyard
git checkout v0.4.0-rc.1
docker build -t switchyard-server:0.4.0-rc.1-ef958a9a8 .

kind load docker-image switchyard-server:0.4.0-rc.1-ef958a9a8
```

The kind nodes cannot see your local Docker image store, so `kind load` copies the image into each node. Check with `docker exec kind-worker crictl images | grep switchyard`. The tag is the upstream version plus the commit SHA; if you build a different commit, change `image.tag` in [`charts/switchyard-server/values.yaml`](charts/switchyard-server/values.yaml).

### 3. Install the model servers (one chart, three releases)

```bash
helm upgrade --install demo-model-llama    charts/ollama -f values/llama.yaml    -n switchyard
helm upgrade --install demo-model-nemotron charts/ollama -f values/nemotron.yaml -n switchyard
helm upgrade --install demo-model-qwen     charts/ollama -f values/qwen.yaml     -n switchyard

kubectl get pods -n switchyard
```

A `postStart` hook pulls the model in the background, so a pod is `Ready` before its model finishes downloading. Check progress and results:

```bash
kubectl exec -n switchyard deploy/demo-model-llama -- cat /tmp/model-pull.log
kubectl exec -n switchyard deploy/demo-model-llama -- ollama list
```

(Repeat for `demo-model-nemotron` and `demo-model-qwen`.)

### 4. Install the router

```bash
helm upgrade --install switchyard-server charts/switchyard-server -n switchyard
kubectl get pods -n switchyard
```

The release name must be `switchyard-server`, or change the names consistently. See "Verify" for what to check.

### 5. Try it

```bash
kubectl port-forward -n switchyard svc/switchyard-server 4000:4000
```

In another terminal:

```bash
curl -s localhost:4000/health
curl -s localhost:4000/v1/models

# passthrough route to one model
curl -s localhost:4000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"demo-model-llama","messages":[{"role":"user","content":"Say hello in five words"}]}'

# auto route: the "model" field in the reply shows which backend was chosen
curl -s localhost:4000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"switchyard","messages":[{"role":"user","content":"What is 2 + 2?"}]}'
```

The first request to a model after a pause is slow (several seconds): Ollama loads the weights into memory and unloads them after about 5 minutes idle.

### 6. Load generator

```bash
cd loadgen
CONCURRENCY=1 INTERVAL=5 MAX_TOKENS=64 ./loadgen.sh localhost
```

The host is the first argument and the port is the `PORT` variable (default 4000), so pass `localhost`, not `localhost:4000`. Start with low concurrency: three Ollama models on CPU can saturate a laptop.

## Verify the configuration

Check Helm output before it reaches the cluster, from least to most thorough:

```bash
helm lint charts/switchyard-server
helm template switchyard-server charts/switchyard-server -n switchyard
helm template switchyard-server charts/switchyard-server -n switchyard | kubectl apply --dry-run=server -f -
```

`helm lint` and `helm template` do not check that the API kinds exist; the server dry run does. To validate the rendered `routes.toml` with the real binary, without writing a file:

```bash
helm template switchyard-server charts/switchyard-server -n switchyard -s templates/configMap.yaml \
  | awk '/routes-config: \|/{f=1;next} f{sub(/^        /,""); print}' \
  | docker run --rm -i switchyard-server:0.4.0-rc.1-ef958a9a8 --config /dev/stdin --dry-run
```

Look at the config the running gateway actually reads:

```bash
kubectl exec -n switchyard deploy/switchyard-server -- cat /etc/switchyard-server/conf/routes.toml
```

## Troubleshooting

Start from the pod's events, then match the stage:

```bash
kubectl get pods -n switchyard
kubectl describe pod -n switchyard <pod>          # read the Events at the bottom
kubectl logs -n switchyard <pod> [--previous]
kubectl get endpointslices -n switchyard
kubectl get pods -n switchyard --show-labels
```

| Symptom | First thing to check |
|---|---|
| `Pending` | `describe` events: resources, PVC, node affinity |
| `ImagePullBackOff` / `ErrImageNeverPull` | image name and tag; was it loaded with `kind load`? |
| `CrashLoopBackOff` or rising restarts | `logs --previous`; exit code (137 = OOMKilled) |
| `Running` but `0/1 Ready` | probes in `describe` events; port and path |
| Ready but requests fail | Service endpoints and selector vs pod labels |
| `model '...' not found` from a route | `ollama list` in that pod: the model is not pulled yet |
| `http=000` in the load generator | the port-forward died (it is bound to one pod and does not reconnect) |

`kubectl port-forward` is a lab convenience. It tunnels to a single pod and breaks when that pod restarts.

## Stop, start, tear down

```bash
# keep everything (cluster state and pulled models live inside the node containers)
docker stop kind-worker kind-worker2 kind-worker3 kind-control-plane
docker start kind-control-plane kind-worker kind-worker2 kind-worker3

# free CPU/RAM but keep releases and models
kubectl scale deploy -n switchyard demo-model-llama demo-model-nemotron demo-model-qwen switchyard-server --replicas=0

# remove a release (this also deletes its PVC and the pulled model)
helm uninstall demo-model-llama -n switchyard

# delete the whole cluster
kind delete cluster
```

## Known issues

- **Memory and probes.** With the default 4 GiB Docker VM, pods were OOM-killed under load. The Ollama probes also have no `timeoutSeconds` (1 s default), so a busy, healthy pod can fail liveness and be restarted. The planned fix is more memory, longer probe timeouts and a higher failure threshold, concurrency limits on Ollama, and memory limits that fit the VM. Not done yet.
- **Resource limits** in the Ollama chart (4 CPU / 4Gi each) are larger than the VM they run in.
- **Namespace handling** in the Ollama chart is inconsistent: the Deployment reads `.Values.metadata.namespace`, and the Service and PVC hardcode `switchyard`. Always pass `-n switchyard`. The gateway chart uses `.Release.Namespace`.
- **Model tags are duplicated** between `values/*.yaml` (Ollama chart) and `charts/switchyard-server/values.yaml` (routes), so they can drift. The release `demo-model-nemotron` serves `gemma3:1b`, which is confusing to read.
- **A ConfigMap change does not restart the gateway.** The file updates but the process reads it at startup. Fix: a checksum annotation on the pod template, or `kubectl rollout restart`.
- **Version tracking.** The gateway version appears in three places (`Chart.yaml` `appVersion`, `labels.version`, `image.tag`).
- **Switchyard `v0.4.0-rc.1` is a release candidate.**
- **No traffic restrictions yet.** Any pod can call the models directly until Step 7.
- Unused scaffold keys remain in both `values.yaml` files, and the Cilium CLI and the kind node image are not pinned.

## Notes

[`NOTES.md`](NOTES.md) is a running list, one section per step, of what I should be able to explain out loud (CNI and IPAM, labels and selectors, PV/PVC, Helm release vs chart, probes, resource limits, and a troubleshooting ladder).
