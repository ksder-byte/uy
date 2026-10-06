#!/usr/bin/env bash
# =============================================================================
#  DurdenVPN — кабинет Bedolaga + быстрый лендинг + правильный nginx.
#  Всё в одном файле: лендинг вшит внутрь скрипта.
# =============================================================================
#  Что делает:
#   1. Находит контейнер кабинета (ghcr.io/bedolaga-dev/bedolaga-cabinet).
#      Если его нет — создаёт новый.
#   2. Кладёт в /opt/durden-cabinet быстрый лендинг (/buy/landing) и конфиг
#      nginx: gzip для JS/CSS, вечный кеш бандлов, no-cache для HTML,
#      настоящие 404, robots.txt, sitemap.xml, favicon.ico, HSTS и
#      /health/unified → бот (если бот в той же Docker-сети).
#   3. Пересоздаёт контейнер с теми же именем, сетями, портами, переменными и
#      метками, подключив эти файлы. Внешний прокси (Caddy/Nginx/Traefik) трогать
#      не нужно: он ходит в тот же контейнер, что и раньше.
#   4. Проверяет результат. При любой ошибке сам возвращает прежний контейнер.
#
#  Запуск (от root):
#    bash install.sh             установить или переустановить
#    bash install.sh update      обновить кабинет до свежего образа
#    bash install.sh status      проверить, что всё работает
#    bash install.sh uninstall   вернуть стандартный кабинет без изменений
#
#  Необязательные настройки (переменные окружения):
#    CONTAINER=cabinet_frontend  имя контейнера кабинета, если автопоиск ошибся
#    IMAGE=ghcr.io/bedolaga-dev/bedolaga-cabinet:latest   образ кабинета
#    DOMAIN=www.durdenvpn.org    домен сайта (ссылки в лендинге и sitemap)
#    PORT=3020                   порт на 127.0.0.1 — только для новой установки
#    BOT_URL=auto                бот для /health/unified: auto | none | http://host:8080
#    APP_DIR=/opt/durden-cabinet
# =============================================================================
# shellcheck disable=SC2016  # шаблоны docker inspect ({{...}}) специально в одинарных кавычках
set -Eeuo pipefail
umask 022
shopt -u patsub_replacement 2>/dev/null || true

VERSION='@@VERSION@@'
OFFICIAL_IMAGE='ghcr.io/bedolaga-dev/bedolaga-cabinet:latest'
APP_DIR=${APP_DIR:-/opt/durden-cabinet}
DOMAIN=${DOMAIN:-www.durdenvpn.org}
PUBLIC_URL=${PUBLIC_URL:-https://$DOMAIN}
PORT=${PORT:-3020}
BOT_URL=${BOT_URL:-auto}
MANAGED_LABEL='durden.cabinet.managed'
SEL=''  # ",z" на серверах с SELinux, иначе nginx не прочитает смонтированные файлы
CONF_MOUNT='/etc/nginx/conf.d'
LANDING_MOUNT='/usr/share/nginx/landing'
BACKUP_SUFFIX='__durden_old'

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'; else B='' G='' Y='' R='' N=''; fi
say()  { printf '\n%s\n' "${B}==> $*${N}"; }
ok()   { printf '%s\n' "  ${G}✓${N} $*"; }
warn() { printf '%s\n' "  ${Y}!${N} $*" >&2; }
die()  { printf '%b\n' "\n${R}✗ $*${N}" >&2; exit 1; }
di()   { docker inspect -f "$2" "$1"; }
exists() { docker inspect "$1" >/dev/null 2>&1; }
is_ours() { [[ $(di "$1" "{{index .Config.Labels \"$MANAGED_LABEL\"}}" 2>/dev/null) == 1 ]]; }

# ----------------------------------------------------------------- откат
# Пока идёт замена контейнера, ROLLBACK=1. Если скрипт упадёт или его прервут,
# ловушка EXIT вернёт прежний контейнер под его имя.
ROLLBACK=0 SWAP_NAME='' SWAP_BACKUP='' SWAP_RESTART=''
rollback() {
  ((ROLLBACK)) || return 0
  ROLLBACK=0
  set +e
  warn 'Возвращаю прежний контейнер…'
  docker rm -f "$SWAP_NAME" >/dev/null 2>&1
  if [[ -n $SWAP_BACKUP ]]; then
    if docker rename "$SWAP_BACKUP" "$SWAP_NAME" && docker update --restart="$SWAP_RESTART" "$SWAP_NAME" >/dev/null &&
      docker start "$SWAP_NAME" >/dev/null; then
      ok "Прежний контейнер $SWAP_NAME снова работает, сайт в исходном состоянии."
    else
      warn "Не удалось вернуть сам. Выполните: docker rename $SWAP_BACKUP $SWAP_NAME && docker start $SWAP_NAME"
    fi
  fi
}
on_exit() {
  local rc=$?
  rollback
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ----------------------------------------------------------------- поиск
find_cabinet() {
  if [[ -n ${CONTAINER:-} ]]; then
    exists "$CONTAINER" || die "Контейнер «$CONTAINER» не найден (см. docker ps -a)."
    printf '%s' "$CONTAINER"
    return
  fi
  local list running
  list=$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.State}}|{{.Label "'"$MANAGED_LABEL"'"}}' |
    awk -F'|' -v sfx="$BACKUP_SUFFIX" 'index($1, sfx) == 0 && ($4 == "1" || $2 ~ /bedolaga-cabinet/ || $1 ~ /^cabinet[_-]frontend$/)' || true)
  [[ -z $list ]] && return 0
  if [[ $(grep -c . <<<"$list" || true) -gt 1 ]]; then
    running=$(awk -F'|' '$3 == "running"' <<<"$list")
    [[ $(grep -c . <<<"$running" || true) -eq 1 ]] ||
      die "Нашёл несколько контейнеров кабинета:\n$(cut -d'|' -f1-3 <<<"$list")\nУкажите нужный: CONTAINER=имя bash install.sh"
    list=$running
  fi
  printf '%s' "${list%%|*}"
}

