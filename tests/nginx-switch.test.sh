#!/usr/bin/env bash
# Проверка «install.sh nginx» на копии конфига с сервера DurdenVPN: nginx на хосте
# раздаёт копию кабинета из папки (root /srv/cabinet), /api/ и /lava-webhook — в
# бота на 127.0.0.1:8080, контейнер кабинета опубликован на 3020.
# nginx запускается отдельным экземпляром (свой nginx.conf), системный не трогается.
# Нужны Docker, nginx, curl, openssl и свободные порты 80/443. Запуск: sudo bash tests/nginx-switch.test.sh
# shellcheck disable=SC2016,SC2034  # проверки передаются строкой в eval
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=ghcr.io/bedolaga-dev/bedolaga-cabinet:latest
D=www.durdenvpn.org
T=$(mktemp -d /tmp/durden-nginx-test.XXXXXX)
N=$T/nginx
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); printf '  \e[32m✓\e[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \e[31m✗ %s\e[0m\n' "$*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n\e[1m%s\e[0m\n' "$*"; }
C=(curl -sk -m 20 --noproxy '*' --resolve "$D:443:127.0.0.1" --resolve "$D:80:127.0.0.1")
body() { "${C[@]}" "https://$D$1"; }
hdrs() { "${C[@]}" -o /dev/null -D - -H 'Accept-Encoding: gzip' "https://$D$1" | tr '[:upper:]' '[:lower:]' | tr -d '\r'; }
run() { NGINX_MAIN_CONF=$N/nginx.conf APP_DIR=$T/app PUBLIC_URL=https://127.0.0.1 bash "$ROOT/install.sh" "$@"; }

cleanup() {
  nginx -c "$N/nginx.conf" -s stop >/dev/null 2>&1 || true
  docker unpause cabinet_frontend >/dev/null 2>&1 || true
  docker rm -f remnawave_bot cabinet_frontend cabinet_frontend__durden_old >/dev/null 2>&1 || true
  docker compose -f "$T/cabinet/docker-compose.yml" -p durdencab down >/dev/null 2>&1 || true
  docker network rm durden_t2_bot >/dev/null 2>&1 || true
  docker image rm durden-test/fakebot:2 >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap '[[ -n ${KEEP:-} ]] || cleanup' EXIT

if ss -ltn | grep -qE ':(80|443)\s'; then
  echo 'Порты 80/443 заняты — тест пропущен.'
  exit 0
fi

section 'Копия сервера: бот :8080, кабинет :3020, nginx раздаёт /srv/cabinet'
docker image inspect "$IMG" >/dev/null 2>&1 || docker pull -q "$IMG"
mkdir -p "$T/bot" "$T/cabinet" "$T/srv/.well-known/acme-challenge" "$N/sites-enabled" "$T/le"
docker tag "$IMG" durden-test/fakebot:2
cp "$ROOT/tests/fixtures/landing.json" "$T/bot/landing.json"
cat >"$T/bot/default.conf" <<'EOF'
server {
    listen 8080;
    location = /health/unified { default_type application/json; return 200 '{"status":"ok"}'; }
    location = /cabinet/landing/landing { default_type application/json; alias /srv/landing.json; }
    location = /lava-webhook { default_type application/json; return 200 '{"lava":true}'; }
    location / { default_type application/json; return 200 '{}'; }
}
EOF
docker network create durden_t2_bot >/dev/null
docker run -d --name remnawave_bot --network durden_t2_bot -p 8080:8080 -v "$T/bot/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$T/bot:/srv:ro" durden-test/fakebot:2 >/dev/null

# Кабинет как в docker-compose.yml репозитория кабинета: порт 3020, своя сеть.
docker run --rm --entrypoint cat "$IMG" /etc/nginx/conf.d/default.conf | grep -v 'listen \[::\]:80' >"$T/cabinet/default.conf"
cat >"$T/cabinet/docker-compose.yml" <<EOF
services:
  cabinet-frontend:
    image: $IMG
    container_name: cabinet_frontend
    restart: unless-stopped
    volumes:
      - ./default.conf:/etc/nginx/conf.d/default.conf:ro
    ports:
      - '3020:80'
EOF
docker compose -f "$T/cabinet/docker-compose.yml" -p durdencab up -d --quiet-pull >/dev/null

# Копия сборки в папке, как после «docker cp … ./cabinet-dist», и свои файлы владельца.
tmp=$(docker create "$IMG")
docker cp "$tmp:/usr/share/nginx/html/." "$T/srv/" >/dev/null
docker rm "$tmp" >/dev/null
echo 'google-site-verification: google123.html' >"$T/srv/google123.html"
echo 'acme-token' >"$T/srv/.well-known/acme-challenge/test.txt"
echo 'x' >"$T/srv/weird name.txt"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$D" -keyout "$T/le/privkey.pem" -out "$T/le/fullchain.pem" 2>/dev/null
openssl dhparam -dsaparam -out "$T/le/ssl-dhparams.pem" 2048 2>/dev/null
printf 'ssl_session_cache shared:le_nginx_SSL:10m;\nssl_session_timeout 1440m;\nssl_protocols TLSv1.2 TLSv1.3;\n' >"$T/le/options-ssl-nginx.conf"

# Конфиг сайта — как прислал владелец (с комментариями certbot).
cat >"$N/sites-enabled/default" <<EOF
##
# You should look at the following URL's in order to grasp a solid understanding
# of Nginx configuration files in order to fully unleash the power of Nginx.
##
server {
    listen 80 default_server;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
    server_name _;
    location / { try_files \$uri \$uri/ =404; }
}

server {
    server_name $D;
    root $T/srv;
    index index.html;

    location = /lava-webhook {
        proxy_pass http://127.0.0.1:8080/lava-webhook;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        try_files \$uri /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Кэширование статики
    location ~* \.(?:ico|css|js|gif|jpe?g|png|woff2?|eot|ttf|svg)\$ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public";
    }

    listen 443 ssl; # managed by Certbot
    ssl_certificate $T/le/fullchain.pem; # managed by Certbot
    ssl_certificate_key $T/le/privkey.pem; # managed by Certbot
    include $T/le/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam $T/le/ssl-dhparams.pem; # managed by Certbot
}

server {
    if (\$host = $D) {
        return 301 https://\$host\$request_uri;
    } # managed by Certbot

    listen 80;
    server_name $D;
    return 404; # managed by Certbot
}
EOF
cat >"$N/nginx.conf" <<EOF
user root;
worker_processes 1;
pid $N/nginx.pid;
error_log $N/error.log warn;
events { worker_connections 256; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    gzip on;
    client_body_temp_path $N/tmp_body; proxy_temp_path $N/tmp_proxy; fastcgi_temp_path $N/tmp_fcgi;
    uwsgi_temp_path $N/tmp_uwsgi; scgi_temp_path $N/tmp_scgi;
    include $N/sites-enabled/*;
}
EOF
nginx -c "$N/nginx.conf" -t >/dev/null 2>&1 || { nginx -c "$N/nginx.conf" -t; exit 1; }
nginx -c "$N/nginx.conf"
for _ in $(seq 1 20); do "${C[@]}" -fsS -o /dev/null "https://$D/" 2>/dev/null && break; sleep 1; done
ORIG_SUM=$(sha256sum "$N/sites-enabled/default" | cut -d' ' -f1)

check 'до: сайт отдаёт старую копию из папки' '[[ $(body /buy/landing) == *"id=\"root\""* && $(body /robots.txt) == *"id=\"root\""* ]]'

section 'install.sh — контейнер готов, но сайт его не видит'
if run >"$T/install.log" 2>&1; then ok 'install.sh отработал'; else bad 'install.sh упал'; cat "$T/install.log"; fi
check 'install.sh подсказал команду nginx' 'grep -q "install.sh nginx" "$T/install.log"'

section 'install.sh nginx'
if run nginx >"$T/nginx.log" 2>&1; then ok 'install.sh nginx отработал'; else bad 'install.sh nginx упал'; cat "$T/nginx.log"; fi
ASSET=$(body /login | grep -o '/assets/[^"]*\.js' | head -n1)
check '/buy/landing — быстрый лендинг' '[[ $(body /buy/landing) == *"id=\"lp-data\""* ]]'
check 'файлы новой сборки открываются и сжаты' '[[ -n $ASSET && $(hdrs "$ASSET") == *"200"* && $(hdrs "$ASSET") == *"content-encoding: gzip"* ]]'
check 'у бандла один Cache-Control: immutable' '[[ $(hdrs "$ASSET" | grep -c "^cache-control:") == 1 && $(hdrs "$ASSET") == *immutable* ]]'
check 'HSTS и robots.txt из контейнера' '[[ $(hdrs /) == *strict-transport-security* && $(body /robots.txt) == *Sitemap* ]]'
check '/api/ по-прежнему идёт в бота' '[[ $(body /api/cabinet/landing/landing) == *tariffs* ]]'
check '/lava-webhook по-прежнему идёт в бота' '[[ $(body /lava-webhook) == *lava* ]]'
check '/health/unified теперь отвечает ботом' '[[ $(body /health/unified) == *"\"status\":\"ok\""* ]]'
check 'свой файл из папки отдаётся как раньше' '[[ $(body /google123.html) == *google-site-verification* ]]'
check '/.well-known/ из папки сохранён' '[[ $(body /.well-known/acme-challenge/test.txt) == acme-token* ]]'
check 'о файле с пробелом в имени предупредили' 'grep -q "weird name.txt" "$T/nginx.log"'
check 'статический regex-блок удалён, /api/ и lava на месте' '! grep -q "expires 1y" "$N/sites-enabled/default" && grep -q "location /api/" "$N/sites-enabled/default" && grep -q "location = /lava-webhook" "$N/sites-enabled/default"'
check 'сервер по умолчанию не тронут' 'grep -q "try_files \$uri \$uri/ =404" "$N/sites-enabled/default"'
check 'резервная копия конфига есть' 'ls "$T"/app/backup/nginx-default-* >/dev/null 2>&1'

section 'Повторный запуск ничего не ломает'
SUM=$(sha256sum "$N/sites-enabled/default" | cut -d' ' -f1)
if run nginx >"$T/nginx2.log" 2>&1; then bad 'повторный запуск должен был отказаться'; else ok 'повторный запуск отказался'; fi
check 'конфиг не изменился' '[[ $(sha256sum "$N/sites-enabled/default" | cut -d" " -f1) == "$SUM" ]]'
check 'сайт работает' '[[ $(body /buy/landing) == *"id=\"lp-data\""* ]]'

section 'Сайт не открылся после переключения → конфиг возвращается'
backups=("$T"/app/backup/nginx-default-*)
cp "${backups[0]}" "$N/sites-enabled/default"
nginx -c "$N/nginx.conf" -s reload
sleep 1
docker pause cabinet_frontend >/dev/null
if run nginx >"$T/nginx3.log" 2>&1; then bad 'переключение на недоступный контейнер не упало'; else ok 'переключение остановлено'; fi
docker unpause cabinet_frontend >/dev/null
check 'конфиг вернулся к исходному' '[[ $(sha256sum "$N/sites-enabled/default" | cut -d" " -f1) == "$ORIG_SUM" ]]'
check 'сайт работает как до переключения' '[[ $(body /buy/landing) == *"id=\"root\""* ]]'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
((FAIL == 0))
