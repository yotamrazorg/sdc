"""Functional tests for the Foundation milestone: catalog-fe (war on Jetty 9.4.58 / JDK 21).

Target-only. Run against the app started by the lifecycle `run` script (stand-in SDC-BE on STUB_BE_PORT).
Each test stores what it observed in CAPTURE_FILE so the results can be recorded verbatim afterwards.
"""
import json
import os
import re
import subprocess
import time
import zipfile
from pathlib import Path

import pytest
import requests

FE = "http://127.0.0.1:%s" % os.environ.get("FE_HTTP_PORT", "8181")
MCODE_DIR = os.environ["MCODE_DIR"]
WORKSPACE_DIR = os.environ["WORKSPACE_DIR"]
RUN_DIR = Path(MCODE_DIR) / "lifecycle/target/run/catalog-fe"
EVENTS = RUN_DIR / "monitoring-events.jsonl"
CONSOLE = RUN_DIR / "jetty-console.log"
CAPTURE_FILE = Path(os.environ.get("FT_CAPTURE_FILE", os.path.join(os.environ.get("TMPDIR", "."), "ft_capture.json")))
HDR = {"Accept": "application/json", "USER_ID": "ftuser"}


def _capture(name, **kw):
    data = json.loads(CAPTURE_FILE.read_text()) if CAPTURE_FILE.exists() else {}
    data[name] = kw
    CAPTURE_FILE.write_text(json.dumps(data))


def _get(path, **kw):
    return requests.get(FE + path, headers=HDR, timeout=15, allow_redirects=False, **kw)


def _events():
    return [json.loads(l)["event"] for l in EVENTS.read_text().splitlines() if l.strip()]


def _jetty_pid():
    out = subprocess.run(["pgrep", "-f", "--", "-Djetty.base=%s/jetty-base" % RUN_DIR],
                         capture_output=True, text=True).stdout.split()
    for p in out:
        try:
            if os.path.basename(os.path.realpath("/proc/%s/exe" % p)) == "java":
                return int(p)
        except OSError:
            pass
    return None


@pytest.fixture(scope="session", autouse=True)
def fe_up():
    if CAPTURE_FILE.exists():
        CAPTURE_FILE.unlink()
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if requests.get(FE + "/sdc1/rest/healthCheck", headers=HDR, timeout=5).status_code in (200, 500):
                return
        except requests.RequestException:
            pass
        time.sleep(2)
    pytest.fail("catalog-fe is not answering on " + FE)


class TestHealthAndRedirect:
    def test_health_check_standalone(self):
        r = _get("/sdc1/rest/healthCheck")
        _capture("test_health_check_standalone", endpoint="/sdc1/rest/healthCheck", method="GET",
                 status=r.status_code, output=r.text)
        # stand-alone: BE is only a stand-in answering 404 -> documented HTTP 500, FE UP / BE DOWN
        assert r.status_code == 500
        assert r.headers["Content-Type"].startswith("application/json")
        comps = {c["healthCheckComponent"]: c for c in r.json()["componentsInfo"]}
        assert comps["FE"]["healthCheckStatus"] == "UP"
        assert comps["FE"]["description"] == "OK"
        assert comps["BE"]["healthCheckStatus"] == "DOWN"

    def test_health_check_fe_version(self):
        r = _get("/sdc1/rest/healthCheck")
        _capture("test_health_check_fe_version", endpoint="/sdc1/rest/healthCheck", method="GET",
                 status=r.status_code, output=r.text)
        comps = {c["healthCheckComponent"]: c for c in r.json()["componentsInfo"]}
        assert re.match(r"^\d+\.\d+\.\d+", comps["FE"]["version"])

    def test_root_redirects_to_sdc1(self):
        r = _get("/")
        _capture("test_root_redirects_to_sdc1", endpoint="/", method="GET", status=r.status_code,
                 output="Location: %s" % r.headers.get("Location"))
        assert r.status_code == 302
        assert r.headers["Location"].rstrip("/").endswith("/sdc1")

    def test_sdc1_context_redirects_to_slash(self):
        r = _get("/sdc1")
        _capture("test_sdc1_context_redirects_to_slash", endpoint="/sdc1", method="GET", status=r.status_code,
                 output="Location: %s" % r.headers.get("Location"))
        assert r.status_code == 302
        assert r.headers["Location"].endswith("/sdc1/")

    def test_unknown_rest_path_404(self):
        r = _get("/sdc1/rest/nonexistent")
        _capture("test_unknown_rest_path_404", endpoint="/sdc1/rest/nonexistent", method="GET",
                 status=r.status_code, output=r.text)
        assert r.status_code == 404

    def test_post_health_check_not_allowed(self):
        r = requests.post(FE + "/sdc1/rest/healthCheck", headers=HDR, timeout=15, json={})
        _capture("test_post_health_check_not_allowed", endpoint="/sdc1/rest/healthCheck", method="POST",
                 status=r.status_code, output=r.text)
        assert r.status_code == 405


