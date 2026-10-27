# Splunk Queries for the Assignment Portal

Ready-to-paste Splunk searches for the logs collected by the setup in [`README.md`](README.md).
Paste a query into **Search & Reporting**, choose a **time range** at the right of the search bar, and press Enter.

## Before you start (2 minutes)

**1. Every search starts with `index=k8s_logs`.** That is the index created by the install script.

**2. Short field names.** The install script creates these search-time aliases, so you can type `app=backend` instead of `kubernetes.labels.app=backend`:

| Short name | Long name | Example values |
|---|---|---|
| `app` | `kubernetes.labels.app` | `backend`, `frontend`, `postgres`, `redis` |
| `namespace` | `kubernetes.namespace_name` | `assignment-portal` |
| `pod` | `kubernetes.pod_name` | `backend-7d9f8c6b5-abcde` |
| `container` | `kubernetes.container_name` | `backend`, `frontend`, `postgres`, `redis` |
| `image` | `kubernetes.container_image` | `...ecr.../assignment-portal-backend:<commit-sha>` |

Other fields you can use: `host` (the EKS **node**), `stream` (`stdout` / `stderr`), `cluster` (`my-eks-cluster`), and `log` (the **log line itself**).
If the short names do not work (no results), replace them with the long names, or see *Troubleshooting* in the README.

**3. Where the text is.** The log line is in the field `log`. Most queries read it with `rex field=log`. If your app later prints JSON, the text moves into fields such as `message`; see section 11.

**4. What was already removed by Fluent Bit.** Kubernetes probes (`kube-probe`), ALB health checks (`ELB-HealthChecker`), `GET /health` and `GET /metrics` never reach Splunk, so they will not distort your numbers. Only the `assignment-portal` namespace is collected.

**5. The queries were written for the standard formats** of Nginx, Flask / Werkzeug / Gunicorn, PostgreSQL and Redis. I could not see your backend's source code, so keyword searches (login, upload, submit ...) are guesses you should adjust after running query 5.1.

**6. Handy habits.**
- Use `| head 20` while testing a long query.
- Add `| table field1 field2` to choose columns, `| sort - count` to put the biggest first.
- *Smart mode* (default) is fine; switch to *Verbose* only if field lists are missing.
- Time shortcuts you can type: `earliest=-15m`, `earliest=-24h@h`, `earliest=-7d@d latest=@d`.
- To keep a search: **Save As > Report / Alert / Dashboard Panel**.
- To download results: the **Export** button above the results (CSV / JSON).

## Contents

