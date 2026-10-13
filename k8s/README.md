# Open5GS + OCUDU gNB (ru_dummy + test_ue) on Kubernetes

Tested on Windows 11 + Docker Desktop Kubernetes (v1.32, WSL2 kernel 5.15), Helm 4.3.

Files in this directory:

| File | Purpose |
|------|---------|
| `deploy.sh` | `up` / `down` (sections 1-4 / Teardown), `gnb` and `gnb-lite` (core in docker compose) |
| `open5gs.yaml` | `Open5GS` custom resource for the Gradiant operator |
| `amf-ngap-headless.yaml` | Headless NGAP Service (Docker Desktop / WSL2 workaround) |
| `ocudu-gnb-values.yaml` | Values for the `ocudu-gnb` chart: ru_dummy + test_ue, no SR-IOV/DPDK |
| `ocudu-gnb-compose-values.yaml` | Same gNB, attached to the Open5GS from `ocudu/docker/docker-compose.open5gs.yml` |
| `compose-ui-gnb-k8s.yml` | Override for `ocudu/docker/docker-compose.ui.yml`: Telegraf reads the gNB in Kubernetes |
| `grafana-ocudu-values.yaml` | Values for the `grafana-ocudu` chart (Grafana + InfluxDB3 + Telegraf) |

## Quick start

After the prerequisites (section 0 or 0a), from the repo root (Git Bash on Windows):

```bash
./k8s/deploy.sh up      # sections 1-4; clones ocudu_helm if missing; safe to re-run
./k8s/deploy.sh down    # Teardown
```

The script uses the current kubectl context and applies the SCTP workaround (section 2) only on `docker-desktop`.

### Variant: Open5GS from docker compose, gNB + Grafana in Kubernetes

```bash
docker compose -f ocudu/docker/docker-compose.open5gs.yml up -d   # open5gs_5gc at 10.53.1.2
./k8s/deploy.sh gnb                                               # gNB (ocudu-gnb-compose-values.yaml) + Grafana
```

`ocudu-gnb-compose-values.yaml` points the AMF at `10.53.1.2` and uses that core's PLMN 00101, TAC 7, SST 1.
Docker Desktop runs pods and compose containers in the same VM, so the gNB pod reaches the container IP directly.
NGAP (38412/sctp) cannot be published as a port there: the WSL2 kernel has no `xt_sctp`, and
`docker compose up` fails with `Extension sctp revision 0 not supported`. GTP-U 2152/udp is published.
`./k8s/deploy.sh down` removes the gNB and Grafana; stop the core with `docker compose ... down`.

### Lite variant: only the gNB in Kubernetes, Grafana + InfluxDB + Telegraf in docker compose

```bash
docker compose -f ocudu/docker/docker-compose.open5gs.yml up -d
./k8s/deploy.sh gnb-lite
docker compose -f ocudu/docker/docker-compose.ui.yml -f k8s/compose-ui-gnb-k8s.yml up -d   # Grafana: http://localhost:3300
```

The gNB metrics Service is a NodePort (30801). `compose-ui-gnb-k8s.yml` points Telegraf at
`host.docker.internal:30801` and moves the `metrics` network to 172.29.1.0/24, because the upstream 172.19.1.0/24
overlaps with k3d's default network. Stop with `docker compose -f ... -f ... down` and `./k8s/deploy.sh down`.

The sections below describe the same steps by hand.

## 0. Prerequisites

1. Docker Desktop -> Settings -> Kubernetes -> *Enable Kubernetes*.
2. Give the WSL2 VM enough CPU and RAM. The gNB runs in real time, and with 2 vCPU it cannot keep up
   (`Unexpected jump in slot indications`, zero throughput). In `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   memory=16GB
   processors=8
   networkingMode=mirrored
   ```

   Then run `wsl --shutdown` and start Docker Desktop again. This stops all WSL distros and containers.
3. Point kubectl at the cluster:

   ```bash
   kubectl config use-context docker-desktop
   kubectl get nodes        # check allocatable CPU: kubectl describe node docker-desktop
   ```

## 0a. Alternative: Ubuntu 26.04 + k3d (not tested yet)

Use this instead of section 0 on a Linux host with Docker and k3d. The other sections apply, with the
differences listed below.

