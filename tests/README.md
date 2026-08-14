# Tests

Characterization tests: they pin what `entrypoint.sh` renders **today**, bugs
included, so any change to the generator shows up as a diff.

One directory per case, holding its input and its expected output:

```
tests/<case>/env                     the environment, passed as --env-file
tests/<case>/existing.ini            optional, mounted at the config path
tests/<case>/expected/pgbouncer.ini  what the entrypoint renders
tests/<case>/expected/userlist.txt
tests/<case>/expected/output.txt     for cases the entrypoint is meant to reject
```

- `run.sh` — renders every case and compares it to `expected/`
  - directives, read from comments at the top of an `env`:
    - `# boot: yes` — pgbouncer must start with the rendered file
    - `# boot: fails` — pgbouncer must refuse it
    - `# expect: failure` — the entrypoint itself must exit non-zero, and its
      output is compared against `expected/output.txt`
  - `existing.ini` is an input, mounted at the config path, to assert the
    entrypoint leaves an already-present config alone
- `coverage.sh` — fails when `entrypoint.sh` reads a variable no case sets
  - line coverage would not catch that: the ~70 knobs share two `printf`
    statements, so any case marks them all covered
- `live.sh` — one postgres, one pooler, a real query through it
  - asserts `SHOW CONFIG` and `SHOW DATABASES` off the running pooler, not the
    generated text, so a setting the entrypoint writes but pgbouncer ignores
    cannot pass
  - `pool-effects.txt` records what a *session* sees rather than what the file
    declares:
    - the timezone and encoding a pool imposes, against an untouched pool as the
      witness
    - the role the session lands on: a pool given `POOL_<NAME>_USER` reaches the
      server as that role, one given none still carries the client's own
    - `SHOW POOLS` while a pool of one holds a transaction and a second client
      waits. Drop that `pool_size` and it reads `cl_waiting=0`, so the assertion
      cannot pass vacuously
  - it also reads the container's own log, for the two things no rendered file
    can show:
    - the echoed config carries `password=***` and nowhere the password itself
    - a pool forcing a user it holds no password for is warned about at boot
  - its expectations live in `tests/live/expected/`, and they move when the
    pinned pgbouncer version changes; that diff is the review signal for a bump

`run.sh` and `live.sh` take `IMAGE` (default `edoburu/pgbouncer:test`) and
`UPDATE_EXPECTED=1`. `live.sh` also takes `POSTGRES_IMAGE`, which CI runs over
the two latest majors; both produce the same expectations.

```bash
make docker-x86 IMAGE_VERSION=test
tests/coverage.sh
tests/run.sh
tests/live.sh
```

## Behaviours worth knowing

- `pools-*` cases cover `POOLS`: the rendered entries, an override of every
  field including the host, and everything it refuses. `live.sh` then serves
  traffic through three pools onto one database and reads their sizes back from
  `SHOW DATABASES`.
- Every `POOLS` and `USERS` refusal happens before a single file is touched, which
  is why none of their `expected/output.txt` carries the `Creating pgbouncer config`
  line. Only the legacy `missing-db-host` still fails mid-render, as it always did.
  - A `USERS` name missing its password is caught in that same pass rather than
    mid-write: `userlist.txt` is often a mounted volume, and the writer skips
    names already in it, so a half-written file outlives the startup that made it.
  - `pools-missing-host` is the same argument for `pgbouncer.ini`: rendering that
    far and failing then leaves a file the next start refuses as a mounted config.
- A setting is refused when it names nothing in `POOLS` or `USERS`
  (`pools-unlisted-setting`), since a misspelt pool otherwise renders defaults and
  says nothing. `POOL_MODE` and `POOL_SIZE` are exempt — the process's pool mode,
  and the default size of every entry, not settings of a pool named `MODE`/`SIZE`.
  - A pool's settings need no allowlist, pgbouncer reporting the parameters it
    knows not. A `USERS` name's do (`users-unknown-setting`): only `NAME` and
    `PASSWORD` are ever read, and nothing downstream sees a third to complain.
- `POOLS` and `USERS` are word-split unquoted, so `set -f` keeps a name out of the
  shell's globbing — `pools-glob-name` reads `*` as the name it is, and without
  that line the message would come back naming a file in the container's root.
- A pool's settings are sorted before they reach the line — `env` order is not
  stable enough to compare against a file.
- `auth_user` follows `DB_USER`, then `AUTH_USER`, then `postgres`, for entries and
  pools alike. `auth-user-beside-db-user` is the witness that must not move: it sets
  both, so it renders the same before and after that fallback existed.
- An empty override is refused by the entrypoint rather than passed on, because
  pgbouncer's own reaction to one depends on where it lands:

  ```
  dbname= host=db.example.com port=5432   accepted
  host=db.example.com dbname= port=5432   accepted
  host=db.example.com port=5432 dbname=   syntax error in connection string
  ```

  Only a trailing empty value is a syntax error. Since the settings are sorted,
  which mistake gets caught would depend on the alphabet — `POOL_X_TIMEZONE=`
  sorts last and fails loudly, `POOL_X_AUTH_USER=` sorts first and starts fine,
  then fails on the first query with an empty database name.
- A `userlist.txt` credential is reused for the onward login, so it only works in
  two shapes, both asserted in `live.sh`:
  - the password equals the role's on the server — pgbouncer verifies the client
    with it, then presents it onward. Disagreeing passwords authenticate at the
    pooler and are then refused by the server (`mismatched`)
  - or the pool carries `POOL_<NAME>_USER`, which supplies the server identity,
    so the credential needs no role at all (`ghost`)
- An empty `USER_<NAME>_PASSWORD` is refused for a different reason: Postgres has
  no such thing as an empty password.

  ```console
  postgres=# create role emptypw login password '';
  NOTICE:  empty string is not a valid password, clearing password
  CREATE ROLE
  ```

  The role ends up with `rolpassword` NULL, which no `md5` or `scram-sha-256`
  exchange can satisfy. A `userlist.txt` line built from one would be a
  credential that fails every login, quietly, at runtime.
- The shell names the line a failure came from, and every edit above it moves
  that number, so `run.sh` rewrites it to `line N` before comparing.
