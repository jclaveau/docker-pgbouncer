#!/usr/bin/env bash
# End-to-end test: real postgres behind the pooler, asserting the runtime config
# pgbouncer loaded. UPDATE_EXPECTED=1 rewrites them.
set -euo pipefail

image="${IMAGE:-edoburu/pgbouncer:test}"
postgres_image="${POSTGRES_IMAGE:-postgres:17-alpine}"
update_expected="${UPDATE_EXPECTED:-0}"

tests_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
expected_dir="$tests_dir/live/expected"

network=pgbouncer-live-test
postgres_container=pgbouncer-live-postgres
pooler_container=pgbouncer-live-pooler
pools_container=pgbouncer-live-pools

work_dir=$(mktemp -d)

teardown() {
  docker rm -f "$pools_container" "$pooler_container" "$postgres_container" \
    > /dev/null 2>&1 || true
  docker network rm "$network" > /dev/null 2>&1 || true
}

trap 'teardown; rm -rf "$work_dir"' EXIT
teardown # leftovers from an interrupted run

docker network create "$network" > /dev/null

docker run -d --name "$postgres_container" --network "$network" \
  --env POSTGRES_USER=appuser \
  --env POSTGRES_PASSWORD=s3cret \
  --env POSTGRES_DB=appdb \
  "$postgres_image" > /dev/null

deadline=$((SECONDS + 60))

until docker exec "$postgres_container" pg_isready -U appuser -d appdb > /dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "postgres never became ready:"
    docker logs "$postgres_container" 2>&1 | awk '{ print "  " $0 }'
    exit 1
  fi

  sleep 1
done

docker run -d --name "$pooler_container" --network "$network" \
  --env "DATABASE_URL=postgres://appuser:s3cret@$postgres_container:5432/appdb" \
  --env AUTH_TYPE=scram-sha-256 \
  --env POOL_MODE=transaction \
  --env LISTEN_ADDR='*' \
  --env LISTEN_PORT=6432 \
  --env DEFAULT_POOL_SIZE=17 \
  --env MAX_CLIENT_CONN=1234 \
  --env IGNORE_STARTUP_PARAMETERS=extra_float_digits \
  --env SERVER_TLS_SSLMODE=disable \
  --env ADMIN_USERS=appuser \
  "$image" > /dev/null

deadline=$((SECONDS + 60))

until docker logs "$pooler_container" 2>&1 | grep -q "process up:"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "pgbouncer never started:"
    docker logs "$pooler_container" 2>&1 | awk '{ print "  " $0 }'
    exit 1
  fi

  sleep 1
done

query_through_pooler() {
  docker exec --env PGPASSWORD=s3cret "$pooler_container" \
    psql "postgres://appuser@127.0.0.1:6432/$1" -tAX -c "$2"
}

proxied_database=$(query_through_pooler appdb "select current_database()")

if [ "$proxied_database" != "appdb" ]; then
  echo "expected a query through the pooler to reach appdb, got '$proxied_database'"
  exit 1
fi

# The generated file is only a claim; SHOW CONFIG is what pgbouncer actually runs.
pinned_settings='auth_type auth_file admin_users pool_mode max_client_conn
default_pool_size listen_addr listen_port ignore_startup_parameters
server_tls_sslmode client_tls_sslmode auth_query max_prepared_statements
server_reset_query server_lifetime server_idle_timeout'

query_through_pooler pgbouncer "SHOW CONFIG" \
  | awk -F'|' -v settings="$pinned_settings" '
      BEGIN { split(settings, wanted, /[ \n]+/); for (i in wanted) keep[wanted[i]] = 1 }
      keep[$1] { print $1 "|" $2 }
    ' \
  | sort > "$work_dir/show-config.txt"

query_through_pooler pgbouncer "SHOW DATABASES" \
  | awk -F'|' '{ print $1 "|" $3 "|" $6 }' \
  | sort > "$work_dir/show-databases.txt"

