# DurdenVPN: кабинет Bedolaga + быстрый лендинг

Оптимизированная страница https://www.durdenvpn.org/buy/landing и установка кабинета [Bedolaga](https://github.com/BEDOLAGA-DEV/bedolaga-cabinet) **одним файлом** — `install.sh`. Полный разбор проблем и цифры «до/после» — в **[AUDIT.md](AUDIT.md)**.

| | Сейчас | После |
|---|---:|---:|
| Первая отрисовка, мобильный 4G | 11,6 с | 0,46 с |
| Трафик своего домена | 1,84 МБ | 31 КБ |
| Нарушения доступности (axe) | 31 | 0 |

## Установка одной командой

Нужны root-доступ к серверу, где запущен кабинет (или будет запущен), Docker и bash 4.4+.

1. **Скачайте и запустите** на сервере:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/ksder-byte/uy/HEAD/install.sh -o install.sh && sudo bash install.sh
   ```
2. **Если сайт раздаёт nginx самого сервера из папки** (`root /srv/cabinet` — копия сборки), `install.sh` в конце так и скажет. Переключите сайт на контейнер:
   ```bash
   sudo bash /opt/durden-cabinet/install.sh nginx
   ```
   Команда делает резервную копию конфига и меняет только блок `server` вашего домена: `location /` начинает вести в контейнер, а статическая отдача старых JS/CSS из папки убирается. `/api/` и вебхуки остаются как были. Ваши файлы из папки (верификации, `.well-known`) продолжают отдаваться. После `nginx -t` и перезагрузки команда проверяет сайт. Если он не открылся, конфиг возвращается сам.

Что сделает скрипт:
1. Найдёт контейнер кабинета (`ghcr.io/bedolaga-dev/bedolaga-cabinet` или `cabinet_frontend`). Если его нет — поставит новый в сеть бота на `127.0.0.1:3020`.
2. Положит в `/opt/durden-cabinet` быстрый лендинг и конфиг nginx. Конфиг даёт:
   - gzip для JS/CSS, в том числе за внешним прокси;
   - кеш бандлов на год и `no-cache` для HTML;
   - настоящие 404 вместо index.html, robots.txt, sitemap.xml, favicon.ico;
   - HSTS и `nosniff`;
   - проксирование `/health/unified` в бота, если бот в той же Docker-сети.
3. Пересоздаст контейнер с теми же именем, сетями, **IP-адресом**, портами, переменными и метками. Внешний прокси (Caddy/Nginx/Traefik) менять не нужно. Сайт недоступен 2–5 секунд.
4. Проверит результат изнутри контейнера и через ваш домен. **При любой ошибке сам вернёт прежний контейнер.**

После установки:
```bash
sudo bash /opt/durden-cabinet/install.sh status      # всё ли работает
sudo bash /opt/durden-cabinet/install.sh update      # обновить кабинет до свежего образа
sudo bash /opt/durden-cabinet/install.sh uninstall   # вернуть стандартный кабинет
sudo bash /opt/durden-cabinet/install.sh nginx       # сайт раздаёт nginx из папки → переключить на контейнер
```

Необязательные настройки задаются переменными перед командой, например `CONTAINER=my_cabinet sudo -E bash install.sh`:

| Переменная | Зачем | По умолчанию |
|---|---|---|
| `CONTAINER` | имя контейнера кабинета, если автопоиск ошибся | ищется сам |
| `IMAGE` | образ кабинета | тот, что уже запущен |
| `DOMAIN` | домен в ссылках лендинга и sitemap | `www.durdenvpn.org` |
| `PORT` | порт на `127.0.0.1`, только для установки с нуля | `3020` |
| `BOT_URL` | бот для `/health/unified`: `auto`, `none` или `http://хост:8080` | `auto` |

