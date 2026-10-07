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
