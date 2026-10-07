# Standard lifecycle commands (Java 21 modernization)

All commands run from the root of the respective checkout. `$WS` is the directory that holds
the seven checkouts (`sdc`, `so`, `aai-resources`, `aai-traversal`, `oom`, `integration`,
`policy-api`); the scripts below live in `$WS/sdc/build-env/`.

## 0. Toolchain (every repo)

```bash
source "$WS/sdc/build-env/bootstrap-java21.sh"                 # Temurin 21 + Maven 3.9.11
JAVA_VERSION_SELECT=17 source "$WS/sdc/build-env/bootstrap-java21.sh"   # system JDK 17 + same Maven (pre-change baseline)
```

* Pins: Temurin `21.0.12.1+1` (SHA-256 verified), Apache Maven `3.9.11` (SHA-512 verified).
  Cache: `${MCODE_BUILD_CACHE:-$HOME/.cache/onap-java21-toolchain}`; idempotent.
* It exports `JAVA_HOME`, `MAVEN_HOME`, `PATH` and `MAVEN_ARGS="-s build-env/settings.xml"`.
  Maven >= 3.9 reads `MAVEN_ARGS` from the environment, so a plain `mvn` picks the settings up
  automatically. Disable with `MCODE_MAVEN_SETTINGS=none`.
* **Why a `settings.xml` is required** (verified against the ONAP Nexus, public/anonymous):
  * `org.onap.oparent:oparent` 3.0.2 (so) and 3.2.0 (sdc) are *not* on Maven Central.
  * `org.onap.aai.aai-common:aai-parent:1.18.0` (aai-resources, aai-traversal) is *not* on Central.
  * `org.onap.policy.parent:integration:6.1.0-SNAPSHOT`, `policy-common:4.1.0-SNAPSHOT`,
    `policy-models:5.1.0-SNAPSHOT` (policy-api) only exist in
    `https://nexus.onap.org/content/repositories/snapshots/`.
  * `org.openecomp.sdc:onboarding-fe:1.19.0-SNAPSHOT` (the war that `catalog-fe` depends on, normally
    built from `openecomp-ui`) is resolved from the same snapshot repository, so the UI module
    does not need to be built.
  * oparent's enforcer rule demands an `onap.nexus.url` property in `settings.xml`.
  * `build-env/settings.xml` therefore defines the `onap-settings` property profile and the public
    `onap-public` / `onap-releases` / `onap-snapshots` repositories. No credentials, no mirrors.
* SNAPSHOT parents/dependencies of policy-api (and `onboarding-fe`) are moving targets: results
  for those can drift if upstream republishes a snapshot.

Verify: `java -version` reports 21.0.x, `mvn -v` reports `Apache Maven 3.9.11` on that JDK.

## 1. sdc

Profile facts (verified with `mvn ... validate`, see `sdc/pom.xml`):

* `fast-build-no-ui` = all Java modules (`openecomp-be`, `common`, `common-app-logging`,
  `common-app-api`, `common-be-tests-utils`, `common-be`, `catalog-dao`, `catalog-model`,
  `catalog-be`, `catalog-be-plugins`, `asdctool`, `sdc-os-chef`, `utils/webseal-simulator`;
  161 reactor projects) and **no** `catalog-ui`, `openecomp-ui`, `dox-sequence-diagram-ui`,
  `cucumber-js-test-apis-ci`. It does not skip tests. It does **not** contain `catalog-fe`.
* `fast-build-backend` = only `common-app-logging`, `common-app-api`, `common-be`, `catalog-dao`,
  `catalog-model`, `catalog-be`, `catalog-be-plugins` (10 reactor projects) and sets
  `maven.test.skip=true` (tests are not even compiled). It lacks `openecomp-be`, `asdctool`,
  `catalog-fe`; use it only for a quick catalog-be compile.
* **Pitfall:** `-DskipTests` and `-DskipITs=true` *activate* the profiles `skip-tests` /
  `skip-integration-tests` (property activation), which add `onboarding` (-> `openecomp-ui`),
  `catalog-ui`, `catalog-fe` ... to the reactor. Combined with `fast-build-no-ui` this fails with
  `Project 'openecomp-sdc-common-rest' is duplicated in the reactor`, and with
  `fast-build-backend` it builds the UI. Always deactivate them explicitly with `!skip-tests` /
  `!skip-integration-tests` (quote the `!` in an interactive shell).
* `sdc/.mvn/maven.config` already contains `-T2`.

