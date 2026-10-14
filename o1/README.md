# OCUDU O1 adapter in docker compose

[ocudu_o1_adapter](https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_o1_adapter) together with the
NETCONF server it reads its configuration from: the same pair the `ocudu-gnb` Helm chart runs as sidecars
(`ocudu_helm/charts/ocudu-gnb/values-o1.yaml`).

Tested on Windows 11 + Docker Desktop 28.2 (Compose v2.37), adapter `d7c82cd`, netconf `20261008_452af662`.

| Service | Image | Port | Role |
|---------|-------|------|------|
| `netconf` | `ocudu_netconf/netconf_nightly_amd64` (pinned) | `830` (SSH, `root`/`root`) | netopeer2 + sysrepo with the 3GPP NRM YANG of the selected profile |
| `o1-adapter` | built from `../ocudu_o1_adapter` (upstream `Dockerfile`) | `5000` (health API) | NETCONF `running` -> `gnb-config.yml`; FM/PNF to VES; PM from the gNB websocket |

## Quick start

From the repo root:

```bash
git clone https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_o1_adapter.git
docker compose -f o1/docker-compose.yml up --build -d

curl -i http://localhost:5000/config-healthy        # 200 {"success":"OK"}
docker exec o1_adapter cat /etc/config/gnb-config.yml
```

Teardown (`-v` also drops the persisted NETCONF config and the rendered gNB config):

```bash
docker compose -f o1/docker-compose.yml down -v
```

## Configuration

Everything is set with environment variables (shell or an `o1/.env` file):

| Variable | Default | |
|----------|---------|-|
| `O1_PROFILE` | `gnb` | `gnb`, `cu`, `cucp`, `cuup`, `du`; selects both the netconf YANG profile and the adapter template |
| `NETCONF_IMAGE` | nightly `20261008_452af662` | |
| `NETCONF_PORT` | `830` | host port of the NETCONF server |
| `NETCONF_USERNAME` / `NETCONF_PASSWORD` | `root` / `root` | |
| `O1_HEALTH_PORT` | `5000` | host port of the adapter's health API |
| `WS_HOST` / `WS_PORT` | `localhost` / `8001` | gNB remote-control/metrics websocket |
| `VES_HOST` / `VES_PORT` / `VES_SCHEME` | `localhost` / `8443` / `https` | SMO VES collector |
| `VES_USERNAME` / `VES_PASSWORD` | `sample1` / `sample1` | |
| `O1_LOG_LEVEL` | `INFO` | |

The netconf server starts from its bundled `/opt/dev/configs/config_<profile>.xml`. On `stop` it exports the
running datastore to the `netconf-running` volume and re-imports it on the next start, so edits survive restarts.
That volume also records the profile: run `down -v` before changing `O1_PROFILE`.

Without a gNB and an SMO the adapter logs `WS connection error` every 5 s and `VES HTTP request failed`; both
are harmless.

## How a configuration change flows

1. An SMO (or any NETCONF client, e.g. on `localhost:830`) does `edit-config` on `running`.
2. The adapter gets the change notification and diffs it:
   - SSB power or `RRMPolicyRatio` only: pushed to the running gNB over the websocket, no restart;
   - anything else: it sends `quit` to the gNB, `/config-healthy` turns `400`, and once the gNB websocket is
     back (or after 30 s) it writes the new `gnb-config.yml`.
3. The gNB side restarts with the new file and calls `POST /restarted`, which turns `/config-healthy` back to `200`.

Checked with the stack above (no gNB): `gNBCUName` changed over NETCONF -> health `400` -> after 30 s
`ran_node_name: <new name>` in `gnb-config.yml` -> `POST /restarted` -> `200`.

```bash
curl -i http://localhost:5000/config-healthy
curl -X POST http://localhost:5000/restarted
```

## Hooking up a gNB

The adapter expects to live next to the gNB like in the Helm pod: it reaches the websocket at `WS_HOST:WS_PORT`
and the gNB reads `/etc/config/gnb-config.yml` from the shared `o1-gnb-config` volume. In compose that means:

- mount `o1-gnb-config` into the gNB container and start it with `-c /etc/config/gnb-config.yml`;
- set `WS_HOST` to the gNB service name; the gNB's `remote_control` section is rendered into `gnb-config.yml`
  by the adapter from the NETCONF `ocudu_remote_control_extensions` (enabled, `bind_addr: 0.0.0.0`);
- run the gNB through a restart loop like `ocudu_helm/charts/ocudu-gnb/resources/entrypoint.sh` with
  `ENABLE_OCUDU_O1=true` (it waits for the config, restarts the gNB after `quit` and posts `/restarted`
  to the adapter, so `localhost:5000` there has to point at the adapter, e.g. `network_mode: service:o1-adapter`).
