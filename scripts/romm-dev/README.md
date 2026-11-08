# Development RomM

A real RomM (installed from source) to develop and test Borne without touching a personal server.
Tested with RomM 5.4.1. The games are generated **dummy files**: no real ROMs.

## Setup (Ubuntu / Debian)

```bash
sudo apt install mariadb-server redis-server nginx libmariadb-dev libpq-dev libmagic1
pip install "uv>=0.13.4,<0.14"

git clone --depth 1 --branch 5.4.1 https://github.com/rommapp/romm
cd romm && uv python install 3.14 && uv sync --all-extras --dev

# Database
sudo mysql -e "CREATE DATABASE romm; CREATE USER 'romm'@'localhost' IDENTIFIED BY 'rommdev';
               GRANT ALL ON romm.* TO 'romm'@'localhost';"

# Test library (29 dummy games: NES, Mega Drive including 2 zips and 1 large file, GameCube, PS2, Switch)
python3 ../borne/scripts/romm-dev/make_test_library.py ~/romm-data
```

Minimal `.env` at the root of `romm/` (the `env.template` file leaves empty values that RomM 5.4 cannot parse):

```dotenv
ROMM_BASE_PATH=/home/<you>/romm-data
ROMM_BASE_URL=http://127.0.0.1:8080
ROMM_DB_DRIVER=mariadb
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=romm
DB_USER=romm
DB_PASSWD=rommdev
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
ROMM_AUTH_SECRET_KEY=<openssl rand -hex 32>
DEV_MODE=true
DEV_HOST=127.0.0.1
DEV_PORT=5000
```

## Running

```bash
cd romm/backend && set -a && . ../.env && set +a
uv run python3 main.py &                                   # API on :5000
W="--path $PWD --worker-class handler.rq_worker.RomMWorker --connection-class handler.redis_handler.RomMRedis"
PYTHONPATH=$PWD RQ_REDIS_URL=redis://127.0.0.1:6379/0 uv run rq worker $W --with-scheduler high default low &
PYTHONPATH=$PWD RQ_REDIS_URL=redis://127.0.0.1:6379/0 uv run rq worker $W scans &
```

In production RomM serves covers through nginx, not through the API: `nginx-romm-dev.conf` reproduces that
setup on **http://127.0.0.1:8080** (the address to use in Borne and in the tests). Adjust the `alias` path.

First account (admin), second account, scan:

```bash
curl -X POST http://127.0.0.1:8080/api/users -H 'Content-Type: application/json' \
  -d '{"username":"light","email":"light@example.test","password":"borne-dev","role":"admin"}'
curl -u light:borne-dev -X POST http://127.0.0.1:8080/api/users -H 'Content-Type: application/json' \
  -d '{"username":"guest","email":"guest@example.test","password":"borne-dev","role":"editor"}'
curl -u light:borne-dev -X POST http://127.0.0.1:8080/api/tasks/scan -H 'Content-Type: application/json' -d '{}'
```

## End-to-end test

```bash
python3 tests/integration_romm.py core/target/release/borne http://127.0.0.1:8080 light borne-dev guest borne-dev
```
