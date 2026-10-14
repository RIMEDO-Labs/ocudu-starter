# rimedo-ocudu

Lokalne środowisko OCUDU na Windows 11 + Docker Desktop (z włączonym Kubernetesem):
rdzeń Open5GS w docker compose, gNB (ru_dummy + test_ue) w Kubernetesie, Grafana oraz O1 adapter z serwerem NETCONF.

| Katalog | Co to jest | Szczegóły |
|---------|------------|-----------|
| `docker-compose.yml` | Open5GS + Grafana/InfluxDB/Telegraf jednym `docker compose up` (gNB osobno w k8s) | [sekcja 2](#2-szybki-start-wszystko-w-compose-jednym-poleceniem--gnb-z-o1-w-k8s) |
| `open5gs/` | sam rdzeń Open5GS (10.53.1.2) w docker compose, budowany z `ocudu/docker/open5gs` | |
| `k8s/` | gNB (+ Grafana, opcjonalnie cały Open5GS) w Kubernetesie, skrypt `deploy.ps1` / `deploy.sh` | [k8s/README.md](k8s/README.md) |
| `o1/` | O1 adapter + serwer NETCONF w docker compose | [o1/README.md](o1/README.md) |
| `netconf/` | serwer NETCONF budowany ze źródeł w docker compose | [netconf/README.md](netconf/README.md) |
| `ocudu/`, `ocudu_helm/`, `ocudu_o1_adapter/`, `ocudu_netconf/` | sklonowane repozytoria upstream (poza gitem tego repo) | |

Wszystkie komendy poniżej uruchamiaj w PowerShellu z katalogu głównego repo.

## 0. Wymagania

- Docker Desktop z włączonym Kubernetesem (Settings -> Kubernetes), kontekst `docker-desktop`
- `kubectl`, `helm` (4.x), Git for Windows (`deploy.ps1` uruchamia `deploy.sh` przez Git Bash)

Szczegóły (zasoby, k3d na Ubuntu) w [k8s/README.md, sekcja 0](k8s/README.md#0-prerequisites).

## 1. Klonowanie repozytoriów (jednorazowo)

```powershell
git clone https://gitlab.com/ocudu/ocudu.git
git -C ocudu checkout release_26_10

git clone https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_o1_adapter.git
git clone https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_netconf.git   # tylko do kroku 3.4
```

`ocudu_helm` klonuje sam `deploy.sh` (przypięty commit). `open5gs/docker-compose.yml` korzysta z plików
z klonu `ocudu` (`ocudu/docker/open5gs`: Dockerfile, konfiguracja, `subscriber_db.csv`), więc `ocudu` musi leżeć obok.

## 2. Szybki start: wszystko w compose jednym poleceniem + gNB z O1 w k8s

`docker-compose.yml` w katalogu głównym łączy (`include`) `open5gs/docker-compose.yml`,
`ocudu/docker/docker-compose.ui.yml` i `k8s/compose-ui-gnb-k8s.yml` w jeden projekt `ocudu-stack`.
To zastępuje krok 3.1 i część compose wariantu 3.2 b2. Kroki 3.x pokazują to samo osobno i z innymi wariantami.

```powershell
docker compose up -d --build     # open5gs_5gc (10.53.1.2), telegraf, influxdb, grafana (http://localhost:3300)
docker compose ps                # czekaj, aż open5gs_5gc będzie (healthy)
.\k8s\deploy.ps1 gnb-o1          # gNB + netconf-server + o1-adapter w k8s (szczegóły: 3.2 b2)

.\k8s\deploy.ps1 down            # sprzątanie
docker compose down -v
```

Nie uruchamiaj tego razem z osobnymi plikami z kroków 3.1 / 3.2 b / 3.2 b2, bo mają te same nazwy kontenerów i podsieci.
Wymaga Compose >= 2.24.

## 3. Uruchomienie krok po kroku

Kolejność ma znaczenie tylko w kroku 3.1 -> 3.2 (gNB potrzebuje działającego AMF). Kroki 3.3 i 3.4 są niezależne
od reszty: tamten O1 adapter nie jest podpięty do gNB (podpięty jest w wariancie b2).

### 3.1 Rdzeń Open5GS (docker compose)

```powershell
docker compose -f .\open5gs\docker-compose.yml up -d     # open5gs_5gc, 10.53.1.2
docker compose -f .\open5gs\docker-compose.yml ps        # czekaj na (healthy)
```

### 3.2 gNB w Kubernetesie (wybierz jeden wariant)

**a) gNB + Grafana w k8s**

```powershell
.\k8s\deploy.ps1 gnb
```

Grafana: http://localhost:30001 (admin / admin1234).

**b) Lite: tylko gNB w k8s, Grafana + InfluxDB + Telegraf w docker compose**