| step | command |
|------|---------|
| install (no tests) | `mvn -Pfast-build-no-ui,'!skip-tests' -DskipTests install` |
| install catalog-fe (war, standalone) | `mvn -f catalog-fe/pom.xml -DskipTests install` (after the line above; it is not in any UI-free profile) |
| quick backend only | `mvn -Pfast-build-backend install` |
| build + unit tests | `mvn -Pfast-build-no-ui,'!skip-integration-tests' -DskipITs=true install` then `mvn -f catalog-fe/pom.xml install` |
| test only (no install) | `mvn -Pfast-build-no-ui,'!skip-integration-tests' -DskipITs=true test` (catalog-fe: `mvn -f catalog-fe/pom.xml test` after an install) |
| collect machine-readable results | `build-env/collect-baseline.sh --jdk 21 --no-aggregate sdc` |

Failsafe integration tests (`catalog-be`, `integration-tests`, ...) need Docker/Testcontainers and
are not part of the unit-test baseline.

Run / healthcheck of `catalog-fe` (no Cassandra/JanusGraph dependency):

* The war is `catalog-fe/target/catalog-fe-<version>.war`; Jetty context path is `/sdc1`
  (`WEB-INF/jetty-web.xml`).
* Local run (README): from `catalog-fe/`
  `mvn jetty:run -Dconfig.home=src/test/resources/config -Dlog.home=target/log -Dlogback.configurationFile=src/main/resources/config/logback.xml`
  then `curl -s http://localhost:8080/sdc1/rest/configmgr/get`.
* Container: `mvn -f catalog-fe/pom.xml -Pdocker install` (needs Docker; copies the
  `catalog-fe` and `onboarding-fe` wars into `catalog-fe/sdc-frontend/` and builds
  `onap/sdc-frontend` from `catalog-fe/sdc-frontend/Dockerfile`);
  `docker run --rm -p 8181:8181 onap/sdc-frontend`.
* **Health endpoint: `GET http://<host>:8181/sdc1/rest/healthCheck`** (container probe
  `sdc-frontend/artifacts/scripts/ready-probe.sh` curls exactly this, expecting HTTP 200).
  `FeHealthCheckServlet` returns the cached result of a scheduled task that calls the SDC-BE
  health check (`http://<beHost>:<beHttpPort>/sdc2/rest/healthCheck`) plus the onboarding-FE check:
  * `200` + JSON component list when BE (and the non-excluded components) are UP;
  * `500` + JSON (`BE` DOWN) when the BE is unreachable - the FE itself is up and the endpoint
    answers. For a stand-alone `catalog-fe` smoke test (no BE) the expected answer is therefore
    **HTTP 500 with a JSON body**; check `curl -s -o /dev/null -w '%{http_code}'` returns 200 or 500
    and the body is JSON.
  * the very first call right after start can also be `500 {}` until the scheduled task ran once.
* JVM version check: `docker exec <container> java -version` (must report 21 after the image
  base move to `eclipse-temurin:21-jre-alpine`).

### catalog-fe on JDK 21 - container check and the Docker-free smoke

`catalog-fe/sdc-frontend/Dockerfile` is based on `eclipse-temurin:21-jre-alpine`. Neither the
Dockerfile, `startup.sh`, `artifacts/scripts/*`, `startdConfig/*` nor `fe_etc/*` pass any JVM flag that
was removed after JDK 11 (no CMS/PermSize/endorsed dirs/`--illegal-access`); the docker-maven-plugin
profile (`-Pdocker`) only copies the wars and builds `sdc-frontend/` - it names no Java image or version.
The interim Jetty stays `jetty-distribution` 9.4.58 (smoke target until the Jetty 12 milestone).

**Docker is not available in the sandbox**, so the image itself can not be built or run there. When
Docker exists, the image check is:

```bash
mvn -f catalog-fe/pom.xml -Pdocker install                 # builds onap/sdc-frontend (needs the onboarding-fe war, see above)
docker run -d --name sdc-fe -p 8181:8181 onap/sdc-frontend
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8181/sdc1/rest/healthCheck   # 200 (BE up) or 500+JSON (stand-alone)
docker exec sdc-fe java -version                           # must report 21.x
```

**Docker-free smoke** (`build-env/smoke-catalog-fe-jdk21.sh`, re-runnable, ~20 s once the war exists):

```bash
build-env/smoke-catalog-fe-jdk21.sh        # exit 0 = PASS; always stops Jetty + the stand-in BE
```

