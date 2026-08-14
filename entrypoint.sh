#!/bin/sh
# Based on https://raw.githubusercontent.com/brainsam/pgbouncer/master/entrypoint.sh

set -e

# Here are some parameters. See all on
# https://pgbouncer.github.io/config.html

PG_CONFIG_DIR=/etc/pgbouncer
PG_CONFIG_FILE="${PG_CONFIG_DIR}/pgbouncer.ini"
_AUTH_FILE="${AUTH_FILE:-$PG_CONFIG_DIR/userlist.txt}"

# What the environment provided, before any URL overwrites it.
ENV_DB_USER="${DB_USER:-}"
ENV_DB_PASSWORD="${DB_PASSWORD:-}"
ENV_DB_HOST="${DB_HOST:-}"
ENV_DB_PORT="${DB_PORT:-}"
ENV_DB_NAME="${DB_NAME:-}"

# Workaround userlist.txt missing issue
# https://github.com/edoburu/docker-pgbouncer/issues/33
if [ ! -e "${_AUTH_FILE}" ]; then
  touch "${_AUTH_FILE}"
fi

# Extract all info from a given URL. Sets variables because shell functions can't return multiple values.
#
# Parameters:
#   - The url we should parse
# Returns (sets variables): DB_USER, DB_PASSWORD, DB_HOST, DB_PORT, DB_NAME
function parse_url() {
  # Reset first: DATABASE_URLS parses all its entries in one subshell.
  DB_USER="${ENV_DB_USER}"
  DB_PASSWORD="${ENV_DB_PASSWORD}"
  DB_HOST="${ENV_DB_HOST}"
  DB_PORT="${ENV_DB_PORT}"
  DB_NAME="${ENV_DB_NAME}"

  # Thanks to https://stackoverflow.com/a/17287984/146289

  # Allow to pass values like dj-database-url / django-environ accept
  proto="$(echo $1 | grep :// | sed -e's,^\(.*://\).*,\1,g')"
  url="$(echo $1 | sed -e s,$proto,,g)"

  # extract the user and password (if any)
  userpass="$(echo $url | grep @ | sed -r 's/^(.*)@([^@]*)$/\1/')"
  DB_PASSWORD="$(echo $userpass | grep : | cut -d: -f2)"
  if [ -n "${DB_PASSWORD}" ]; then
    DB_USER="$(echo $userpass | grep : | cut -d: -f1)"
  else
    DB_USER="${userpass}"
  fi

  # extract the host -- updated
  hostport=`echo $url | sed -e s,$userpass@,,g | cut -d/ -f1`
  port=`echo $hostport | grep : | cut -d: -f2`
  if [ -n "$port" ]; then
    DB_HOST=`echo $hostport | grep : | cut -d: -f1`
    DB_PORT="${port}"
  else
    DB_HOST="${hostport}"
  fi

  DB_NAME="$(echo $url | grep / | cut -d/ -f2-)"
}

# Grabs variables set by `parse_url` and adds them to the userlist if not already set in there.
function generate_userlist_if_needed() {
  if [ -n "${DB_USER}" -a -n "${DB_PASSWORD}" -a -e "${_AUTH_FILE}" ] && ! grep -q "^\"${DB_USER}\"" "${_AUTH_FILE}"; then
    if echo "${DB_PASSWORD}" | grep -qE '^(md5[0-9a-f]{32}|SCRAM-SHA-256\$)'; then
      pass="${DB_PASSWORD}" # already a verifier, hashing it again would break login
    elif [ "${AUTH_TYPE}" == "plain" ] || [ "${AUTH_TYPE}" == "scram-sha-256" ]; then
      pass="${DB_PASSWORD}"
    else
      pass="md5$(echo -n "${DB_PASSWORD}${DB_USER}" | md5sum | cut -f 1 -d ' ')"
    fi
    echo "\"${DB_USER}\" \"${pass}\"" >> "${_AUTH_FILE}"
    echo "Wrote authentication credentials for '${DB_USER}' to ${_AUTH_FILE}"
  fi
}

