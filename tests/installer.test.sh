#!/usr/bin/env bash
# Проверка install.sh на имитации сервера в Docker (нужен запущенный Docker):
#   - «бот» remnawave_bot в своей сети (отвечает на /health/unified и API лендинга);
#   - кабинет из официального образа, запущенный через docker compose, как в README кабинета;
#   - внешний nginx, который ходит в кабинет по имени контейнера (адрес запоминается
#     при старте) и сжимает только HTML — как на текущем сервере.
# Запуск: sudo bash tests/installer.test.sh
# shellcheck disable=SC2016,SC2034  # проверки передаются строкой в eval
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=ghcr.io/bedolaga-dev/bedolaga-cabinet:latest
NET=durden_test_botnet
NET2=durden_test_extra
T=$(mktemp -d /tmp/durden-installer-test.XXXXXX)
URL=http://127.0.0.1:18080
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); printf '  \e[32m✓\e[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \e[31m✗ %s\e[0m\n' "$*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n\e[1m%s\e[0m\n' "$*"; }
hdrs() { curl -sS -o /dev/null -D - -H 'Accept-Encoding: gzip' "$URL$1" | tr '[:upper:]' '[:lower:]' | tr -d '\r'; }
body() { curl -sS "$URL$1"; }
cid() { docker inspect -f '{{.Id}}' cabinet_frontend 2>/dev/null || true; }
cip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" cabinet_frontend; }
install_sh() { PUBLIC_URL=$URL APP_DIR=$T/app bash "$@"; }

