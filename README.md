PgBouncer Docker image
======================

This is a minimal PgBouncer image, based on Alpine Linux.

Features:

* Very small, quick to pull (just 15MB)
* Configurable using environment variables
* Uses standard Postgres port 5432, to work transparently for applications.
* Includes PostgreSQL client tools such as ``psql``, ``pg_isready``
* MD5 authentication by default.
* `/etc/pgbouncer/pgbouncer.ini` and `/etc/pgbouncer/userlist.txt` are auto-created if they don't exist.

Why use PgBouncer
-----------------

PostgreSQL connections take up a lot of memory ([about 10MB per connection](http://hans.io/blog/2014/02/19/postgresql_connection)). There is also a significant startup cost to establish a connection with TLS, hence web applications gain performance by using persistent connections.

By placing PgBouncer in between the web application and the actual PostgreSQL database, the memory and start-up costs are reduced. The web application can keep persistent connections to PgBouncer, while PgBouncer only keeps a few connections to the actual PostgreSQL server. It can reuse the same connection for multiple clients.

Usage
-----

```sh
docker run --rm \
    -e DATABASE_URL="postgres://user:pass@postgres-host/database" \
    -p 5432:5432 \
    edoburu/pgbouncer
```

Or using separate variables:

```sh
docker run --rm \
    -e DB_USER=user \
    -e DB_PASSWORD=pass \
    -e DB_HOST=postgres-host \
    -e DB_NAME=database \
    -p 5432:5432 \
    edoburu/pgbouncer
```

During startup we'll generate the necessary `userlist.txt` & `pgbouncer.ini` entries to match this information. Connecting should work as expected:

```sh
psql 'postgresql://user:pass@localhost/dbname'
```

> [!NOTE]
> If you need quick multi-user setup you can use `DATABASE_URLS` (instead of `DATABASE_URL`) with a comma (`,`) separated list of URLs.
>
> ```sh
> docker run --rm \
>     -e DATABASE_URLS="postgres://foo:123@postgres-host/foo,postgres://bar:456@postgres-host/bar" \
>     -p 5432:5432 \
>     edoburu/pgbouncer
> ```

Configuration
-------------

Almost all settings found in the [pgbouncer.ini](https://pgbouncer.github.io/config.html) can be defined as environment variables, except a few that make little sense in a Docker environment (like port numbers, syslog and pid settings). See the [entrypoint script](https://github.com/edoburu/docker-pgbouncer/blob/master/entrypoint.sh) for details. For example:

```sh
docker run --rm \
    -e DATABASE_URL="postgres://user:pass@postgres-host/database" \
    -e POOL_MODE=session \
    -e SERVER_RESET_QUERY="DISCARD ALL" \
    -e MAX_CLIENT_CONN=100 \
    -p 5432:5432
    edoburu/pgbouncer
```

Multiple pools and users
------------------------

One PgBouncer can serve the same database through several pools, each with its own
size and its own identity, and hold credentials for several clients.

Typical goal, in one file:

- a **default** pool, inheriting everything
- a pool that only changes **who passwords are looked up as**
- a pool that changes **who the session becomes** on the server
- credentials listed in `userlist.txt`, so those clients need no lookup at all

### Doing it before these variables

`DATABASE_URLS` takes a comma-separated list of URLs and writes one `[databases]`
entry plus one `userlist.txt` line per URL.

```ini
DATABASE_URLS=postgres://app:s3cret@postgres-host/appdb,postgres://reporting:r3port@postgres-host/reports
```

- Every entry is named after its URL's path, so two pools cannot share a database.
- `pool_size`, `pool_mode` and the rest of the `[databases]` parameters cannot be
  expressed at all.
- One value carries both roles: the URL's user becomes the entry's `auth_user`
  *and* a `userlist.txt` credential.

Mounting a `pgbouncer.ini` gives full control, at the cost of leaving environment
configuration behind — every other variable this image reads stops applying.

### Doing it with POOLS and USERS

```ini
DB_HOST=postgres-host
DB_NAME=appdb
DB_USER=appuser
DB_PASSWORD=s3cret

POOLS=base,audit,readonly,reporting

POOL_BASE_POOL_SIZE=20

POOL_AUDIT_AUTH_USER=auditor

POOL_READONLY_USER=viewer
POOL_READONLY_PASSWORD=v13wer

POOL_REPORTING_USER=reporter
POOL_REPORTING_PASSWORD=r3port
POOL_REPORTING_AUTH_USER=reporter
POOL_REPORTING_POOL_SIZE=5

USERS=metrics
USER_METRICS_NAME=metrics.exporter
USER_METRICS_PASSWORD=…
```

renders — the copy echoed at startup shows those two passwords as `***`

```ini
[databases]
base = auth_user=appuser dbname=appdb host=postgres-host pool_size=20 port=5432
audit = auth_user=auditor dbname=appdb host=postgres-host port=5432
readonly = auth_user=appuser dbname=appdb host=postgres-host password=v13wer port=5432 user=viewer
reporting = auth_user=reporter dbname=appdb host=postgres-host password=r3port pool_size=5 port=5432 user=reporter
```

Each pool inherits the connection settings above it, overriding through
`POOL_<NAME>_<SETTING>` — any [connect string parameter](https://pgbouncer.github.io/config.html#section-databases).

Identity has two independent axes, and a pool may use either, both or neither:

- `POOL_<NAME>_USER` and `_PASSWORD` — the role the **server session** becomes.
  - Clients reach Postgres as that role whoever they authenticated as.
  - They then need no role of their own on the server, which is how one database
    role can serve many pooler credentials.
- `POOL_<NAME>_AUTH_USER` — the role PgBouncer **looks other users up as**.
  - Used for clients absent from `userlist.txt`, through `auth_query`.
  - Leaves the session identity alone: clients still arrive as themselves.

A pool is keyed on **(entry, user)**, so `pool_size` counts per client identity, not
per entry.

- Two clients arriving as different roles on one entry make two pools, each allowed
  its own `pool_size` — an entry capped at 20 holds 40 server connections.
- Setting `POOL_<NAME>_USER` collapses them into one pool, which is what makes the
  cap mean what it says.
- Combining it with `POOL_<NAME>_AUTH_USER` keeps clients authenticating as
  themselves while sharing that single pool.
- The cost is server-side identity: `current_user`, audit trails, row-level security
  and per-role grants all see the forced role.

`USERS` fills `userlist.txt`, one entry per name:

- A client listed there is verified against it directly, with no `auth_query`
  round trip to the server per login.
- Its password must equal the role's on the server, since PgBouncer presents it
  onward — unless the pool forces a user, in which case no server role is needed.
- A verifier copied out of `pg_authid` (`md5…`, `SCRAM-SHA-256$…`) is written
  through untouched instead of being hashed again.
- A username can be spelled in ways an environment variable cannot, so the name is
  a label and `USER_<LABEL>_NAME` carries the real one.

Names in `POOLS` and `USERS` take letters, digits and underscores, must be unique,
and none may be the prefix of another.

- `POOL_BASE_REPORTING_POOL_SIZE` would otherwise belong to both `base` and
  `base_reporting`, and names differing only in case collide the same way.
- `pgbouncer` is refused as a pool name: that one belongs to the admin console.

The rest is refused too, at startup and before a single file is written, rather
than misread in silence:

- a setting naming nothing in the list — `POOL_BSAE_POOL_SIZE` beside
  `POOLS=base` would otherwise leave a pool of plain defaults and say nothing.
  - `POOL_MODE` and `POOL_SIZE` keep their meaning: they configure the process,
    not a pool named `MODE` or `SIZE`.
- an empty override, which is a reference resolving to nothing far more often than
  a request to blank an inherited value.
- a name in `USERS` with no password, every name checked before the first one is
  written, since `userlist.txt` usually outlives the container that filled it.
- `POOLS` beside a mounted `pgbouncer.ini`: that file is served as it stands, so
  the pools would be rendered nowhere.

Two things are reported instead of refused:

- a pool forcing a user it carries no password for gets a warning — a mounted
  `userlist.txt` may hold that password, so it cannot be an error.
- the config echoed at startup shows `password=***`. The passwords reach the file,
  never the logs.

### DATABASE_URL and DATABASE_URLS

`DATABASE_URL` describes a single connection and still provides the defaults a pool
does not override.

`DATABASE_URLS` says who may connect *and* what they connect to in one value, which
`POOLS` and `USERS` split apart.

- The two spellings cannot be combined: mixing them has no single reading, and the
  container refuses to start rather than pick one.
- Nothing is lost by migrating — the table below maps each half.

| `DATABASE_URLS` gives you | replacement |
|---|---|
| one entry per URL, named by its path | `POOLS` + `POOL_<NAME>_DBNAME` |
| host and port per URL | `POOL_<NAME>_HOST` / `POOL_<NAME>_PORT` |
| that URL's user as the entry's `auth_user` | `POOL_<NAME>_AUTH_USER` |
| that URL's user and password in `userlist.txt` | `USERS` + `USER_<NAME>_PASSWORD` |

Kubernetes integration
----------------------

For example in Kubernetes, see the [examples/kubernetes folder](https://github.com/edoburu/docker-pgbouncer/tree/master/examples/kubernetes).

Docker Compose
--------------

For example in Docker Compose, see the [examples/docker-compose folder](https://github.com/edoburu/docker-pgbouncer/tree/master/examples/docker-compose).

PostgreSQL configuration
------------------------

Make sure PostgreSQL at least accepts connections from the machine where PgBouncer runs! Update `listen_addresses` in `postgresql.conf` and accept incoming connections from your IP range (e.g. `10.0.0.0/8`) in `pg_hba.conf`:

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD
host    all             all             10.0.0.0/8              md5
```

Using a custom configuration
----------------------------

When the default `pgbouncer.ini` is not sufficient, or you'd like to let multiple users connect through a single PgBouncer instance, mount an updated configuration:

```sh
docker run --rm \
    -e DB_USER=user \
    -e DB_PASSWORD=pass \
    -e DB_HOST=postgres-host \
    -e DB_NAME=database \
    -v pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
    -p 5432:5432
    edoburu/pgbouncer
```

Or extend the `Dockerfile`:

```Dockerfile
FROM edoburu/pgbouncer:1.11.0
COPY pgbouncer.ini userlist.txt /etc/pgbouncer/
```

When the `pgbouncer.ini` file exists, the startup script will not override it. An extra entry will be written to `userlist.txt` when `DATABASE_URL` contains credentials, or `DB_USER` and `DB_PASSWORD` are defined.

The `userlist.txt` file uses the following format:

```txt
"username" "plaintext-password"
```

or:

```txt
"username" "md5<md5 of password + username>"
```

Use [examples/generate-userlist](https://github.com/edoburu/docker-pgbouncer/blob/master/examples/generate-userlist) to generate this file:

```sh
examples/generate-userlist >> userlist.txt
```

You can also connect with a single user to PgBouncer, and from there retrieve the actual database password
by setting ``AUTH_USER``. See the example from: <https://www.cybertec-postgresql.com/en/pgbouncer-authentication-made-easy/>

Connecting to the admin console
-------------------------------

When an *admin user* is defined, and it has a password in the `userlist.txt`, it can connect to the special `pgbouncer` database:

```sh
psql postgres://postgres@hostname-of-container/pgbouncer  # outside container
psql postgres://127.0.0.1/pgbouncer                       # inside container
```

Hence this requires a custom configuration, or a mount of a custom ``userlist.txt`` in the docker file.
Various [admin console commands](https://pgbouncer.github.io/usage.html#admin-console) can be executed, for example:

```sql
SHOW STATS;
SHOW SERVERS;
SHOW CLIENTS;
SHOW POOLS;
```

And it allows temporary disconnecting the backend database (e.g. for restarts) while the web applications keep a connection to PgBouncer:

```sql
PAUSE;
RESUME;
```