1. [Pipeline health and data discovery](#1-pipeline-health-and-data-discovery) (24 searches)
2. [Browsing and searching the logs](#2-browsing-and-searching-the-logs) (19 searches)
3. [Errors, warnings and exceptions](#3-errors-warnings-and-exceptions) (20 searches)
4. [Web traffic: frontend (Nginx) access log](#4-web-traffic-frontend-nginx-access-log) (38 searches)
5. [Backend (Flask / Gunicorn)](#5-backend-flask--gunicorn) (27 searches)
6. [PostgreSQL](#6-postgresql) (19 searches)
7. [Redis](#7-redis) (8 searches)
8. [Kubernetes lifecycle and releases (from the logs)](#8-kubernetes-lifecycle-and-releases-from-the-logs) (12 searches)
9. [Security and abuse](#9-security-and-abuse) (14 searches)
10. [If you also collect other namespaces (ArgoCD, monitoring)](#10-if-you-also-collect-other-namespaces-argocd-monitoring) (3 searches)
11. [If your app switches to JSON logging later](#11-if-your-app-switches-to-json-logging-later) (3 searches)
12. [Ready-made alerts](#12-ready-made-alerts) (14 searches)
13. [Starter dashboard (copy these panels)](#13-starter-dashboard-copy-these-panels) (12 searches)

---

## 1. Pipeline health and data discovery

Start here. These prove logs are flowing and show you what the data looks like.

### 1.1 Is anything arriving right now?

One row with the number of events in the last 15 minutes and the time of the newest one.

```spl
index=k8s_logs earliest=-15m
| stats count, latest(_time) as last_event
| eval last_event=strftime(last_event,"%F %T")
```

### 1.2 Events per component

backend / frontend / postgres / redis. Quiet components (postgres, redis) have small counts; that is normal.

```spl
index=k8s_logs
| stats count by app
| sort - count
```

### 1.3 Events per pod

One row per pod. After an ArgoCD rollout you will see old and new pod names.

```spl
index=k8s_logs
| stats count by app, pod
| sort app, - count
```

### 1.4 Events per worker node

`host` is the EKS node that ran the pod. Shows how your 3 nodes share the load.

```spl
index=k8s_logs
| stats count by host
| sort - count
```

### 1.5 Events per container

Every pod of this app has one container, so this should match the component list.

```spl
index=k8s_logs
| stats count by app, container
```

### 1.6 Log volume over time per component

The basic traffic chart. Use a line or stacked column chart.

```spl
index=k8s_logs
| timechart span=5m count by app
```

### 1.7 Log volume per node over time

If one node suddenly drops to zero, Fluent Bit on that node (or the node itself) has a problem.

```spl
index=k8s_logs
| timechart span=5m count by host
```

### 1.8 Pods that went silent

Pods that logged in the last hour but not in the last 10 minutes. A quiet pod may simply be idle (health checks are filtered out), so read the result as a hint, not proof.

```spl
index=k8s_logs earliest=-60m
| stats latest(_time) as last_seen by app, pod
| eval minutes_silent=round((now()-last_seen)/60,1)
| where minutes_silent>10
| eval last_seen=strftime(last_seen,"%F %T")
| sort - minutes_silent
```

### 1.9 Ingestion delay (log written -> searchable)

How many seconds pass between the app printing a line and Splunk indexing it. Normally 5-15 s. Large values mean Fluent Bit is catching up (e.g. after a Splunk outage).

```spl
index=k8s_logs
| eval lag_sec=_indextime-_time
| stats avg(lag_sec) as avg_lag max(lag_sec) as max_lag perc95(lag_sec) as p95_lag by app
```

### 1.10 Ingestion delay over time

Spikes show moments where Splunk was unreachable or slow.

```spl
index=k8s_logs
| eval lag_sec=_indextime-_time
| timechart span=5m avg(lag_sec) as avg_lag max(lag_sec) as max_lag
```

### 1.11 stdout versus stderr

Flask and Gunicorn print their normal messages to stderr, so a lot of stderr is not automatically bad.

```spl
index=k8s_logs
| stats count by app, stream
```

### 1.12 Which namespaces are being collected?

Should be exactly one row: assignment-portal (unless you widened the Path in the ConfigMap).

```spl
index=k8s_logs
| stats count by namespace
```

### 1.13 Cluster tag check

Every event is tagged with the cluster name by Fluent Bit.

```spl
index=k8s_logs
| stats count by cluster
```

### 1.14 What fields do my events have?

Lists every field Splunk found, how many events have it and a few example values. Great for learning the data.

```spl
index=k8s_logs earliest=-15m
| fieldsummary maxvals=5
| table field count distinct_count values
| sort - count
```

### 1.15 One sample event per component

Quickest way to see what each component's log line looks like.

```spl
index=k8s_logs
| dedup app
| table _time app pod stream log
```

### 1.16 Newest 50 log lines of the whole app

Like `kubectl logs`, but for every pod at once.

```spl
index=k8s_logs
| head 50
| table _time app pod stream log
```

### 1.17 First and last event in the index

Tells you how far back your data goes.

```spl
index=k8s_logs
| stats earliest(_time) as first_event latest(_time) as last_event count
| eval first_event=strftime(first_event,"%F %T"), last_event=strftime(last_event,"%F %T")
```

### 1.18 Data volume per component (MB)

Which component produces most of your Splunk volume (and license usage).

```spl
index=k8s_logs
| eval bytes=len(_raw)
| stats sum(bytes) as bytes count by app
| eval MB=round(bytes/1024/1024,2)
| sort - bytes
| fields app count MB
```

### 1.19 Noisiest pods

Top 10 pods by number of events. A single very chatty pod is a good candidate for a filter.

```spl
index=k8s_logs
| stats count by pod
| sort - count
| head 10
```

### 1.20 Events per minute and bytes per minute

Use to estimate daily volume: multiply the average by 1440.

```spl
index=k8s_logs
| eval bytes=len(_raw)
| timechart span=1m count as events sum(bytes) as bytes
```

### 1.21 Splunk-side HEC problems

Errors Splunk itself logged while receiving data from Fluent Bit (bad token, bad index, ...). Run in the same time range as the problem.

```spl
index=_internal source=*splunkd.log* component=HttpInputDataHandler (log_level=ERROR OR log_level=WARN)
| stats count by log_level, event_message
| sort - count
```

### 1.22 How full is the k8s_logs index?

Current size against the cap set by the install script, with the date range it holds.

```spl
| rest /services/data/indexes/k8s_logs splunk_server=local
| eval used_pct=round(100*currentDBSizeMB/maxTotalDataSizeMB,1)
| table title currentDBSizeMB maxTotalDataSizeMB used_pct totalEventCount minTime maxTime
```

### 1.23 Disk space the index really uses

Size on disk and event count from the index buckets.

```spl
| dbinspect index=k8s_logs
| stats sum(sizeOnDiskMB) as MB_on_disk sum(eventCount) as events min(startEpoch) as oldest max(endEpoch) as newest
| eval oldest=strftime(oldest,"%F %T"), newest=strftime(newest,"%F %T")
```

### 1.24 License usage per day

Daily GB indexed into k8s_logs. Compare with the limit in Settings > Licensing.

```spl
index=_internal source=*license_usage.log* type=Usage idx=k8s_logs
| eval GB=b/1024/1024/1024
| timechart span=1d sum(GB) as GB_indexed
```

## 2. Browsing and searching the logs

Everyday searching: the Splunk version of `kubectl logs`, but across all pods and all time.

### 2.1 Frontend (Nginx) logs

Newest first. Add a time range at the top right of the search bar.

```spl
index=k8s_logs app=frontend
| table _time pod stream log
```

### 2.2 Backend (Flask/Gunicorn) logs

```spl
index=k8s_logs app=backend
| table _time pod stream log
```

### 2.3 PostgreSQL logs

```spl
index=k8s_logs app=postgres
| table _time pod log
```

### 2.4 Redis logs

```spl
index=k8s_logs app=redis
| table _time pod log
```

### 2.5 All logs of one pod

Replace the pod name with one from the pod list (query 1.3). Wildcards work.

```spl
index=k8s_logs pod="backend-*"
| table _time pod log
```

### 2.6 Chronological order (oldest first)

Splunk shows newest first by default. `sort 0 _time` reads like a log file.

```spl
index=k8s_logs app=backend
| sort 0 _time
| table _time pod log
```

### 2.7 Search for a word or phrase

Plain text search is case-insensitive. Quote phrases.

```spl
index=k8s_logs "connection refused"
| table _time app pod log
```

### 2.8 Several words with AND / OR / NOT

Parentheses group OR terms. NOT removes events.

```spl
index=k8s_logs app=backend (login OR logout OR "sign in") NOT favicon
| table _time pod log
```

### 2.9 Wildcard search

`*` matches any characters.

```spl
index=k8s_logs app=backend *timeout*
| table _time pod log
```

### 2.10 Regular-expression filter

Keep only events whose log line matches a regex (case-insensitive here).

```spl
index=k8s_logs app=backend
| regex log="(?i)timeout|refused|reset by peer"
| table _time pod log
```

### 2.11 Only stderr lines

```spl
index=k8s_logs stream=stderr
| table _time app pod log
```

### 2.12 Everything from one worker node

Handy when a node misbehaves. Use the node name from `kubectl get nodes`.

```spl
index=k8s_logs host="ip-*.ec2.internal"
| stats count by host, app
```

### 2.13 Logs from one release (image tag)

Your image tag is the Git commit SHA. Replace it with the one from deployment.yaml.

```spl
index=k8s_logs app=backend image="*d399c71f34b7157d54c81573db80b3306e985ecf*"
| table _time pod log
```

### 2.14 Look at what happened around a moment

Replace pod and times. Shows the 5 minutes around an incident in order.

```spl
index=k8s_logs pod="backend-*" earliest="10/26/2026:10:00:00" latest="10/26/2026:10:05:00"
| sort 0 _time
| table _time pod stream log
```

### 2.15 Live tail (real-time)

Set the time picker to Real-time > 5 minute window, then run. Shows new lines as they arrive.

```spl
index=k8s_logs app=backend
| table _time pod log
```

### 2.16 Longest log lines

Finds huge messages (large payloads, dumps, stack traces). Long lines can also hide secrets.

```spl
index=k8s_logs
| eval len=len(log)
| sort - len
| head 10
| table _time app pod len log
```

### 2.17 Count of one word over time

Replace the word. Good for a quick trend of any phrase.

```spl
index=k8s_logs "timeout"
| timechart span=15m count by app
```

### 2.18 Compare today with yesterday

Overlays the same chart for 1-day-earlier periods. Needs a time range of at least 2 days.

```spl
index=k8s_logs app=frontend
| timechart span=1h count
| timewrap 1d series=short
```

### 2.19 Events in a busy minute

Finds the 10 busiest minutes of the selected time range.

```spl
index=k8s_logs
| bin _time span=1m
| stats count by _time
| sort - count
| head 10
```

## 3. Errors, warnings and exceptions

Finds problems fast. The level is read from the log text, so it works for Gunicorn, Flask and plain Python logging.

### 3.1 Log levels of the backend

Counts DEBUG / INFO / WARNING / ERROR / CRITICAL found in the log text.

```spl
index=k8s_logs app=backend
| rex field=log "(?i)\b(?<lvl>DEBUG|INFO|WARNING|WARN|ERROR|CRITICAL|FATAL)\b"
| eval level=upper(lvl)
| stats count by level
| sort - count
```

### 3.2 Log levels over time

```spl
index=k8s_logs app=backend
| rex field=log "(?i)\b(?<lvl>DEBUG|INFO|WARNING|WARN|ERROR|CRITICAL|FATAL)\b"
| eval level=upper(lvl)
| timechart span=15m count by level
```

### 3.3 All errors in the whole application

Counts error-looking lines per component.

```spl
index=k8s_logs (ERROR OR Exception OR Traceback OR CRITICAL OR FATAL OR PANIC)
| stats count by app
```

### 3.4 Error lines, newest first

The detailed list behind the count above.

```spl
index=k8s_logs (ERROR OR Exception OR Traceback OR CRITICAL OR FATAL OR PANIC)
| table _time app pod stream log
```

### 3.5 Errors over time per component

```spl
index=k8s_logs (ERROR OR Exception OR Traceback OR CRITICAL OR FATAL OR PANIC)
| timechart span=15m count by app
```

### 3.6 Top error messages

Numbers are replaced by N so that the same message with different ids is counted together.

```spl
index=k8s_logs (ERROR OR Exception OR CRITICAL OR FATAL)
| rex mode=sed field=log "s/[0-9]+/N/g"
| stats count by app, log
| sort - count
| head 20
```

### 3.7 Backend error rate (%)

Share of backend lines that are errors, per 5 minutes.

```spl
index=k8s_logs app=backend
| rex field=log "(?i)\b(?<err>ERROR|CRITICAL|FATAL)\b"
| timechart span=5m count(err) as errors count as total
| eval error_pct=round(100*errors/total,2)
```

### 3.8 Warnings

```spl
index=k8s_logs (WARNING OR WARN)
| stats count by app, pod
| sort - count
```

### 3.9 Python tracebacks over time

A traceback means an unhandled exception in the backend.

```spl
index=k8s_logs app=backend "Traceback (most recent call last)"
| timechart span=15m count
```

### 3.10 Which exceptions happen most?

Reads the last line of a traceback (for example `psycopg2.OperationalError: ...`). Works because each traceback line is its own event.

```spl
index=k8s_logs app=backend
| rex field=log "^(?<exception>[A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Exit|Timeout)):"
| stats count latest(log) as example by exception
| sort - count
```

### 3.11 Which file and line fail most?

Reads the `File "...", line N` part of tracebacks.

```spl
index=k8s_logs app=backend "File \""
| rex field=log "File \"(?<file>[^\"]+)\", line (?<line_no>\d+), in (?<function>\S+)"
| stats count by file, line_no, function
| sort - count
| head 20
```

### 3.12 Brand-new error messages (first seen in the last day)

Messages that never appeared in the previous 7 days. Excellent right after a release.

```spl
index=k8s_logs app=backend (ERROR OR Exception) earliest=-7d
| rex mode=sed field=log "s/[0-9]+/N/g"
| stats earliest(_time) as first_seen count by log
| where first_seen>relative_time(now(),"-1d")
| eval first_seen=strftime(first_seen,"%F %T")
| sort - count
```

### 3.13 Errors per pod

If one replica has many more errors than the others, suspect that pod or its node.

```spl
index=k8s_logs app=backend (ERROR OR Exception OR Traceback)
| stats count latest(log) as latest_message by pod, host
| sort - count
```

### 3.14 Error bursts (more than 20 per minute)

```spl
index=k8s_logs (ERROR OR Exception OR Traceback OR FATAL)
| bin _time span=1m
| stats count by _time, app
| where count>20
| sort - count
```

### 3.15 Errors by hour of the day

Shows if problems happen at a certain time (for example around an assignment deadline).

```spl
index=k8s_logs (ERROR OR Exception OR Traceback)
| eval hour=strftime(_time,"%H")
| stats count by hour
| sort hour
```

### 3.16 Errors today compared with yesterday

```spl
index=k8s_logs (ERROR OR Exception OR Traceback)
| timechart span=1h count
| timewrap 1d series=short
```

### 3.17 Smoothed error trend

Adds a moving average so that a rising trend stands out from random noise.

```spl
index=k8s_logs (ERROR OR Exception OR Traceback)
| timechart span=10m count
| trendline sma6(count) as trend
```

### 3.18 Timeouts and refused connections

Typical symptoms of a dependency (Postgres, Redis, the backend) being down or slow.

```spl
index=k8s_logs (timeout OR "timed out" OR "connection refused" OR "connection reset" OR "broken pipe" OR "name resolution")
| stats count by app, pod
| sort - count
```

### 3.19 Out-of-memory and kill signals

Kubernetes kills a container that goes over its memory limit (backend 512Mi, postgres 512Mi, redis 256Mi).

```spl
index=k8s_logs ("out of memory" OR OOM OR "SIGKILL" OR "Killed" OR "Cannot allocate memory" OR "MemoryError")
| table _time app pod log
```

### 3.20 Error samples by component

One example error per pod, handy for a quick look.

```spl
index=k8s_logs (ERROR OR Exception OR FATAL)
| stats count latest(log) as sample by app, pod
| sort app, - count
```

## 4. Web traffic: frontend (Nginx) access log

The frontend pods log every request that reaches your portal through the ALB. Each query below starts with the same 4 lines that read the Nginx *combined* log format into fields (`client_ip method uri path status resp_bytes referer user_agent xff`). Health checks and `/metrics` are already dropped by Fluent Bit. **Note:** behind an ALB, Nginx normally sees the load balancer's address in `client_ip`; the visitor's real address is only in `xff` (X-Forwarded-For) if your Nginx log format prints it. Queries that need a visitor address use `real_ip`, which picks `xff` when present.

### 4.1 Check that the parsing works

You should see a clean table. If `status` is empty, your Nginx log format differs; look at the raw lines with query 2.1 and adjust.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| head 20
| table _time pod client_ip method path status resp_bytes user_agent xff
```

### 4.2 Requests per minute

Traffic to the portal.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| timechart span=1m count as requests
```

### 4.3 Requests per pod over time

Shows whether the load balancer spreads traffic across all frontend pods.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| timechart span=5m count by pod
```

### 4.4 HTTP status codes

How many 200, 302, 404, 500 ...

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by status
| sort - count
```

### 4.5 Status classes over time (2xx / 3xx / 4xx / 5xx)

The classic health chart. Use a stacked column chart.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval class=substr(status,1,1)."xx"
| timechart span=5m count by class
```

### 4.6 Server error rate (5xx %)

Percentage of requests that failed on the server side, per 5 minutes.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| timechart span=5m count(eval(status>=500)) as errors_5xx count as total
| eval error_pct=round(100*errors_5xx/total,2)
```

### 4.7 Client error rate (4xx %)

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| timechart span=5m count(eval(status>=400 AND status<500)) as errors_4xx count as total
| eval error_pct=round(100*errors_4xx/total,2)
```

### 4.8 Availability percentage

Share of requests that did not end in a 5xx error in the selected time range.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count(eval(status<500)) as ok count as total
| eval availability_pct=round(100*ok/total,3)
```

### 4.9 Top 20 pages (without query string)

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by path
| sort - count
| head 20
```

### 4.10 Top pages with ids merged

`/assignments/17` and `/assignments/42` are counted as `/assignments/:id`.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval route=replace(replace(path,"/[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}","/:uuid"),"/\d+","/:id")
| stats count by route
| sort - count
| head 20
```

### 4.11 Pages that return 404

Broken links, missing static files, or scanners.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status=404
| stats count by path
| sort - count
| head 20
```

### 4.12 All 5xx responses

Every failed request with its details.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status>=500
| table _time pod client_ip method uri status
```

### 4.13 502 / 503 / 504 (frontend cannot reach the backend)

These almost always mean the backend pods were down, restarting or too slow.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status=502 OR status=503 OR status=504
| timechart span=5m count by status
```

### 4.14 413: upload too large

Relevant for a submission portal: the file was bigger than Nginx's `client_max_body_size`.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status=413
| table _time client_ip method uri user_agent
```

### 4.15 499: user gave up while waiting

The browser closed the connection before the response; points to slowness.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status=499
| timechart span=15m count
```

### 4.16 HTTP methods

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by method
| sort - count
```

### 4.17 POST requests per page

Form submissions: logins, assignment uploads, group changes ...

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where method="POST"
| stats count by path, status
| sort - count
```

### 4.18 POST requests over time

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where method="POST"
| timechart span=15m count by path
```

### 4.19 Redirects (3xx)

A 302 right after the home page is normal when the portal sends visitors to the login page.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status>=300 AND status<400
| stats count by status, path
| sort - count
```

### 4.20 Top client addresses

Behind the ALB this may list only load-balancer addresses. See the note at the top of this section.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| stats count by real_ip
| sort - count
| head 20
```

### 4.21 Unique visitors per hour

Distinct addresses per hour.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| timechart span=1h dc(real_ip) as unique_visitors
```

### 4.22 Unique visitors per day

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| timechart span=1d dc(real_ip) as unique_visitors count as requests
```

### 4.23 Where do visitors come from? (country)

Uses Splunk's built-in GeoIP. Private addresses (10.x, 192.168.x) have no country.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| iplocation real_ip
| stats count by Country
| sort - count
```

### 4.24 Browsers

Edge and Chrome contain each other's names, so the order of the tests matters.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval browser=case(match(user_agent,"Edg/"),"Edge", match(user_agent,"Chrome/"),"Chrome", match(user_agent,"Firefox/"),"Firefox", match(user_agent,"Safari/"),"Safari", match(user_agent,"(?i)curl|python|Go-http|wget|okhttp"),"script / CLI", true(),"other")
| stats count by browser
| sort - count
```

### 4.25 Mobile versus desktop

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval device=if(match(user_agent,"(?i)Mobile|Android|iPhone|iPad"),"mobile","desktop / other")
| timechart span=1d count by device
```

### 4.26 Top user agents

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by user_agent
| sort - count
| head 20
```

### 4.27 Traffic by hour of day

When do students use the portal?

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval hour=strftime(_time,"%H")
| stats count by hour
| sort hour
```

### 4.28 Traffic by day of week

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval weekday=strftime(_time,"%a")
| stats count by weekday
```

### 4.29 Busiest 5 minutes

Peak load, useful for sizing the HPA (frontend scales at 70% CPU).

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| bin _time span=1m
| stats count by _time
| sort - count
| head 5
```

### 4.30 Static files versus pages

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval kind=if(match(path,"^/static/"),"static","dynamic")
| timechart span=15m count by kind
```

### 4.31 Data sent to users per hour (MB)

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval bytes=if(resp_bytes="-",0,tonumber(resp_bytes))
| timechart span=1h sum(bytes) as bytes
| eval MB=round(bytes/1024/1024,2)
| fields _time MB
```

### 4.32 Largest responses

Big downloads of assignment files, or something unexpectedly heavy.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval bytes=if(resp_bytes="-",0,tonumber(resp_bytes))
| sort - bytes
| head 20
| eval KB=round(bytes/1024,1)
| table _time method uri status KB
```

### 4.33 Referrers

Where visitors came from (empty / `-` means typed address or bookmark).

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by referer
| sort - count
| head 20
```

### 4.34 Login page activity

How often the login page is opened and submitted, with the result.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where match(path,"(?i)login|signin|auth")
| stats count by method, status, path
```

### 4.35 Upload / submit / download activity

Assumes your URLs contain these words; adjust to your real routes.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where match(path,"(?i)upload|submit|submission|download")
| timechart span=1h count by status
```

### 4.36 Very long URLs

Unusually long request addresses are often attacks.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval len=len(uri)
| where len>200
| table _time client_ip len uri
```

### 4.37 Slowest pages (only if Nginx logs the request time)

Needs `rt=$request_time` added to the Nginx `log_format`. Until then it returns nothing.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| rex field=log "rt=(?<rt>[\d.]+)"
| where isnotnull(rt)
| stats avg(rt) as avg_s perc95(rt) as p95_s max(rt) as max_s count by path
| sort - p95_s
| head 20
```

### 4.38 Requests that are not GET/POST/HEAD

Unusual methods (PUT, DELETE, CONNECT, PROPFIND ...) deserve a look.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where NOT match(method,"^(GET|POST|HEAD)$")
| stats count by method, path, status
| sort - count
```

## 5. Backend (Flask / Gunicorn)

I could not see the backend's source code, so these searches rely on the standard Flask, Werkzeug and Gunicorn message formats and on plain keywords. **Start with 5.1 and 5.2 to see what your backend really prints**, then adjust the keywords to your own messages. Request lines from the backend itself appear only if access logging is on (Werkzeug does it by default; Gunicorn needs `--access-logfile -`).

### 5.1 What does the backend print? (read this first)

The 50 newest backend lines. Use them to decide which keywords below fit your app.

```spl
index=k8s_logs app=backend
| head 50
| table _time pod stream log
```

### 5.2 Message patterns in the backend log

Groups similar lines and shows how often each pattern occurs. The fastest way to learn an unfamiliar log.

```spl
index=k8s_logs app=backend
| cluster field=log t=0.8 showcount=true
| table cluster_count log
| sort - cluster_count
| head 30
```

### 5.3 Same, with numbers normalised

Alternative pattern finder: every number becomes N.

```spl
index=k8s_logs app=backend
| rex mode=sed field=log "s/[0-9]+/N/g"
| stats count by log
| sort - count
| head 30
```

### 5.4 Backend requests: status codes

Only works if the backend prints access lines (see section intro).

```spl
index=k8s_logs app=backend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3})"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by status
| sort - count
```

### 5.5 Backend requests per endpoint

```spl
index=k8s_logs app=backend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3})"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by method, path, status
| sort - count
| head 30
```

### 5.6 Backend 4xx and 5xx by endpoint

Which API routes fail.

```spl
index=k8s_logs app=backend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3})"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status>=400
| stats count by path, status
| sort - count
```

### 5.7 Backend requests over time per pod

```spl
index=k8s_logs app=backend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3})"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| timechart span=5m count by pod
```

### 5.8 Backend 5xx timeline

```spl
index=k8s_logs app=backend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3})"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status>=500
| timechart span=5m count by path
```

### 5.9 Backend start-ups and restarts

Gunicorn and Flask start-up messages. A burst right after an ArgoCD sync is a rollout; a burst at another time is a crash loop.

```spl
index=k8s_logs app=backend ("Starting gunicorn" OR "Listening at" OR "Booting worker" OR "Running on" OR "Serving Flask app")
| timechart span=15m count by pod
```

### 5.10 Worker boots per pod

Many boots of one pod means its workers keep dying.

```spl
index=k8s_logs app=backend "Booting worker"
| stats count latest(_time) as last_boot by pod
| eval last_boot=strftime(last_boot,"%F %T")
| sort - count
```

### 5.11 Gunicorn worker problems

WORKER TIMEOUT = a request took longer than the Gunicorn timeout (30 s default). SIGKILL usually = out of memory (limit 512Mi).

```spl
index=k8s_logs app=backend ("WORKER TIMEOUT" OR "SIGKILL" OR "Perhaps out of memory" OR "Worker exiting" OR "Worker failed to boot")
| table _time pod log
```

### 5.12 Graceful shutdowns (rollouts, scale-down)

```spl
index=k8s_logs app=backend ("Handling signal: term" OR "Shutting down" OR "Worker exiting" OR "Received SIGTERM")
| timechart span=15m count by pod
```

### 5.13 Is the backend running in development mode?

Your ConfigMap sets `FLASK_ENV=development`. Hits here mean the Flask development server or debugger is active, which is not meant for production.

```spl
index=k8s_logs app=backend ("development server" OR "Debugger is active" OR "Debug mode: on" OR "Do not use it in a production")
| stats count latest(_time) as last_seen by pod
| eval last_seen=strftime(last_seen,"%F %T")
```

### 5.14 Database connection problems (backend side)

The backend cannot talk to Postgres. Compare the time with the Postgres section.

```spl
index=k8s_logs app=backend (psycopg2 OR sqlalchemy OR OperationalError OR "could not connect" OR "connection refused" OR "too many clients" OR "server closed the connection" OR "QueuePool limit")
| stats count latest(log) as example by pod
| sort - count
```

### 5.15 Database connection problems over time

```spl
index=k8s_logs app=backend (OperationalError OR "could not connect" OR "server closed the connection" OR "QueuePool limit")
| timechart span=5m count
```

### 5.16 Redis problems (backend side)

```spl
index=k8s_logs app=backend ("redis.exceptions" OR "Error connecting to redis" OR (redis (error OR refused OR timeout)))
| table _time pod log
```

### 5.17 Authentication events

Keyword search for logins, logouts and failures. Adjust to the words your app prints.

```spl
index=k8s_logs app=backend (login OR logout OR "logged in" OR "logged out" OR authenticated OR "sign in" OR "signed in")
| timechart span=1h count
```

### 5.18 Failed logins and access denied

```spl
index=k8s_logs app=backend ("invalid credentials" OR "invalid password" OR "incorrect password" OR "login failed" OR "failed login" OR unauthorized OR forbidden OR "access denied" OR "not authorized")
| table _time pod log
```

### 5.19 Submissions and uploads

```spl
index=k8s_logs app=backend (submit OR submitted OR submission OR upload OR uploaded)
| timechart span=1h count
```

### 5.20 Assignment, group and grade activity

```spl
index=k8s_logs app=backend (assignment OR group OR deadline OR grade OR marks OR feedback)
| stats count by pod
```

### 5.21 File and permission errors

Typical for uploads: file too large, missing folder, no permission.

```spl
index=k8s_logs app=backend ("No such file" OR "Permission denied" OR "File too large" OR RequestEntityTooLarge OR "Read-only file system" OR "No space left")
| table _time pod log
```

### 5.22 Timeouts in the backend

```spl
index=k8s_logs app=backend (timeout OR "timed out" OR TimeoutError)
| timechart span=15m count by pod
```

### 5.23 CSRF and CORS messages

```spl
index=k8s_logs app=backend (CSRF OR CORS OR "cross-origin")
| table _time pod log
```

### 5.24 Request duration, if your app logs it

Matches text like `took 120ms`, `duration=85 ms`, `elapsed: 1.2 ms`. Returns nothing if your app does not print durations.

```spl
index=k8s_logs app=backend
| rex field=log "(?i)(?:took|duration|elapsed|time)[=: ]+(?<ms>\d+(?:\.\d+)?) ?ms"
| where isnotnull(ms)
| stats avg(ms) as avg_ms perc95(ms) as p95_ms max(ms) as max_ms count by pod
```

### 5.25 Backend pods running over time (HPA)

Counts pods that logged in each interval. Rises when the HPA scales the backend up (2 to 5).

```spl
index=k8s_logs app=backend
| timechart span=5m dc(pod) as backend_pods
```

### 5.26 Frontend pods running over time (HPA)

```spl
index=k8s_logs app=frontend
| timechart span=5m dc(pod) as frontend_pods
```

### 5.27 Passwords or secrets printed in logs

Should return **0 events**. Your Deployment holds `DATABASE_URL`, `SECRET_KEY` and the Postgres password; they must never appear in logs.

```spl
index=k8s_logs ("postgresql://" OR "DATABASE_URL" OR "SECRET_KEY" OR "POSTGRES_PASSWORD" OR "password=" OR "passwd=" OR "Authorization: Bearer")
| table _time app pod log
```

## 6. PostgreSQL

The official `postgres:16-alpine` image prints lines such as `2026-10-26 10:00:00.123 UTC [27] LOG:  checkpoint starting: time`. The queries read the level (`LOG`, `WARNING`, `ERROR`, `FATAL`, `PANIC`) and the message from that format.

### 6.1 Postgres message levels

```spl
index=k8s_logs app=postgres
| rex field=log "^(?<pg_time>\d{4}-\d{2}-\d{2} [\d:.]+ \w+) \[(?<pg_pid>\d+)\] (?<pg_level>[A-Z]+):\s+(?<pg_msg>.*)"
| stats count by pg_level
| sort - count
```

### 6.2 Postgres errors, fatal errors and panics

```spl
index=k8s_logs app=postgres
| rex field=log "^(?<pg_time>\d{4}-\d{2}-\d{2} [\d:.]+ \w+) \[(?<pg_pid>\d+)\] (?<pg_level>[A-Z]+):\s+(?<pg_msg>.*)"
| where pg_level="ERROR" OR pg_level="FATAL" OR pg_level="PANIC"
| table _time pod pg_level pg_msg
```

### 6.3 Postgres warnings

```spl
index=k8s_logs app=postgres
| rex field=log "^(?<pg_time>\d{4}-\d{2}-\d{2} [\d:.]+ \w+) \[(?<pg_pid>\d+)\] (?<pg_level>[A-Z]+):\s+(?<pg_msg>.*)"
| where pg_level="WARNING"
| stats count by pg_msg
| sort - count
```

### 6.4 Database start-ups

Each line marks a Postgres start. More than one per deployment means restarts.

```spl
index=k8s_logs app=postgres "database system is ready to accept connections"
| table _time pod log
```

### 6.5 Crash recovery

Postgres was not shut down cleanly (node loss, OOM kill). Data is recovered automatically, but find out why it happened.

```spl
index=k8s_logs app=postgres ("not properly shut down" OR "automatic recovery in progress" OR "database system was interrupted" OR "redo starts")
| table _time pod log
```

### 6.6 Failed password / authentication

Wrong database password, or someone probing the database.

```spl
index=k8s_logs app=postgres ("password authentication failed" OR "no pg_hba.conf entry" OR "authentication failed")
| table _time pod log
```

### 6.7 Too many connections

The backend (3 or more pods) opened more connections than Postgres allows (100 by default).

```spl
index=k8s_logs app=postgres ("too many clients already" OR "remaining connection slots are reserved")
| timechart span=5m count
```

### 6.8 Disk problems on the Postgres volume

The data volume is a 5Gi EBS disk (`postgres-pvc`).

```spl
index=k8s_logs app=postgres ("No space left on device" OR "could not write" OR "could not extend file" OR "disk full")
| table _time pod log
```

### 6.9 Missing tables or columns

Usually a database migration that did not run after a release.

```spl
index=k8s_logs app=postgres ("does not exist")
| rex field=log "(?<object>(?:relation|column|table|function|schema) \"[^\"]+\" does not exist)"
| stats count by object
| sort - count
```

### 6.10 Duplicate key violations

A user submitted something that already exists (duplicate group, duplicate submission, duplicate e-mail ...).

```spl
index=k8s_logs app=postgres "duplicate key value violates unique constraint"
| rex field=log "unique constraint \"(?<constraint>[^\"]+)\""
| stats count by constraint
| sort - count
```

### 6.11 Deadlocks and lock waits

```spl
index=k8s_logs app=postgres ("deadlock detected" OR "still waiting for" OR "canceling statement due to lock timeout")
| table _time pod log
```

### 6.12 SQL syntax or permission errors

```spl
index=k8s_logs app=postgres ("syntax error" OR "permission denied" OR "violates foreign key" OR "violates not-null" OR "invalid input syntax")
| stats count latest(log) as example by pod
```

### 6.13 Connections dropped by clients

Backend pods restarting or being killed in the middle of a query.

```spl
index=k8s_logs app=postgres ("unexpected EOF on client connection" OR "could not receive data from client" OR "terminating connection")
| timechart span=15m count
```

### 6.14 Checkpoints

Postgres writes dirty data to disk regularly. This charts how often and how long it takes.

```spl
index=k8s_logs app=postgres "checkpoint complete"
| rex field=log "total=(?<total_s>[\d.]+) s"
| timechart span=1h count as checkpoints avg(total_s) as avg_seconds
```

### 6.15 Checkpoints happening too often

Warning that WAL settings may need tuning.

```spl
index=k8s_logs app=postgres "checkpoints are occurring too frequently"
| table _time pod log
```

### 6.16 Slow statements (only if you enable it)

Needs `log_min_duration_statement` in Postgres. Until then it returns nothing.

```spl
index=k8s_logs app=postgres "duration:"
| rex field=log "duration: (?<ms>[\d.]+) ms"
| where tonumber(ms)>500
| table _time pod ms log
| sort - ms
```

### 6.17 Autovacuum activity

```spl
index=k8s_logs app=postgres ("automatic vacuum" OR "automatic analyze")
| timechart span=1d count
```

### 6.18 Statements logged with errors

Postgres prints the failing SQL on a `STATEMENT:` line right after an error.

```spl
index=k8s_logs app=postgres "STATEMENT:"
| rex mode=sed field=log "s/[0-9]+/N/g"
| stats count by log
| sort - count
| head 20
```

### 6.19 Top Postgres messages

Pattern view of everything Postgres prints.

```spl
index=k8s_logs app=postgres
| rex field=log "^(?<pg_time>\d{4}-\d{2}-\d{2} [\d:.]+ \w+) \[(?<pg_pid>\d+)\] (?<pg_level>[A-Z]+):\s+(?<pg_msg>.*)"
| rex mode=sed field=pg_msg "s/[0-9]+/N/g"
| stats count by pg_level, pg_msg
| sort - count
| head 30
```

## 7. Redis

The `redis:7-alpine` image prints lines such as `1:M 26 Oct 2026 10:00:00.123 * Ready to accept connections tcp`. The level symbol is `.` debug, `-` verbose, `*` notice, `#` warning.

### 7.1 Redis message levels

```spl
index=k8s_logs app=redis
| rex field=log "^(?<redis_pid>\d+):(?<redis_role>[A-Z]) (?<redis_time>\d+ \w+ \d{4} [\d:.]+) (?<redis_level>[.\-*#]) (?<redis_msg>.*)"
| stats count by redis_level
```

### 7.2 Redis warnings

Lines marked with `#`.

```spl
index=k8s_logs app=redis
| rex field=log "^(?<redis_pid>\d+):(?<redis_role>[A-Z]) (?<redis_time>\d+ \w+ \d{4} [\d:.]+) (?<redis_level>[.\-*#]) (?<redis_msg>.*)"
| where redis_level="#"
| table _time pod redis_msg
```

### 7.3 Redis start-ups

More than one start per deployment means restarts. Redis here has no volume, so a restart empties it.

```spl
index=k8s_logs app=redis "Ready to accept connections"
| table _time pod log
```

### 7.4 Redis saving to disk

Background saves (RDB). Failures show up as MISCONF in the backend.

```spl
index=k8s_logs app=redis ("Background saving" OR "DB saved on disk" OR "Saving the final RDB" OR "RDB:")
| timechart span=1h count
```

### 7.5 Redis cannot save or is out of memory

Redis limit in the Deployment is 256Mi.

```spl
index=k8s_logs (app=redis OR app=backend) (MISCONF OR "OOM command not allowed" OR "maxmemory" OR "Can't save in background" OR "Cannot allocate memory")
| table _time app pod log
```

### 7.6 Redis shutdown reasons

```spl
index=k8s_logs app=redis ("User requested shutdown" OR "Received SIGTERM" OR "Received SIGINT" OR "Redis is now ready to exit")
| table _time pod log
```

### 7.7 Someone talked HTTP to Redis

Redis logs this when a web request or scanner hits its port. Should be 0 events.

```spl
index=k8s_logs app=redis ("SECURITY ATTACK" OR "Possible SECURITY ATTACK" OR "POST or Host")
| table _time pod log
```

### 7.8 Top Redis messages

```spl
index=k8s_logs app=redis
| rex field=log "^(?<redis_pid>\d+):(?<redis_role>[A-Z]) (?<redis_time>\d+ \w+ \d{4} [\d:.]+) (?<redis_level>[.\-*#]) (?<redis_msg>.*)"
| rex mode=sed field=redis_msg "s/[0-9]+/N/g"
| stats count by redis_level, redis_msg
| sort - count
| head 20
```

## 8. Kubernetes lifecycle and releases (from the logs)

Fluent Bit adds the pod, node and image to every event, so you can follow rollouts, HPA scaling and releases without `kubectl`. Your image tags are Git commit SHAs written by the CI pipeline, so each tag is one release.

### 8.1 Pod inventory with first and last log time

One row per pod that ever logged in the time range.

```spl
index=k8s_logs
| stats earliest(_time) as first_seen latest(_time) as last_seen count by app, pod, host
| eval first_seen=strftime(first_seen,"%F %T"), last_seen=strftime(last_seen,"%F %T")
| sort app, first_seen
```

### 8.2 Release history (when each image tag first appeared)

Your deployment timeline. Use a time range of 7 days or more.

```spl
index=k8s_logs (app=backend OR app=frontend)
| stats earliest(_time) as first_seen latest(_time) as last_seen dc(pod) as pods by app, image
| eval first_seen=strftime(first_seen,"%F %T"), last_seen=strftime(last_seen,"%F %T")
| sort app, first_seen
```

### 8.3 Which version is running right now?

Newest image per component over the last 15 minutes. Two values in one row means a rollout is in progress.

```spl
index=k8s_logs earliest=-15m
| stats values(image) as running_images dc(pod) as pods by app
```

### 8.4 Rollouts: more than one image version at the same time

Rises above 1 while ArgoCD replaces old pods with new ones (maxSurge 1, maxUnavailable 1).

```spl
index=k8s_logs (app=backend OR app=frontend)
| timechart span=5m dc(image) by app
```

### 8.5 New pods per hour

Counts pods whose first log line appeared in each hour: rollouts, HPA scale-ups, crashes.

```spl
index=k8s_logs
| stats earliest(_time) as first_seen by app, pod
| eval hour=strftime(first_seen,"%F %H:00")
| stats count as new_pods by hour, app
| sort hour
```

### 8.6 Pods per node

Check that the 3 nodes share the pods evenly.

```spl
index=k8s_logs earliest=-15m
| stats dc(pod) as pods values(app) as components by host
| sort - pods
```

### 8.7 Which node did each pod run on?

```spl
index=k8s_logs earliest=-60m
| stats latest(host) as node by app, pod
| sort app, pod
```

### 8.8 Backend and frontend scaling timeline

Pods per component over time; compare with traffic in 4.2.

```spl
index=k8s_logs (app=backend OR app=frontend)
| timechart span=5m dc(pod) by app
```

### 8.9 Did a release cause new errors?

Error lines per release tag. A tag with a much higher count than its predecessor is suspect.

```spl
index=k8s_logs app=backend (ERROR OR Exception OR Traceback)
| stats count by image
| sort - count
```

### 8.10 Error rate per release over time

Overlay: errors per 15 minutes split by image tag.

```spl
index=k8s_logs app=backend (ERROR OR Exception OR Traceback)
| timechart span=15m count by image
```

### 8.11 Pods that stopped logging after a rollout

Old pods that disappeared, with their last message. Normal after a release; unexpected at other times.

```spl
index=k8s_logs earliest=-24h
| stats latest(_time) as last_seen latest(log) as last_message by app, pod
| where last_seen<relative_time(now(),"-30m")
| eval last_seen=strftime(last_seen,"%F %T")
| sort - last_seen
```

### 8.12 Container image hash check

The exact image digest, to prove which build is running.

```spl
index=k8s_logs earliest=-15m
| stats values(kubernetes.container_hash) as digest by app, image
```

## 9. Security and abuse

Simple detections based on the Nginx access log and the database logs. They are starting points, not a replacement for a WAF.

### 9.1 Scanners looking for well-known files

Requests for `.env`, `wp-login`, `phpmyadmin`, `.git`, `/admin` ... A public ALB receives these within hours.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where match(path,"(?i)(\.env|wp-login|wp-admin|wp-content|phpmyadmin|\.git|etc/passwd|xmlrpc|cgi-bin|\.php|\.asp|actuator|boaform|/console|/shell|\.aws|\.ssh)")
| stats count values(path) as paths by real_ip, user_agent
| sort - count
```

### 9.2 Path traversal attempts

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where match(uri,"(\.\./|%2e%2e|%252e|\.\.%2f)")
| table _time real_ip method uri status
```

### 9.3 SQL injection patterns in URLs

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where match(uri,"(?i)(union(\+|%20| )select|or(\+|%20| )1(=|%3d)1|sleep\(|information_schema|%27|benchmark\()")
| table _time real_ip method uri status
```

### 9.4 Cross-site scripting patterns in URLs

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where match(uri,"(?i)(<script|%3cscript|javascript:|onerror=|onload=)")
| table _time real_ip method uri status
```

### 9.5 Hacking tools and scripts in the User-Agent

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where match(user_agent,"(?i)(sqlmap|nikto|nmap|masscan|zgrab|hydra|dirbuster|gobuster|wpscan|acunetix|nessus)")
| stats count by real_ip, user_agent
```

### 9.6 Too many requests from one address (more than 100 per minute)

Crawlers, brute-force and denial-of-service attempts.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| bin _time span=1m
| stats count by _time, real_ip
| where count>100
| sort - count
```

### 9.7 One address, many different 404 pages

Typical for directory guessing.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where status=404
| stats count dc(path) as different_paths by real_ip
| where count>20
| sort - count
```

### 9.8 Repeated login failures from one address

Counts POSTs to login pages that were refused. Many apps answer a failed login with 200 or 302 instead of 401; check what yours returns with query 4.34 first.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where method="POST" AND match(path,"(?i)login|signin|auth") AND (status=401 OR status=403)
| stats count by real_ip
| where count>5
| sort - count
```

### 9.9 Spike of 401 / 403 answers

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| where status=401 OR status=403
| timechart span=5m count by status
```

### 9.10 Unusual HTTP methods

TRACE, CONNECT, PROPFIND ... are almost always probes.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where NOT match(method,"^(GET|POST|HEAD|PUT|DELETE|PATCH|OPTIONS)$")
| table _time real_ip method uri status
```

### 9.11 Requests with an empty or tool User-Agent

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where user_agent="-" OR user_agent="" OR match(user_agent,"(?i)^(curl|python-requests|Go-http-client|libwww|Java)")
| stats count by user_agent, real_ip
| sort - count
```

### 9.12 Top countries of failed requests

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where status>=400
| iplocation real_ip
| stats count by Country
| sort - count
```

### 9.13 Database login failures (all sources)

Wrong or guessed Postgres passwords.

```spl
index=k8s_logs (app=postgres OR app=backend) ("password authentication failed" OR (FATAL authentication))
| table _time app pod log
```

### 9.14 Secrets visible in any log

Run daily. Anything found here must be fixed in the application and the secret rotated.

```spl
index=k8s_logs ("postgresql://" OR "SECRET_KEY" OR "POSTGRES_PASSWORD" OR "password=" OR "api_key" OR "Authorization: Bearer" OR "AWS_SECRET_ACCESS_KEY")
| stats count by app, pod
```

## 10. If you also collect other namespaces (ArgoCD, monitoring)

Only useful after you add them to the `Path` line of the Fluent Bit ConfigMap (README, *Good to know*).

### 10.1 ArgoCD sync problems

```spl
index=k8s_logs namespace=argocd ("level=error" OR "Sync failed" OR "ComparisonError" OR "OutOfSync" OR "failed to sync")
| table _time pod log
```

### 10.2 ArgoCD sync activity

Shows when ArgoCD applied a Git change to the cluster.

```spl
index=k8s_logs namespace=argocd "Updated sync status"
| table _time pod log
```

### 10.3 Prometheus / Grafana errors

```spl
index=k8s_logs namespace=monitoring (level=error OR "level=warn" OR "Failed")
| stats count by app, pod
| sort - count
```

## 11. If your app switches to JSON logging later

If the backend prints one JSON object per line, Fluent Bit (`Merge_Log On`) turns the keys into Splunk fields, so you can skip the regular expressions.

### 11.1 List the fields of JSON logs

```spl
index=k8s_logs app=backend earliest=-15m
| fieldsummary maxvals=5
| table field count values
| sort - count
```

### 11.2 Count by level field

Use the field name your logger prints: `level`, `levelname`, `severity` ...

```spl
index=k8s_logs app=backend
| eval lvl=upper(coalesce(level, levelname, severity))
| timechart span=15m count by lvl
```

### 11.3 Top messages

```spl
index=k8s_logs app=backend
| eval msg_text=coalesce(message, msg, event)
| stats count by msg_text
| sort - count
| head 20
```

## 12. Ready-made alerts

In the search bar: run the query, then **Save As > Alert**. Pick *Scheduled*, the schedule below, and *Trigger when: Number of Results is greater than 0* (unless noted). Under *Trigger Actions* choose **Add to Triggered Alerts** (works without any setup; e-mail needs Splunk's mail server to be configured).

### 12.1 ALERT: 5xx rate above 5% (run every 5 minutes, time range last 5 minutes)

Ignores quiet periods by requiring at least 20 requests.

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count(eval(status>=500)) as errors count as total
| eval error_pct=round(100*errors/total,1)
| where total>=20 AND error_pct>5
```

### 12.2 ALERT: backend errors (every 5 minutes, last 5 minutes)

More than 10 error lines from the backend.

```spl
index=k8s_logs app=backend (ERROR OR Exception OR CRITICAL OR Traceback)
| stats count
| where count>10
```

### 12.3 ALERT: any Python traceback (every 5 minutes, last 5 minutes)

```spl
index=k8s_logs app=backend "Traceback (most recent call last)"
| stats count latest(log) as example by pod
```

### 12.4 ALERT: Gunicorn worker killed or timed out (every 5 minutes, last 5 minutes)

```spl
index=k8s_logs app=backend ("WORKER TIMEOUT" OR "SIGKILL" OR "Perhaps out of memory")
| stats count by pod
```

### 12.5 ALERT: Postgres fatal error or crash recovery (every 5 minutes, last 5 minutes)

```spl
index=k8s_logs app=postgres (FATAL OR PANIC OR "not properly shut down" OR "automatic recovery in progress" OR "No space left on device")
| stats count latest(log) as example by pod
```

### 12.6 ALERT: too many database connections (every 5 minutes, last 5 minutes)

```spl
index=k8s_logs app=postgres "too many clients already"
| stats count
```

### 12.7 ALERT: Redis cannot save or is out of memory (every 5 minutes, last 5 minutes)

```spl
index=k8s_logs (app=redis OR app=backend) (MISCONF OR "OOM command not allowed" OR "Can't save in background")
| stats count by app
```

### 12.8 ALERT: brute-force login attempts (every 10 minutes, last 10 minutes)

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where method="POST" AND match(path,"(?i)login|signin|auth") AND (status=401 OR status=403)
| stats count by real_ip
| where count>10
```

### 12.9 ALERT: scanner activity (every 15 minutes, last 15 minutes)

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| where match(path,"(?i)(\.env|wp-login|phpmyadmin|\.git|etc/passwd|cgi-bin|\.php)")
| stats count by real_ip
| where count>5
```

### 12.10 ALERT: a new release was deployed (every 15 minutes, last 7 days)

Informational: fires when an image tag appears for the first time in the last 15 minutes. Set the schedule time range to 7 days.

```spl
index=k8s_logs (app=backend OR app=frontend)
| stats earliest(_time) as first_seen by app, image
| where first_seen>relative_time(now(),"-15m")
| eval first_seen=strftime(first_seen,"%F %T")
```

### 12.11 ALERT: logs arrive late (every 15 minutes, last 15 minutes)

Average delay above 5 minutes means Fluent Bit cannot reach Splunk (or Splunk is overloaded).

```spl
index=k8s_logs
| eval lag=_indextime-_time
| stats avg(lag) as avg_lag
| where avg_lag>300
```

### 12.12 ALERT: index almost full (once a day, time range irrelevant)

The index is capped; when it is 85% full the oldest logs start to be deleted.

```spl
| rest /services/data/indexes/k8s_logs splunk_server=local
| eval used_pct=round(100*currentDBSizeMB/maxTotalDataSizeMB,1)
| where used_pct>85
| table title used_pct currentDBSizeMB maxTotalDataSizeMB
```

### 12.13 ALERT: secret found in logs (every hour, last 60 minutes)

```spl
index=k8s_logs ("postgresql://" OR "SECRET_KEY" OR "POSTGRES_PASSWORD" OR "password=")
| stats count by app, pod
```

### 12.14 ALERT: no logs from the whole app (every 15 minutes, last 30 minutes)

Health checks are filtered out, so a quiet system at night is normal. Use this one only with a schedule restricted to working hours, or as a pipeline alarm.

```spl
index=k8s_logs earliest=-30m
| stats count
| where count=0
```

## 13. Starter dashboard (copy these panels)

Create the dashboard once: run the first query, **Save As > New Dashboard**, name it *Assignment Portal*. For each next query use **Save As > Existing Dashboard**. The visualisation type is in the title.

### 13.1 PANEL (Single value): requests in the last hour

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count as requests
```

### 13.2 PANEL (Single value): server error rate %, last hour

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count(eval(status>=500)) as e count as t
| eval error_pct=round(100*e/t,2)
| fields error_pct
```

### 13.3 PANEL (Single value): unique visitors today

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval real_ip=if(isnotnull(xff) AND xff!="-" AND xff!="", trim(mvindex(split(xff,","),0)), client_ip)
| stats dc(real_ip) as visitors
```

### 13.4 PANEL (Column chart, stacked): requests by status class

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval class=substr(status,1,1)."xx"
| timechart span=15m count by class
```

### 13.5 PANEL (Line chart): log volume per component

```spl
index=k8s_logs
| timechart span=15m count by app
```

### 13.6 PANEL (Line chart): errors per component

```spl
index=k8s_logs (ERROR OR Exception OR Traceback OR FATAL)
| timechart span=15m count by app
```

### 13.7 PANEL (Bar chart): top 10 pages

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| stats count by path
| sort - count
| head 10
```

### 13.8 PANEL (Pie chart): browsers

```spl
index=k8s_logs app=frontend
| rex field=log "^(?<client_ip>\S+) \S+ \S+ \[[^\]]+\] \"(?<method>[A-Z]+) (?<uri>\S+) [^\"]+\" (?<status>\d{3}) (?<resp_bytes>\d+|-) \"(?<referer>[^\"]*)\" \"(?<user_agent>[^\"]*)\"(?: \"(?<xff>[^\"]*)\")?"
| where isnotnull(status)
| eval status=tonumber(status), path=replace(uri,"\?.*$","")
| eval browser=case(match(user_agent,"Edg/"),"Edge", match(user_agent,"Chrome/"),"Chrome", match(user_agent,"Firefox/"),"Firefox", match(user_agent,"Safari/"),"Safari", true(),"other")
| stats count by browser
```

### 13.9 PANEL (Line chart): backend pods (HPA)

```spl
index=k8s_logs app=backend
| timechart span=5m dc(pod) as backend_pods
```

### 13.10 PANEL (Table): newest errors

```spl
index=k8s_logs (ERROR OR Exception OR Traceback OR FATAL)
| head 20
| table _time app pod log
```

### 13.11 PANEL (Table): running versions

```spl
index=k8s_logs earliest=-15m
| stats values(image) as images dc(pod) as pods by app
```

### 13.12 PANEL (Line chart): ingestion delay

```spl
index=k8s_logs
| eval lag=_indextime-_time
| timechart span=15m avg(lag) as avg_lag_seconds
```

---

*213 searches in total.*