# Grabs variables set by `parse_url` and adds them to the PG config file as a database entry.
function generate_config_db_entry() {
  # auth_user falls back to postgres even when nothing here holds its password:
  # a mounted userlist may, and dropping it takes auth_query from those setups.
  printf "\
${DB_NAME:-*} = host=${DB_HOST:?"Setup pgbouncer config error! You must set DB_HOST env"} \
port=${DB_PORT:-5432} auth_user=${DB_USER:-postgres}\
${CLIENT_ENCODING:+ client_encoding=${CLIENT_ENCODING}}\
${TIMEZONE:+ timezone=${TIMEZONE}}\
${POOL_SIZE:+ pool_size=${POOL_SIZE}}
" >> "${PG_CONFIG_FILE}"
}

# The env prefix a name's settings live under, e.g. POOL + paid -> POOL_PAID_
function name_env_prefix() {
  printf "%s_%s_" "$1" "$(echo "$2" | tr 'a-z' 'A-Z')"
}

# One setting, empty when it is not set.
function env_setting() {
  env | awk -F= -v key="$1$2" '$1 == key { print substr($0, length(key) + 2); exit }'
}

# The connect string of a pool: the inherited defaults, then its own overrides,
# the last value of a key winning. pgbouncer refuses a parameter it knows not.
function pool_connect_string() {
  pool_prefix="$1"
  pool_name="$2"

  {
    printf 'host=%s\n' "${DB_HOST}"
    printf 'port=%s\n' "${DB_PORT:-5432}"
    printf 'dbname=%s\n' "${DB_NAME:-$pool_name}"
    printf 'auth_user=%s\n' "${DB_USER:-postgres}" # a mounted userlist may hold it

    # pgbouncer has no process-wide setting for these three.
    if [ -n "${CLIENT_ENCODING}" ]; then
      printf 'client_encoding=%s\n' "${CLIENT_ENCODING}"
    fi

    if [ -n "${TIMEZONE}" ]; then
      printf 'timezone=%s\n' "${TIMEZONE}"
    fi

    if [ -n "${POOL_SIZE}" ]; then
      printf 'pool_size=%s\n' "${POOL_SIZE}"
    fi

    env | awk -F= -v prefix="$pool_prefix" '
      index($0, prefix) == 1 {
        print tolower(substr($1, length(prefix) + 1)) "=" substr($0, length($1) + 2)
      }'
  } \
    | awk -F= '{ key = $1; value = substr($0, length(key) + 2); last[key] = value }
               END { for (key in last) print key "=" last[key] }' \
    | sort \
    | awk -F= '
        {
          key = $1
          value = substr($0, length(key) + 2)

          # A value with a space needs quoting, and a quote inside it doubling.
          if (value ~ /[[:space:]]/) {
            gsub(/'"'"'/, "'"'"''"'"'", value)
            value = "'"'"'" value "'"'"'"
          }

          printf " %s=%s", key, value
        }'
}

# A name reaching its settings through an env prefix cannot contain anything an
# env name cannot, nor be the prefix of another name.
function assert_names_are_usable() {
  env_root="$1"
  kind="$2"
  names="$3"
  seen_names=""

  for name in $(echo "$names" | tr , ' '); do
    if ! echo "$name" | grep -qE '^[A-Za-z0-9_]+$'; then
      echo "$kind name \"$name\" is not usable: ${env_root}S takes letters, digits and underscores" >&2
      exit 1
    fi

    case " ${seen_names} " in
      *" $name "*)
        echo "$kind name \"$name\" appears twice in ${env_root}S" >&2
        exit 1
        ;;
    esac

    seen_names="${seen_names} $name"

    for other in $(echo "$names" | tr , ' '); do
      if [ "$name" = "$other" ]; then
        continue
      fi

      case "$(name_env_prefix "$env_root" "$other")" in
        "$(name_env_prefix "$env_root" "$name")"*)
          echo "$kind names \"$name\" and \"$other\" overlap: the settings of one would be read as the other's" >&2
          exit 1
          ;;
      esac
    done
  done
}

