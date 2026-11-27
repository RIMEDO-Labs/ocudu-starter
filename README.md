# rimedo-ocudu

Lokalne środowisko OCUDU na Windows 11 + Docker Desktop (z włączonym Kubernetesem):
rdzeń Open5GS w docker compose, gNB w Kubernetesie (docelowo z USRP B210 przez UHD, bez sprzętu: ru_dummy + test_ue),
Grafana oraz O1 adapter z serwerem NETCONF.

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
z klonu `ocudu` (`ocudu/docker/open5gs`: Dockerfile, konfiguracja; abonenci są w `open5gs/subscriber_db.csv`), więc `ocudu` musi leżeć obok.

## 2. Szybki start: wszystko w compose jednym poleceniem + gNB z O1 w k8s

`docker-compose.yml` w katalogu głównym łączy (`include`) `open5gs/docker-compose.yml`,
`ocudu/docker/docker-compose.ui.yml` i `k8s/compose-ui-gnb-k8s.yml` w jeden projekt `ocudu-stack`.
To zastępuje krok 3.1 i część compose wariantu 3.2 b2. Kroki 3.x pokazują to samo osobno i z innymi wariantami.

```powershell
# w osobnym oknie: B210 podpięty do VM Dockera przez usbipd (sekcja 5), okno zostaw otwarte
usbipd attach --wsl --busid <BUSID> --auto-attach

docker compose up -d --build     # open5gs_5gc (10.53.1.2), telegraf, influxdb, grafana (http://localhost:3300)
docker compose ps                # czekaj, aż open5gs_5gc będzie (healthy)
.\k8s\deploy.ps1 gnb-o1-b210     # gNB z USRP B210 + netconf-server + o1-adapter w k8s (szczegóły: sekcja 5)

.\k8s\deploy.ps1 down            # sprzątanie
docker compose down -v
```

Bez sprzętu użyj `.\k8s\deploy.ps1 gnb-o1` (ru_dummy + test_ue, szczegóły: 3.2 b2); reszta bez zmian.

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

# 3.2 i 5: gNB, Grafana i Open5GS w k8s (wszystkie warianty: a, b, b2, c, B210)
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

## 5. gNB z USRP B210 (UHD)

Wariant docelowy: jak 3.2 b2 (gNB + netconf-server + o1-adapter w jednym podzie, rdzeń z compose), ale zamiast
`ru_dummy` + `test_ue` gNB używa B210 jako frontu radiowego (`ru_sdr`, split 8). Komórka: **n3 FDD 5 MHz**, SCS 15 kHz,
DL ARFCN 368500 (1842,5 MHz), UL 1747,5 MHz, PLMN 00101, TAC 7, SST 1. Pliki: `k8s/ocudu-gnb-o1-b210-values.yaml` nakładany na
`ocudu-gnb-o1-values.yaml` oraz `deploy.ps1 gnb-o1-b210`.

Różnice względem `gnb-o1`:

- obraz `gnb-uhd` zamiast `gnb-dpdk` (ten drugi nie ma UHD); dla buildu 20261007 nie ma wersji `gnb-uhd`, więc użyty
  jest najbliższy stabilny `ubuntu-24.04-avx2-20261016_de11750b-stable` (UHD 4.6.0.0, firmware i FPGA B210 w obrazie),
- kontener `ocudu-gnb` jest `privileged` i działa jako root (dostęp do `/dev/bus/usb`); sidecary O1 zostają na uid 1000,
- w O1 (`ocudu_gnbdufunction_extensions`) jest `ocudu_ru_sdr_extensions` (uhd, `type=b200`, 7,68 MHz, sc12, 512 ramek RX,
  256 TX, tx_gain 80, rx_gain 40), test mode jest wyłączony, a estymator PUSCH kompensuje CFO zegara B210,
- pasmo jest ustawione jawnie (`band` w `ocudu_nrcelldu_base_extensions`): bez tego gNB wybiera pierwsze pasujące do
  ARFCN (dla ARFCN z n78 jest to n77, którego telefony obsługujące tylko n78 nie widzą),
- najwęższa możliwa komórka NR (5 MHz, 7,68 Msps), żeby przez usbipd szło jak najmniej danych. Przy n78 TDD 10 MHz
  (15,36 Msps) gNB gubił bufory RX i wszystkie PRACH. n3 obsługuje większość telefonów 5G (np. Galaxy A52 5G SM-A526B),
