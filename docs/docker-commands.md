# Docker commands used in this lab

A quick reference for the Docker commands used while running the kind cluster. Everything here was run on macOS with Docker Desktop. The kind nodes are Docker containers, so these commands apply to the cluster too.

## Is Docker up, and how big is it?

| Command | What it tells you |
|---|---|
| `docker desktop status` | Docker Desktop's own state (`running`). Newer Docker Desktop only; it also has `start` and `stop`. |
| `docker info` | Daemon details. If it prints `Cannot connect to the Docker daemon`, Docker is down. |
| `docker info --format 'mem={{.MemTotal}} cpus={{.NCPU}}'` | The VM's memory (bytes) and CPU count. 8 GiB shows as about 8,322,969,600. |
| `docker version` | Client and server versions; errors if the daemon is down. |
| `grep MemoryMiB ~/Library/Group\ Containers/group.com.docker/settings-store.json` | The memory setting Docker has saved. If it differs from `docker info`, the change was not applied. |

Resource settings live in Docker Desktop > Settings > Resources. Changes only apply after **Apply & restart**. This lab uses 8 GB memory and 8 CPUs.

## How much is it using?

```bash
docker ps                                   # running containers (-a for all)
docker stats --no-stream                    # CPU and memory per container, one snapshot
docker system df                            # disk used by images, containers, volumes
```

Total CPU and memory across all containers:

```bash
docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' | awk '{gsub("%","",$1); cpu+=$1; v=$2; if (v ~ /GiB/) {gsub("GiB","",v); mem+=v*1024} else {gsub("MiB","",v); mem+=v}} END {printf "CPU %.0f%%  Mem %.0f MiB\n", cpu, mem}'
```

CPU is a percentage of one core, so with 8 CPUs the ceiling is 800%.

What the Docker VM costs the Mac (resident memory of its process):

```bash
ps -axo rss,comm | grep -i 'Virtualization.VirtualMachine' | grep -v grep
memory_pressure | tail -3                   # system-wide free percentage
```

`docker stats` counts file cache inside the VM, so its total can be higher than the VM's resident memory on the Mac. Activity Monitor's Memory tab (green/yellow/red pressure graph) matters more than the menu-bar percentage.

## The kind nodes (they are containers)

```bash
docker ps -a --format '{{.Names}} {{.Status}}' | grep kind

# stop (keeps all cluster state and the pulled models)
docker stop kind-worker kind-worker2 kind-worker3 kind-control-plane

# start (control plane first, then wait a few minutes)
docker start kind-control-plane kind-worker kind-worker2 kind-worker3
```

After a Docker restart the pods show `Unknown` for a minute or two while the kubelets re-sync. Wait before troubleshooting.

**Do not** run `kind delete cluster`, `docker rm`, or use the trash icon in the Docker dashboard on the kind containers unless you mean to destroy the cluster. That deletes the nodes, the Helm releases and the pulled models.

## Images

```bash
docker build -t switchyard-server:0.4.0-rc.1-ef958a9a8 .     # from the Switchyard repo root
docker images switchyard-server                              # in Docker's local store
docker image inspect switchyard-server:0.4.0-rc.1-ef958a9a8 \
  --format 'arch={{.Architecture}} user={{.Config.User}} entrypoint={{.Config.Entrypoint}}'

kind load docker-image switchyard-server:0.4.0-rc.1-ef958a9a8
```

`kind load` copies the image from Docker's store into each node's own containerd store. Check it arrived:

```bash
docker exec kind-worker crictl images | grep switchyard
docker exec kind-worker crictl ps            # containers running on that node
```

`docker ps` shows only the nodes, not the pods inside them; use `crictl ps` or `kubectl get pods`.

If `kind load docker-image` fails with `content digest ... not found` (containerd image store), use the archive route, and keep the tarball outside the repo:

```bash
docker save <image:tag> -o /path/outside/repo/image.tar
kind load image-archive /path/outside/repo/image.tar
```

## Running a container to test something

```bash
# validate a config with the real binary, reading it from stdin (no file written)
docker run --rm -i switchyard-server:0.4.0-rc.1-ef958a9a8 --config /dev/stdin --dry-run < routes.toml

docker run --rm switchyard-server:0.4.0-rc.1-ef958a9a8 --help
```

`-i` keeps stdin open (needed to pipe input); `-t` adds a terminal for an interactive shell (`-it`). `--rm` removes the container when it exits.

## Looking inside a node

```bash
docker exec kind-worker ps -eo pid,pcpu,etime,args --sort=-pcpu | head    # busiest processes on a node
docker exec kind-worker curl -s -m 3 http://<clusterIP>:<port>/health     # test a ClusterIP from inside the cluster network
```

ClusterIPs are not reachable from the Mac itself; use `kubectl port-forward` or run the command inside a node.
