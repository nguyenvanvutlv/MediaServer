#!/bin/sh
set -eu

log() {
  echo "bootstrap: $*"
}

die() {
  echo "bootstrap: $*" >&2
  exit 1
}

need_env() {
  eval "val=\${$1-}"
  [ -n "$val" ] || die "thieu bien $1 trong .env"
}

need_env JELLYFIN_USERNAME
need_env JELLYFIN_PASSWORD
need_env NZBGET_USER
need_env NZBGET_PASS

JELLYFIN_URL="${JELLYFIN_URL:-http://jellyfin:8096}"
SONARR_URL="${SONARR_URL:-http://sonarr:8989}"
RADARR_URL="${RADARR_URL:-http://radarr:7878}"
NZBGET_URL="${NZBGET_URL:-http://nzbget:6789}"
MOVIE_PATH="${MOVIE_PATH:-/media/movie}"
SHOW_PATH="${SHOW_PATH:-/media/show}"
AUTH_HEADER='Authorization: MediaBrowser Client="MediaServer", Device="bootstrap", DeviceId="mediaserver-bootstrap", Version="1.0.0"'

jellyfin_auth() {
  printf 'Authorization: MediaBrowser Client="MediaServer", Device="bootstrap", DeviceId="mediaserver-bootstrap", Version="1.0.0", Token="%s"' "$1"
}

apk add --no-cache curl jq >/dev/null

wait_url() {
  url=$1
  i=0
  while [ "$i" -lt 90 ]; do
    if curl -sf --max-time 5 "$url" >/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  die "het thoi gian cho $url"
}

wait_file_key() {
  file=$1
  i=0
  while [ "$i" -lt 90 ]; do
    if [ -f "$file" ]; then
      key=$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "$file")
      if [ -n "$key" ]; then
        printf '%s' "$key"
        return 0
      fi
    fi
    i=$((i + 1))
    sleep 2
  done
  die "khong doc duoc ApiKey tu $file"
}

