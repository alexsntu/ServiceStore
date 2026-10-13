#!/bin/bash
# irepair-store.ru (CS-Cart): полная резервная копия сайта с сервера на этот Mac.
#
# Запускается на Mac раз в час и при входе в систему (launchd, ru.irepair-store.backup-pull).
# Если последней копии здесь больше MIN_AGE_HOURS часов — снимает новую: дамп базы и архив файлов магазина,
# плюс остальное с сервера: почта, DNS-зона, сертификаты, настройки служб (старый сайт old.* не копируется).
# Всё идёт потоком по SSH прямо на Mac, на сервере ничего не сохраняется и не меняется.
# Хранение: KEEP последних копий в папке backups/ проекта (папка в .gitignore — в git не попадает).
# Старая копия удаляется только после того, как новая скачана и проверена.
# Если свежей копии нет больше STALE_DAYS дней — показывает уведомление (не чаще раза в сутки).
#
# Установка расписания: скопировать ru.irepair-store.backup-pull.plist в ~/Library/LaunchAgents и выполнить
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ru.irepair-store.backup-pull.plist
# Ручной запуск: bash scripts/site-backup-pull.sh          (пропустит, если свежая копия уже есть)
#                bash scripts/site-backup-pull.sh --force  (снять копию прямо сейчас)
set -u
export LC_ALL=C

DEST="/Users/a0000/Документы/Cursor/ServiceStor-Cursor/backups"
KEY="$HOME/.ssh/servicestore_ed25519"
HOST=root@188.120.250.194
DB=store
WWW_DIR=/var/www/www-root/data/www
SITE=irepair-store.ru
EXTRA_DBS="roundcube"
CONFIG_PATHS="etc/nginx etc/exim4 etc/dovecot etc/bind etc/proftpd etc/ufw etc/fail2ban etc/ssh/sshd_config.d opt/php83/etc var/www/httpd-cert var/www/www-root/data/email var/www/www-root/data/calc-prices var/spool/cron/crontabs usr/local/mgr5/etc"
KEEP=3
MIN_AGE_HOURS=24
STALE_DAYS=3
MIN_DB_BYTES=10485760        # дамп меньше 10 МБ считаем битым
MIN_FILES_BYTES=524288000    # архив файлов меньше 500 МБ считаем битым
LOG="$DEST/pull.log"
LOCK="$DEST/.lock"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
NICE="nice -n 19 ionice -c2 -n7"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$DEST" || exit 1
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# один запуск одновременно; зависший замок старше трёх часов снимаем
if ! mkdir "$LOCK" 2>/dev/null; then
    [ -n "$(find "$LOCK" -maxdepth 0 -mmin +180 2>/dev/null)" ] || exit 0
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
fi
TMP=""
trap '[ -n "$TMP" ] && rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null' EXIT

latest() { ls -1d "$DEST"/irepair-store-20??????-?????? 2>/dev/null | sort | tail -1; }

# уведомление, если последняя копия здесь старше STALE_DAYS дней
check_stale() {
    local last age stamp="$DEST/.stale-notified"
    last=$(latest)
    if [ -n "$last" ]; then
        age=$(( ( $(date +%s) - $(stat -f %m "$last") ) / 86400 ))
        [ "$age" -lt "$STALE_DAYS" ] && { rm -f "$stamp"; return; }
    else
        age="?"
    fi
    [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ] && return
    touch "$stamp"
    log "ВНИМАНИЕ: свежей копии нет (последней дней: $age)"
    osascript -e 'display notification "Свежая резервная копия магазина не получена. Журнал: backups/pull.log" with title "irepair-store.ru: резервные копии"' >/dev/null 2>&1
}

fail() { log "ОШИБКА: $*"; check_stale; exit 1; }

# 1. свежая копия уже есть — делать нечего
LAST=$(latest)
if [ "$FORCE" = 0 ] && [ -n "$LAST" ]; then
    AGE_H=$(( ( $(date +%s) - $(stat -f %m "$LAST") ) / 3600 ))
    [ "$AGE_H" -lt "$MIN_AGE_HOURS" ] && exit 0
fi

# 2. сервер на связи?
if ! ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null; then
    log "сервер недоступен"
    check_stale; exit 0
fi

STAMP=$(date '+%Y%m%d-%H%M%S')
NAME="irepair-store-$STAMP"
rm -rf "$DEST"/.partial-*
TMP="$DEST/.partial-$STAMP"
mkdir "$TMP" || fail "не создаётся $TMP"
log "начало: $NAME"