- `max_proc_delay` 8 (domyślnie 5) i `max_request_headroom_slots` 4 (domyślnie 0) w `ocudu_expert_phy_extensions`:
  usbipd dostarcza próbki RX paczkami i zegar slotów skacze. 6 gubiło dużo buforów RX, przy 10 RAR nie mieścił się
  w oknie 10 ms (maksimum dla 15 kHz).

### 5.0 Szybkie uruchomienie (np. po restarcie komputera)

Sprawdzona kolejność, szczegóły w 5.1 i 5.2:

1. Docker Desktop działa i ma włączony Kubernetes (Settings -> Kubernetes -> Enable Kubernetes).
   `kubectl get nodes` ma pokazać `docker-desktop Ready`. Błąd `127.0.0.1:6443 ... actively refused` oznacza, że
   Kubernetes jest wyłączony albo jeszcze startuje.
2. Rdzeń + Grafana: `docker compose up -d --build`. W `docker compose ps` `open5gs_5gc` ma być `(healthy)`.
3. Osobne okno, zostaw otwarte: `wsl -d Ubuntu-24.04 -- sleep infinity`
4. Osobne okno, zostaw otwarte: `usbipd attach --wsl --hardware-id 2500:0020 --auto-attach`.
   `usbipd list` ma pokazać B210 jako `Attached`.
5. `.\k8s\deploy.ps1 gnb-o1-b210`. Skrypt ładuje firmware i ma wypisać `B210 ready` (serial B210, np. `3113F10`),
   potem instaluje gNB.
6. `kubectl -n ran logs -f deploy/gnb-ocudu-gnb -c ocudu-gnb`
7. UE (karta Amarisoft z `open5gs/subscriber_db.csv`): tryb 5G SA, APN `internet`, ręczny wybór sieci 00101.
   Rejestrację widać w `docker logs -f open5gs_5gc`.

Po uśpieniu komputera gNB dalej działa, ale strumień z B210 jest zerwany (`exceeded maximum number of timed out
receive calls`, gNB rozłącza się z AMF): uruchom `.\k8s\deploy.ps1 gnb-o1-b210` jeszcze raz. Na czas testów wyłącz
usypianie (`powercfg /change standby-timeout-ac 0`).

### 5.1 Podpięcie B210 do Docker Desktop (usbipd-win)