```powershell
.\k8s\deploy.ps1 gnb-lite
docker compose -f .\ocudu\docker\docker-compose.ui.yml -f .\k8s\compose-ui-gnb-k8s.yml up -d
```

Grafana: http://localhost:3300.

**b2) Jak b), ale z O1: serwer NETCONF i O1 adapter jako sidecary w podzie gNB**

```powershell
.\k8s\deploy.ps1 gnb-o1
docker compose -f .\ocudu\docker\docker-compose.ui.yml -f .\k8s\compose-ui-gnb-k8s.yml up -d   # opcjonalnie Grafana
```

Konfiguracja gNB pochodzi wtedy z NETCONF (`o1Config` w `k8s/ocudu-gnb-o1-values.yaml`), a zmiana wymagająca
restartu (np. `gNBCUName`) restartuje gNB wewnątrz kontenera: `/config-healthy` przechodzi `NOK` -> `OK`, a licznik
RESTARTS w k8s się nie zmienia. NETCONF: `localhost:30830` (`root` / `root`).

Zmiana konfiguracji z wnętrza kontenera `netconf-server`. Potrzebne jest `-it` (samo `-i` nie daje terminala,
więc nie ma promptu, a nano nie działa):

```powershell
kubectl -n ran exec -it deploy/gnb-ocudu-gnb -c netconf-server -- bash
```

```bash
sysrepocfg -X -d running -f xml > /tmp/cfg.xml     # eksport obecnej konfiguracji
nano /tmp/cfg.xml                                  # zmień wartości, np. gNBCUName, ssb_block_power_dbm
sysrepocfg --edit=/tmp/cfg.xml -d running -f xml   # zapis jako merge -> adapter dostaje powiadomienie
exit
```