wait_arr() {
  url=$1
  key=$2
  i=0
  while [ "$i" -lt 60 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "X-Api-Key: $key" "$url/api/v3/system/status")
    if [ "$code" = "200" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  die "API $url chua san sang"
}

jellyfin_token() {
  payload=$(jq -n --arg Username "$JELLYFIN_USERNAME" --arg Pw "$JELLYFIN_PASSWORD" '{Username:$Username,Pw:$Pw}')
  curl -sf --max-time 15 -X POST "$JELLYFIN_URL/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -d "$payload" | jq -r '.AccessToken'
}

ensure_jellyfin_library() {
  name=$1
  collection_type=$2
  path=$3
  token=$4

  folders=$(curl -sf --max-time 15 -H "$(jellyfin_auth "$token")" "$JELLYFIN_URL/Library/VirtualFolders")
  if echo "$folders" | jq -e --arg name "$name" --arg path "$path" '
      any(.[]; .Name == $name or ((.Locations // []) | index($path)))
    ' >/dev/null; then
    log "Jellyfin da co library $name ($path)"
    return 0
  fi

  encoded_name=$(jq -rn --arg name "$name" '$name|@uri')
  body=$(jq -n --arg path "$path" '{LibraryOptions:{PathInfos:[{Path:$path}]}}')
  code=$(curl -s -o /tmp/jf-lib.json -w '%{http_code}' --max-time 30 -X POST \
    "$JELLYFIN_URL/Library/VirtualFolders?name=${encoded_name}&collectionType=${collection_type}&refreshLibrary=true" \
    -H "Content-Type: application/json" \
    -H "$(jellyfin_auth "$token")" \
    -d "$body")

  if [ "$code" != "204" ] && [ "$code" != "200" ]; then
    die "khong tao duoc library $name (HTTP $code): $(cat /tmp/jf-lib.json)"
  fi

  log "Jellyfin da them library $name -> $path"
}

ensure_arr_root() {
  name=$1
  url=$2
  key=$3
  path=$4

  folders=$(curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/rootfolder")
  if echo "$folders" | jq -e --arg path "$path" 'any(.[]; .path == $path or .path == ($path + "/"))' >/dev/null; then
    log "$name da co root folder $path"
    return 0
  fi

  body=$(jq -n --arg path "$path" '{path:$path}')
  code=$(curl -s -o /tmp/arr-root.json -w '%{http_code}' --max-time 30 -X POST \
    "$url/api/v3/rootfolder" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $key" \
    -d "$body")

  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    die "khong tao duoc root folder $path tren $name (HTTP $code): $(cat /tmp/arr-root.json)"
  fi

  log "$name da them root folder $path"
}

nzbget_rpc() {
  method=$1
  params_json=${2:-[]}
  body=$(jq -n --arg method "$method" --argjson params "$params_json" '{method:$method, params:$params}')
  resp=$(curl -s --max-time 15 -u "$NZBGET_USER:$NZBGET_PASS" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$NZBGET_URL/jsonrpc") || die "khong goi duoc NZBGet $method"
  if echo "$resp" | jq -e '.error != null' >/dev/null; then
    die "NZBGet $method that bai: $(echo "$resp" | jq -c '.error')"
  fi
  printf '%s' "$resp"
}

NZBGET_CONF="${NZBGET_CONF:-/nzbget/nzbget.conf}"

nzbget_set_conf() {
  file=$NZBGET_CONF
  [ -f "$file" ] || die "khong thay $file"
  NZBGET_OPT_NAME=$1 NZBGET_OPT_VALUE=$2 awk '
    BEGIN {
      name = ENVIRON["NZBGET_OPT_NAME"]
      value = ENVIRON["NZBGET_OPT_VALUE"]
      found = 0
    }
    index($0, name "=") == 1 || index($0, "#" name "=") == 1 {
      if (!found) { print name "=" value; found = 1 }
      next
    }
    { print }
    END { if (!found) print name "=" value }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

nzbget_conf_value() {
  awk -v name="$1" '
    index($0, name "=") == 1 {
      sub(/^[^=]+=/, "")
      print
      exit
    }
  ' "$NZBGET_CONF"
}

nzbget_apply_config() {
  changed=0
  while [ "$#" -ge 2 ]; do
    if [ "$(nzbget_conf_value "$1")" != "$2" ]; then
      nzbget_set_conf "$1" "$2"
      changed=1
    fi
    shift 2
  done
  if [ "$changed" -eq 1 ]; then
    nzbget_rpc reload >/dev/null
    sleep 3
    wait_nzbget
  fi
}

wait_nzbget() {
  i=0
  while [ "$i" -lt 90 ]; do
    result=$(curl -s --max-time 5 -u "$NZBGET_USER:$NZBGET_PASS" \
      -H "Content-Type: application/json" \
      -d '{"method":"version","params":[]}' \
      "$NZBGET_URL/jsonrpc" | jq -r '.result // empty')
    if [ -n "$result" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  die "het thoi gian cho NZBGet"
}

ensure_download_dirs() {
  mkdir -p \
    /downloads/completed/Movies \
    /downloads/completed/Series \
    /downloads/completed/Music \
    /downloads/completed/Software \
    /downloads/intermediate \
    /downloads/nzb \
    /downloads/queue \
    /downloads/tmp
  nzbget_apply_config \
    ControlUsername "$NZBGET_USER" \
    ControlPassword "$NZBGET_PASS" \
    DestDir '${MainDir}/completed' \
    AppendCategoryDir yes \
    ArticleCache "${NZBGET_ARTICLE_CACHE:-256}" \
    WriteBuffer "${NZBGET_WRITE_BUFFER:-1024}"
  log "da tao /downloads/completed/{Movies,Series}"
}

ensure_nzbget_news_server() {
  if [ -z "${NZBGET_NEWS_HOST:-}" ]; then
    log "bo qua news server: NZBGET_NEWS_HOST trong .env dang trong"
    return 0
  fi

  set -- \
    Server1.Active yes \
    Server1.Name "${NZBGET_NEWS_NAME:-News}" \
    Server1.Host "$NZBGET_NEWS_HOST" \
    Server1.Port "${NZBGET_NEWS_PORT:-563}" \
    Server1.Encryption yes \
    Server1.Connections "${NZBGET_NEWS_CONNECTIONS:-8}"
  if [ -n "${NZBGET_NEWS_USER:-}" ]; then
    set -- "$@" Server1.Username "$NZBGET_NEWS_USER"
  fi
  if [ -n "${NZBGET_NEWS_PASS:-}" ]; then
    set -- "$@" Server1.Password "$NZBGET_NEWS_PASS"
  fi
  nzbget_apply_config "$@"
  log "NZBGet da gan news server $NZBGET_NEWS_HOST"
}

ensure_arr_nzbget() {
  name=$1
  url=$2
  key=$3
  category_field=$4
  category_value=$5

  existing=$(curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/downloadclient")
  if echo "$existing" | jq -e 'any(.[]; .implementation == "Nzbget")' >/dev/null; then
    log "$name da co download client NZBGet"
    return 0
  fi

  body=$(curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/downloadclient/schema" | jq \
    --arg host "nzbget" \
    --argjson port 6789 \
    --arg user "$NZBGET_USER" \
    --arg pass "$NZBGET_PASS" \
    --arg catfield "$category_field" \
    --arg cat "$category_value" '
      [.[] | select(.implementation == "Nzbget")][0]
      | .enable = true
      | .name = "NZBGet"
      | .priority = 1
      | .removeCompletedDownloads = true
      | .removeFailedDownloads = true
      | .fields |= map(
          if .name == "host" then .value = $host
          elif .name == "port" then .value = $port
          elif .name == "useSsl" then .value = false
          elif .name == "urlBase" then .value = ""
          elif .name == "username" then .value = $user
          elif .name == "password" then .value = $pass
          elif .name == $catfield then .value = $cat
          else .
          end
        )
    ')

  code=$(curl -s -o /tmp/arr-dc.json -w '%{http_code}' --max-time 30 -X POST \
    "$url/api/v3/downloadclient" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $key" \
    -d "$body")

  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    die "khong gan duoc NZBGet vao $name (HTTP $code): $(cat /tmp/arr-dc.json)"
  fi

  log "$name da gan download client NZBGet (category $category_value)"
}

ensure_arr_newznab() {
  name=$1
  url=$2
  key=$3
  default_cats=$4

  if [ -z "${NEWZNAB_URL:-}" ]; then
    log "bo qua indexer Newznab tren $name: NEWZNAB_URL trong .env dang trong"
    return 0
  fi

  newznab_base=$(printf '%s' "$NEWZNAB_URL" | sed 's|/*$||')
  indexer_name="${NEWZNAB_NAME:-Newznab}"

  existing=$(curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/indexer")
  if echo "$existing" | jq -e --arg base "$newznab_base" '
      any(.[]; .implementation == "Newznab" and any(.fields[];
        .name == "baseUrl" and ((.value // "") | sub("/+$"; "")) == $base
      ))
    ' >/dev/null; then
    log "$name da co indexer Newznab $newznab_base"
    return 0
  fi

  curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/indexer/schema" | jq -c \
    --arg base "$newznab_base" \
    --arg apiKey "${NEWZNAB_API:-}" \
    --arg iname "$indexer_name" \
    --argjson cats "$default_cats" '
      [.[] | select(.implementation == "Newznab")][0]
      | .enable = true
      | .enableRss = true
      | .enableAutomaticSearch = true
      | .enableInteractiveSearch = true
      | .name = $iname
      | .priority = 25
      | .fields |= map(
          if .name == "baseUrl" then .value = $base
          elif .name == "apiPath" then .value = "/api"
          elif .name == "apiKey" then .value = $apiKey
          elif .name == "categories" then
            if ((.value | type) == "array" and (.value | length) > 0) then .
            else .value = $cats
            end
          else .
          end
        )
        | del(.fields[]?.selectOptions)
    ' > /tmp/arr-idx-body.json

  code=$(curl -s -o /tmp/arr-idx.json -w '%{http_code}' --max-time 30 -X POST \
    "$url/api/v3/indexer" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $key" \
    -d @/tmp/arr-idx-body.json)

  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    die "khong gan duoc Newznab vao $name (HTTP $code): $(cat /tmp/arr-idx.json)"
  fi

  log "$name da gan indexer Newznab $newznab_base"
}

jellyfin_api_key() {
  token=$1
  keys=$(curl -sf --max-time 15 -H "$(jellyfin_auth "$token")" "$JELLYFIN_URL/Auth/Keys")
  existing=$(echo "$keys" | jq -r '.Items[]? | select(.AppName == "MediaServer") | .AccessToken' | head -n 1)
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    printf '%s' "$existing"
    return 0
  fi

  curl -sf --max-time 15 -X POST "$JELLYFIN_URL/Auth/Keys?app=MediaServer" \
    -H "$(jellyfin_auth "$token")" >/dev/null

  curl -sf --max-time 15 -H "$(jellyfin_auth "$token")" "$JELLYFIN_URL/Auth/Keys" \
    | jq -r '.Items[]? | select(.AppName == "MediaServer") | .AccessToken' | head -n 1
}

ensure_arr_jellyfin() {
  name=$1
  url=$2
  key=$3
  jf_apikey=$4

  existing=$(curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/notification")
  if echo "$existing" | jq -e 'any(.[]; .implementation == "Jellyfin" or .implementation == "MediaBrowser")' >/dev/null; then
    log "$name da noi Jellyfin"
    return 0
  fi

  body=$(curl -sf --max-time 15 -H "X-Api-Key: $key" "$url/api/v3/notification/schema" | jq \
    --arg apiKey "$jf_apikey" '
      [.[] | select(.implementation == "Jellyfin" or .implementation == "MediaBrowser")][0]
      | .enable = true
      | .name = "Jellyfin"
      | .onDownload = true
      | .onUpgrade = true
      | .onImportComplete = true
      | .fields |= map(
          if .name == "host" then .value = "jellyfin"
          elif .name == "port" then .value = 8096
          elif .name == "useSsl" then .value = false
          elif .name == "apiKey" then .value = $apiKey
          elif .name == "notify" then .value = false
          elif .name == "updateLibrary" then .value = true
          else .
          end
        )
    ')

  code=$(curl -s -o /tmp/arr-jf.json -w '%{http_code}' --max-time 30 -X POST \
    "$url/api/v3/notification" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $key" \
    -d "$body")

  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    die "khong noi duoc $name voi Jellyfin (HTTP $code): $(cat /tmp/arr-jf.json)"
  fi

  log "$name da noi Jellyfin (update library khi import xong)"
}

log "cho NZBGet san sang"
wait_nzbget
ensure_download_dirs
ensure_nzbget_news_server

log "cho Jellyfin san sang"
wait_url "$JELLYFIN_URL/System/Info/Public"

wizard_done=$(curl -s --max-time 10 "$JELLYFIN_URL/System/Info/Public" | jq -r '.StartupWizardCompleted // empty')
if [ "$wizard_done" != "true" ]; then
  log "hoan tat setup wizard Jellyfin"
  curl -sf --max-time 15 -X POST "$JELLYFIN_URL/Startup/Configuration" \
    -H "Content-Type: application/json" \
    -d '{"UICulture":"en-US","MetadataCountryCode":"VN","PreferredMetadataLanguage":"en"}' >/dev/null

  curl -s --max-time 15 "$JELLYFIN_URL/Startup/User" >/dev/null || true

  user_body=$(jq -n --arg Name "$JELLYFIN_USERNAME" --arg Password "$JELLYFIN_PASSWORD" '{Name:$Name,Password:$Password}')
  user_code=$(curl -s -o /tmp/jf-user.json -w '%{http_code}' --max-time 15 -X POST \
    "$JELLYFIN_URL/Startup/User" \
    -H "Content-Type: application/json" \
    -d "$user_body")
  if [ "$user_code" != "204" ] && [ "$user_code" != "200" ]; then
    die "khong tao duoc user Jellyfin (HTTP $user_code): $(cat /tmp/jf-user.json)"
  fi

  curl -s --max-time 15 -X POST "$JELLYFIN_URL/Startup/RemoteAccess" \
    -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null || true
fi

token=$(jellyfin_token) || die "khong dang nhap Jellyfin duoc. Kiem tra JELLYFIN_USERNAME / JELLYFIN_PASSWORD trong .env"
ensure_jellyfin_library "Movies" "movies" "$MOVIE_PATH" "$token"
ensure_jellyfin_library "Shows" "tvshows" "$SHOW_PATH" "$token"

if [ "$wizard_done" != "true" ]; then
  curl -sf --max-time 15 -X POST "$JELLYFIN_URL/Startup/Complete" >/dev/null
  log "Jellyfin wizard da complete"
fi

log "cho Sonarr san sang"
sonarr_key=$(wait_file_key /sonarr/config.xml)
wait_arr "$SONARR_URL" "$sonarr_key"
ensure_arr_root "Sonarr" "$SONARR_URL" "$sonarr_key" "$SHOW_PATH"

log "cho Radarr san sang"
radarr_key=$(wait_file_key /radarr/config.xml)
wait_arr "$RADARR_URL" "$radarr_key"
ensure_arr_root "Radarr" "$RADARR_URL" "$radarr_key" "$MOVIE_PATH"

ensure_arr_nzbget "Sonarr" "$SONARR_URL" "$sonarr_key" "tvCategory" "Series"
ensure_arr_nzbget "Radarr" "$RADARR_URL" "$radarr_key" "movieCategory" "Movies"
ensure_arr_newznab "Sonarr" "$SONARR_URL" "$sonarr_key" '[5030,5040,5045]'
ensure_arr_newznab "Radarr" "$RADARR_URL" "$radarr_key" '[2000,2010,2020,2030,2040,2045,2050]'

jf_apikey=$(jellyfin_api_key "$token") || die "khong tao duoc Jellyfin API key"
[ -n "$jf_apikey" ] && [ "$jf_apikey" != "null" ] || die "Jellyfin API key trong"
ensure_arr_jellyfin "Sonarr" "$SONARR_URL" "$sonarr_key" "$jf_apikey"
ensure_arr_jellyfin "Radarr" "$RADARR_URL" "$radarr_key" "$jf_apikey"

log "xong"