# A setting addresses a name the list holds and carries a value; empty means a
# reference that resolved to nothing, never an instruction to blank an inherited one.
function assert_settings_are_usable() {
  env_root="$1"
  names="$2"
  hint="$3"
  exempt=" $4 " # settings of the process itself, which share the prefix

  prefixes=""

  for name in $(echo "$names" | tr , ' '); do
    prefixes="${prefixes} $(name_env_prefix "$env_root" "$name")"
  done

  problems="$(env | awk -F= -v root="${env_root}_" -v list="${env_root}S" \
    -v prefixes="$prefixes" -v exempt="$exempt" -v hint="$hint" '
      index($1, root) != 1 || index(exempt, " " $1 " ") > 0 { next }

      {
        count = split(prefixes, known, " ")
        prefix = ""

        for (i = 1; i <= count; i++) {
          if (index($1, known[i]) == 1) {
            prefix = known[i]
          }
        }

        if (prefix == "") {
          print $1 " is not a setting of any name in " list
        }
        else if ($1 == prefix) {
          print $1 " names no setting"
        }
        else if (substr($0, length($1) + 2) == "") {
          print $1 " is empty, " hint
        }
      }' | sort)" # a stable order to report them in, which env has not

  if [ -n "$problems" ]; then
    echo "$problems" >&2
    exit 1
  fi
}

# One userlist entry per USERS name, the label standing in for the username when
# the database spells it in a way an env name cannot.
function generate_userlist_from_users() {
  # The writer reads the globals, so put back what the connection settings say
  # once the last credential is written.
  connection_user="${DB_USER}"
  connection_password="${DB_PASSWORD}"

  for name in $(echo "${USERS}" | tr , ' '); do
    prefix="$(name_env_prefix USER "$name")"
    DB_USER="$(env_setting "$prefix" NAME)"
    DB_USER="${DB_USER:-$name}"
    DB_PASSWORD="$(env_setting "$prefix" PASSWORD)"

    generate_userlist_if_needed
  done

  DB_USER="${connection_user}"
  DB_PASSWORD="${connection_password}"
}

# One [databases] entry per pool, each inheriting what it does not override.
function generate_pool_entries() {
  for name in $(echo "${POOLS}" | tr , ' '); do
    prefix="$(name_env_prefix POOL "$name")"

    # Fail here rather than hand pgbouncer an entry with an empty host.
    pool_host="$(env_setting "$prefix" HOST)"
    : "${pool_host:-${DB_HOST:?"Setup pgbouncer config error! Pool \"$name\" has no host, set ${prefix}HOST or DB_HOST"}}"

    # Only a warning: a mounted userlist may hold that role's password.
    pool_user="$(env_setting "$prefix" USER)"

    if [ -n "$pool_user" ] && [ -z "$(env_setting "$prefix" PASSWORD)" ]; then
      echo "Pool \"$name\" reaches the server as \"$pool_user\" with no password: set ${prefix}PASSWORD or list the role in ${_AUTH_FILE}" >&2
    fi

    printf "%s =%s\n" "$name" "$(pool_connect_string "$prefix" "$name")" \
      >> "${PG_CONFIG_FILE}"
  done
}

# DATABASE_URLS spells topology and credentials in one value; POOLS and USERS
# split them, and mixing the two spellings has no single reading.
if [ -n "${DATABASE_URLS}" ] && [ -n "${POOLS}${USERS}" ]; then
  echo "DATABASE_URLS cannot be combined with POOLS or USERS: name the entries in POOLS and the credentials in USERS" >&2
  exit 1