**Совместимость:**
- `docker compose up -d` в папке кабинета контейнер не пересоздаёт: скрипт сохраняет метки compose.
- Watchtower обновляет образ, сохраняя изменения.
- Если обновите кабинет своим `docker compose pull && docker compose up -d`, compose пересоздаст контейнер по своему файлу без лендинга. Сайт продолжит работать, просто медленнее. Запустите `install.sh update`, чтобы вернуть ускорение.
- Если в контейнер был смонтирован свой `default.conf`, его копия кладётся в `/opt/durden-cabinet/backup/`, а `uninstall` смонтирует его обратно.

## Что в репозитории

```
install.sh                   ← главный файл: установщик с вшитым лендингом (собирается, не править руками)
installer/install.template.sh  исходник установщика
scripts/build-installer.sh   собирает install.sh из шаблона + landing/ + public/
landing/index.html           страница: HTML + инлайн CSS/JS (~23 КБ gzip), без зависимостей
landing/lp/                  логотип (WebP), фавиконки, картинка для превью ссылок 1200×630
public/robots.txt, sitemap.xml
nginx/                       конфиг для внешнего nginx — если кабинет раздаётся статикой без Docker
scripts/update-snapshot.mjs  обновляет цены и тексты, «запечённые» в HTML, из API кабинета
tests/landing.test.mjs       e2e-тесты страницы (Playwright) против мок-API
tests/installer.test.sh      проверка install.sh на имитации сервера в Docker
tests/nginx-switch.test.sh   проверка «install.sh nginx» на копии конфига сервера
docs/                        скриншоты до/после
```

Страница работает с тем же API, что и кабинет:
- `GET /api/cabinet/landing/landing?lang=ru|en` — тарифы, цены, способы оплаты, скидка, подарки;
- `POST /api/cabinet/landing/landing/purchase` — тот же payload и та же CSRF-схема, что у кабинета.

После оплаты провайдер возвращает клиента на страницу успеха кабинета (`/buy/success/:token`). Её и все остальные разделы кабинета изменения не затрагивают. Цены подставляются из API при каждом открытии; снимок внутри HTML нужен для мгновенной первой отрисовки, поисковиков и превью ссылок.

## Без Docker: кабинет раздаётся статикой через nginx

1. Скопируйте файлы:
   ```bash
   mkdir -p /var/www/durden-landing
   cp -r landing/* public/robots.txt public/sitemap.xml /var/www/durden-landing/
   cp nginx/snippets/durden-security-headers.conf /etc/nginx/snippets/
   ```
2. Перенесите в свой конфиг блоки из `nginx/durdenvpn.conf`: `gzip` — в `http {}`, `location`-ы — в `server {}` сайта. Свой рабочий `location /api/` оставьте, только сделайте его `^~ /api/`. Затем `nginx -t && nginx -s reload`.

## Для разработки

- **Изменили лендинг или шаблон установщика:** `bash scripts/build-installer.sh` пересоберёт `install.sh`.
- **Поменяли тарифы и хотите обновить HTML для поисковиков:** `node scripts/update-snapshot.mjs`, затем пересоберите `install.sh`.
- **Настройки в начале скрипта `landing/index.html`:**
  - `SLUG` — какой лендинг из админки показывать;
  - `GA_ID` — счётчик GA4;
  - `RESPECT_LIMITS` — скрывать способы оплаты, если цена вне `min/max_amount_kopeks`. Поставьте `false`, если провайдер принимает такие суммы.
- **Футер теперь статичный HTML:** поля `footer_text` и `custom_css` из админки на эту страницу не влияют.
- **Сменили логотип:** `python3 scripts/make-icons.py логотип.png` пересоберёт иконки сайта (для вкладки, Google, Яндекса и iPhone), затем пересоберите `install.sh`.

Тесты:
```bash
npm install && npx playwright install chromium
npm test                  # страница
sudo bash tests/installer.test.sh     # установщик (нужен Docker)
sudo bash tests/nginx-switch.test.sh  # переключение nginx (Docker, nginx, свободные 80/443)
```