Węzeł k8s Docker Desktop to VM WSL2, więc USB trzeba do niej przekazać przez [usbipd-win](https://github.com/dorssel/usbipd-win)
(`winget install usbipd`). B210 podłącz do portu USB 3.

```powershell
usbipd list                                         # B210: VID:PID 2500:0020 ("WestBridge" przed firmware, "USRP B200" po)
usbipd bind --busid <BUSID>                         # jednorazowo, PowerShell jako Administrator

# okno 1 (zostaw otwarte): utrzymuje działającą dystrybucję WSL z bashem
wsl -d Ubuntu-24.04 -- sleep infinity

# okno 2 (zostaw otwarte): podpina B210 po VID:PID, także po zmianie BUSID
usbipd attach --wsl --hardware-id 2500:0020 --auto-attach
```

Sprawdzone pułapki:

- **Podpinaj po `--hardware-id 2500:0020`, nie po `--busid`.** Po załadowaniu firmware B210 wraca pod innym BUSID
  (np. `4-5` -> `4-13`), a pętla `--busid ... --auto-attach` dalej czeka na stary numer (`Device not found`).
- **Potrzebna jest działająca dystrybucja z bashem** (np. Ubuntu-24.04). Gdy działa tylko `docker-desktop`, pętla
  kończy się od razu błędem `can't execute 'bash'`, a gdy Ubuntu jest zatrzymane, błędem
  `The selected WSL distribution is not running`. Urządzenie podpięte przez Ubuntu jest widoczne w całej VM WSL2,
  także dla Dockera i k8s.
- W `usbipd list` B210 ma być w stanie `Attached`. `Shared` oznacza, że nie jest podpięty do VM.
- **Po restarcie Docker Desktop / VM WSL2 stan `Attached` bywa nieaktualny**: urządzenia nie ma w VM
  (`wsl -d Ubuntu-24.04 -- lsusb`), a pętla attach zgłasza `Device busy (exported)`. Pomaga
  `usbipd detach --hardware-id 2500:0020`, po czym pętla `--auto-attach` podpina B210 od nowa.

`--auto-attach` jest potrzebne: przy ładowaniu firmware B210 odłącza się i podłącza ponownie z nowym numerem
urządzenia. Kontener uprzywilejowany widzi tylko te węzły `/dev`, które istniały przy jego starcie, dlatego
`deploy.sh gnb-o1-b210` przed instalacją charta ładuje firmware (`uhd_find_devices` w jednorazowym kontenerze
z obrazem `gnb-uhd`) i czeka, aż B210 wróci. Bez B210 skrypt kończy się komunikatem `No B210 in the Docker VM`.

Sprawdzenie ręczne:

```powershell
docker run --rm --privileged --user 0 -v /dev/bus/usb:/dev/bus/usb --entrypoint uhd_usrp_probe `
  registry.gitlab.com/ocudu/ocudu/images/gnb-uhd:ubuntu-24.04-avx2-20261016_de11750b-stable --args type=b200
```

### 5.2 Uruchomienie

```powershell
docker compose up -d --build                     # albo tylko rdzeń: docker compose -f .\open5gs\docker-compose.yml up -d
.\k8s\deploy.ps1 gnb-o1-b210
kubectl -n ran logs -f deploy/gnb-ocudu-gnb -c ocudu-gnb
kubectl -n ran exec deploy/gnb-ocudu-gnb -c ocudu-gnb -- cat /etc/config/gnb-config.yml   # sekcja ru_sdr
```

Po odłączeniu lub wyłączeniu B210 (traci firmware) uruchom `.\k8s\deploy.ps1 gnb-o1-b210` jeszcze raz, a jeśli
chart się nie zmienił, dodatkowo `kubectl -n ran rollout restart deploy/gnb-ocudu-gnb`.

Parametry radia (`tx_gain`, `rx_gain`, `device_args`, `srate`, ...) zmieniasz przez NETCONF jak w 3.2 b2,
w `ocudu_gnbdufunction_extensions/ocudu_ru_sdr_extensions` w `GNBDUFunction` (`<id>du1</id>`); adapter restartuje gNB.

Uwagi:

- To nadajnik w paśmie n3 (licencjonowanym). Testuj na kablu z tłumikami albo w komorze ekranowanej i dobierz
  `tx_gain` do swojego układu.
- Telefon / moduł potrzebuje karty SIM wpisanej do `open5gs/subscriber_db.csv` (IMSI z PLMN 00101, K, OPc;
  jest tam już karta Amarisoft IMSI 001010123456789) i obsługi n3 SA. Samsung włącza SA tylko dla operatorów znanych z firmware (CSC), więc z kartą
  00101 może w ogóle nie próbować; stan radia widać w Service Mode (`*#0011#`). W UE: tryb 5G SA, APN/DNN `internet`,
  ręczny wybór sieci 00101. Po zmianie pliku zrestartuj rdzeń
  (`docker compose -f .\open5gs\docker-compose.yml up -d --force-recreate`).
- **Przez usbipd UE się nie podłączył.** usbip przez wirtualną sieć VM ma za duże i zbyt nieregularne opóźnienia
  nawet dla 5 MHz: około 100–200 Late/s, spóźnione `UL/DL_TTI.request` w co szóstym slocie, gubione PRACH. gNB
  odebrał pojedyncze PRACH, ale nie zdążył z RAR (`Could not transmit RAR within the window`). Ok. 70% CPU gNB to
  czas jądra (obsługa USB/IP), throttlingu CPU nie ma. Do testów z telefonem uruchom stack na natywnym Linuksie (k3d, [k8s/README.md, sekcja 0a](k8s/README.md#0a-alternative-ubuntu-2604--k3d-not-tested-yet)).
  Na k3d węzeł jest kontenerem: utwórz klaster z `--volume /dev/bus/usb:/dev/bus/usb@server:0`.
- Ostrzeżenia `Scheduling priority ... Not enough privileges` są na Docker Desktop normalne (jak w innych wariantach).

Ten wariant przetestowano bez podłączonego B210: adapter generuje `ru_sdr` (bez `ru_dummy` i `test_mode`), gNB
ładuje UHD 4.6.0.0 i kończy się `No devices found` (pod w CrashLoopBackOff). Praca z fizycznym B210 nie była jeszcze
sprawdzona.