fi

# An existing config is served as it stands, so these pools would reach nothing.
if [ -n "${POOLS}" ] && [ -f "${PG_CONFIG_FILE}" ]; then
  echo "POOLS cannot be used with an existing ${PG_CONFIG_FILE}: that file is served as it stands, so no pool would be rendered into it" >&2
  exit 1
fi

# pgbouncer keeps this name for its admin console and refuses a database using it.
case ",${POOLS}," in
  *,pgbouncer,*)
    echo "Pool name \"pgbouncer\" is reserved for pgbouncer's own admin console" >&2
    exit 1
    ;;
esac

assert_names_are_usable POOL Pool "${POOLS}"
assert_settings_are_usable POOL "${POOLS}" "unset it to inherit" "POOL_MODE POOL_SIZE"

assert_names_are_usable USER User "${USERS}"
assert_settings_are_usable USER "${USERS}" "give it a value or drop the name from USERS" ""

# Every credential is checked before one is written: a userlist left half filled
# by a refused startup outlives it, and the writer skips names already in there.
for name in $(echo "${USERS}" | tr , ' '); do
  user_prefix="$(name_env_prefix USER "$name")"

  if [ -z "$(env_setting "$user_prefix" PASSWORD)" ]; then
    echo "User \"$name\" has no password, set ${user_prefix}PASSWORD" >&2
    exit 1
  fi
done

# Write the password with MD5 encryption, to avoid printing it during startup.
# Notice that `docker inspect` will show unencrypted env variables.
if [ -n "${DATABASE_URLS}" ]; then
  echo "${DATABASE_URLS}" | tr , '\n' | while read url; do
    parse_url "$url"
    generate_userlist_if_needed
  done
else
  if [ -n "${DATABASE_URL}" ]; then
    parse_url "${DATABASE_URL}"
  fi
  generate_userlist_if_needed
fi

if [ -n "${USERS}" ]; then
  generate_userlist_from_users
fi

if [ ! -f "${PG_CONFIG_FILE}" ]; then
  echo "Creating pgbouncer config in ${PG_CONFIG_DIR}"

  # Config file is in "ini" format. Section names are between "[" and "]".
  # Lines starting with ";" or "#" are taken as comments and ignored.
  # The characters ";" and "#" are not recognized when they appear later in the line.
  printf "\
################## Auto generated ##################
[databases]
" > "${PG_CONFIG_FILE}"

  if [ -n "$DATABASE_URL" ]; then
    parse_url "$DATABASE_URL"
  fi

  if [ -n "$POOLS" ]; then
    generate_pool_entries
  elif [ -n "$DATABASE_URLS" ]; then
    echo "$DATABASE_URLS" | tr , '\n' | while read url; do
      parse_url "$url"
      generate_config_db_entry
    done
  else
    generate_config_db_entry
  fi

  printf "\
[pgbouncer]
listen_addr = ${LISTEN_ADDR:-0.0.0.0}
listen_port = ${LISTEN_PORT:-5432}
unix_socket_dir = ${UNIX_SOCKET_DIR}
user = postgres
auth_file = ${_AUTH_FILE}
${AUTH_HBA_FILE:+auth_hba_file = ${AUTH_HBA_FILE}\n}\
auth_type = ${AUTH_TYPE:-md5}
${AUTH_USER:+auth_user = ${AUTH_USER}\n}\
${AUTH_QUERY:+auth_query = ${AUTH_QUERY}\n}\
${AUTH_DBNAME:+auth_dbname = ${AUTH_DBNAME}\n}\
${POOL_MODE:+pool_mode = ${POOL_MODE}\n}\
${MAX_CLIENT_CONN:+max_client_conn = ${MAX_CLIENT_CONN}\n}\
${DEFAULT_POOL_SIZE:+default_pool_size = ${DEFAULT_POOL_SIZE}\n}\
${MIN_POOL_SIZE:+min_pool_size = ${MIN_POOL_SIZE}\n}\
${RESERVE_POOL_SIZE:+reserve_pool_size = ${RESERVE_POOL_SIZE}\n}\
${RESERVE_POOL_TIMEOUT:+reserve_pool_timeout = ${RESERVE_POOL_TIMEOUT}\n}\
${MAX_DB_CONNECTIONS:+max_db_connections = ${MAX_DB_CONNECTIONS}\n}\
${MAX_USER_CONNECTIONS:+max_user_connections = ${MAX_USER_CONNECTIONS}\n}\
${SERVER_ROUND_ROBIN:+server_round_robin = ${SERVER_ROUND_ROBIN}\n}\
ignore_startup_parameters = ${IGNORE_STARTUP_PARAMETERS:-extra_float_digits}
${DISABLE_PQEXEC:+disable_pqexec = ${DISABLE_PQEXEC}\n}\
${APPLICATION_NAME_ADD_HOST:+application_name_add_host = ${APPLICATION_NAME_ADD_HOST}\n}\
${MAX_PREPARED_STATEMENTS:+max_prepared_statements = ${MAX_PREPARED_STATEMENTS}\n}\

