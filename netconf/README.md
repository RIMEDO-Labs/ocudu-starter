# OCUDU NETCONF server in docker compose

[ocudu_netconf](https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_netconf) built from source:
netopeer2 + sysrepo with the 3GPP NRM / O-RAN YANG models and the OCUDU extensions, preloaded with the config of
the selected profile. This is the server the [O1 adapter](../o1/README.md) reads, and the one an SMO configures.

Tested on Windows 11 + Docker Desktop 28.2 (Compose v2.37), ocudu_netconf `79fa7a0`.

## Quick start

From the repo root:

```bash
git clone https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_netconf.git
docker compose -f netconf/docker-compose.yml up --build -d    # first build: libyang/sysrepo/netopeer2 from source
docker compose -f netconf/docker-compose.yml logs -f
```

Talk to it (`root`/`root`, SSH on `localhost:830`):

```bash
docker exec -it ocudu_netconf netopeer2-cli      # > connect --login root   > get-config --source running
docker exec ocudu_netconf sysrepocfg -X -d running -f xml
```

Teardown (`-v` also drops the persisted running config and TLS certs):

```bash
docker compose -f netconf/docker-compose.yml down -v
```

## Configuration

Environment variables (shell or `netconf/.env`):

| Variable | Default | |
|----------|---------|-|
| `NETCONF_PROFILE` | `gnb` | `gnb`, `cu`, `cucp`, `cuup`, `du`, `ru` (mock O-RU) |
| `NETCONF_ARGS` | | extra entrypoint options, e.g. `--enable-tls`, `--enable-callhome <host>[:<port>]` |
| `NETCONF_PORT` / `NETCONF_TLS_PORT` | `830` / `6513` | host ports |
| `NETCONF_SSH_USERNAME` / `NETCONF_SSH_PASSWORD` | empty | extra user with SSH *password* auth and full NACM access (OpenDaylight cannot do the keyboard-interactive auth `root` uses); set both or neither |

The bundled `configs/config_<profile>.xml` is loaded on the first start. On `stop` the running datastore is
exported to the `netconf-running` volume and re-imported next time, so edits survive restarts. The volume also
records the profile: run `down -v` before changing `NETCONF_PROFILE`.

### TLS

```bash
NETCONF_ARGS=--enable-tls docker compose -f netconf/docker-compose.yml up -d
mkdir -p tls && for f in ca.crt client.crt client.key; do docker compose -f netconf/docker-compose.yml cp netconf:/etc/netconf-tls/$f tls/$f; done
```

On the first start a self-signed CA, server cert and client certs (`CN=root`, `CN=hybrid-odu`) are generated into
the `netconf-tls` volume. The client cert's CN is the NETCONF username.

### SSH host key

The image's ed25519 host key changes on every rebuild. To pin one, mount a directory with
`ssh_host_ed25519_key` at `/etc/netconf-ssh` (read-only), see "Provision the SSH host key" in the upstream README.

## With the O1 adapter

`o1/docker-compose.yml` runs its own netconf container from the pinned nightly image. To use this build instead:

```bash
NETCONF_IMAGE=ocudu-netconf:local docker compose -f o1/docker-compose.yml up -d
```
