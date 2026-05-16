# ELK Log Aggregation Stack

A centralised log aggregation pipeline built with the ELK stack — Filebeat
ships logs from Docker containers to Logstash, which parses and structures
them before storing in Elasticsearch. Kibana provides a searchable dashboard
across all logs. Everything runs via Docker Compose with a single command.

This project demonstrates a core SRE and DevOps skill — giving engineers one
place to search, filter, and alert on logs from all services instead of
hunting across individual containers during an incident.

---

## Architecture

```
log-generator (stdout)
       ↓
Docker captures stdout → /var/lib/docker/containers/*/*.log
       ↓
Filebeat (watches Docker log files, ships to Logstash)
       ↓
Logstash (parses raw text, extracts log_level field, structures into JSON)
       ↓
Elasticsearch (stores as daily indexed JSON documents)
       ↓
Kibana (search, filter, visualise)
```

---

## Project Structure

```
elk-log-aggregation/
├── app/
│   └── generate-logs.sh              # simulates an app generating logs
├── filebeat/
│   └── filebeat.yml                  # tells Filebeat what to watch and where to ship
├── logstash/
│   ├── config/
│   │   └── logstash.yml              # Logstash settings
│   └── pipeline/
│       └── logstash.conf             # input, filter and output pipeline
├── .github/
│   └── workflows/
│       └── ci.yml                    # validates Filebeat and Logstash configs
├── docker-compose.yml                # runs all five services
└── README.md
```

---

## How to Run Locally

**Prerequisites:** Docker Desktop installed and running.

Clone the repo:
```bash
git clone git@github.com:mohammedkhaiserulla/elk-log-aggregation.git
cd elk-log-aggregation
```

Start the stack:
```bash
docker compose up -d
```

The first run downloads images and takes a few minutes. Elasticsearch takes
around 30 seconds to become healthy before Logstash and Kibana start.

Verify all five containers are running:
```bash
docker compose ps
```

---

## Verify Logs Are Flowing

Check Elasticsearch has received logs:
```
http://localhost:9200/_cat/indices?v
```

You should see indices named `app-logs-YYYY.MM.DD` with a growing `docs.count`.

---

## Access Kibana

Open `http://localhost:5601` in your browser.

**First time setup:**
1. Click **Explore on my own**
2. Hamburger menu → **Discover**
3. Click **Create data view**
4. Index pattern: `app-logs-*`
5. Timestamp field: `@timestamp`
6. Click **Save data view to Kibana**

You will now see all log lines streaming in with timestamps, log levels, and messages.

**Filter by log level:**
```
log_level: ERROR
log_level: WARNING
log_level: INFO
```

This is the core value — searching across all services in one place instead
of SSHing into individual containers.

---

## Services and Ports

| Service | Port | Purpose |
|---------|------|---------|
| Elasticsearch | 9200 | Database API and health check |
| Kibana | 5601 | Search and visualisation UI |
| Logstash | 5044 | Receives logs from Filebeat |
| log-generator | — | Generates sample logs, no port needed |
| Filebeat | — | Ships logs, no port needed |

---

## CI Pipeline

The GitHub Actions pipeline validates config files on every push and pull request.

**Two jobs run in parallel:**

**Validate Filebeat config** — runs `filebeat test config` inside the official
Filebeat Docker image to check `filebeat.yml` is syntactically valid.

**Validate Logstash pipeline** — runs `logstash --config.test_and_exit` inside
the official Logstash Docker image to check `logstash.conf` is valid.

If either validation fails the pipeline turns red and the pull request cannot
be merged. This ensures broken configs never reach the environment where the
stack is running.

---

## Known Behaviour

**Yellow index status** — expected on a single node cluster. Elasticsearch
cannot assign replica shards when there is only one node. All data is safe
on the primary shards. In production with a 3-node cluster, status would be green.

**Windows file permissions** — Filebeat requires `--strict.perms=false` when
running on Windows with Docker. Windows cannot set Linux-style file ownership
on mounted volumes, causing Filebeat's security check to fail without this flag.

---

## Production Considerations

**Elasticsearch cluster** — minimum 3 nodes for high availability and green
index status. Replica shards distributed across nodes ensure no data loss if
a node fails.

**Long term storage** — Elasticsearch Index Lifecycle Management (ILM) policies
automatically move old indices to cheaper storage and eventually archive them
to S3. Hot data stays in Elasticsearch for fast search. Cold data goes to S3.

**Filebeat as DaemonSet** — in Kubernetes, Filebeat runs as a DaemonSet ensuring
exactly one Filebeat pod on every node automatically. New nodes get Filebeat
without any manual intervention.

**Kafka as buffer** — high volume production environments place Kafka between
Filebeat and Logstash to absorb traffic spikes. Logs are never lost if Logstash
temporarily goes down — they wait in Kafka until Logstash recovers.

**Security** — in production `xpack.security.enabled` is always true.
Elasticsearch requires authentication. Kibana has role-based access control.

**Alerting** — Kibana alerting rules send Slack or email notifications when
ERROR log count exceeds a defined threshold, removing the need for engineers
to manually watch dashboards.

---

## Tech Stack

- **Filebeat 8.13** — lightweight log shipper
- **Logstash 8.13** — log processing and transformation pipeline
- **Elasticsearch 8.13** — distributed search and analytics database
- **Kibana 8.13** — visualisation and search UI
- **Docker Compose** — local orchestration
- **GitHub Actions** — CI config validation