docker run -d --name "$pools_container" --network "$network" \
  --env "DATABASE_URL=postgres://appuser:s3cret@$postgres_container:5432/appdb" \
  --env AUTH_TYPE=scram-sha-256 \
  --env POOL_MODE=transaction \
  --env LISTEN_ADDR='*' \
  --env LISTEN_PORT=6432 \
  --env SERVER_TLS_SSLMODE=disable \
  --env ADMIN_USERS=appuser \
  --env POOLS=base,paid,free,capped \
  --env POOL_BASE_POOL_SIZE=20 \
  --env POOL_PAID_POOL_SIZE=34 \
  --env POOL_FREE_POOL_SIZE=10 \
  --env POOL_FREE_TIMEZONE=Europe/Paris \
  --env POOL_FREE_CLIENT_ENCODING=LATIN1 \
  --env POOL_CAPPED_POOL_SIZE=1 \
  "$image" > /dev/null

deadline=$((SECONDS + 60))

until docker logs "$pools_container" 2>&1 | grep -q "process up:"; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "the pooled pgbouncer never started:"
    docker logs "$pools_container" 2>&1 | awk '{ print "  " $0 }'
    exit 1
  fi

  sleep 1
done

# Every tier must reach the one real database, each through its own pool.
for pool in base paid free; do
  pooled_database=$(
    docker exec --env PGPASSWORD=s3cret "$pools_container" \
      psql "postgres://appuser@127.0.0.1:6432/$pool" -tAX -c "select current_database()"
  )

  if [ "$pooled_database" != "appdb" ]; then
    echo "expected pool $pool to reach appdb, got '$pooled_database'"
    exit 1
  fi
done

docker exec --env PGPASSWORD=s3cret "$pools_container" \
  psql "postgres://appuser@127.0.0.1:6432/pgbouncer" -tAX -c "SHOW DATABASES" \
  | awk -F'|' '{ print $1 "|" $3 "|" $6 }' \
  | sort > "$work_dir/show-databases-pools.txt"

query_pool() {
  docker exec --env PGPASSWORD=s3cret "$pools_container" \
    psql "postgres://appuser@127.0.0.1:6432/$1" -tAX -c "$2"
}

# A setting on a pool has to reach the session, not merely parse. base is the
# witness: same server, no overrides.
{
  printf 'base timezone=%s\n' "$(query_pool base "select current_setting('TimeZone')")"
  printf 'free timezone=%s\n' "$(query_pool free "select current_setting('TimeZone')")"
  printf 'base client_encoding=%s\n' "$(query_pool base 'show client_encoding')"
  printf 'free client_encoding=%s\n' "$(query_pool free 'show client_encoding')"
} > "$work_dir/pool-effects.txt"

# pool_size has to cap: hold one transaction on a pool of one, and a second
# client must queue instead of opening a second server connection.
for _ in 1 2; do
  docker exec --detach --env PGPASSWORD=s3cret "$pools_container" \
    psql "postgres://appuser@127.0.0.1:6432/capped" -tAX \
    -c "begin; select pg_sleep(20); commit;" > /dev/null
done

deadline=$((SECONDS + 30))

until [ "$(query_pool pgbouncer "SHOW POOLS" | awk -F'|' '$1 == "capped" { print $4 }')" = "1" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "no client ever queued on a pool of one, so pool_size did not cap:"
    query_pool pgbouncer "SHOW POOLS" | awk -F'|' '$1 == "capped"' | awk '{ print "  " $0 }'
    exit 1
  fi

  sleep 1
done

query_pool pgbouncer "SHOW POOLS" \
  | awk -F'|' '$1 == "capped" { print "capped cl_active=" $3 " cl_waiting=" $4 " sv_active=" $7 }' \
  >> "$work_dir/pool-effects.txt"

status=0

for artifact in show-config.txt show-databases.txt show-databases-pools.txt pool-effects.txt; do
  if [ "$update_expected" = "1" ]; then
    mkdir -p "$expected_dir"
    cp "$work_dir/$artifact" "$expected_dir/$artifact"
    continue
  fi

  diff -u "$expected_dir/$artifact" "$work_dir/$artifact" || status=1
done

if [ "$status" -ne 0 ]; then
  echo "FAILED: the pooler's runtime config drifted"
  exit 1
fi

if [ "$update_expected" = "1" ]; then
  echo "Expectations updated — review the diff before committing."
else
  echo "Live pooler matches its expectations."
fi