class TestJerseyResourcesRegisteredByClassName:
    def test_configmgr_get(self):
        r = _get("/sdc1/rest/configmgr/get")
        _capture("test_configmgr_get", endpoint="/sdc1/rest/configmgr/get", method="GET",
                 status=r.status_code, output=r.text)
        assert r.status_code == 200
        body = r.json()
        assert body["beHost"] == "127.0.0.1"
        assert body["beHttpPort"] == int(os.environ.get("STUB_BE_PORT", "18080"))
        assert body["systemMonitoring"]["enabled"] is True

    def test_config_ui_workspace(self):
        r = _get("/sdc1/rest/config/ui/workspace")
        _capture("test_config_ui_workspace", endpoint="/sdc1/rest/config/ui/workspace", method="GET",
                 status=r.status_code, output=r.text)
        assert r.status_code == 200
        menu = r.json()["workspaceMenuConfiguration"]
        assert "VFC" in menu and len(menu["VFC"]) > 0
        assert menu["VFC"][0]["text"] == "General"

    def test_config_ui_plugins(self):
        r = _get("/sdc1/rest/config/ui/plugins")
        _capture("test_config_ui_plugins", endpoint="/sdc1/rest/config/ui/plugins", method="GET",
                 status=r.status_code, output=r.text)
        assert r.status_code == 200
        plugins = r.json()
        assert isinstance(plugins, list) and plugins
        assert {"pluginId", "pluginDiscoveryUrl", "isOnline"} <= set(plugins[0])

    def test_plugin_online_known_plugin(self):
        r = _get("/sdc1/rest/config/ui/plugins/POLICY/online")
        _capture("test_plugin_online_known_plugin", endpoint="/sdc1/rest/config/ui/plugins/POLICY/online",
                 method="GET", status=r.status_code, output=r.text)
        # plugin host is unreachable here -> resource answers (200) with an online flag, never 404/500
        assert r.status_code == 200
        assert r.text.strip().lower() in ("true", "false")

    def test_plugin_online_unknown_plugin_404(self):
        r = _get("/sdc1/rest/config/ui/plugins/foo/online")
        _capture("test_plugin_online_unknown_plugin_404", endpoint="/sdc1/rest/config/ui/plugins/foo/online",
                 method="GET", status=r.status_code, output=r.text)
        assert r.status_code == 404
        assert 'pluginId:"foo"' in r.text

    def test_portal_servlet_html(self):
        r = _get("/sdc1/portal")
        _capture("test_portal_servlet_html", endpoint="/sdc1/portal", method="GET", status=r.status_code,
                 output=r.text)
        assert r.status_code == 200
        assert r.headers["Content-Type"].startswith("text/html")


class TestJdk21Runtime:
    def test_running_jvm_is_21(self):
        pid = _jetty_pid()
        assert pid, "no Jetty java process found"
        exe = os.path.realpath("/proc/%d/exe" % pid)
        out = subprocess.run([exe, "-version"], capture_output=True, text=True)
        text = out.stdout + out.stderr
        _capture("test_running_jvm_is_21", command="java", args="-version (exe of jetty pid %d: %s)" % (pid, exe),
                 exit_code=out.returncode, output=text)
        assert out.returncode == 0
        assert re.search(r'version "21\.', text)
        # the long-running process itself must have been launched from that JDK, not JDK 17
        assert "21" in exe or "jdk-21" in exe

    def test_war_has_no_sigar_and_registers_resources(self):
        wars = sorted((Path(WORKSPACE_DIR) / "sdc/catalog-fe/target").glob("catalog-fe-*.war"))
        assert wars, "catalog-fe war missing"
        with zipfile.ZipFile(wars[0]) as z:
            names = z.namelist()
            web_xml = z.read("WEB-INF/web.xml").decode()
        sigar = [n for n in names if "sigar" in n.lower()]
        _capture("test_war_has_no_sigar_and_registers_resources", endpoint=str(wars[0]), method="WAR",
                 output="entries=%d sigar_entries=%s" % (len(names), sigar))
        assert sigar == []
        for cls in ("ConfigMgrServlet", "ConfigServlet", "FeHealthCheckServlet", "PortalServlet"):
            assert "org.openecomp.sdc.fe.servlets.%s" % cls in web_xml
        assert "jersey.config.server.provider.classnames" in web_xml
        # package scanning must not be what registers the resources (comment text mentioning it is fine)
        assert "<param-name>jersey.config.server.provider.packages</param-name>" not in web_xml

    def test_console_log_has_no_jdk21_incompatibility(self):
        log = CONSOLE.read_text(errors="replace")
        bad = [p for p in ("sigar", "UnsatisfiedLinkError", "NoClassDefFoundError", "IllegalAccessError",
                           "InaccessibleObjectException", "Unrecognized VM option",
                           "Unsupported class file major version") if p.lower() in log.lower()]
        _capture("test_console_log_has_no_jdk21_incompatibility", endpoint=str(CONSOLE), method="LOG",
                 output="bytes=%d offending=%s" % (len(log), bad))
        assert bad == []


