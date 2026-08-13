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
    declares: the timezone and encoding a pool imposes, with an untouched pool
    as the witness, and `SHOW POOLS` while a pool of one holds a transaction and
    a second client waits. Drop the `pool_size` and that last one reads
    `cl_waiting=0`, so it cannot pass vacuously
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
  field including the host, and the two names it refuses. `live.sh` then serves
  traffic through three pools onto one database and reads their sizes back from
  `SHOW DATABASES`.
- A pool's settings are sorted before they reach the line — `env` order is not
  stable enough to compare against a file.
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
- `missing-db-host/expected/output.txt` carries the line number the entrypoint
  failed on, so it moves whenever lines are added above `generate_config_db_entry`.
