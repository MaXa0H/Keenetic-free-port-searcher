#!/usr/bin/env bash

# ===============================================
# Подборщик рандомного свободного порта Keenetic
# Требования: Bash 4.3+, curl, jq
# ===============================================

# --- Настройки Keenetic ---
KEENETIC_SCHEME="http"
KEENETIC_HOST="192.168.1.1"
KEENETIC_PORT="80"
KEENETIC_USER="admin"
KEENETIC_PASSWORD="admin"

# Диапазон подбора
PORT_MIN=1024
PORT_MAX=65535

# Дополнительные исключения.
# Пример: EXTRA_EXCLUDE="10000,12000-12100,25000"
EXTRA_EXCLUDE=""

# Проверять динамические UPnP-пробросы: 1 = да, 0 = нет
CHECK_UPNP=1

# Разрешить самоподписанный/недоверенный HTTPS-сертификат: 1 = да, 0 = нет
ALLOW_INSECURE_HTTPS=0

# Отладка: 1 = да, 0 = нет
DEBUG=0

# Пауза после завершения: 1 = да, 0 = нет.
# Пауза выполняется только при интерактивном запуске из терминала.
PAUSE_AFTER=1

# ----------------------------------------------------------

set -Eeuo pipefail

TMP_DIR=""
COOKIE_JAR=""
BASE_URL=""
AUTH_MODE="interactive"
CURL_COMMON=()

status_log() {
    printf '%s\n' "$*" >&2
}

debug_log() {
    if [[ "$DEBUG" == "1" ]]; then
        printf 'DEBUG: %s\n' "$*" >&2
    fi
}

fail() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local rc=$?

    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi

    if [[ "$PAUSE_AFTER" == "1" && -t 0 ]]; then
        printf '\nНажмите любую клавишу для продолжения...' >&2
        IFS= read -r -n 1 -s _ || true
        printf '\n' >&2
    fi

    return "$rc"
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Не найдена обязательная команда: $1"
}

validate_int() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name должен быть целым числом."
}

hash_md5() {
    local text="$1"

    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$text" | md5sum | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$text" | md5 -q
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$text" | openssl dgst -md5 | awk '{print $NF}'
    else
        fail "Для авторизации нужен md5sum, md5 или openssl."
    fi
}

hash_sha256() {
    local text="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$text" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        printf '%s' "$text" | openssl dgst -sha256 | awk '{print $NF}'
    else
        fail "Для авторизации нужен sha256sum, shasum или openssl."
    fi
}

header_value() {
    local file="$1"
    local wanted="$2"

    awk -v wanted="$wanted" '
        BEGIN { IGNORECASE=1 }
        {
            line=$0
            sub(/\r$/, "", line)
            pos=index(line, ":")
            if (pos > 0) {
                name=substr(line, 1, pos-1)
                value=substr(line, pos+1)
                sub(/^[[:space:]]+/, "", value)
                if (tolower(name) == tolower(wanted)) {
                    print value
                    exit
                }
            }
        }
    ' "$file"
}

http_request() {
    local method="$1"
    local path="$2"
    local body_file="$3"
    local headers_file="$4"
    local data="${5-}"
    local -a cmd

    cmd=("${CURL_COMMON[@]}" -X "$method" -D "$headers_file" -o "$body_file" -w '%{http_code}')

    if [[ "$AUTH_MODE" == "digest" ]]; then
        cmd+=(--digest -u "${KEENETIC_USER}:${KEENETIC_PASSWORD}")
    fi

    if [[ "$method" == "POST" ]]; then
        cmd+=(-H 'Content-Type: application/json' --data "$data")
    fi

    cmd+=("${BASE_URL}${path}")

    "${cmd[@]}"
}

trim_line() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

add_port_range() {
    local -n set_ref="$1"
    local from="$2"
    local to="$3"
    local tmp p

    if (( from > to )); then
        tmp=$from
        from=$to
        to=$tmp
    fi

    (( from < 1 )) && from=1
    (( to > 65535 )) && to=65535
    (( from > 65535 || to < 1 )) && return 0

    for ((p=from; p<=to; p++)); do
        set_ref["$p"]=1
    done
}