1. Load the SCTP kernel module on the host. k3d nodes are containers that share the host kernel and cannot
   load modules themselves. On server/cloud images `sctp.ko` comes from `linux-modules-extra`:

   ```bash
   sudo modprobe sctp       # if "Module sctp not found": sudo apt install linux-modules-extra-$(uname -r)
   lsmod | grep sctp
   echo sctp | sudo tee /etc/modules-load.d/sctp.conf    # load on boot
   ```

2. Create the cluster and map the Grafana NodePort to the host (k3d does not expose NodePorts by default):

   ```bash
   k3d cluster create ocudu -p "30001:30001@server:0"
   kubectl config use-context k3d-ocudu
   kubectl describe node k3d-ocudu-server-0 | grep -A6 Allocatable
   ```

   k3s has a default `local-path` StorageClass, so the MongoDB PVC is provisioned automatically.

3. Check the CPU. The gNB requests 4 CPUs (limit 6), so the host needs about 8 cores for everything. Pick the
   image variant that matches the host: `grep -o -w -E 'avx512f|avx2' /proc/cpuinfo | sort -u`.

4. Differences in the later sections:
   - Section 2: do not scale down the operator or delete its Service. Only apply the headless Service, because
     `ocudu-gnb-values.yaml` points at `amf-ngap.open5gs.svc.cluster.local`:

     ```bash
     kubectl apply -f k8s/amf-ngap-headless.yaml
     ```

     If kube-proxy works with SCTP (`kubectl -n kube-system logs` shows no k3s/iptables `sctp` errors), you can
     instead set `cu_cp.amf.addr` to `open5gs-amf-ngap.open5gs.svc.cluster.local` and skip the headless Service.
   - Section 3: `core.autocrlf` does not matter on Linux. The `Not enough privileges` warning should not appear
     (Ubuntu kernels have no `CONFIG_RT_GROUP_SCHED`).
   - Section 4: Grafana is at http://localhost:30001 only with the `-p` port mapping from step 2. Without it, use
     `http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' k3d-ocudu-server-0):30001`.

Teardown: `k3d cluster delete ocudu`.

## 1. Open5GS (Gradiant operator)

```bash
helm install open5gs-operator oci://registry-1.docker.io/gradiantcharts/open5gs-operator \
  --version 1.0.7 --namespace open5gs --create-namespace --wait

kubectl apply -f k8s/open5gs.yaml
kubectl -n open5gs get pods -w      # wait for 12 pods + operator to be Running
```

Notes:
- Operator 1.0.7 already uses `quay.io/brancz/kube-rbac-proxy`, so the `open5gs-operator-values.yaml`
  override from ocudu_helm is not needed.
- Docker Desktop has a default `hostpath` StorageClass, so the MongoDB PVC is provisioned automatically.
  Skip `open5gs-pv-pvc.yaml` from ocudu_helm: it is meant for clusters without a default StorageClass.
- `open5gs.yaml` pins Open5GS/WebUI 2.7.5 and MongoDB `bitnamilegacy/mongodb:8.0.13-debian-12-r0`. The operator's
  default MongoDB image is `bitnami/mongodb:latest`, which is not reproducible.
- PLMN/TAC are the operator defaults: MCC 999, MNC 70, TAC 1, slice SST 1 / SD 0x111111.

## 2. Docker Desktop only: SCTP workaround

The WSL2 kernel has no SCTP conntrack (`CONFIG_NF_CT_PROTO_SCTP`) and no `xt_sctp`. When the operator
creates the SCTP Service `open5gs-amf-ngap`, kube-proxy fails every iptables sync
(`Extension sctp revision 0 not supported`), and **no** Service in the cluster works after that.
In Open5GS this shows up as UDR/PCF in CrashLoopBackOff with `Failed to connect to server [mongodb://...]`.

Fix: stop the operator so it does not recreate the Service, delete the Service, and add a headless one.
kube-proxy ignores headless Services; DNS returns the AMF pod IP directly.

```bash
kubectl -n open5gs scale deploy open5gs-operator-controller-manager --replicas=0
kubectl -n open5gs delete svc open5gs-amf-ngap
kubectl apply -f k8s/amf-ngap-headless.yaml

# kube-proxy should stop logging iptables-restore errors within ~30 s
kubectl -n kube-system logs ds/kube-proxy --since=1m

# restart anything that crashed while Services were broken
kubectl -n open5gs rollout restart deploy open5gs-udr open5gs-pcf
```