It sources the bootstrap, builds the war only when `catalog-fe/target/catalog-fe-<ver>.war` is missing
(`SMOKE_BUILD=1` forces it; log in `$SMOKE_CACHE/logs`), downloads `jetty-distribution`
(version read from the root pom, SHA-1 verified) into `${SMOKE_CACHE:-$HOME/.cache/onap-smoke}` (outside
the repo), creates a fresh `JETTY_BASE` with the same `start.jar` commands and file layout as the
Dockerfile (`deploy`, `http`, `https`, `rewrite`; `setuid` is skipped - it needs the container's `onap`
user), deploys the `catalog-fe` and `onboarding-fe` wars and starts Jetty through the real
`startup.sh` (JDK 21 from the bootstrap). Deviations from the image, all smoke-only: free ports instead of
fixed 8181/9443, `-Xmx512m`, `-Djetty.base` (the image runs with base == home), and the run-dir copy of
`configuration.yaml` has `systemMonitoring.enabled=true`, probe interval 3 s and BE/onboarding hosts
pointing to `127.0.0.1`. A python listener plays SDC-BE (404 on `/sdc2/rest/healthCheck`, records POSTs
to `/sdc2/rest/monitoring`). Checks (non-zero exit on any failure):

1. `GET /sdc1/rest/healthCheck` answers 200/500 with a JSON body (stand-alone: `500`, BE DOWN, FE UP;
   afterwards the stand-in BE is switched to "healthy" and the endpoint is shown answering `200`, which is
   informational unless `SMOKE_REQUIRE_200=1`);
2. JVM is 21: `jcmd <pid> VM.version`, `/proc/<pid>/exe` under the bootstrap `JAVA_HOME`, Jetty's own log
   line `jetty-9.4.58...; jvm 21.0.12.1+1-LTS`;
3. the `MonitoringEvent` posted by `FeMonitoringService` has `hostcpu` 0..100, `hostmem` (0,100], a
   `hostdisk` mount map, `jvmcpu` > 0 and increasing, `jvmmem` > 0, `jvmtnum` > 0; neither the war nor
   the logs mention sigar; the console log has no `UnsatisfiedLinkError`/`Unrecognized VM option`/etc.

Knobs: `SMOKE_CACHE`, `SMOKE_HTTP_PORT`, `SMOKE_HTTPS_PORT`, `SMOKE_BE_PORT`, `SMOKE_BUILD`,
`SMOKE_TIMEOUT`, `SMOKE_REQUIRE_200`, `SMOKE_KEEP=1` (keep `<cache>/run` with the Jetty logs; always kept
on failure).

Not verifiable without Docker: that the image builds (`apk add curl jq`, jetty/otel downloads inside the
image), the alpine/musl runtime, the `onap` user + `setuid` module, and container-aware (cgroup) CPU/memory
values.

Known JDK 21 product fix: Jersey 2.34 `provider.packages` scanning cannot read Java 21 class files
(`Unsupported class file major version 65`), so `catalog-fe`'s `web.xml` registers its resource classes
explicitly via `jersey.config.server.provider.classnames`. `catalog-be`'s `web.xml` still uses package
scanning and needs the same treatment before it can start on JDK 21.

## 2. so

```bash
cd so
mvn -DskipTests install                                   # install (docker.skip=true by default)
mvn install -fae -Dmaven.test.failure.ignore=true         # build + unit tests (what the baseline runs)
mvn test                                                  # unit tests only
# run (needs MariaDB; see so/docs): java -jar bpmn/mso-infrastructure-bpmn/target/app.jar
curl -s http://localhost:8080/manage/health               # bpmn-infra actuator, base-path /manage
```
`so/.mvn/jvm.config` supplies the `--add-opens` flags needed by the Maven JVM itself.

## 3. aai-resources / aai-traversal

Parent `org.onap.aai.aai-common:aai-parent:1.18.0` and `aai-common` artifacts come from the
ONAP Nexus (see settings above).

```bash
cd aai-resources            # or aai-traversal
mvn -DskipTests install
mvn install -fae -Dmaven.test.failure.ignore=true         # build + unit tests
mvn test
# run:  java -jar aai-resources/target/aai-resources.jar   (spring-boot jar, port 8447;
#       aai-traversal: 8446)  - needs the Cassandra/schema-service stack for a real start
curl -sk -u <user>:<pass> -H 'X-FromAppId: smoke' -H 'X-TransactionId: smoke' \
     https://localhost:8447/aai/util/echo                # echo health endpoint
```
Management port for both is 8448 (`management.server.port`).
`K6ReadTest` (aai-resources) requires Docker/Testcontainers and errors without it.

## 4. policy-api