cleanup() {
  docker rm -f remnawave_bot outer_proxy cabinet_frontend cabinet_frontend__durden_old >/dev/null 2>&1 || true
  docker network rm "$NET" "$NET2" >/dev/null 2>&1 || true
  docker image rm durden-test/fakebot:1 durden-test/outer:1 durden-test/broken:1 >/dev/null 2>&1 || true
  [[ -n ${ORIG_ID:-} ]] && docker tag "$ORIG_ID" "$IMG" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

section 'Подготовка имитации сервера'
docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG"
cleanup
mkdir -p "$T/bot" "$T/outer" "$T/cabinet" "$T/broken"
# Отдельные теги, чтобы скрипт не принял «бота» и прокси за кабинет по имени образа.
docker tag "$IMG" durden-test/fakebot:1
docker tag "$IMG" durden-test/outer:1
printf 'FROM %s\nRUN rm /usr/share/nginx/html/index.html\n' "$IMG" >"$T/broken/Dockerfile"
docker build -q -t durden-test/broken:1 "$T/broken" >/dev/null
docker network create --subnet 172.31.250.0/24 "$NET" >/dev/null
docker network create "$NET2" >/dev/null

cp "$ROOT/tests/fixtures/landing.json" "$T/bot/landing.json"
cat >"$T/bot/default.conf" <<'EOF'
server {
    listen 8080;
    location = /health/unified { default_type application/json; return 200 '{"status":"ok"}'; }
    location = /cabinet/landing/landing { default_type application/json; alias /srv/landing.json; }
    location / { default_type application/json; return 200 '{}'; }
}
EOF
docker run -d --name remnawave_bot --network "$NET" -v "$T/bot/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$T/bot:/srv:ro" durden-test/fakebot:1 >/dev/null

# Стандартный конфиг образа без «listen [::]:80»: без IPv6 образ кабинета иначе не стартует.
# Заодно проверяется сценарий «пользователь смонтировал свой конфиг nginx».
docker run --rm --entrypoint cat "$IMG" /etc/nginx/conf.d/default.conf | grep -v 'listen \[::\]:80' >"$T/cabinet/default.conf"
cat >"$T/cabinet/docker-compose.yml" <<EOF
services:
  cabinet-frontend:
    image: $IMG
    container_name: cabinet_frontend
    restart: unless-stopped
    volumes:
      - ./default.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - bot_network
networks:
  bot_network:
    external: true
    name: $NET
EOF
docker compose -f "$T/cabinet/docker-compose.yml" -p cabinet up -d --quiet-pull >/dev/null
docker network connect "$NET2" cabinet_frontend

cat >"$T/outer/default.conf" <<'EOF'
server {
    listen 80;
    gzip on;
    location /api/ { proxy_pass http://remnawave_bot:8080/; }
    location / { proxy_pass http://cabinet_frontend:80; }
}
EOF
docker run -d --name outer_proxy --network "$NET" -p 127.0.0.1:18080:80 \
  -v "$T/outer/default.conf:/etc/nginx/conf.d/default.conf:ro" durden-test/outer:1 >/dev/null
for _ in $(seq 1 30); do curl -fsS -o /dev/null "$URL/" 2>/dev/null && break; sleep 1; done

ASSET=$(body / | grep -o '/assets/index-[^"]*\.js' | head -n1)
check 'до установки: /buy/landing отдаёт тяжёлый кабинет' '[[ $(body /buy/landing) == *"id=\"root\""* ]]'
check 'до установки: JS идёт без сжатия' '[[ $(hdrs "$ASSET") != *"content-encoding: gzip"* ]]'
IP_BEFORE=$(cip)

section 'Установка'
if install_sh "$ROOT/install.sh"; then ok 'install.sh завершился успешно'; else bad 'install.sh упал'; fi
check 'IP контейнера сохранён — внешний nginx не потерял кабинет' '[[ $(cip) == "$IP_BEFORE" ]]'
check '/buy/landing — новый лендинг' '[[ $(body /buy/landing) == *"id=\"lp-data\""* ]]'
check 'лендинг: no-cache и frame-ancestors' '[[ $(hdrs /buy/landing) == *"cache-control: no-cache"* && $(hdrs /buy/landing) == *frame-ancestors* ]]'
check 'JS сжат gzip даже через прокси с HTTP/1.0' '[[ $(hdrs "$ASSET") == *"content-encoding: gzip"* ]]'
check 'у бандла один Cache-Control: immutable' '[[ $(hdrs "$ASSET" | grep -c "^cache-control:") == 1 && $(hdrs "$ASSET") == *"max-age=31536000, immutable"* ]]'
check 'кабинет: index.html no-cache' '[[ $(hdrs /login) == *"no-cache, must-revalidate"* && $(body /login) == *"id=\"root\""* ]]'
check 'HSTS и nosniff' '[[ $(hdrs /) == *strict-transport-security* && $(hdrs /) == *"x-content-type-options: nosniff"* ]]'
check 'robots.txt, sitemap.xml, favicon.ico' '[[ $(body /robots.txt) == *Sitemap* && $(body /sitemap.xml) == *"<urlset"* && $(hdrs /favicon.ico) == *"200 ok"* ]]'
check 'картинки лендинга /lp/ отдаются с кешем' '[[ $(hdrs /lp/logo-128.webp) == *"content-type: image/webp"* && $(hdrs /lp/logo-128.webp) == *"max-age=2592000"* ]]'
check 'несуществующий файл → 404' '[[ $(hdrs /assets/nope.js) == *" 404 "* ]]'
check '/health/unified отвечает ботом' '[[ $(body /health/unified) == *"\"status\":\"ok\""* ]]'
check 'API через внешний прокси не тронут' '[[ $(body /api/cabinet/landing/landing) == *tariffs* ]]'
check 'свой конфиг пользователя сохранён в backup' '[[ -f $T/app/backup/default.conf ]]'
check 'вторая сеть контейнера сохранена' '[[ $(docker inspect -f "{{range \$n, \$s := .NetworkSettings.Networks}}{{\$n}} {{end}}" cabinet_frontend) == *"$NET2"* ]]'
check 'нет оставшегося резервного контейнера' '! docker inspect cabinet_frontend__durden_old >/dev/null 2>&1'
check 'копия скрипта сохранена для update' '[[ -x $T/app/install.sh ]]'

section 'docker compose up -d не откатывает изменения'
ID=$(cid)
docker compose -f "$T/cabinet/docker-compose.yml" -p cabinet up -d >/dev/null 2>&1
check 'контейнер не пересоздан' '[[ $(cid) == "$ID" ]]'
check 'лендинг на месте' '[[ $(body /buy/landing) == *"id=\"lp-data\""* ]]'

section 'Повторный запуск и update'
if install_sh "$T/app/install.sh" update >/dev/null; then ok 'update завершился успешно'; else bad 'update упал'; fi
check 'после update лендинг на месте, IP тот же' '[[ $(body /buy/landing) == *"id=\"lp-data\""* && $(cip) == "$IP_BEFORE" ]]'

section 'Новый образ под тем же тегом (как после docker pull)'
ORIG_ID=$(docker image inspect -f '{{.Id}}' "$IMG")
mkdir -p "$T/newer"
printf 'FROM %s\nRUN echo newer >/usr/share/nginx/html/newer.txt\n' "$IMG" >"$T/newer/Dockerfile"
docker build -q -t "$IMG" "$T/newer" >/dev/null
if install_sh "$T/app/install.sh" >/dev/null 2>&1; then ok 'установка на новый образ прошла'; else bad 'установка на новый образ упала'; fi
check 'контейнер на новом образе' '[[ $(body /newer.txt) == newer* ]]'
ID=$(cid)
docker compose -f "$T/cabinet/docker-compose.yml" -p cabinet up -d >/dev/null 2>&1
check 'docker compose up -d и после смены образа ничего не пересоздал' '[[ $(cid) == "$ID" && $(body /buy/landing) == *"id=\"lp-data\""* ]]'
docker tag "$ORIG_ID" "$IMG"

section 'Сломанный образ → автоматический откат'
ID=$(cid)
if IMAGE=durden-test/broken:1 install_sh "$T/app/install.sh" update >"$T/broken.log" 2>&1; then bad 'установка сломанного образа не упала'; else ok 'установка сломанного образа остановлена'; fi
check 'прежний контейнер вернулся и работает' '[[ $(cid) == "$ID" && $(docker inspect -f "{{.State.Running}}" cabinet_frontend) == true ]]'
check 'сайт работает после отката' '[[ $(body /buy/landing) == *"id=\"lp-data\""* && $(body /login) == *"id=\"root\""* ]]'
check 'политика перезапуска восстановлена' '[[ $(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" cabinet_frontend) == unless-stopped ]]'
check 'резервный контейнер не остался' '! docker inspect cabinet_frontend__durden_old >/dev/null 2>&1'

section 'Прерванный запуск (kill -9 посреди замены)'
docker rename cabinet_frontend cabinet_frontend__durden_old
docker stop -t 2 cabinet_frontend__durden_old >/dev/null
if install_sh "$T/app/install.sh" >/dev/null 2>&1; then ok 'скрипт восстановился и установил'; else bad 'скрипт не справился с остатками'; fi
docker restart outer_proxy >/dev/null
for _ in $(seq 1 20); do curl -fsS -o /dev/null "$URL/" 2>/dev/null && break; sleep 1; done
IP_BEFORE=$(cip)
check 'контейнер работает под своим именем' '[[ $(docker inspect -f "{{.State.Running}}" cabinet_frontend) == true && $(body /buy/landing) == *"id=\"lp-data\""* ]]'

section 'status'
if install_sh "$T/app/install.sh" status >"$T/status.log" 2>&1; then ok 'status отработал'; else bad 'status упал'; fi
check 'status видит лендинг и сжатие' 'grep -q "Быстрый лендинг" "$T/status.log" && grep -q "сжимаются" "$T/status.log"'

section 'uninstall'
if install_sh "$T/app/install.sh" uninstall >/dev/null; then ok 'uninstall завершился успешно'; else bad 'uninstall упал'; fi
check 'вернулся стандартный кабинет' '[[ $(body /buy/landing) == *"id=\"root\""* && $(body /buy/landing) != *lp-data* ]]'
check 'метки docker compose сохранены' '[[ $(docker inspect -f "{{index .Config.Labels \"com.docker.compose.service\"}}" cabinet_frontend) == cabinet-frontend ]]'
check 'IP тот же' '[[ $(cip) == "$IP_BEFORE" ]]'

section 'Чистая установка (кабинета ещё нет)'
docker rm -f cabinet_frontend >/dev/null
if PORT=13020 install_sh "$ROOT/install.sh" >/dev/null 2>&1; then ok 'установка с нуля прошла'; else bad 'установка с нуля упала'; fi
check 'кабинет на 127.0.0.1:13020 с лендингом' '[[ $(curl -sS http://127.0.0.1:13020/buy/landing) == *"id=\"lp-data\""* ]]'
check 'подключён к сети бота' '[[ -n $(cip) ]]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
((FAIL == 0))