add_port_spec() {
    local -n set_ref="$1"
    local spec="$2"
    local from to

    spec="$(trim_line "$spec")"
    [[ -z "$spec" ]] && return 0

    if [[ "$spec" =~ ^([0-9]{1,5})[[:space:]]*-[[:space:]]*([0-9]{1,5})$ ]]; then
        from="${BASH_REMATCH[1]}"
        to="${BASH_REMATCH[2]}"
        add_port_range "$1" "$from" "$to"
    elif [[ "$spec" =~ ^[0-9]{1,5}$ ]]; then
        if (( 10#$spec >= 1 && 10#$spec <= 65535 )); then
            set_ref["$((10#$spec))"]=1
        fi
    fi
}

get_running_config() {
    local body="$TMP_DIR/config.body"
    local headers="$TMP_DIR/config.headers"
    local code

    code="$(http_request GET '/ci/running-config.txt' "$body" "$headers")" || \
        fail "Не удалось выполнить запрос /ci/running-config.txt."

    if [[ "$code" == "200" && -s "$body" ]]; then
        cat "$body"
        return 0
    fi

    if [[ "$code" == "401" ]]; then
        fail "Ошибка авторизации при чтении /ci/running-config.txt."
    fi

    debug_log "Переход на /rci/show/running-config (HTTP $code)."

    code="$(http_request GET '/rci/show/running-config' "$body" "$headers")" || \
        fail "Не удалось выполнить запрос /rci/show/running-config."

    [[ "$code" == "200" ]] || fail "Не удалось получить running-config. HTTP $code."

    if ! jq -er '
        if type == "array" then
            .[]
        elif type == "string" then
            .
        elif type == "object" and has("message") then
            .message |
            if type == "array" then .[]
            elif type == "string" then .
            else empty
            end
        else
            empty
        end
    ' "$body" 2>/dev/null; then
        fail "Роутер вернул running-config в неподдерживаемом формате."
    fi
}

authenticate() {
    local body="$TMP_DIR/auth.body"
    local headers="$TMP_DIR/auth.headers"
    local code realm challenge www_auth md5 key json

    status_log "Авторизуюсь..."

    code="$(http_request GET '/auth' "$body" "$headers")" || \
        fail "Не удалось обратиться к /auth."

    if [[ "$code" == "200" ]]; then
        status_log "Соединение с API уже авторизовано."
        return 0
    fi

    if [[ "$code" == "401" ]]; then
        realm="$(header_value "$headers" 'X-NDM-Realm')"
        challenge="$(header_value "$headers" 'X-NDM-Challenge')"
        www_auth="$(header_value "$headers" 'WWW-Authenticate')"

        if [[ -n "$realm" && -n "$challenge" ]]; then
            md5="$(hash_md5 "${KEENETIC_USER}:${realm}:${KEENETIC_PASSWORD}")"
            key="$(hash_sha256 "${challenge}${md5}")"
            json="$(jq -nc --arg login "$KEENETIC_USER" --arg password "$key" '{login:$login,password:$password}')"

            code="$(http_request POST '/auth' "$body" "$headers" "$json")" || \
                fail "Не удалось отправить данные авторизации Keenetic."

            [[ "$code" == "200" ]] || fail "Ошибка авторизации Keenetic. HTTP $code."

            status_log "Авторизация выполнена."
            debug_log "Использована x-ndw2-interactive авторизация."
            return 0
        fi

        if [[ "$www_auth" =~ [Dd]igest ]]; then
            AUTH_MODE="digest"

            code="$(http_request GET '/auth' "$body" "$headers")" || \
                fail "Не удалось выполнить HTTP Digest-авторизацию."

            [[ "$code" == "200" ]] || fail "Ошибка HTTP Digest-авторизации. HTTP $code."

            status_log "Авторизация выполнена через HTTP Digest."
            debug_log "Использована HTTP Digest-авторизация."
            return 0
        fi

        fail "Роутер вернул HTTP 401 без поддерживаемого challenge авторизации."
    fi

    debug_log "/auth вернул HTTP $code; пробую HTTP Digest."
    AUTH_MODE="digest"

    code="$(http_request GET '/auth' "$body" "$headers")" || \
        fail "Не удалось выполнить HTTP Digest-авторизацию."

    [[ "$code" == "200" ]] || fail "Не удалось авторизоваться. HTTP $code."
    status_log "Авторизация выполнена через HTTP Digest."
}

random_index() {
    local max="$1"
    local value

    (( max > 0 )) || return 1

    if command -v od >/dev/null 2>&1 && [[ -r /dev/urandom ]]; then
        value="$(od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]')"
        printf '%d' "$(( value % max ))"
    else
        value=$(( (RANDOM << 15) ^ RANDOM ))
        printf '%d' "$(( value % max ))"
    fi
}

main() {
    local config_file config_count
    local line s p first
    local -a tokens specs free default_exclude
    local i code upnp_body upnp_headers upnp_text idx selected_port

    status_log "Запускаю проверку свободного порта..."

    require_command curl
    require_command jq
    require_command awk

    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        fail "Требуется Bash 4.3 или новее. Текущая версия: ${BASH_VERSION}."
    fi

    validate_int KEENETIC_PORT "$KEENETIC_PORT"
    validate_int PORT_MIN "$PORT_MIN"
    validate_int PORT_MAX "$PORT_MAX"

    (( KEENETIC_PORT >= 1 && KEENETIC_PORT <= 65535 )) || fail "KEENETIC_PORT вне диапазона 1-65535."
    (( PORT_MIN >= 1 && PORT_MAX <= 65535 && PORT_MIN <= PORT_MAX )) || fail "Некорректный диапазон PORT_MIN/PORT_MAX."

    [[ "$KEENETIC_SCHEME" == "http" || "$KEENETIC_SCHEME" == "https" ]] || \
        fail "KEENETIC_SCHEME должен быть http или https."
    [[ -n "$KEENETIC_HOST" ]] || fail "KEENETIC_HOST не задан."
    [[ -n "$KEENETIC_USER" ]] || fail "KEENETIC_USER не задан."

    if [[ -z "$KEENETIC_PASSWORD" ]]; then
        status_log "Пароль администратора не задан. Запрашиваю пароль..."
        IFS= read -r -s -p 'Keenetic admin password: ' KEENETIC_PASSWORD
        printf '\n' >&2
    fi

    TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t keenetic-port)" || fail "Не удалось создать временный каталог."
    COOKIE_JAR="$TMP_DIR/cookies.txt"
    : > "$COOKIE_JAR"

    BASE_URL="${KEENETIC_SCHEME}://${KEENETIC_HOST}:${KEENETIC_PORT}"

    CURL_COMMON=(
        curl
        -sS
        --connect-timeout 10
        --max-time 20
        -c "$COOKIE_JAR"
        -b "$COOKIE_JAR"
    )

    if [[ "$KEENETIC_SCHEME" == "https" && "$ALLOW_INSECURE_HTTPS" == "1" ]]; then
        CURL_COMMON+=(-k)
    fi

    status_log "Подключаюсь к Keenetic: ${BASE_URL}..."
    authenticate

    status_log "Получаю конфигурацию роутера..."
    config_file="$TMP_DIR/running-config.txt"
    get_running_config > "$config_file"
    config_count="$(awk 'END { print NR }' "$config_file")"
    status_log "Конфигурация получена: ${config_count} строк."

    declare -A occupied=()
    declare -A excluded=()

    status_log "Получаю список занятых портов из правил переадресации..."

    while IFS= read -r line || [[ -n "$line" ]]; do
        s="$(trim_line "$line")"

        if [[ ! "$s" =~ ^ip[[:space:]]+static[[:space:]]+(tcp|udp)[[:space:]]+ ]]; then
            continue
        fi

        read -r -a tokens <<< "$s"

        for ((i=3; i<${#tokens[@]}; i++)); do
            if [[ "${tokens[i]}" =~ ^[0-9]{1,5}$ ]]; then
                first=$((10#${tokens[i]}))

                (( first >= 1 && first <= 65535 )) || continue

                if (( i + 2 < ${#tokens[@]} )) && \
                   [[ "${tokens[i+1]}" == "through" ]] && \
                   [[ "${tokens[i+2]}" =~ ^[0-9]{1,5}$ ]]; then
                    add_port_range occupied "$first" "$((10#${tokens[i+2]}))"
                else
                    occupied["$first"]=1
                fi

                break
            fi
        done
    done < "$config_file"

    status_log "Статические правила обработаны. Занято портов: ${#occupied[@]}."

    if [[ "$CHECK_UPNP" != "0" ]]; then
        status_log "Проверяю динамические UPnP-пробросы..."

        upnp_body="$TMP_DIR/upnp.body"
        upnp_headers="$TMP_DIR/upnp.headers"

        if code="$(http_request GET '/rci/show/upnp/redirect' "$upnp_body" "$upnp_headers")"; then
            if [[ "$code" == "200" && -s "$upnp_body" ]]; then
                while IFS= read -r p; do
                    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
                        occupied["$((10#$p))"]=1
                    fi
                done < <(
                    jq -r '
                        .. | objects | to_entries[]? |
                        select(.key | test("^(port|external-port|external_port)$"; "i")) |
                        .value | tostring
                    ' "$upnp_body" 2>/dev/null || true
                )
            elif [[ "$code" != "404" ]]; then
                debug_log "UPnP endpoint вернул HTTP $code; продолжаю без ошибки."
            fi
        else
            debug_log "Не удалось проверить UPnP; продолжаю."
        fi

        status_log "Проверка UPnP завершена. Всего занято портов: ${#occupied[@]}."
    else
        status_log "Проверка UPnP отключена."
    fi

    status_log "Формирую список служебных и зарезервированных портов-исключений..."

    default_exclude=(
        '20-23'
        '25'
        '53'
        '67-69'
        '80'
        '110'
        '123'
        '135-139'
        '143'
        '161-162'
        '389'
        '443'
        '445'
        '465'
        '500'
        '514'
        '587'
        '631'
        '636'
        '853'
        '993'
        '995'
        '1194'
        '1433'
        '1521'
        '1701'
        '1723'
        '1812-1813'
        '1883'
        '1900'
        '2049'
        '2375-2376'
        '3306'
        '3389'
        '3478-3481'
        '4500'
        '5000'
        '5060-5061'
        '5353'
        '5355'
        '5432'
        '5672'
        '5900'
        '6379'
        '8000'
        '8080-8081'
        '8443'
        '8883'
        '9000'
        '9092'
        '9100'
        '9200'
        '11211'
        '27017'
        '32400'
        '51820'
    )

    for s in "${default_exclude[@]}"; do
        add_port_spec excluded "$s"
    done

    # Порт текущей веб-панели/API всегда исключаем.
    excluded["$KEENETIC_PORT"]=1

    # Исключаем явно настроенные порты сервисов Keenetic.
    while IFS= read -r line || [[ -n "$line" ]]; do
        s="$(trim_line "$line")"
        p=""

        if [[ "$s" =~ ^ip[[:space:]]+http[[:space:]]+port[[:space:]]+([0-9]{1,5})([[:space:]]|$) ]]; then
            p="${BASH_REMATCH[1]}"
        elif [[ "$s" =~ ^ip[[:space:]]+http[[:space:]]+ssl[[:space:]]+port[[:space:]]+([0-9]{1,5})([[:space:]]|$) ]]; then
            p="${BASH_REMATCH[1]}"
        elif [[ "$s" =~ ^ip[[:space:]]+ssh[[:space:]]+port[[:space:]]+([0-9]{1,5})([[:space:]]|$) ]]; then
            p="${BASH_REMATCH[1]}"
        elif [[ "$s" =~ ^ip[[:space:]]+telnet[[:space:]]+port[[:space:]]+([0-9]{1,5})([[:space:]]|$) ]]; then
            p="${BASH_REMATCH[1]}"
        elif [[ "$s" =~ ^listen-port[[:space:]]+([0-9]{1,5})([[:space:]]|$) ]]; then
            p="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$p" ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
            excluded["$((10#$p))"]=1
        fi
    done < "$config_file"

    if [[ -n "$EXTRA_EXCLUDE" ]]; then
        status_log "Добавляю пользовательские исключения..."
        IFS=',;' read -r -a specs <<< "$EXTRA_EXCLUDE"
        for s in "${specs[@]}"; do
            add_port_spec excluded "$s"
        done
    fi

    status_log "Исключено служебных/зарезервированных портов: ${#excluded[@]}."
    status_log "Формирую список свободных портов в диапазоне ${PORT_MIN}-${PORT_MAX}..."

    free=()
    for ((p=PORT_MIN; p<=PORT_MAX; p++)); do
        if [[ -z "${occupied[$p]+x}" && -z "${excluded[$p]+x}" ]]; then
            free+=("$p")
        fi
    done

    debug_log "Занято портов: ${#occupied[@]}"
    debug_log "Исключено портов: ${#excluded[@]}"
    debug_log "Свободных кандидатов: ${#free[@]}"

    (( ${#free[@]} > 0 )) || fail "В выбранном диапазоне не осталось свободных портов."

    status_log "Найдено свободных кандидатов: ${#free[@]}."
    status_log "Выбираю случайный полностью свободный порт..."

    idx="$(random_index "${#free[@]}")" || fail "Не удалось выбрать случайный индекс."
    selected_port="${free[idx]}"

    status_log "Готово. Выбран свободный порт:"

    # В stdout выводится только номер порта.
    # Все статусные сообщения идут в stderr.
    printf '%s\n' "$selected_port"
}

main "$@"