# Log settings
${LOG_CONNECTIONS:+log_connections = ${LOG_CONNECTIONS}\n}\
${LOG_DISCONNECTIONS:+log_disconnections = ${LOG_DISCONNECTIONS}\n}\
${LOG_POOLER_ERRORS:+log_pooler_errors = ${LOG_POOLER_ERRORS}\n}\
${LOG_STATS:+log_stats = ${LOG_STATS}\n}\
${STATS_PERIOD:+stats_period = ${STATS_PERIOD}\n}\
${VERBOSE:+verbose = ${VERBOSE}\n}\
admin_users = ${ADMIN_USERS:-postgres}
${STATS_USERS:+stats_users = ${STATS_USERS}\n}\
${LOGFILE:+logfile = ${LOGFILE}\n}\n

# Connection sanity checks, timeouts
${SERVER_RESET_QUERY:+server_reset_query = ${SERVER_RESET_QUERY}\n}\
${SERVER_RESET_QUERY_ALWAYS:+server_reset_query_always = ${SERVER_RESET_QUERY_ALWAYS}\n}\
${SERVER_CHECK_DELAY:+server_check_delay = ${SERVER_CHECK_DELAY}\n}\
${SERVER_CHECK_QUERY:+server_check_query = ${SERVER_CHECK_QUERY}\n}\
${SERVER_LIFETIME:+server_lifetime = ${SERVER_LIFETIME}\n}\
${SERVER_IDLE_TIMEOUT:+server_idle_timeout = ${SERVER_IDLE_TIMEOUT}\n}\
${SERVER_CONNECT_TIMEOUT:+server_connect_timeout = ${SERVER_CONNECT_TIMEOUT}\n}\
${SERVER_LOGIN_RETRY:+server_login_retry = ${SERVER_LOGIN_RETRY}\n}\
${CLIENT_LOGIN_TIMEOUT:+client_login_timeout = ${CLIENT_LOGIN_TIMEOUT}\n}\
${AUTODB_IDLE_TIMEOUT:+autodb_idle_timeout = ${AUTODB_IDLE_TIMEOUT}\n}\
${DNS_MAX_TTL:+dns_max_ttl = ${DNS_MAX_TTL}\n}\
${DNS_NXDOMAIN_TTL:+dns_nxdomain_ttl = ${DNS_NXDOMAIN_TTL}\n}\