On a real Linux host (Ubuntu with stock kernel) skip the operator scale-down and Service deletion. Either apply
only `amf-ngap-headless.yaml`, or point the gNB at `open5gs-amf-ngap.open5gs.svc.cluster.local` (see 0a).

## 3. OCUDU gNB

The newest OCI chart (3.9.2) still uses `tini`, which the current images no longer have. Use the chart from
the git `main` branch, pinned to commit `47062ad3` (chart 3.12.2, appVersion 26.10), which uses `catatonit`.

**Clone with `core.autocrlf=false`.** With Git for Windows' default (`true`), `entrypoint.sh` gets CRLF line
endings and the pod fails with `entrypoint-ocudu-gnb.sh: cannot execute: required file not found`.

```bash
git clone -c core.autocrlf=false https://gitlab.com/ocudu/ocudu_elements/ocudu_helm.git
git -C ocudu_helm checkout --detach 47062ad36c6b3588280a7a6ad1783b5ef34f746c   # pinned, same as deploy.sh

kubectl create namespace ran
kubectl label ns ran pod-security.kubernetes.io/enforce=privileged

helm install gnb ./ocudu_helm/charts/ocudu-gnb -n ran -f k8s/ocudu-gnb-values.yaml
kubectl -n ran logs -f deploy/gnb-ocudu-gnb
```

Expected output:

```
Connected to AMF. Supported PLMNs: 99970
==== gNB started ===
 pci rnti | cqi  ri  mcs  brate   ok  nok ...
   1   44 |  15 1.0   27   ...M  ...    0 ...
```

Image: `gnb-dpdk:ubuntu-24.04-avx2-*` (this CPU has AVX2, not AVX-512). Check with
`grep -o -w -E 'avx512f|avx2' /proc/cpuinfo | sort -u` in WSL.

Change the gNB config: edit `ocudu-gnb-values.yaml`, then
`helm upgrade gnb ./ocudu_helm/charts/ocudu-gnb -n ran -f k8s/ocudu-gnb-values.yaml`.

Full log file inside the pod:
`kubectl -n ran exec deploy/gnb-ocudu-gnb -- tail -f /var/log/ocudu/gnb.log`.

CPU limit: the gNB values use `requests.cpu: 4` and `limits.cpu: 6`. With `limits.cpu: 2`, the container was
CFS-throttled in 84% of periods (`/sys/fs/cgroup/cpu/cpu.stat` → `nr_throttled`). The cell then missed slots
(`DL task queue is full`) and test_ue showed zero throughput.
`Scheduling priority ... Not enough privileges` is expected on WSL2 (`CONFIG_RT_GROUP_SCHED=y`) and harmless here.

## 4. Grafana + InfluxDB3 + Telegraf

The gNB values already enable what Telegraf needs: `metrics.enable_json`, `remote_control` (WebSocket on
port 8001) and `metricsService` (ClusterIP Service `gnb-ocudu-gnb-metrics`).

```bash
helm install grafana oci://registry.gitlab.com/ocudu/ocudu_elements/ocudu_helm/grafana-ocudu \
  --version 2.5.2 -n monitoring --create-namespace -f k8s/grafana-ocudu-values.yaml --wait
kubectl -n monitoring get pods
```

Grafana: http://localhost:30001 (NodePort; anonymous viewer, admin / admin1234).

On the first start Telegraf may restart once while InfluxDB is still coming up (`context deadline exceeded`).
Check that data arrives:

```bash
kubectl -n monitoring exec deploy/grafana-influxdb3 -- \
  influxdb3 query --host http://localhost:8081 --database ocudu "SELECT count(*), max(time) FROM ue"
```

InfluxDB keeps data in memory (`--object-store=memory`), so a pod restart clears the history.

## Teardown

```bash
helm uninstall grafana -n monitoring
helm uninstall gnb -n ran
kubectl delete -f k8s/open5gs.yaml          # needs the operator running: scale it back to 1 first
helm uninstall open5gs-operator -n open5gs
kubectl delete -f k8s/amf-ngap-headless.yaml
kubectl delete ns ran open5gs monitoring
```
