# DevOps Simulator

Learn DevOps by fixing a (fake) production system in your browser. You get a
terminal, logs and dashboards for a small online shop, and things go wrong:
the disk fills up, memory leaks, a deploy breaks the site. Nothing is real,
so you can't break anything.

## Chapters

| # | Topic      | Chapter                | Status      |
|---|------------|------------------------|-------------|
| 1 | GitHub     | Open your first PR     | planned     |
| 2 | CI         | The build is red       | planned     |
| 3 | Deploy     | Roll back a bad release| planned     |
| 4 | Linux      | The disk is full       | playable (API) |
| 5 | Monitoring | Memory is climbing     | playable (API) |

Each chapter can be played on its own.

## Running it

```sh
cd backend
bundle install
bin/rails db:prepare
bin/rails server        # API on http://localhost:3000
bin/rails test
```

## Trying the API

```sh
curl -s -X POST localhost:3000/api/runs -H 'Content-Type: application/json' -d '{"scenario":"linux-disk-full"}'
curl -s -X POST localhost:3000/api/runs/1/commands -H 'Content-Type: application/json' -d '{"input":"ssh web-01"}'
curl -s -X POST localhost:3000/api/runs/1/tick
```

Live updates for a run are broadcast on the `RunChannel` (Action Cable, `/cable`, param `run_id`).