# TLS settings
${CLIENT_TLS_SSLMODE:+client_tls_sslmode = ${CLIENT_TLS_SSLMODE}\n}\
${CLIENT_TLS_KEY_FILE:+client_tls_key_file = ${CLIENT_TLS_KEY_FILE}\n}\
${CLIENT_TLS_CERT_FILE:+client_tls_cert_file = ${CLIENT_TLS_CERT_FILE}\n}\
${CLIENT_TLS_CA_FILE:+client_tls_ca_file = ${CLIENT_TLS_CA_FILE}\n}\
${CLIENT_TLS_PROTOCOLS:+client_tls_protocols = ${CLIENT_TLS_PROTOCOLS}\n}\
${CLIENT_TLS_CIPHERS:+client_tls_ciphers = ${CLIENT_TLS_CIPHERS}\n}\
${CLIENT_TLS_ECDHCURVE:+client_tls_ecdhcurve = ${CLIENT_TLS_ECDHCURVE}\n}\
${CLIENT_TLS_DHEPARAMS:+client_tls_dheparams = ${CLIENT_TLS_DHEPARAMS}\n}\
${SERVER_TLS_SSLMODE:+server_tls_sslmode = ${SERVER_TLS_SSLMODE}\n}\
${SERVER_TLS_CA_FILE:+server_tls_ca_file = ${SERVER_TLS_CA_FILE}\n}\
${SERVER_TLS_KEY_FILE:+server_tls_key_file = ${SERVER_TLS_KEY_FILE}\n}\
${SERVER_TLS_CERT_FILE:+server_tls_cert_file = ${SERVER_TLS_CERT_FILE}\n}\
${SERVER_TLS_PROTOCOLS:+server_tls_protocols = ${SERVER_TLS_PROTOCOLS}\n}\
${SERVER_TLS_CIPHERS:+server_tls_ciphers = ${SERVER_TLS_CIPHERS}\n}\

# Dangerous timeouts
${QUERY_TIMEOUT:+query_timeout = ${QUERY_TIMEOUT}\n}\
${QUERY_WAIT_TIMEOUT:+query_wait_timeout = ${QUERY_WAIT_TIMEOUT}\n}\
${CLIENT_IDLE_TIMEOUT:+client_idle_timeout = ${CLIENT_IDLE_TIMEOUT}\n}\
${IDLE_TRANSACTION_TIMEOUT:+idle_transaction_timeout = ${IDLE_TRANSACTION_TIMEOUT}\n}\
${PKT_BUF:+pkt_buf = ${PKT_BUF}\n}\
${MAX_PACKET_SIZE:+max_packet_size = ${MAX_PACKET_SIZE}\n}\
${LISTEN_BACKLOG:+listen_backlog = ${LISTEN_BACKLOG}\n}\
${SBUF_LOOPCNT:+sbuf_loopcnt = ${SBUF_LOOPCNT}\n}\
${SUSPEND_TIMEOUT:+suspend_timeout = ${SUSPEND_TIMEOUT}\n}\
${TCP_DEFER_ACCEPT:+tcp_defer_accept = ${TCP_DEFER_ACCEPT}\n}\
${TCP_KEEPALIVE:+tcp_keepalive = ${TCP_KEEPALIVE}\n}\
${TCP_KEEPCNT:+tcp_keepcnt = ${TCP_KEEPCNT}\n}\
${TCP_KEEPIDLE:+tcp_keepidle = ${TCP_KEEPIDLE}\n}\
${TCP_KEEPINTVL:+tcp_keepintvl = ${TCP_KEEPINTVL}\n}\
${TCP_USER_TIMEOUT:+tcp_user_timeout = ${TCP_USER_TIMEOUT}\n}\
################## end file ##################
" >> "${PG_CONFIG_FILE}"

  # A pool's password has to reach the file in the clear, and the logs never.
  awk '
    BEGIN {
      quote = sprintf("%c", 39)
      quoted = "password=" quote "((" quote quote ")|([^" quote "]))*" quote
    }

    {
      gsub(quoted, "password=***")
      gsub(/password=[^ ]+/, "password=***")
      print
    }' "${PG_CONFIG_FILE}"
fi

echo "Starting $*..."
exec "$@"
