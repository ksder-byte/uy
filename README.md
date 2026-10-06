# DurdenVPN: быстрый лендинг покупки

Оптимизированная замена страницы https://www.durdenvpn.org/buy/landing. Полный разбор проблем, цифры «до/после» и список того, что нужно сделать вне кода, — в **[AUDIT.md](AUDIT.md)**.

| | Сейчас | После |
|---|---:|---:|
| Первая отрисовка, мобильный 4G | 11,6 с | 0,46 с |
| Трафик своего домена | 1,84 МБ | 31 КБ |
| Нарушения доступности (axe) | 31 | 0 |

## Что в репозитории

```
landing/index.html        страница: HTML + инлайн CSS/JS (~23 КБ gzip), без зависимостей
landing/lp/               логотип (WebP), фавиконки, картинка для превью ссылок 1200×630
public/robots.txt         robots и sitemap (сейчас вместо них отдаётся HTML кабинета)
public/sitemap.xml
nginx/durdenvpn.conf      сжатие, кеширование, заголовки безопасности, маршрут /buy/landing
nginx/snippets/           общие заголовки безопасности
scripts/update-snapshot.mjs  обновляет цены и тексты, «запечённые» в HTML, из API кабинета
tests/landing.test.mjs    e2e-тесты (Playwright) против мок-API
docs/                     скриншоты до/после
```

Страница работает с тем же API, что и кабинет:
- `GET /api/cabinet/landing/landing?lang=ru|en` — тарифы, цены, способы оплаты, скидка, подарки;
- `POST /api/cabinet/landing/landing/purchase` — тот же payload и та же CSRF-схема, что у кабинета.

После оплаты провайдер возвращает клиента на страницу успеха кабинета (`/buy/success/:token`). Её и все остальные разделы кабинета изменения не затрагивают.

Цены и тексты подставляются из API при каждом открытии. Снимок данных внутри HTML нужен для мгновенной первой отрисовки, поисковиков и превью ссылок. Если API недоступен, страница работает по снимку.

## Установка

1. Скопируйте файлы на сервер:
   ```bash
   mkdir -p /var/www/durden-landing
   cp -r landing/* public/robots.txt public/sitemap.xml /var/www/durden-landing/
   cp nginx/snippets/durden-security-headers.conf /etc/nginx/snippets/
   ```
2. Перенесите в свой конфиг nginx блоки из `nginx/durdenvpn.conf`: `gzip` в `http {}`, `location`-ы в `server {}` сайта. Пути, upstream API и сертификаты в начале файла поправьте под себя. Свой рабочий `location /api/` оставьте как есть, только сделайте его `^~ /api/`.
   ```bash
   nginx -t && nginx -s reload
   ```
   Если кабинет крутится в Docker-образе со своим nginx внутри, эти `location` и `gzip` ставятся во внешний reverse-proxy (или в nginx контейнера через volume).
3. Проверьте:
   ```bash
   curl -sI -H 'Accept-Encoding: gzip' https://www.durdenvpn.org/buy/landing | grep -iE 'content-encoding|cache-control'
   curl -sI -H 'Accept-Encoding: gzip' https://www.durdenvpn.org/assets/<любой бандл>.js | grep -iE 'content-encoding|cache-control'
   ```
   Ожидается `content-encoding: gzip`, у HTML `cache-control: no-cache`, у бандлов один `cache-control: public, max-age=31536000, immutable`.

**Откат:** удалите `location = /buy/landing`, и страницу снова будет отдавать кабинет.

## Обновление цен в HTML

Страница и так берёт актуальные данные из API. Запускайте скрипт после изменения тарифов в админке (или повесьте на cron раз в час), чтобы HTML для поисковиков и превью совпадал с реальностью:

```bash
node scripts/update-snapshot.mjs                 # берёт данные с https://www.durdenvpn.org
cp landing/index.html /var/www/durden-landing/
```

Скрипт обновляет снимок тарифов, цифры на первом экране, преимущества, FAQ, title/description и JSON-LD.

## Настройки в коде

В начале скрипта `landing/index.html`:
- `SLUG = 'landing'` — какой лендинг из админки показывать. Чтобы ускорить другой `/buy/<slug>`, скопируйте страницу и добавьте ещё один `location =`.
- `GA_ID` — счётчик GA4. Яндекс.Метрика и Google Ads подхватываются из настроек брендинга.
- `RESPECT_LIMITS = true` — скрывать способы оплаты, если цена ниже `min_amount_kopeks` или выше `max_amount_kopeks`. Поставьте `false`, если провайдер принимает такие суммы.

Футер теперь статичный HTML. Поля `footer_text` и `custom_css` из админки на эту страницу не влияют, остальные настройки лендинга — влияют.

## Тесты

```bash
npm install
npx playwright install chromium
npm test
```