# 3. база. Без блокировки таблиц, чтобы не подвешивать магазин, если копия снимается днём
#    (согласованная ночная копия — на стороне ISPmanager).
ssh "${SSH_OPTS[@]}" "$HOST" "set -o pipefail; $NICE mysqldump --single-transaction --skip-lock-tables --quick --routines --triggers --default-character-set=utf8mb4 $DB | $NICE gzip -6" > "$TMP/store_db.sql.gz" 2>>"$LOG" \
    || fail "дамп базы не снялся"
[ "$(stat -f %z "$TMP/store_db.sql.gz")" -ge "$MIN_DB_BYTES" ] || fail "дамп базы подозрительно мал"
gzip -dc "$TMP/store_db.sql.gz" 2>>"$LOG" | tail -n 1 | grep -q 'Dump completed' || fail "дамп базы оборван или повреждён"

# 4. файлы сайта. Код 1 у tar — «файл изменился во время чтения», на живом сайте это нормально.
ssh "${SSH_OPTS[@]}" "$HOST" "$NICE tar -czf - -C $WWW_DIR $SITE; rc=\$?; [ \$rc -le 1 ]" > "$TMP/${SITE}_files.tar.gz" 2>>"$LOG" \
    || fail "архив файлов не снялся"
[ "$(stat -f %z "$TMP/${SITE}_files.tar.gz")" -ge "$MIN_FILES_BYTES" ] || fail "архив файлов подозрительно мал"
gzip -t "$TMP/${SITE}_files.tar.gz" 2>>"$LOG" || fail "архив файлов повреждён"

# 5. остальное, что живёт на сервере рядом с магазином. Сбой здесь — предупреждение в журнале,
#    копия магазина при этом считается состоявшейся.
warn() { log "предупреждение: $*"; }

# 5а. прочие базы: веб-почта
for XDB in $EXTRA_DBS; do
    ssh "${SSH_OPTS[@]}" "$HOST" "set -o pipefail; $NICE mysqldump --single-transaction --skip-lock-tables --quick --routines --triggers $XDB | gzip -6" > "$TMP/${XDB}_db.sql.gz" 2>>"$LOG" \
        && gzip -dc "$TMP/${XDB}_db.sql.gz" 2>>"$LOG" | tail -n 1 | grep -q 'Dump completed' \
        || { warn "база $XDB не сохранилась"; rm -f "$TMP/${XDB}_db.sql.gz"; }
done

# 5б. настройки сервера и мелкие данные, без которых всё не поднять с нуля: nginx, PHP, почта (ящики, exim, dovecot,
#     DKIM), DNS-зона, SSL-сертификаты, FTP, firewall, cron, настройки ISPmanager, права пользователей MariaDB.
#     ВНИМАНИЕ: внутри закрытые ключи и хеши паролей — этот архив никуда не выкладывать.
ssh "${SSH_OPTS[@]}" "$HOST" "D=\$(mktemp -d) && mysql -N -e \"select concat('show grants for ', quote(user), '@', quote(host), ';') from mysql.user where user <> ''\" | mysql -N -f 2>/dev/null | sed 's/\$/;/' > \$D/mariadb-grants.sql; tar -czf - --ignore-failed-read -C \$D mariadb-grants.sql -C / $CONFIG_PATHS 2>/dev/null; rc=\$?; rm -rf \$D; [ \$rc -le 1 ]" > "$TMP/server-config.tar.gz" 2>>"$LOG" \
    && gzip -t "$TMP/server-config.tar.gz" 2>>"$LOG" \
    || { warn "настройки сервера не сохранились"; rm -f "$TMP/server-config.tar.gz"; }

( cd "$TMP" && shasum -a 256 *.gz > SHA256SUMS ) || fail "не посчитались контрольные суммы"
mv "$TMP" "$DEST/$NAME" || fail "не переименовать $TMP"
TMP=""

# 6. оставляем KEEP последних (только после успешной новой)
ls -1d "$DEST"/irepair-store-20??????-?????? | sort -r | tail -n +$((KEEP + 1)) | while read -r OLD; do
    rm -rf "$OLD" && log "удалена старая: $(basename "$OLD")"
done

log "готово: $NAME, $(du -sh "$DEST/$NAME" | cut -f1 | tr -d ' '), копий в папке: $(ls -1d "$DEST"/irepair-store-20??????-?????? | wc -l | tr -d ' ')"
check_stale
