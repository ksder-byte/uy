#!/usr/bin/env bash
# Собирает install.sh в корне репозитория: шаблон installer/install.template.sh
# + вшитые файлы лендинга (landing/, public/robots.txt, public/sitemap.xml).
# Запускайте после любых изменений лендинга или шаблона.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/files"
cp "$root/landing/index.html" "$root/public/robots.txt" "$root/public/sitemap.xml" "$work/files/"
cp -r "$root/landing/lp" "$work/files/lp"
# Воспроизводимый архив: одинаковые файлы → одинаковый install.sh.
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='2026-01-01 00:00Z' -C "$work/files" -cf - . |
  gzip -9n | base64 -w 76 >"$work/payload.b64"

version=$(cat "$root/installer/install.template.sh" "$work/payload.b64" | sha256sum | cut -c1-10)
awk -v ver="$version" -v pf="$work/payload.b64" '
  $0 == "@@PAYLOAD@@" { while ((getline line < pf) > 0) print line; next }
  { gsub(/@@VERSION@@/, ver); print }
' "$root/installer/install.template.sh" >"$root/install.sh"
chmod 755 "$root/install.sh"
bash -n "$root/install.sh"
echo "install.sh: версия $version, $(wc -c <"$root/install.sh") байт"