find_bot() {
  docker ps --format '{{.Names}}|{{.Image}}' |
    awk -F'|' '$1 == "remnawave_bot" || $2 ~ /remnawave-bedolaga-telegram-bot/ {print $1; exit}' || true
}

# Контейнер, оставшийся переименованным после аварийного прерывания (kill -9, перезагрузка).
recover_leftovers() {
  local b base
  for b in $(docker ps -a --format '{{.Names}}' | grep -F -- "$BACKUP_SUFFIX" || true); do
    base=${b%"$BACKUP_SUFFIX"}
    if exists "$base"; then
      docker rm -f "$b" >/dev/null
    else
      warn "Нашёл $b от прерванного запуска — возвращаю ему имя $base."
      docker rename "$b" "$base"
      docker update --restart=unless-stopped "$base" >/dev/null
      docker start "$base" >/dev/null
    fi
  done
}

# ----------------------------------------------------------------- настройки контейнера
# Читает всё, что нужно, чтобы создать такой же контейнер: сети и алиасы, порты,
# политику перезапуска, переменные и метки (кроме унаследованных от образа),
# логирование, extra_hosts и свои тома (кроме подключаемых этим скриптом).
read_spec() {
  local c=$1 img short net aliases ip curip retries
  img=$(di "$c" '{{.Image}}')
  short=$(di "$c" '{{.Id}}')
  short=${short:0:12}
  SPEC_IMAGE_REF=$(di "$c" '{{.Config.Image}}')
  SPEC_IMAGE_ID=$img
  SPEC_RESTART=$(di "$c" '{{.HostConfig.RestartPolicy.Name}}')
  retries=$(di "$c" '{{.HostConfig.RestartPolicy.MaximumRetryCount}}')
  [[ $SPEC_RESTART == on-failure && $retries -gt 0 ]] && SPEC_RESTART+=":$retries"
  [[ -n $SPEC_RESTART ]] || SPEC_RESTART=no
  SPEC_NETMODE=$(di "$c" '{{.HostConfig.NetworkMode}}')
  mapfile -t SPEC_PORTS < <(di "$c" '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}|{{.HostPort}}|{{$p}}{{println}}{{end}}{{end}}' | sed '/^$/d')
  SPEC_NETS=()
  while IFS='|' read -r net aliases ip curip; do
    [[ -n $net ]] || continue
    # Docker 29 печатает пустой адрес как «invalid IP», старые версии — как «<nil>».
    [[ $ip =~ ^[0-9.]+$ ]] || ip=''
    [[ $curip =~ ^[0-9.]+$ ]] || curip=''
    aliases=$(tr ',' '\n' <<<"$aliases" | grep -vx -e "$short" -e '' | paste -sd, - || true)
    SPEC_NETS+=("$net|$aliases|$ip|$curip")
  done < <(di "$c" '{{range $n, $s := .NetworkSettings.Networks}}{{$n}}|{{join $s.Aliases ","}}|{{if $s.IPAMConfig}}{{$s.IPAMConfig.IPv4Address}}{{end}}|{{$s.IPAddress}}{{println}}{{end}}')
  mapfile -t SPEC_ENV < <(LC_ALL=C comm -23 \
    <(di "$c" '{{range .Config.Env}}{{println .}}{{end}}' | sed '/^$/d' | LC_ALL=C sort -u) \
    <(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$img" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u))
  mapfile -t SPEC_LABELS < <(LC_ALL=C comm -23 \
    <(di "$c" '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' | sed '/^$/d' | grep -v '^durden\.' | LC_ALL=C sort -u) \
    <(docker image inspect -f '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' "$img" 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u))
  SPEC_LOG_DRIVER=$(di "$c" '{{.HostConfig.LogConfig.Type}}')
  mapfile -t SPEC_LOG_OPTS < <(di "$c" '{{range $k, $v := .HostConfig.LogConfig.Config}}{{$k}}={{$v}}{{println}}{{end}}' | sed '/^$/d')
  mapfile -t SPEC_HOSTS < <(di "$c" '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' | sed '/^$/d')
  # Свой конфиг nginx, смонтированный пользователем (не наш из APP_DIR): src|dst|rw.
  SPEC_USER_CONF=$(di "$c" '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}|{{.RW}}{{println}}{{end}}' |
    awk -F'|' -v a="$CONF_MOUNT" -v app="$APP_DIR/" '$1 == "bind" && ($3 == a || $3 == a "/default.conf") && index($2, app) != 1 {print $2 "|" $3 "|" $4; exit}' || true)
  mapfile -t SPEC_MOUNTS < <(di "$c" '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}|{{.RW}}{{println}}{{end}}' |
    sed '/^$/d' | awk -F'|' -v a="$CONF_MOUNT" -v b="$LANDING_MOUNT" '$4 != a && $4 != b && $4 != a "/default.conf"')
}

# Настройки для новой установки: сеть бота (если найден) и порт 127.0.0.1:PORT.
fresh_spec() {
  local bot net
  SPEC_IMAGE_REF=$OFFICIAL_IMAGE SPEC_IMAGE_ID='' SPEC_USER_CONF='' SPEC_RESTART=unless-stopped SPEC_NETMODE=bridge SPEC_NETS=('bridge|||')
  SPEC_PORTS=("127.0.0.1|$PORT|80/tcp") SPEC_ENV=() SPEC_LABELS=() SPEC_LOG_DRIVER='' SPEC_LOG_OPTS=() SPEC_HOSTS=() SPEC_MOUNTS=()
  bot=$(find_bot)
  if [[ -n $bot ]]; then
    net=$(di "$bot" '{{range $n, $s := .NetworkSettings.Networks}}{{$n}}{{println}}{{end}}' | grep -vx -e bridge -e host -e none -e '' | head -n1 || true)
    if [[ -n $net ]]; then SPEC_NETMODE=$net SPEC_NETS=("$net|cabinet-frontend||"); fi
  fi
}

# Флаги сети для docker create/connect: алиасы и IP. Прежний IP сохраняется
# (KEEP_IP=1), потому что nginx с «proxy_pass http://cabinet_frontend» запоминает
# адрес при старте и после смены IP отдавал бы 502 до перезапуска.
NET_FLAGS=()
net_flags() {  # $1 = запись SPEC_NETS, $2 = префикс флага алиаса (--network-alias | --alias)
  local net aliases ip curip a
  local -a arr
  IFS='|' read -r net aliases ip curip <<<"$1"
  NET_FLAGS=()
  [[ $net == bridge ]] && return 0
  IFS=',' read -ra arr <<<"$aliases"
  for a in "${arr[@]}"; do [[ -n $a ]] && NET_FLAGS+=("$2" "$a"); done
  [[ -z $ip && $KEEP_IP == 1 ]] && ip=$curip
  [[ -n $ip ]] && NET_FLAGS+=(--ip "$ip")
  return 0
}
KEEP_IP=1

# Значение метки com.docker.compose.image для образа $1 ($2 — прежнее значение).
# Compose пишет туда ID образа под платформу сервера (при хранилище containerd он
# отличается от ID, который показывает docker image inspect без --platform).
compose_image_id() {
  local plat
  if [[ $(docker image inspect -f '{{.Id}}' "$1") == "$SPEC_IMAGE_ID" ]]; then
    printf '%s' "$2"
    return
  fi
  plat=$(docker version -f '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || true)
  docker image inspect --platform "$plat" -f '{{.Id}}' "$1" 2>/dev/null || docker image inspect -f '{{.Id}}' "$1"
}

# Собирает аргументы docker create из SPEC_*. $3 = managed (с лендингом) | stock (как было).
build_args() {
  local name=$1 image=$2 mode=$3 first='' entry net hostip hostport cport type vname src dst rw ro
  ARGS=(--name "$name" --restart "$SPEC_RESTART")
  LATER_NETS=()
  case $SPEC_NETMODE in
    host | none | container:*) ARGS+=(--network "$SPEC_NETMODE") ;;
    *)
      for entry in "${SPEC_NETS[@]}"; do [[ ${entry%%|*} == "$SPEC_NETMODE" ]] && first=$entry; done
      [[ -n $first || ${#SPEC_NETS[@]} -eq 0 ]] || first=${SPEC_NETS[0]}
      if [[ -n $first ]]; then
        net_flags "$first" --network-alias
        ARGS+=(--network "${first%%|*}" "${NET_FLAGS[@]}")
      fi
      for entry in "${SPEC_NETS[@]}"; do [[ $entry == "$first" ]] || LATER_NETS+=("$entry"); done
      for entry in "${SPEC_PORTS[@]}"; do
        IFS='|' read -r hostip hostport cport <<<"$entry"
        [[ $hostip == *:* ]] && hostip="[$hostip]"
        if [[ -n $hostip ]]; then ARGS+=(-p "$hostip:$hostport:$cport"); else ARGS+=(-p "${hostport:+$hostport:}$cport"); fi
      done
      ;;
  esac
  for entry in "${SPEC_ENV[@]}"; do ARGS+=(-e "$entry"); done
  for entry in "${SPEC_LABELS[@]}"; do
    # docker compose сравнивает эту метку с образом сервиса: держим её точной,
    # чтобы «docker compose up -d» не пересоздавал контейнер без лендинга.
    [[ $entry == com.docker.compose.image=* ]] && entry="com.docker.compose.image=$(compose_image_id "$image" "${entry#*=}")"
    ARGS+=(-l "$entry")
  done
  [[ -n $SPEC_LOG_DRIVER ]] && ARGS+=(--log-driver "$SPEC_LOG_DRIVER")
  for entry in "${SPEC_LOG_OPTS[@]}"; do ARGS+=(--log-opt "$entry"); done
  for entry in "${SPEC_HOSTS[@]}"; do ARGS+=(--add-host "$entry"); done
  for entry in "${SPEC_MOUNTS[@]}"; do
    IFS='|' read -r type vname src dst rw <<<"$entry"
    ro=''
    [[ $rw == false ]] && ro=':ro'
    case $type in
      bind) ARGS+=(-v "$src:$dst$ro") ;;
      volume) ARGS+=(-v "$vname:$dst$ro") ;;
      tmpfs) ARGS+=(--tmpfs "$dst") ;;
    esac
  done
  if [[ $mode == managed ]]; then
    ARGS+=(-v "$APP_DIR/conf.d:$CONF_MOUNT:ro$SEL" -v "$APP_DIR/landing:$LANDING_MOUNT:ro$SEL"
      -l "$MANAGED_LABEL=1" -l "durden.cabinet.version=$VERSION")
  fi
  ARGS+=("$image")
}

# ----------------------------------------------------------------- состояние
state_get() { sed -n "s/^$1=//p" "$APP_DIR/state" 2>/dev/null | tail -n1; }
state_set() {
  touch "$APP_DIR/state"
  { grep -v "^$1=" "$APP_DIR/state" || true; printf '%s=%s\n' "$1" "$2"; } >"$APP_DIR/state.tmp"
  mv -f "$APP_DIR/state.tmp" "$APP_DIR/state"
}

# ----------------------------------------------------------------- файлы
extract_landing() {
  local tmp=$APP_DIR/.landing.new
  rm -rf "$tmp"
  mkdir -p "$tmp"
  payload | base64 -d | tar -xzf - -C "$tmp"
  if [[ $DOMAIN != www.durdenvpn.org ]]; then
    sed -i "s#https://www\.durdenvpn\.org#https://$DOMAIN#g" "$tmp/index.html" "$tmp/robots.txt" "$tmp/sitemap.xml"
  fi
  chmod -R a+rX "$tmp"
  rm -rf "$APP_DIR/landing.old"
  [[ -d $APP_DIR/landing ]] && mv "$APP_DIR/landing" "$APP_DIR/landing.old"
  mv "$tmp" "$APP_DIR/landing"
  rm -rf "$APP_DIR/landing.old"
}

headers() {  # $1 = отступ
  printf '%sadd_header Strict-Transport-Security "max-age=31536000" always;\n' "$1"
  printf '%sadd_header X-Content-Type-Options "nosniff" always;\n' "$1"
  printf '%sadd_header Referrer-Policy "strict-origin-when-cross-origin" always;\n' "$1"
}

write_conf() {  # $1 = адрес бота для /health/unified или пусто, $2 = 1, если в контейнере есть IPv6
  local h4 h8 health='' tpl listen6=''
  [[ ${2:-1} == 1 ]] && listen6='    listen [::]:80;'
  h4=$(headers '    ')
  h8=$(headers '        ')
  if [[ -n $1 ]]; then
    health=$(cat <<'EOF'
    # Проверка доступности бэкенда, которую делает кабинет. Без этого блока она
    # получала index.html (всегда 200), и сбой бота не замечался.
    location = /health/unified {
        resolver 127.0.0.11 valid=30s ipv6=off;
        set $durden_bot @BOT@;
        proxy_pass $durden_bot;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_connect_timeout 3s;
        proxy_read_timeout 10s;
        access_log off;
    }
EOF
)
    health=${health//@BOT@/$1}
  fi
  tpl=$(cat <<'EOF'
# Сгенерировано install.sh (DurdenVPN). Не правьте руками: файл перезаписывается
# при каждом запуске скрипта.
server {
    listen 80;
@LISTEN6@
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    server_tokens off;
    absolute_redirect off;
    charset utf-8;

    # Сжатие. gzip_http_version 1.0 и gzip_proxied any нужны, чтобы сжатие
    # работало за внешним прокси (nginx по умолчанию ходит к апстриму по HTTP/1.0).
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_http_version 1.0;
    gzip_comp_level 6;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml application/javascript application/json
               application/xml application/manifest+json image/svg+xml image/x-icon;

@H4@

    # Быстрый лендинг. Остальные /buy/<slug>, /buy/success/…, /buy/gift/… — в кабинете.
    location = /buy/landing {
        default_type text/html;
        alias /usr/share/nginx/landing/index.html;
@H8@
        add_header Cache-Control "no-cache" always;
        add_header Content-Security-Policy "frame-ancestors 'self' https://web.telegram.org https://*.telegram.org" always;
    }
    location = /buy/landing/ {
        return 301 /buy/landing$is_args$args;
    }
    location ^~ /lp/ {
        alias /usr/share/nginx/landing/lp/;
        try_files $uri =404;
@H8@
        add_header Cache-Control "public, max-age=2592000";
        access_log off;
    }
    location = /robots.txt {
        alias /usr/share/nginx/landing/robots.txt;
        default_type text/plain;
    }
    location = /sitemap.xml {
        alias /usr/share/nginx/landing/sitemap.xml;
        default_type application/xml;
    }
    location = /favicon.ico {
        alias /usr/share/nginx/landing/lp/favicon.ico;
@H8@
        add_header Cache-Control "public, max-age=2592000";
        access_log off;
    }

    # Бандлы с хешем в имени: кеш навсегда. Без «always», чтобы 404 во время
    # деплоя не закешировался на год.
    location ^~ /assets/ {
        try_files $uri =404;
@H8@
        add_header Cache-Control "public, max-age=31536000, immutable";
        access_log off;
    }
    location ^~ /fonts/ {
        try_files $uri =404;
@H8@
        add_header Cache-Control "public, max-age=2592000";
        access_log off;
    }

    # Оболочка SPA всегда перепроверяется, иначе после обновления браузер
    # тянул бы удалённые бандлы.
    location = /index.html {
@H8@
        add_header Cache-Control "no-cache, must-revalidate" always;
    }
@HEALTH@
    # Несуществующие файлы — настоящий 404, а не index.html с кодом 200.
    location ~* \.(?:js|mjs|css|map|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|eot|txt|xml|json)$ {
        try_files $uri =404;
        access_log off;
    }
    location / {
        try_files $uri /index.html;
    }
}
EOF
)
  tpl=${tpl//@H4@/$h4}
  tpl=${tpl//@H8@/$h8}
  tpl=${tpl//@HEALTH@/$health}
  tpl=${tpl//@LISTEN6@/$listen6}
  mkdir -p "$APP_DIR/conf.d"
  printf '%s\n' "$tpl" >"$APP_DIR/conf.d/default.conf.new"
  mv -f "$APP_DIR/conf.d/default.conf.new" "$APP_DIR/conf.d/default.conf"
}

# Бот в общей с кабинетом сети, отвечающий на /health/unified, → HEALTH_UPSTREAM.
detect_health() {
  local image=$1 bot entry net
  HEALTH_UPSTREAM=''
  case $BOT_URL in
    none | off | '') return 0 ;;
    auto) ;;
    *) HEALTH_UPSTREAM=$BOT_URL; return 0 ;;
  esac
  bot=$(find_bot)
  if [[ -z $bot ]]; then
    warn 'Бот не найден среди запущенных контейнеров — /health/unified останется как был.'
    return 0
  fi
  for entry in "${SPEC_NETS[@]}"; do
    net=${entry%%|*}
    [[ $net == bridge || $net == host ]] && continue
    di "$bot" '{{range $n, $s := .NetworkSettings.Networks}}{{$n}}{{println}}{{end}}' | grep -qx -- "$net" || continue
    if docker run --rm --network "$net" --entrypoint wget "$image" -q -T 5 -O - "http://$bot:8080/health/unified" 2>/dev/null | grep -q '"status"'; then
      HEALTH_UPSTREAM="http://$bot:8080"
      ok "Бот $bot отвечает в сети $net — /health/unified будет проксироваться в него."
      return 0
    fi
  done
  warn "Бот $bot не в одной сети с кабинетом — /health/unified останется как был."
}

# ----------------------------------------------------------------- проверки
wait_ready() {
  local c=$1 _
  for _ in $(seq 1 40); do
    if [[ $(di "$c" '{{.State.Running}}' 2>/dev/null) == true ]] && docker exec "$c" wget -q -O /dev/null http://127.0.0.1/ 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

fetch() { docker exec "$1" wget -q -O - "http://127.0.0.1$2" 2>/dev/null || true; }
heads() { docker exec "$1" wget -S -q -O /dev/null --header 'Accept-Encoding: gzip' "http://127.0.0.1$2" 2>&1 || true; }

smoke() {  # $1 контейнер, $2 managed|stock
  local c=$1 fail=0 asset h hdr
  check() { if [[ $1 == 1 ]]; then ok "$2"; else warn "$2 — не работает"; fail=1; fi; }
  [[ $(fetch "$c" /) == *'id="root"'* ]] && h=1 || h=0
  check $h 'Кабинет открывается'
  [[ $2 == managed ]] || return $fail
  [[ $(fetch "$c" /buy/landing) == *'id="lp-data"'* ]] && h=1 || h=0
  check $h 'Быстрый лендинг на /buy/landing'
  asset=$(docker exec "$c" sh -c "grep -o '/assets/[^\"]*\.js' /usr/share/nginx/html/index.html | head -n1" 2>/dev/null || true)
  if [[ -n $asset ]]; then
    hdr=$(heads "$c" "$asset" | tr '[:upper:]' '[:lower:]')
    [[ $hdr == *'content-encoding: gzip'* ]] && h=1 || h=0
    check $h 'JS и CSS сжимаются (gzip)'
    [[ $hdr == *'max-age=31536000, immutable'* ]] && h=1 || h=0
    check $h 'Бандлы кешируются на год'
  fi
  [[ $(heads "$c" /assets/__durden_check__.js) == *404* ]] && h=1 || h=0
  check $h 'Несуществующие файлы отдают 404'
  [[ $(fetch "$c" /robots.txt) == *Sitemap* ]] && h=1 || h=0
  check $h 'robots.txt и sitemap.xml'
  if [[ -n ${HEALTH_UPSTREAM:-} ]]; then
    [[ $(fetch "$c" /health/unified) == *'"status"'* ]] && h=1 || h=0
    check $h '/health/unified отвечает ботом'
  fi
  return $fail
}

# Проверка снаружи: отдаёт ли домен именно этот контейнер. Ничего не ломает.
check_public() {
  command -v curl >/dev/null || return 0
  local h
  h=$(curl -sS -m 10 -o /dev/null -D - "$PUBLIC_URL/buy/landing" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
  if [[ -z $h ]]; then
    warn "Не смог открыть $PUBLIC_URL с этого сервера — проверьте сайт в браузере."
  elif [[ $h == *frame-ancestors* ]]; then
    ok "$PUBLIC_URL/buy/landing отдаёт новый лендинг через ваш прокси."
  else
    warn "$PUBLIC_URL/buy/landing отдаёт не этот контейнер. Внешний прокси должен вести «/» в контейнер кабинета."
  fi
}

# ----------------------------------------------------------------- замена контейнера
# Старый контейнер переименовывается и останавливается, новый создаётся под тем же
# именем. Удачно — старый удаляется. Ошибка — старый возвращается (rollback).
swap() {  # $1 текущий контейнер или пусто, $2 образ, $3 managed|stock
  local cur=$1 image=$2 mode=$3 name entry err
  if [[ -n $cur ]]; then name=$cur; else name=${CONTAINER:-cabinet_frontend}; fi
  KEEP_IP=1
  build_args "$name" "$image" "$mode"
  SWAP_NAME=$name SWAP_BACKUP='' SWAP_RESTART=$SPEC_RESTART
  if [[ -n $cur ]]; then
    SWAP_BACKUP=$name$BACKUP_SUFFIX
    docker rename "$name" "$SWAP_BACKUP"
    ROLLBACK=1
    docker update --restart=no "$SWAP_BACKUP" >/dev/null
    docker stop -t 10 "$SWAP_BACKUP" >/dev/null
  else
    exists "$name" && die "Имя $name уже занято другим контейнером."
    ROLLBACK=1
  fi
  if ! err=$(docker create "${ARGS[@]}" 2>&1); then
    # Сеть без своей подсети не даёт задать IP — создаём с новым адресом.
    KEEP_IP=0
    build_args "$name" "$image" "$mode"
    docker create "${ARGS[@]}" >/dev/null || die "docker create: $err"
    warn 'IP-адрес контейнера изменится. Если внешний прокси — nginx, который ходит в кабинет по имени контейнера, перезапустите его после установки.'
  fi
  for entry in "${LATER_NETS[@]}"; do
    net_flags "$entry" --alias
    docker network connect "${NET_FLAGS[@]}" "${entry%%|*}" "$name" 2>/dev/null || {
      KEEP_IP=0
      net_flags "$entry" --alias
      docker network connect "${NET_FLAGS[@]}" "${entry%%|*}" "$name"
    }
  done
  docker start "$name" >/dev/null
  wait_ready "$name" || die "Новый контейнер не запустился. Последние строки лога:\n$(docker logs --tail 15 "$name" 2>&1)"
  smoke "$name" "$mode" || die 'Проверка не прошла.'
  ROLLBACK=0
  [[ -n $SWAP_BACKUP ]] && docker rm -f "$SWAP_BACKUP" >/dev/null
  return 0
}

pull() {  # $1 образ; $2 = force — скачать свежий даже если есть локально
  if [[ ${2:-} == force ]] || ! docker image inspect "$1" >/dev/null 2>&1; then
    say "Скачиваю образ $1"
    if ! docker pull "$1"; then
      docker image inspect "$1" >/dev/null 2>&1 || die "Не удалось скачать образ $1."
      warn 'Свежий образ скачать не удалось — использую локальный.'
    fi
  fi
}

preflight() {
  ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die 'Нужен bash 4.4 или новее.'
  [[ $EUID -eq 0 ]] || die 'Запустите от root: sudo bash install.sh'
  command -v docker >/dev/null || die 'Docker не установлен.'
  docker info >/dev/null 2>&1 || die 'Docker не отвечает (systemctl start docker?).'
  local t
  for t in base64 tar awk sed comm sort grep paste; do command -v $t >/dev/null || die "Нет утилиты $t."; done
  [[ $(getenforce 2>/dev/null || true) == Enforcing ]] && SEL=',z'
  mkdir -p "$APP_DIR"
  if command -v flock >/dev/null; then
    exec 9>"$APP_DIR/.lock"
    flock -n 9 || die 'Скрипт уже запущен в другом окне.'
  fi
  recover_leftovers
}

save_self() {
  local src=${BASH_SOURCE[0]:-}
  if [[ -f $src && $(readlink -f "$src") != $(readlink -f "$APP_DIR/install.sh" 2>/dev/null || true) ]]; then
    cp -f -- "$src" "$APP_DIR/install.sh"
    chmod 755 "$APP_DIR/install.sh"
  fi
}

# ----------------------------------------------------------------- команды
cmd_install() {  # $1 = update → скачать свежий образ
  preflight
  local cur image
  cur=$(find_cabinet)
  if [[ -n $cur ]]; then
    say "Кабинет найден: контейнер $cur ($(di "$cur" '{{.Config.Image}}'))"
    read_spec "$cur"
    if ! is_ours "$cur"; then
      # Свой конфиг пользователя заменяется нашим; его копия и путь сохраняются,
      # uninstall смонтирует его обратно.
      state_set ORIG_CONF_MOUNT "$SPEC_USER_CONF"
      if [[ -n $SPEC_USER_CONF ]]; then
        mkdir -p "$APP_DIR/backup"
        cp -a -- "${SPEC_USER_CONF%%|*}" "$APP_DIR/backup/" 2>/dev/null || true
        warn "В контейнер был смонтирован свой конфиг nginx (${SPEC_USER_CONF%%|*}). Он заменяется; копия: $APP_DIR/backup/"
      fi
    fi
  else
    say 'Контейнер кабинета не найден — ставлю новый.'
    fresh_spec
  fi
  image=${IMAGE:-$SPEC_IMAGE_REF}
  if [[ ${1:-} == update ]]; then pull "$image" force; else pull "$image"; fi

  say 'Готовлю лендинг и конфиг nginx'
  extract_landing
  ok "Лендинг: $APP_DIR/landing"
  detect_health "$image"
  local ipv6=1
  docker run --rm --entrypoint sh "$image" -c 'test -f /proc/net/if_inet6' >/dev/null 2>&1 || ipv6=0
  write_conf "$HEALTH_UPSTREAM" "$ipv6"
  local test_out
  test_out=$(docker run --rm -v "$APP_DIR/conf.d:$CONF_MOUNT:ro$SEL" -v "$APP_DIR/landing:$LANDING_MOUNT:ro$SEL" --entrypoint nginx "$image" -t 2>&1) ||
    die "Конфиг nginx не прошёл проверку:\n$(tail -5 <<<"$test_out")"
  ok "Конфиг nginx: $APP_DIR/conf.d/default.conf"

  say "Пересоздаю контейнер ${cur:-${CONTAINER:-cabinet_frontend}} (сайт недоступен 2–5 секунд)"
  swap "$cur" "$image" managed
  save_self
  check_public

  say 'Готово'
  if [[ -z $cur ]]; then
    printf '%s\n' "  Кабинет слушает 127.0.0.1:$PORT${SPEC_NETMODE:+ и сеть $SPEC_NETMODE (имя cabinet_frontend:80)}." \
      '  Направьте на него прокси домена: /api/* → бот (без префикса /api), всё остальное → кабинет.'
  fi
  printf '%s\n' "  Обновить кабинет:  bash $APP_DIR/install.sh update" \
    "  Проверить:         bash $APP_DIR/install.sh status" \
    "  Убрать изменения:  bash $APP_DIR/install.sh uninstall"
}

cmd_status() {
  [[ $EUID -eq 0 ]] || die 'Запустите от root: sudo bash install.sh status'
  local cur
  cur=$(find_cabinet)
  [[ -n $cur ]] || die 'Контейнер кабинета не найден.'
  say "Контейнер $cur: $(di "$cur" '{{.State.Status}}'), образ $(di "$cur" '{{.Config.Image}}')"
  if is_ours "$cur"; then
    ok "Установлено этим скриптом, версия $(di "$cur" '{{index .Config.Labels "durden.cabinet.version"}}')"
    HEALTH_UPSTREAM=''
    grep -q 'location = /health/unified' "$APP_DIR/conf.d/default.conf" 2>/dev/null && HEALTH_UPSTREAM=yes
    smoke "$cur" managed || true
  else
    warn 'Это стандартный кабинет, скрипт ещё не устанавливался.'
    smoke "$cur" stock || true
  fi
  check_public
}

cmd_uninstall() {
  preflight
  local cur
  cur=$(find_cabinet)
  if [[ -z $cur ]] || ! is_ours "$cur"; then die 'Контейнер, установленный этим скриптом, не найден.'; fi
  read_spec "$cur"
  local conf src dst rw
  conf=$(state_get ORIG_CONF_MOUNT)
  if [[ -n $conf ]]; then
    IFS='|' read -r src dst rw <<<"$conf"
    if [[ -e $src ]]; then SPEC_MOUNTS+=("bind||$src|$dst|$rw"); else warn "Ваш прежний конфиг $src не найден — будет стандартный."; fi
  fi
  say "Возвращаю стандартный кабинет в контейнере $cur"
  swap "$cur" "$SPEC_IMAGE_REF" stock
  ok "Готово. Файлы остались в $APP_DIR — их можно удалить: rm -rf $APP_DIR"
}

main() {
  case ${1:-install} in
    install) cmd_install ;;
    update) cmd_install update ;;
    status) cmd_status ;;
    uninstall | remove) cmd_uninstall ;;
    -h | --help | help) sed -n '2,32p' "${BASH_SOURCE[0]}" 2>/dev/null || echo 'Команды: install | update | status | uninstall' ;;
    *) die "Неизвестная команда «$1». Команды: install | update | status | uninstall" ;;
  esac
}

# ----------------------------------------------------------------- вложенные файлы
# Лендинг, картинки, robots.txt и sitemap.xml (tar.gz в base64). Собирается
# scripts/build-installer.sh из папок landing/ и public/ репозитория.
payload() {
  cat <<'__DURDEN_PAYLOAD__'
@@PAYLOAD@@
__DURDEN_PAYLOAD__
}

main "$@"