**Needs JDK 21 even today:** the SNAPSHOT parent `org.onap.policy.parent:policy-parent:6.1.0-SNAPSHOT`
sets `maven.compiler.release=21`, so on JDK 17 `api-main` fails with
`release version 21 not supported` (recorded as `prior_attempts` in the baseline; use
`source build-env/bootstrap-java21.sh` for every policy-api command).

Parent `org.onap.policy.parent:integration:6.1.0-SNAPSHOT`, `policy-common` 4.1.0-SNAPSHOT and
`policy-models` 5.1.0-SNAPSHOT are resolved from the ONAP snapshot repository (settings above).

```bash
cd policy-api
mvn -DskipTests install
mvn install -fae -Dmaven.test.failure.ignore=true
mvn test
# run: java -jar main/target/policy-api.jar  (port 6969, needs PostgreSQL)
curl -s -u <user>:<pass> http://localhost:6969/policy/api/v1/healthcheck
```

### Build smoke on JDK 21 (so, aai-resources, aai-traversal, policy-api)

`mvn -B -ntp -DskipTests clean install` under `source build-env/bootstrap-java21.sh` succeeds in all
four repos (so ~2 min, the others < 1 min).

* Use `clean` when `target/` holds an earlier test run: aai-resources / aai-traversal otherwise fail
  `jacoco:check` on a stale `jacoco-ut.exec` that does not match the freshly compiled classes
  (not a JDK 21 problem).
* Class-file levels today: aai-* 61 (release 17), policy-api 65 (release 21, forced by its parent),
  so 55 (effective `<release>11</release>` inherited from oparent 3.0.2, despite `java.version` 17)
  and 59 for the two groovy-eclipse BPMN modules (`MSOCommonBPMN`,
  `so-bpmn-infrastructure-common`, groovy-eclipse is capped at Java 15). These are pre-existing;
  the release bump belongs to each repo's own milestone.
* so emits ~2000 non-fatal warnings (checkstyle, enforcer upper-bound dependencies, hk2 paths).

## 5. oom / integration (no Java build)

* `oom`: `helm lint` / `helm template` on the modified charts (`oom/kubernetes/...`); chart build
  flow is `make` in `oom/kubernetes`.
* `integration`: Python/Robot content only - no Maven step. The basic_vm runner is added by a
  later milestone.

## 6. Baseline and regression check

```bash
build-env/collect-baseline.sh --jdk 17 sdc so aai-resources aai-traversal   # pre-change baseline (JDK 17)
build-env/collect-baseline.sh --jdk 21 policy-api                           # policy-api cannot build on 17
build-env/collect-baseline.sh --jdk 21 --no-aggregate --log-dir fresh-results sdc  # fresh results, JDK 21
python3 build-env/compare_baseline.py --current fresh-results/sdc-baseline.json   # exit 1 on regression
```

* The baseline is `build-env/test-baseline.json` (per module: tests/passed/failures/errors/skipped
  plus the names of failing and skipped tests). Logs are written outside the repos (default
  `$WS/../mcode/baseline-logs`, override `MCODE_BASELINE_LOGS` / `--log-dir`).
* Hang protection: every Maven call gets `-Dsurefire.timeout` (`MVN_FORK_TIMEOUT`, default
  2400 s per fork) and is wrapped in `timeout` (`MVN_STEP_TIMEOUT`, default 14400 s). A fork killed
  by the timeout is recorded as `fork_timeouts` and the repo becomes `partial`.
* **Environment exclusions** (`build-env/baseline-exclusions.json` -> `environment_exclusions` in
  the baseline): classes that hang in the sandbox are excluded through a generated
  `-Dsurefire.excludesFile` (command line only, no pom is touched) and are not part of the module
  counts. Currently: `catalog-dao` `CassandraClientTest`, `SdcSchemaBuilderTest`,
  `SdcSchemaUtilsTest` (cassandra-unit `EmbeddedCassandraServerHelper` blocks forever). When a later
  milestone moves them to Testcontainers, delete the entry; `compare_baseline.py` then reports the
  classes as "re-enabled" and any failure as a new failing test.
* sdc: the build rewrites the tracked `asdctool/sdc-cassandra-init/version.sh`; run
  `git checkout -- asdctool/sdc-cassandra-init/version.sh` after a build so it is not committed.
* Known pre-existing failures in the baseline are explained in the `notes` of each repo entry
  (JanusGraph in-memory locking failures in catalog-model/-dao/-be, JDK 17 encapsulation errors,
  Docker-dependent tests).
