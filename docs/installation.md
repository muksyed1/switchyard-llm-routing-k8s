# Installation: local Kubernetes cluster (kind + Cilium)

How to build the local cluster that the Switchyard workloads run on. This covers Step 1 only: the cluster, a CNI that enforces NetworkPolicy, and the project namespace.

Result: a 4-node kind cluster (1 control plane, 3 workers) with Cilium as the only CNI, and an empty `switchyard` namespace.

Reference: the official guide, [Cilium: Installation using kind](https://docs.cilium.io/en/stable/installation/kind/). This document follows it. Where the guide changes (versions, flags), the guide wins.

## Prerequisites

| Tool | Used for | Install (macOS) |
|---|---|---|
| Docker Desktop | kind runs each node as a Docker container | https://www.docker.com/products/docker-desktop/ |
| kind | creates the cluster | `brew install kind` |
| kubectl | talks to the cluster | `brew install kubectl` |
| helm | installs Cilium | `brew install helm` |
| cilium CLI | status and connectivity checks | see "Cilium CLI" below |

Minimum versions per the Cilium guide: kubectl 1.14.0+, Helm 3.13.0+, kind 0.7.0+.

Kind's default pod subnet is `10.244.0.0/16` and its service subnet is `10.96.0.0/12`. If either overlaps your local network, change it under `networking` in the kind config.

Docker Desktop must be running before any `kind` command. Give it enough memory for the whole cluster: the Ollama models in later steps are the biggest consumers.

Versions used in this lab:

- Kubernetes (kind node image default): v1.37.0
- Cilium Helm chart: 1.20.4 (pinned)

## 1. Create the cluster

The cluster config is [`kind/kind-config.yaml`](../kind/kind-config.yaml). The important setting is `networking.disableDefaultCNI: true`.

Without it, kind installs its own CNI (kindnet), which runs alongside Cilium and leaves the cluster with two CNIs. This setting can only be applied when the cluster is created, so a cluster created without it must be deleted and recreated.

```bash
kind create cluster --config kind/kind-config.yaml
```

Check the nodes. They will show `NotReady` until a CNI is installed. That is expected.

```bash
kubectl get nodes
```

Check that no `kindnet-*` pod exists in `kube-system`. Its absence confirms the default CNI is off.

```bash
kubectl -n kube-system get pods
```

## 2. Install Cilium

Add the Helm repo once:

```bash
helm repo add cilium https://helm.cilium.io
helm repo update
```

**Optional, and not run in this lab.** The guide preloads the agent image onto the kind nodes first. Without this the nodes pull it from the registry on first start, which is slower but still works (the install succeeded without it).

```bash
docker pull quay.io/cilium/cilium:v1.20.4
kind load docker-image quay.io/cilium/cilium:v1.20.4
```

Install into **`kube-system`**. The `cilium` CLI looks there by default, so installing into another namespace makes `cilium status` fail with `daemonsets.apps "cilium" not found`.

```bash
helm install cilium cilium/cilium --version 1.20.4 \
   --namespace kube-system \
   --set image.pullPolicy=IfNotPresent \
   --set ipam.mode=kubernetes
```

- `--version` pins the chart so the install is repeatable.
- `ipam.mode=kubernetes` takes pod CIDRs from each node's `spec.podCIDR`, as the Cilium kind guide specifies.
- `image.pullPolicy=IfNotPresent` uses an image already on the node instead of pulling it again. It only saves a pull if the image is already there, for example after the preload above.

The guide also offers an OCI install that needs no `helm repo add`: `helm install cilium oci://quay.io/cilium/charts/cilium 1.20.4`, with the same namespace and `--set` flags.

Wait for the nodes to become `Ready`:

```bash
kubectl get nodes -w
```

### Cilium CLI

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "arm64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}
shasum -a 256 -c cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-darwin-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}
```

This installs whatever version `stable.txt` points to, so it is **not pinned**.

## 3. Verify Cilium

```bash
cilium status --wait
cilium connectivity test
```

Expected: `cilium status` reports no errors, and the connectivity test ends with all tests successful. Some tests are skipped, which is normal.

In `kube-system` you should see:

- one `cilium-*` and one `cilium-envoy-*` pod per node (DaemonSets), so 4 of each
- two `cilium-operator-*` pods, both `Running`
- one `kube-proxy-*` pod per node (Cilium runs alongside kube-proxy here)

### Troubleshooting (from the Cilium guide)

- If the agent can't reach the API server, delete and recreate the cluster, then reinstall Cilium, so stale eBPF programs are detached.
- If agent pods crash, another Cilium install or overlapping BPF cgroup programs on the host may be the cause.
- If connectivity-test pods fail with "too many open files", raise the inotify limits on the host.
- Connectivity-test pods that check multi-node traffic stay `Pending` on a single-node cluster. This cluster has workers, so it shouldn't happen.

## 4. Create the project namespace

```bash
kubectl create namespace switchyard
```

Everything for the Switchyard stack goes in this namespace, which keeps the NetworkPolicies in Step 7 scoped. Cilium stays in `kube-system`.

Check it is empty and active:

```bash
kubectl get ns switchyard
kubectl get all -n switchyard
```

Optional: make it the default namespace for the current kubectl context so `-n switchyard` isn't needed each time.

## Tear down

```bash
kind delete cluster
```

This removes all nodes and everything in the cluster, including the namespace. Recreate by repeating this document from step 1.

## Known gaps (to improve)

- The kind node image is not pinned, so the Kubernetes version follows the installed kind release.
- The cluster `name` is not set in the config file, so it defaults to `kind` (kubectl context `kind-kind`).
- The Cilium CLI install is unpinned.
- Cilium's settings are `--set` flags rather than a values file, so they are not tracked in git. Moving them to a values file and using `helm upgrade --install` would make the install repeatable.
- The namespace is created imperatively rather than from a manifest.
