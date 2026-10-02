# counting the daily check

the app asks `dictate.jass.gg/api/latest?version=0.9.4` once a day. `api/latest.ts` adds 1 to a counter for each ask. this file is how to switch the counting on, check that it works, and read the numbers. until step 1 is done the endpoint still answers and counts nothing.

## what is stored

one redis hash per utc day, with a field per version:

```
checkins:2026-10-02
  0.9.3      2
  0.9.4     12
  invalid    1
```

each hash expires 400 days after its last check. that is everything in the database. the function reads the `version` query parameter and nothing else from the request, so no ip address, user agent, id or other parameter is stored.

a `version` that is missing, or is not digits and dots, or is longer than 20 characters, is counted under `invalid`. i chose that over dropping it, so the daily total is every request and a bug that makes the app send nonsense shows up as a number. the text that was sent is never stored.

vercel keeps its own request logs for the site, ip addresses included, under its retention rules. my code doesn't read them and nothing here copies them.

## 1. make the database

use the vercel dashboard. the labels move around, so go by the names.

1. open the dictate project, then its **storage** tab. if there's no create button, open the **marketplace** from there and pick **upstash**.
2. create an **upstash for redis** database. name it `dictate-counts`. pick the free plan. pick the region closest to where the function runs. vercel's default is washington dc (`iad1`), so `us-east-1` on upstash's side.
3. connect it to the dictate project. when it asks which environments, pick **production** only. a preview deployment would add its test traffic to the real counts.
4. leave the environment variable prefix alone. the integration adds `KV_REST_API_URL`, `KV_REST_API_TOKEN`, `KV_REST_API_READ_ONLY_TOKEN`, `KV_URL` and `REDIS_URL`. the function reads the first two. it also accepts `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`, if upstash's own integration names them that way.
5. in project settings, **environment variables**, check the first two are there for production.

each check costs two redis commands, a counter bump and an expiry. the free plan's command allowance is far above a few dozen installs asking once a day.

## 2. redeploy

environment variables only reach deployments made after they exist. the counting code has to be merged and deployed first. then, if the deployment is older than step 1, redeploy: **deployments**, the latest production one, the three dots, **redeploy**.

## 3. check it

```sh
for i in 1 2 3; do curl -si "https://dictate.jass.gg/api/latest?version=0.0.1"; echo; done
```

each answer should be `HTTP/2 200` with `cache-control: no-store` and `{"latest":"0.9.5"}` (or whatever is newest). `x-vercel-cache` must not say `HIT`. `0.0.1` is a version no real mac has, so these three are easy to tell from real ones.

now read the counts:

```sh
cd apps/site
vercel env pull .env.local --environment=production
bun run checkins
```

`vercel env pull` needs `vercel link` run once in `apps/site`. without the cli, make `apps/site/.env.local` by hand from the upstash console (the database's page, **rest api**):

```
KV_REST_API_URL="https://<name>.upstash.io"
KV_REST_API_TOKEN="<token>"
```

`.env.local` is gitignored, like every `.env*` file in this repo. if `KV_REST_API_READ_ONLY_TOKEN` is in the file the script uses it, because reading is all the script does.

today's row should show `0.0.1  3`. three curls and a 1 means something is caching, and the counts are low. three curls and nothing means counting is off, see below.

to remove the test numbers, in the upstash console's data browser or cli tab run `HDEL checkins:<today's date> 0.0.1`.

## 4. reading it

```sh
cd apps/site
bun run checkins        # last 30 days
bun run checkins 7      # last 7
```

```
date        0.9.3  0.9.4  invalid  total
2026-10-01      -      4        -      4
2026-10-02      1      3        1      5
total           1      7        1      9
```

dates are utc, so a day ends at 05:30 in india. today's row is partial.

## what the numbers are

- checks, not people. the app asks about once a day per running mac, so a day's total is roughly the installs that were open that day. a mac that is shut for a week is missing for a week.
- debug builds ask too, with the version in `project.yml`, and nothing tells them apart. so do your own curls.
- anyone can call the endpoint, so anyone can add to a count. with no id there's nothing to stop that. the numbers are good for "how many, which versions", not for accounting.
- a lookup that fails on github's side is still counted. the check happened.

## when it breaks

counting never fails an answer. a count that fails is logged, once per request, as `check-in not counted: <the error>`. look in vercel's runtime logs for that.

- `store answered 401`: the token is wrong or was rotated. reconnect the integration, then redeploy.
- nothing logged and no counts: the variables aren't on the production deployment. step 1.5, then step 2.
- a timeout message: upstash took over 2 seconds. the answer went out without the count. once is noise, every request is a wrong region or an upstash outage.

## switching it off

disconnect the database from the project (storage tab, the database, **disconnect**), or delete the two variables, and redeploy. the endpoint keeps answering. delete the database to delete the numbers.
