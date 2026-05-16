# How This Project Works — Detailed Notes

These are my personal notes explaining every single line of every single file
in this project. I wrote this while building so I never have to guess what
something does or why it is there. If someone asks me in an interview I can
explain any line confidently.

---

## Table of Contents

1. [Why This Project Exists](#1-why-this-project-exists)
2. [app/generate-logs.sh](#2-appgenerate-logssh)
3. [filebeat/filebeat.yml](#3-filebeatfilebeatyml)
4. [logstash/config/logstash.yml](#4-logstashconfiglogstashyml)
5. [logstash/pipeline/logstash.conf](#5-logstashpipelinelogstashconf)
6. [docker-compose.yml](#6-docker-composeyml)
7. [.github/workflows/ci.yml](#7-githubworkflowsciyml)
8. [How a Log Line Travels End to End](#8-how-a-log-line-travels-end-to-end)
9. [Production Considerations](#9-production-considerations)

---

## 1. Why This Project Exists

Every application generates logs — messages printed to the console telling you
what is happening inside the system. User logged in. Database connected.
Payment failed. Request timed out.

In a modern system you do not have one application. You have tens or hundreds
of services running in their own containers simultaneously. If something breaks
at 2am you cannot SSH into each container one by one reading log files. By the
time you find the right container the incident has escalated.

Centralised logging solves this. Every container ships its logs to one central
place. You open one browser tab, search, filter by ERROR level, and within
seconds you see exactly which service is broken and what the error message says.

This project builds that pipeline from scratch using the ELK stack:
- **Filebeat** ships logs
- **Logstash** processes and structures them
- **Elasticsearch** stores them
- **Kibana** lets you search and visualise them

---

## 2. app/generate-logs.sh

This file simulates a real application generating logs. In production this
would be your actual Node.js, Java, or Python service printing log lines.
Here we use a simple shell script so the project has no language dependency.

```bash
#!/bin/bash
```
This is called a **shebang line**. It tells the operating system which
interpreter to use to run this file. `#!/bin/bash` means use the Bash shell.
Without this line the OS would not know how to execute the script.

```bash
LOG_LEVELS=("INFO" "WARNING" "ERROR" "DEBUG")
```
Creates an array called `LOG_LEVELS` containing four strings. Arrays in Bash
are defined with parentheses and space-separated values. We will pick randomly
from this array to simulate different severity levels.

```bash
MESSAGES=(
  "User login successful"
  "Database connection established"
  "API request received"
  "Cache miss detected"
  "Payment processed successfully"
  "Authentication failed"
  "Timeout connecting to service"
  "Request rate limit exceeded"
)
```
Creates another array called `MESSAGES` with eight sample log messages spread
across multiple lines for readability. These simulate realistic application
events — some normal (login successful), some problems (authentication failed,
timeout). Having a mix means our Logstash filters will see all four log levels.

```bash
echo "Starting log generator..."
```
Prints one startup message to stdout. Docker captures this and writes it to
the container log file. This line exists just so you can see in the Docker
logs that the script actually started.

```bash
while true; do
```
Starts an infinite loop. `while true` means keep looping forever because the
condition `true` is always satisfied. This is intentional — we want the script
to keep generating logs continuously until the container is stopped. In a real
application, the application process itself runs continuously in the same way.

```bash
  LEVEL=${LOG_LEVELS[$RANDOM % ${#LOG_LEVELS[@]}]}
```
This line picks a random log level from the array. Breaking it down:

`${#LOG_LEVELS[@]}` — counts how many items are in the array. Here it returns 4.

`$RANDOM` — a special Bash variable that returns a random number between 0
and 32767 every time it is referenced.

`$RANDOM % 4` — the modulo operator gives the remainder after division. Any
number modulo 4 gives 0, 1, 2, or 3. So this gives a random index between
0 and 3.

`${LOG_LEVELS[0]}` would be INFO, `${LOG_LEVELS[1]}` would be WARNING, and
so on. So the full expression picks a random item from the array.

```bash
  MESSAGE=${MESSAGES[$RANDOM % ${#MESSAGES[@]}]}
```
Same logic as above but for the MESSAGES array. Picks a random message from
the eight options.

```bash
  TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
```
Gets the current date and time formatted as `2026-05-17T01:10:56`.

`$(...)` is command substitution — it runs the command inside and uses the
output as the value. `date '+%Y-%m-%dT%H:%M:%S'` runs the `date` command
with a specific format: year-month-dayThour:minute:second. The T in the
middle is standard ISO 8601 timestamp format used universally in logging.

```bash
  echo "${TIMESTAMP} [${LEVEL}] ${MESSAGE}"
```
Prints the final log line to stdout. For example:
```
2026-05-17T01:10:56 [ERROR] Authentication failed
```
The square brackets around `${LEVEL}` are just formatting — they make the
log level visually distinct and easy to parse with pattern matching in Logstash.
Docker captures this stdout output and writes it to a JSON file on the host.

```bash
  sleep 2
done
```
Pauses for 2 seconds before the next iteration. Without this the script would
generate thousands of log lines per second and flood Elasticsearch. In
production, real applications generate logs only when events happen — not
on a fixed timer. The 2-second sleep simulates a reasonable event frequency.

`done` closes the `while` loop.

---

## 3. filebeat/filebeat.yml

Filebeat is the log shipper. This config file tells it what to watch and
where to send what it finds.

```yaml
filebeat.inputs:
  - type: container
    paths:
      - /var/lib/docker/containers/*/*.log
```
`filebeat.inputs` — the section that defines what Filebeat should read from.
You can have multiple inputs of different types.

`type: container` — tells Filebeat this is Docker container log input. This
type understands Docker's JSON log format and automatically parses the JSON
wrapper that Docker puts around every log line.

`paths` — the list of file paths to watch. Filebeat monitors these paths for
new content and ships anything new to the output.

`/var/lib/docker/containers/*/*.log` — this path uses wildcards. The first `*`
matches any container ID directory. The second `*` matches the log filename
(which is also the container ID). So this single path pattern watches log files
for all running containers on the host simultaneously.

This path exists on the host machine. Inside the Filebeat container we mount
the host's `/var/lib/docker/containers` directory at the same path, which is
why Filebeat can access it even though it runs inside its own container.

```yaml
processors:
  - add_docker_metadata:
      host: "unix:///var/run/docker.sock"
```
`processors` — a list of transformations applied to each log event before
shipping it. Processors enrich or modify the data.

`add_docker_metadata` — this processor adds extra fields to every log event
by querying Docker for container information. It adds fields like:
- `container.name` — the container name (e.g. `log-generator`)
- `container.image.name` — the Docker image used
- `container.id` — the full container ID

Without this processor you would see logs in Kibana but have no idea which
container they came from — just raw log text with no context.

`host: "unix:///var/run/docker.sock"` — tells the processor how to talk to
Docker. The Docker socket is a Unix socket file that the Docker daemon listens
on. Any process with access to this socket can query Docker for information
about running containers. We mount `/var/run/docker.sock` from the host into
the Filebeat container so Filebeat can use it.

```yaml
output.logstash:
  hosts: ["logstash:5044"]
```
`output.logstash` — tells Filebeat to send all collected log events to Logstash.
Filebeat supports multiple output types — Elasticsearch directly, Logstash,
Kafka, Redis — but we route through Logstash because we want to process and
structure the logs before storing them.

`hosts: ["logstash:5044"]` — the address of the Logstash instance. `logstash`
is the container name which Docker Compose resolves to the Logstash container's
IP address on the internal network. `5044` is the port Logstash listens on for
Beats input (the protocol Filebeat uses). This works because Docker Compose
creates a private network between all containers and containers can reach each
other using their service names as hostnames.

```yaml
logging.level: info
```
Sets Filebeat's own internal log level. `info` means Filebeat will log what
it is doing at a reasonable level — startup messages, connection status,
shipping statistics — without flooding the logs with debug-level detail. In
production you might set this to `warning` to reduce noise.

---

## 4. logstash/config/logstash.yml

This is Logstash's main settings file. It is separate from the pipeline config
because it controls how Logstash itself behaves, not what it does with data.

```yaml
http.host: "0.0.0.0"
```
Logstash exposes an HTTP API on port 9600 that provides monitoring information
— pipeline stats, node info, hot threads. `0.0.0.0` means accept connections
from any IP address, not just localhost.

Inside Docker, `localhost` inside the Logstash container refers to the container
itself, not your laptop. If we set `http.host: "localhost"` then nothing outside
the container could reach the API — including Docker health checks. `0.0.0.0`
means accept connections from anywhere, which is what we need inside Docker.

```yaml
xpack.monitoring.enabled: false
```
X-Pack is Elastic's commercial feature set. The monitoring feature tries to
send Logstash metrics to Elasticsearch automatically. This sounds useful but
it requires additional Elasticsearch configuration and creates connection
attempts on startup.

Since we are not setting up X-Pack monitoring we disable it explicitly.
Without this line Logstash logs would be filled with connection errors as it
repeatedly tries and fails to connect to an Elasticsearch monitoring endpoint
that does not exist in our setup. Setting it to `false` silences those errors.

---

## 5. logstash/pipeline/logstash.conf

This is the most important Logstash file. It defines the three-stage pipeline
that every log event passes through: input → filter → output.

### Input Section

```ruby
input {
  beats {
    port => 5044
  }
}
```
`input` — defines where Logstash receives data from.

`beats` — the Beats input plugin. Beats is Elastic's family of lightweight
shippers — Filebeat, Metricbeat, Packetbeat, and others. They all use the
same Beats protocol to communicate with Logstash. Using the `beats` input
means Logstash speaks the Beats protocol and can receive data from any of them.

`port => 5044` — Logstash listens on TCP port 5044 for incoming Beats
connections. This must match the port we configured in `filebeat.yml` under
`output.logstash.hosts`. If these ports do not match, Filebeat cannot connect
to Logstash and logs never arrive.

### Filter Section

```ruby
filter {
  if [message] =~ /\[ERROR\]/ {
    mutate {
      add_field => { "log_level" => "ERROR" }
    }
  } else if [message] =~ /\[WARNING\]/ {
    mutate {
      add_field => { "log_level" => "WARNING" }
    }
  } else if [message] =~ /\[INFO\]/ {
    mutate {
      add_field => { "log_level" => "INFO" }
    }
  } else {
    mutate {
      add_field => { "log_level" => "DEBUG" }
    }
  }
}
```
`filter` — this section processes every event that passes through. Without a
filter section Logstash would just forward raw data from input to output with
no transformation. The filter is where we turn unstructured text into
structured data.

`if [message] =~ /\[ERROR\]/` — a conditional check. Breaking it down:

`[message]` — accesses the `message` field of the current log event. Every
event has a `message` field containing the actual log text, for example:
`2026-05-17T01:10:56 [ERROR] Authentication failed`

`=~` — the pattern match operator. It checks if the left side contains the
pattern on the right side.

`/\[ERROR\]/` — a regular expression pattern. The forward slashes `/` delimit
the pattern. The backslashes `\` before the square brackets escape them because
square brackets have special meaning in regex. `\[ERROR\]` literally matches
the text `[ERROR]` in the message.

So `if [message] =~ /\[ERROR\]/` means: if the message field contains the
text `[ERROR]`, then do the following.

```ruby
    mutate {
      add_field => { "log_level" => "ERROR" }
    }
```
`mutate` — a Logstash filter plugin that modifies events. It can add fields,
remove fields, rename fields, convert field types, and more.

`add_field` — adds a new field to the event. Here we add a field called
`log_level` with the value `"ERROR"`. After this filter runs, the Elasticsearch
document will have a proper `log_level` field that Kibana can filter on — not
just the raw text buried inside the `message` field.

The `else if` and `else` blocks work identically for WARNING, INFO, and DEBUG.
The `else` at the end catches anything that does not match the first three
patterns and labels it DEBUG. This ensures every log event gets a `log_level`
field regardless of its content.

### Output Section

```ruby
output {
  elasticsearch {
    hosts => ["elasticsearch:9200"]
    index => "app-logs-%{+YYYY.MM.dd}"
  }
  stdout {
    codec => rubydebug
  }
}
```
`output` — defines where Logstash sends processed events. We have two outputs
here — both run for every event simultaneously.

```ruby
  elasticsearch {
    hosts => ["elasticsearch:9200"]
    index => "app-logs-%{+YYYY.MM.dd}"
  }
```
`elasticsearch` — the Elasticsearch output plugin. Sends events to Elasticsearch.

`hosts => ["elasticsearch:9200"]` — the address of Elasticsearch. Same concept
as Filebeat — `elasticsearch` is the container name that Docker Compose resolves
to the Elasticsearch container's IP. Port `9200` is the Elasticsearch HTTP API
port used for all read and write operations.

`index => "app-logs-%{+YYYY.MM.dd}"` — the name of the Elasticsearch index to
store documents in. `%{+YYYY.MM.dd}` is a date format directive. Logstash
replaces it with today's date at the time the event is processed. So on 17th
May 2026 it becomes `app-logs-2026.05.17`. Tomorrow's logs go into
`app-logs-2026.05.18`. A new index is created automatically each day.

This is called **daily index rotation**. It makes managing old logs easy —
delete `app-logs-2026.01.*` to remove all of January's data. It also keeps
each index a manageable size which improves search performance.

```ruby
  stdout {
    codec => rubydebug
  }
```
`stdout` — a second output that prints every processed event to Logstash's
own console output. This is purely for development visibility — you can run
`docker logs logstash` and see exactly what Logstash is receiving and processing
in real time.

`codec => rubydebug` — formats the output in a human-readable way with all
fields displayed clearly. In production this output would be removed because
printing every log event to the console creates noise and wastes resources.

---

## 6. docker-compose.yml

This file defines all five services and how they connect to each other.
Docker Compose reads this file and manages the entire stack.

```yaml
services:
```
Everything under `services` is a container definition. Each key under services
is the service name which also becomes the hostname that other containers use
to reach it on the Docker internal network.

### Elasticsearch

```yaml
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.13.0
```
`image` — the Docker image to use. Notice this is not from Docker Hub
(`docker.io`) but from Elastic's own registry at `docker.elastic.co`. Elastic
hosts their own registry because their images are large and they want full
control over distribution. The concept is identical to Docker Hub — pull an
image, run it as a container.

`8.13.0` — the exact version pinned. All three Elastic components
(Elasticsearch, Logstash, Kibana, Filebeat) must use the same version number.
Mixing versions causes compatibility errors.

```yaml
    container_name: elasticsearch
```
Gives the container a fixed name. Without this Docker generates a random name
like `elk-log-aggregation-elasticsearch-1`. The fixed name is what other
containers use as the hostname to reach Elasticsearch.

```yaml
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
```
`environment` — sets environment variables inside the container. Elasticsearch
reads these on startup to configure itself.

`discovery.type=single-node` — tells Elasticsearch not to look for other
Elasticsearch nodes to form a cluster with. In production Elasticsearch runs
as a cluster of multiple nodes that discover each other automatically. With
`single-node` it skips the cluster formation process and starts immediately
as a standalone instance. Without this, Elasticsearch would wait indefinitely
trying to find other nodes and never finish starting up.

`xpack.security.enabled=false` — disables authentication completely. With
security enabled, every request to Elasticsearch requires a username and
password including from Logstash and Kibana. Configuring those credentials
adds complexity. We disable it for simplicity in this local development setup.
In production this is always enabled.

`ES_JAVA_OPTS=-Xms512m -Xmx512m` — Elasticsearch runs on the Java Virtual
Machine. These are JVM memory settings:
- `-Xms512m` — set the minimum heap size to 512 megabytes
- `-Xmx512m` — set the maximum heap size to 512 megabytes

Setting min and max to the same value prevents the JVM from resizing the heap
at runtime which causes performance pauses. Without these settings Elasticsearch
tries to allocate half of your total system RAM as heap. On a laptop with 16GB
RAM that would be 8GB just for Elasticsearch, leaving everything else starved.

```yaml
    ports:
      - "9200:9200"
```
Maps port 9200 on your laptop to port 9200 inside the Elasticsearch container.
This lets you access the Elasticsearch API directly from your browser at
`http://localhost:9200` to check cluster health and view indices. Logstash
does not use this port mapping — it talks to Elasticsearch directly on the
internal Docker network, not through your laptop.

```yaml
    volumes:
      - elasticsearch-data:/usr/share/elasticsearch/data
```
A named volume that persists Elasticsearch data. `/usr/share/elasticsearch/data`
is where Elasticsearch stores its index files inside the container. By mounting
a named volume here, the data survives container restarts. If you stop and
start the stack, your indexed logs are still there.

Without this volume, every `docker compose down` would delete all indexed data
and you would start fresh each time.

```yaml
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200/_health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
```
`healthcheck` — Docker periodically runs this command inside the container to
check if the service is actually ready, not just running.

`test` — the command to run. `curl -s http://localhost:9200/_health` sends a
silent HTTP request to Elasticsearch's health endpoint. If Elasticsearch is
ready it returns a JSON response and curl exits with code 0 (success). If
Elasticsearch is not ready yet curl fails and exits with a non-zero code.
`|| exit 1` ensures a non-zero exit code is returned on failure.

`interval: 30s` — run the health check every 30 seconds.

`timeout: 10s` — if the health check takes more than 10 seconds to respond,
consider it failed.

`retries: 5` — if the health check fails 5 times in a row, mark the container
as unhealthy.

The healthcheck is critical for this project because Logstash and Kibana both
depend on Elasticsearch being fully ready before they start. Docker's
`depends_on` with `condition: service_healthy` waits for this healthcheck to
pass before starting dependent services.

### Logstash

```yaml
  logstash:
    image: docker.elastic.co/logstash/logstash:8.13.0
    container_name: logstash
    ports:
      - "5044:5044"
```
Port 5044 is mapped so you could connect an external Filebeat to this Logstash
if needed. In our setup Filebeat connects via the internal Docker network and
does not need this port mapping — but it is good practice to expose it.

```yaml
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline
      - ./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml
```
Two bind mounts:

`./logstash/pipeline:/usr/share/logstash/pipeline` — mounts our entire pipeline
directory into the container. Logstash automatically reads all `.conf` files
from this directory. If you add multiple pipeline files they all get loaded.

`./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml` —
mounts our settings file over the default one. This is how we inject our
custom settings (disable X-Pack monitoring, set HTTP host) without modifying
the image itself.

```yaml
    depends_on:
      elasticsearch:
        condition: service_healthy
```
`depends_on` — tells Docker Compose not to start Logstash until Elasticsearch
is ready. Without this, Logstash would try to connect to Elasticsearch the
moment it starts, Elasticsearch would not be ready yet, Logstash would fail
to connect, and you would see connection errors in the logs.

`condition: service_healthy` — does not just wait for the Elasticsearch
container to start. It waits for the healthcheck to report healthy. This is
more reliable than the old `depends_on` which only waited for the container
process to start, not for the application inside to be ready.

### Kibana

```yaml
  kibana:
    image: docker.elastic.co/kibana/kibana:8.13.0
    container_name: kibana
    ports:
      - "5601:5601"
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    depends_on:
      elasticsearch:
        condition: service_healthy
```
`ELASTICSEARCH_HOSTS=http://elasticsearch:9200` — tells Kibana where to find
Elasticsearch. Without this environment variable Kibana defaults to looking
for Elasticsearch at `http://localhost:9200` which inside the Kibana container
refers to the Kibana container itself, not the Elasticsearch container. This
would fail immediately. By setting this variable we point Kibana at the correct
container using the Docker internal network hostname.

Kibana also waits for Elasticsearch to be healthy before starting — same reason
as Logstash. Kibana connects to Elasticsearch on startup to verify the connection
and load configuration. If Elasticsearch is not ready, Kibana fails to start.

### Filebeat

```yaml
  filebeat:
    image: docker.elastic.co/beats/filebeat:8.13.0
    container_name: filebeat
    user: root
```
`user: root` — runs the Filebeat process inside the container as the root user.
Filebeat needs root access for two reasons:
1. To read Docker log files at `/var/lib/docker/containers` which are owned
   by root on the host
2. To access the Docker socket at `/var/run/docker.sock` which is also
   restricted to root

Without `user: root` Filebeat would get permission denied errors trying to
read these files.

```yaml
    command: filebeat -e --strict.perms=false
```
`command` — overrides the default startup command of the container.

`filebeat -e` — starts Filebeat with logging to stderr (the console) so you
can see its output with `docker logs filebeat`.

`--strict.perms=false` — disables Filebeat's file permission check. By default
Filebeat refuses to start if its config file is writable by anyone other than
the owner. This is a security measure on Linux.

On Windows, when Docker mounts a file from the Windows filesystem into a Linux
container, it cannot set proper Linux file ownership. Docker defaults to giving
the file open permissions (`-rwxrwxrwx` — everyone can read and write). Filebeat
sees these open permissions, its security check fails, and it exits immediately
with an error before even reading the config.

`--strict.perms=false` tells Filebeat to skip this check entirely and proceed
regardless of file permissions. This is the documented solution for running
Filebeat on Windows with Docker.

```yaml
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
```
Three volume mounts, all read-only (`:ro`):

`./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro` — our config
file mounted into the location Filebeat expects it. Read-only because Filebeat
only needs to read the config, not write to it.

`/var/lib/docker/containers:/var/lib/docker/containers:ro` — mounts the host's
Docker container log directory into the Filebeat container at the same path.
This is how Filebeat, running inside its own container, can read log files
from other containers on the host. Read-only because Filebeat reads logs,
never writes to them.

`/var/run/docker.sock:/var/run/docker.sock:ro` — mounts the Docker socket
into the Filebeat container. This is how the `add_docker_metadata` processor
in `filebeat.yml` queries Docker for container names and image names to enrich
log events. Without this mount, Filebeat cannot talk to Docker and the metadata
enrichment would fail silently.

```yaml
    depends_on:
      - logstash
```
Filebeat waits for Logstash to start before starting itself. Note this uses
the simpler `depends_on` without `condition: service_healthy` — this is because
Logstash does not have a healthcheck defined. It just waits for the Logstash
container to start, then starts Filebeat. Filebeat has retry logic built in
so even if Logstash is not fully ready when Filebeat starts, Filebeat will
keep retrying the connection until it succeeds.

### log-generator

```yaml
  log-generator:
    image: bash:latest
    container_name: log-generator
    command: bash /app/generate-logs.sh
    volumes:
      - ./app/generate-logs.sh:/app/generate-logs.sh
```
`image: bash:latest` — a minimal Docker image that contains only the Bash
shell and basic Linux utilities. We do not need Node.js, Python, or any
runtime — just a shell to run our script. This keeps the image tiny.

`command: bash /app/generate-logs.sh` — overrides the default container
command to run our script. `bash` is the interpreter, `/app/generate-logs.sh`
is the script path inside the container.

`volumes` — mounts only our script file into `/app/` inside the container.
The script runs, prints log lines to stdout, Docker captures them, Filebeat
ships them. This is the starting point of the entire log pipeline.

### Volumes

```yaml
volumes:
  elasticsearch-data:
```
Declares the named volume `elasticsearch-data` at the top level. Named volumes
declared here are created and managed by Docker. The data is stored in Docker's
own storage area on your machine and persists across container restarts and
even `docker compose down`. Only `docker compose down -v` deletes named volumes.

---

## 7. .github/workflows/ci.yml

```yaml
name: Validate ELK Config
```
Display name shown in the GitHub Actions tab.

```yaml
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
```
Triggers the pipeline on every push to main and every pull request targeting
main. Same trigger pattern as the previous two projects.

```yaml
jobs:
  validate-filebeat:
    name: Validate Filebeat Config
    runs-on: ubuntu-latest
    env:
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
```
The first job. `runs-on: ubuntu-latest` spins up a fresh Ubuntu machine on
GitHub's servers. The `env` variable forces GitHub Actions to use Node.js 24
internally to suppress deprecation warnings.

Notice there is no `needs:` between `validate-filebeat` and `validate-logstash`.
This means both jobs run in parallel simultaneously on separate machines.
They have no dependency on each other so there is no reason to run them
sequentially. Parallel jobs make the pipeline faster.

```yaml
    steps:
      - uses: actions/checkout@v4.2.2
```
Clones your repository onto the Ubuntu machine. Without this the machine has
no idea what your files are.

```yaml
      - name: Validate Filebeat config
        run: |
          docker run --rm \
            -v ${{ github.workspace }}/filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml \
            docker.elastic.co/beats/filebeat:8.13.0 \
            filebeat test config --strict.perms=false
```
This runs a Docker container on the GitHub Ubuntu machine specifically to
validate our Filebeat config. Breaking down each part:

`docker run --rm` — start a container and delete it automatically when it
finishes. The `--rm` flag prevents containers from piling up after validation.

`-v ${{ github.workspace }}/filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml`
— mounts our config file into the container. `${{ github.workspace }}` is a
GitHub Actions variable containing the path where your repo was cloned on the
Ubuntu machine — something like `/home/runner/work/elk-log-aggregation/elk-log-aggregation`.
So the full left side becomes the path to your `filebeat.yml` on the GitHub
machine, mounted into the standard Filebeat config location inside the container.

`docker.elastic.co/beats/filebeat:8.13.0` — the official Filebeat Docker image.
Using the same version as in `docker-compose.yml` ensures the validation uses
the same Filebeat version that runs in the actual stack.

`filebeat test config --strict.perms=false` — the command to run inside the
container. `filebeat test config` reads the config file, validates its syntax
and structure, and exits. If valid it exits with code 0 and the step shows
green. If invalid it exits with a non-zero code, the step fails, and the job
turns red. `--strict.perms=false` is needed for the same Windows permissions
reason explained earlier — though on GitHub's Ubuntu machines it is not
strictly necessary, it keeps the command consistent with our docker-compose setup.

```yaml
  validate-logstash:
    name: Validate Logstash Pipeline
    runs-on: ubuntu-latest
    env:
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
    steps:
      - uses: actions/checkout@v4.2.2

      - name: Validate Logstash pipeline config
        run: |
          docker run --rm \
            -v ${{ github.workspace }}/logstash/pipeline:/usr/share/logstash/pipeline \
            -v ${{ github.workspace }}/logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml \
            docker.elastic.co/logstash/logstash:8.13.0 \
            logstash --config.test_and_exit
```
The second job runs in parallel on a separate Ubuntu machine.

Two volume mounts instead of one — we need both the pipeline directory and
the config file mounted because Logstash reads both on startup.

`logstash --config.test_and_exit` — starts Logstash in validation mode. It
reads the pipeline config from `/usr/share/logstash/pipeline`, validates the
syntax and structure of every `.conf` file, and exits without actually starting
the pipeline or listening for incoming data. If valid, exits with code 0.
If invalid, exits with a non-zero code and prints the error showing exactly
which line in the pipeline config is wrong.

This catches errors like:
- Missing closing brace in the filter section
- Invalid plugin name (`beats` misspelled as `beat`)
- Wrong data type for a field value
- Invalid port number format

---

## 8. How a Log Line Travels End to End

Putting everything together — the complete journey of one log line:

```
generate-logs.sh prints to stdout
"2026-05-17T01:10:56 [ERROR] Authentication failed"
       ↓
Docker's json-file logging driver intercepts stdout
Writes to /var/lib/docker/containers/<id>/<id>-json.log on host:
{"log":"2026-05-17T01:10:56 [ERROR] Authentication failed\n","stream":"stdout","time":"..."}
       ↓
Filebeat watches /var/lib/docker/containers/*/*.log
Detects new line, reads it
add_docker_metadata processor queries Docker socket
Adds container.name, container.image.name to the event
Ships enriched event to logstash:5044 using Beats protocol
       ↓
Logstash receives on port 5044
Filter section reads [message] field
Finds [ERROR] in the message
mutate plugin adds new field: log_level = "ERROR"
Event is now structured JSON with proper fields
       ↓
Logstash output sends to elasticsearch:9200
Index: app-logs-2026.05.17 (created automatically if not exists)
Document stored in Elasticsearch with all fields indexed
       ↓
Logstash also prints to stdout via rubydebug codec
(visible in docker logs logstash during development)
       ↓
You open Kibana at http://localhost:5601
Search: log_level: ERROR
Kibana queries Elasticsearch
Returns all matching documents
Displayed in Discover view with timestamp, message, log_level, container name
```

Total time from log line printed to visible in Kibana — under one second.

---

## 9. Production Considerations

**Elasticsearch cluster** — minimum 3 nodes. Replica shards distributed across
nodes. Index status green, not yellow. If one node dies the other two continue
serving data with no downtime.

**Index Lifecycle Management (ILM)** — automatic policies that move indices
through phases. Hot phase (last 7 days) — fast SSD storage, frequent searches.
Warm phase (7-30 days) — slower storage, less frequent searches. Cold phase
(30-90 days) — cheapest storage, rare searches. Delete phase — indices older
than 90 days deleted automatically. No manual cleanup needed.

**Elasticsearch snapshots to S3** — regular automated snapshots of all indices
stored in S3. If the entire Elasticsearch cluster is lost, you restore from
the S3 snapshot. This is your disaster recovery mechanism.

**Filebeat as Kubernetes DaemonSet** — one Filebeat pod automatically on every
node. New nodes added to the cluster automatically get Filebeat. No manual
configuration per node.

**Kafka as buffer** — between Filebeat and Logstash. Filebeat writes to Kafka
topics. Logstash reads from Kafka. If Logstash goes down for maintenance,
logs accumulate in Kafka without being lost. When Logstash comes back it
processes the backlog. Without Kafka, logs generated while Logstash is down
are lost forever.

**Security enabled** — Elasticsearch requires username and password.
Certificates for TLS encryption between all components. Kibana has user
accounts with role-based access control — some teams see all logs, others
only their own service logs.

**Alerting** — Kibana alerting rules send Slack or PagerDuty notifications
when error rate exceeds a threshold. No engineer needs to watch dashboards
manually.

**Full production architecture:**
```
Every K8s node
└── Filebeat DaemonSet pod
        ↓
    Kafka cluster (buffer, never lose logs)
        ↓
    Logstash cluster (multiple instances, load balanced)
        ↓
    Elasticsearch cluster (3+ nodes, replicated, ILM policies)
        ↓                         ↓
    Kibana (UI, alerts)        S3 (snapshots, cold archive)
```