class TestMonitoringMetrics:
    """MonitoringEvent posted by FeMonitoringService -> MonitoringMetricsFetcher on JDK MXBeans."""

    def test_event_has_expected_shape_and_ranges(self):
        evs = _events()
        assert evs, "no monitoring events received by the stand-in BE"
        e = evs[-1]
        _capture("test_event_has_expected_shape_and_ranges", endpoint="/sdc2/rest/monitoring", method="POST",
                 status=200, output=json.dumps(e, sort_keys=True))
        assert {"appid", "hostid", "jvmid", "hostcpu", "hostmem", "hostdisk", "jvmcpu", "jvmmem",
                "jvmtnum"} <= set(e)
        assert e["appid"] == "catalog-fe"
        assert 0 <= e["hostcpu"] <= 100
        assert 0 < e["hostmem"] <= 100
        assert e["jvmcpu"] > 0 and e["jvmmem"] > 0 and e["jvmtnum"] > 0
        disks = re.findall(r"([^,{}=]+)=([0-9.]+)", e["hostdisk"])
        assert disks
        assert all(0 <= float(v) <= 100 for _, v in disks)

    def test_events_keep_arriving_and_values_change(self):
        n0 = len(_events())
        time.sleep(11)  # probe interval is 3s in the run dir configuration
        evs = _events()
        new = evs[n0:]
        window = evs[-6:]
        _capture("test_events_keep_arriving_and_values_change", endpoint="/sdc2/rest/monitoring", method="POST",
                 status=200,
                 output=json.dumps({"events_before": n0, "events_after": len(evs),
                                    "last_6_jvmcpu": [x["jvmcpu"] for x in window],
                                    "last_6_jvmmem": [x["jvmmem"] for x in window],
                                    "last_6_hostcpu": [x["hostcpu"] for x in window],
                                    "last_6_hostmem": [x["hostmem"] for x in window],
                                    "last_6_jvmtnum": [x["jvmtnum"] for x in window]}))
        assert len(new) >= 2, "monitoring events stopped arriving"
        cpu = [x["jvmcpu"] for x in evs]
        assert cpu == sorted(cpu), "jvmcpu (process CPU time ns) must be monotonic"
        assert cpu[-1] > cpu[0], "jvmcpu never advanced"
        assert len({x["jvmmem"] for x in window}) > 1 or len({x["hostmem"] for x in window}) > 1, \
            "memory metrics are constant - looks stubbed"

    def test_jvmcpu_consistent_with_os_process_time(self):
        pid = _jetty_pid()
        assert pid
        e = _events()[-1]
        fields = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
        ticks = int(fields[11]) + int(fields[12])  # utime + stime
        os_ns = ticks * (1_000_000_000 // os.sysconf("SC_CLK_TCK"))
        _capture("test_jvmcpu_consistent_with_os_process_time", endpoint="/proc/%d/stat" % pid, method="OS",
                 output="event.jvmcpu=%d ns, os utime+stime=%d ns" % (e["jvmcpu"], os_ns))
        # event was taken in the past, so it cannot exceed the OS value; and it must be the same order of magnitude
        assert e["jvmcpu"] <= os_ns * 1.05 + 200_000_000
        assert e["jvmcpu"] >= os_ns * 0.25

    def test_hostmem_consistent_with_proc_meminfo(self):
        mem = {l.split(":")[0]: int(l.split()[1]) for l in open("/proc/meminfo")}
        # spec: used = (total - free) / total with the JDK OperatingSystemMXBean free size (== MemFree, page cache counts as used)
        used_pct = 100.0 * (mem["MemTotal"] - mem["MemFree"]) / mem["MemTotal"]
        evs = _events()
        vals = [x["hostmem"] for x in evs[-5:]]
        _capture("test_hostmem_consistent_with_proc_meminfo", endpoint="/proc/meminfo", method="OS",
                 output="proc used%%=%.2f event hostmem=%s" % (used_pct, vals))
        assert abs(vals[-1] - used_pct) < 5.0

    def test_jvmtnum_consistent_with_os_threads(self):
        pid = _jetty_pid()
        assert pid
        e = _events()[-1]
        os_threads = int(re.search(r"Threads:\s+(\d+)", open("/proc/%d/status" % pid).read()).group(1))
        _capture("test_jvmtnum_consistent_with_os_threads", endpoint="/proc/%d/status" % pid, method="OS",
                 output="event.jvmtnum=%d os threads=%d" % (e["jvmtnum"], os_threads))
        assert 5 <= e["jvmtnum"] <= os_threads

    def test_hostdisk_root_matches_filesystem(self):
        st = os.statvfs("/")
        used = 100.0 * (st.f_blocks - st.f_bfree) / st.f_blocks
        e = _events()[-1]
        m = dict((k.strip(), float(v)) for k, v in re.findall(r"([^,{}=]+)=([0-9.]+)", e["hostdisk"]))
        _capture("test_hostdisk_root_matches_filesystem", endpoint="statvfs(/)", method="OS",
                 output="statvfs used%%=%.2f event hostdisk=%s" % (used, e["hostdisk"]))
        assert "/" in m
        assert abs(m["/"] - used) < 10.0