Nie używaj `sysrepocfg -E` / `--import` (podmiana całego datastore'u): na tym obrazie kończą się błędem nawet bez
zmian (`Failed to find metadata "yang:orig-value" ... rv_sequence`). Nie zmieniaj `<id>`, bo zmiana klucza tworzy
nowy obiekt. Merge nie usuwa elementów: usunięcie czegoś z pliku nie skasuje tego w datastore.
`gNBCUName` i większość pól powoduje restart gNB; `ssb_block_power_dbm` i `RRMPolicyRatio` są zmieniane w locie.

```powershell
kubectl -n ran logs -f deploy/gnb-ocudu-gnb -c ocudu-gnb          # "gNB exited cleanly, restarting..."
kubectl -n ran logs -f deploy/gnb-ocudu-gnb -c ocudu-o1-adapter   # "Waiting for the reboot" / "Updating SSB power"
kubectl -n ran exec deploy/gnb-ocudu-gnb -c ocudu-gnb -- curl -s localhost:5000/config-healthy
```

W tym wariancie nie uruchamiaj kroku 3.3 (osobny O1 adapter w compose nie jest podpięty do gNB).
Szczegóły: [k8s/README.md](k8s/README.md#o1-variant-gnb--netconf-server--o1-adapter-in-one-pod).

**c) Wszystko w Kubernetesie, łącznie z Open5GS (wtedy pomiń krok 3.1)**

```powershell
.\k8s\deploy.ps1 up
```

Grafana: http://localhost:30001.

Logi gNB: `kubectl -n ran logs -f deploy/gnb-ocudu-gnb`.

### 3.3 O1 adapter + serwer NETCONF (docker compose)

```powershell
docker compose -f .\o1\docker-compose.yml up --build -d
curl.exe -i http://localhost:5000/config-healthy                          # 200 {"success":"OK"}
docker exec o1_adapter cat /etc/config/gnb-config.yml                      # konfiguracja wygenerowana z NETCONF
```

Wenątrz kontenera o1_netconf wpisz:
```powershell
netopeer2-cli
connect --login root  # password: root
get-config --source=running
sysrepocfg --edit=/tmp/zmiana.xml --datastore running --format xml # merge; -E/--import fails, see variant b2
```

NETCONF: `localhost:830`, `root` / `root`. Domyślnie używany jest obraz nightly serwera NETCONF. Bez gNB i SMO adapter
loguje co kilka sekund `WS connection error` i `VES HTTP request failed`, co jest normalne.

### 3.4 (opcjonalnie) Serwer NETCONF ze źródeł

Pierwsze budowanie kompiluje libyang, sysrepo i netopeer2, więc trwa długo.

Samodzielny serwer:

```powershell
docker compose -f .\netconf\docker-compose.yml up --build -d
docker exec -it ocudu_netconf netopeer2-cli
```

Ten serwer i ten z kroku 3.3 zajmują port 830 na hoście, więc nie uruchamiaj obu naraz (albo ustaw
`$env:NETCONF_PORT="8300"` przed jednym z nich).

Zamiast tego możesz uruchomić O1 adapter na obrazie zbudowanym ze źródeł:

```powershell
docker compose -f .\netconf\docker-compose.yml build
$env:NETCONF_IMAGE="ocudu-netconf:local"; docker compose -f .\o1\docker-compose.yml up --build -d
Remove-Item Env:NETCONF_IMAGE
```

## 4. Sprzątanie

Zatrzymuj elementy w odwrotnej kolejności. Każda komenda pomija to, czego nie uruchomiłeś.

```powershell
# 3.4 / 3.3: NETCONF i O1 (-v usuwa też zapisaną konfigurację NETCONF i wygenerowany gnb-config.yml)
docker compose -f .\netconf\docker-compose.yml down -v
docker compose -f .\o1\docker-compose.yml down -v

# 3.2: gNB, Grafana i Open5GS w k8s (wszystkie warianty: a, b, b2, c)
.\k8s\deploy.ps1 down
docker compose -f .\ocudu\docker\docker-compose.ui.yml -f .\k8s\compose-ui-gnb-k8s.yml down -v   # tylko warianty b i b2

# 3.1: rdzeń Open5GS
docker compose -f .\open5gs\docker-compose.yml down

# krok 2: wspólny docker-compose.yml (Open5GS + Grafana/InfluxDB/Telegraf)
docker compose down -v
```

Sprawdzenie, że nic nie zostało:

```powershell
docker ps -a
kubectl get ns          # nie powinno być ran, open5gs, monitoring
```

### Pełne sprzątanie (obrazy i cache budowania)

Komendy `down` powyżej zostawiają obrazy, więc kolejne uruchomienie jest szybkie. Żeby zwolnić miejsce na dysku,
dodatkowo uruchom:

```powershell
docker compose -f .\o1\docker-compose.yml down -v --rmi all            # ocudu-o1-adapter:local + obraz nightly NETCONF
docker compose -f .\netconf\docker-compose.yml down -v --rmi all       # ocudu-netconf:local
docker compose -f .\open5gs\docker-compose.yml down --rmi all
docker builder prune -f                                                # cache budowania (netconf: kilka GB)
```

Sklonowane repozytoria (`ocudu*`) możesz po prostu usunąć. Krok 1 sklonuje je ponownie.
