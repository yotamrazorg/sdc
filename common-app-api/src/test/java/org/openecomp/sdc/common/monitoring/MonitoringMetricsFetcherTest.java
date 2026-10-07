/*-
 * ============LICENSE_START=======================================================
 * SDC
 * ================================================================================
 * Copyright (C) 2019 AT&T Intellectual Property. All rights reserved.
 * ================================================================================
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *      http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * ============LICENSE_END=========================================================
 */

package org.openecomp.sdc.common.monitoring;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.sun.management.OperatingSystemMXBean;
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.management.MemoryUsage;
import java.lang.management.ThreadMXBean;
import java.nio.file.FileStore;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.function.UnaryOperator;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.openecomp.sdc.common.impl.ExternalConfiguration;

class MonitoringMetricsFetcherTest {

    private String originalAppName;
    private OperatingSystemMXBean os;
    private ThreadMXBean threads;
    private MemoryMXBean memory;

    @BeforeEach
    void setUp() {
        originalAppName = ExternalConfiguration.getAppName();
        os = mock(OperatingSystemMXBean.class);
        threads = mock(ThreadMXBean.class);
        memory = mock(MemoryMXBean.class);
        when(threads.getThreadCount()).thenReturn(42);
        when(memory.getHeapMemoryUsage()).thenReturn(new MemoryUsage(0, 1234L, 2000L, 4000L));
        when(os.getProcessCpuTime()).thenReturn(5_000_000L);
        when(os.getCpuLoad()).thenReturn(0.256);
        when(os.getTotalMemorySize()).thenReturn(1000L);
        when(os.getFreeMemorySize()).thenReturn(250L);
    }

    @AfterEach
    void tearDown() {
        ExternalConfiguration.setAppName(originalAppName);
    }

    private MonitoringMetricsFetcher fetcher(String appName, List<FileStore> stores) {
        return new MonitoringMetricsFetcher(os, threads, memory, () -> "host.example.org", () -> stores, name -> null, appName);
    }

    private static FileStore store(String name, long total, long unallocated, long usable) throws IOException {
        FileStore store = mock(FileStore.class);
        when(store.toString()).thenReturn(name);
        when(store.getTotalSpace()).thenReturn(total);
        when(store.getUnallocatedSpace()).thenReturn(unallocated);
        when(store.getUsableSpace()).thenReturn(usable);
        return store;
    }

    // ---- real JVM / host MXBeans ----

    @Test
    void realMetricsAreSensible() {
        MonitoringEvent event = MonitoringMetricsFetcher.createDefault("sdc-be").getMonitoringMetrics();

        assertNotNull(event.getHostid());
        assertFalse(event.getHostid().isEmpty());
        assertTrue(event.getHostmem() > 0 && event.getHostmem() <= 100, "hostmem " + event.getHostmem());
        assertTrue(event.getHostcpu() >= 0 && event.getHostcpu() <= 100, "hostcpu " + event.getHostcpu());
        assertTrue(event.getJvmcpu() > 0, "jvmcpu " + event.getJvmcpu());
        assertTrue(event.getJvmmem() > 0);
        assertTrue(event.getJvmtnum() > 0);
        assertEquals("jetty-be", event.getJvmid());
        assertEquals("sdc-be", event.getAppid());
        assertEquals("appStatus", event.getAppstat());

        // hostdisk is serialized with Map.toString(): {mount=percent, ...}
        String disk = event.getHostdisk();
        assertTrue(disk.startsWith("{") && disk.endsWith("}"));
        assertFalse("{}".equals(disk), "hostdisk must not be empty");
        Matcher m = Pattern.compile("=(\\d+(?:\\.\\d+)?(?:E-?\\d+)?)").matcher(disk);
        int found = 0;
        while (m.find()) {
            double pct = Double.parseDouble(m.group(1));
            assertTrue(pct >= 0 && pct <= 100, "disk percent " + pct);
            found++;
        }
        assertTrue(found > 0);
    }

    @Test
    void getInstanceReturnsSingleton() {
        ExternalConfiguration.setAppName("sdc-fe");
        MonitoringMetricsFetcher first = MonitoringMetricsFetcher.getInstance();
        assertNotNull(first);
        assertSame(first, MonitoringMetricsFetcher.getInstance());
        assertNotNull(first.getMonitoringMetrics().getHostid());
    }

    // ---- mocked OperatingSystemMXBean ----

    @Test
    void knownValuesMapToExpectedOutputs() throws Exception {
        List<FileStore> stores = Arrays.asList(
            store("/ (/dev/sda1)", 1000L, 300L, 200L),   // used 700, usable 200 -> 700/900
            store("/data (/dev/sdb1)", 2000L, 2000L, 2000L), // empty -> 0%
            store("/proc (proc)", 0L, 0L, 0L));          // zero sized -> skipped
        MonitoringEvent event = fetcher("sdc-be", stores).getMonitoringMetrics();

        assertEquals("host.example.org", event.getHostid());
        assertEquals(26L, event.getHostcpu());
        assertEquals(75.0, event.getHostmem(), 1e-9);
        assertEquals(5_000_000L, event.getJvmcpu());
        assertEquals(1234L, event.getJvmmem());
        assertEquals(42, event.getJvmtnum());
        assertEquals("jetty-be", event.getJvmid());
        assertEquals("{/=" + (700.0 / 900 * 100) + ", /data=0.0}", event.getHostdisk());
    }

    @Test
    void cpuLoadIsClampedAndRounded() {
        when(os.getCpuLoad()).thenReturn(1.7);
        assertEquals(100L, fetcher("be", Collections.emptyList()).getMonitoringMetrics().getHostcpu());
        when(os.getCpuLoad()).thenReturn(0.0);
        assertEquals(0L, fetcher("be", Collections.emptyList()).getMonitoringMetrics().getHostcpu());
        when(os.getCpuLoad()).thenReturn(0.994);
        assertEquals(99L, fetcher("be", Collections.emptyList()).getMonitoringMetrics().getHostcpu());
    }

    @Test
    void unsupportedValuesFallBackToMinusOne() {
        when(os.getCpuLoad()).thenReturn(Double.NaN);
        when(os.getProcessCpuTime()).thenReturn(-1L);
        when(os.getTotalMemorySize()).thenReturn(0L);
        MonitoringEvent event = fetcher("sdc-fe", Collections.emptyList()).getMonitoringMetrics();

        assertEquals(-1L, event.getHostcpu());
        assertEquals(-1.0, event.getHostmem(), 0.0);
        assertEquals(-1L, event.getJvmcpu());
        assertEquals("{}", event.getHostdisk());
        assertEquals("jetty-fe", event.getJvmid());
    }

    @Test
    void negativeCpuLoadAndNegativeFreeMemoryFallBack() {
        when(os.getCpuLoad()).thenReturn(-1.0);
        when(os.getFreeMemorySize()).thenReturn(-1L);
        MonitoringEvent event = fetcher("sdc-be", Collections.emptyList()).getMonitoringMetrics();
        assertEquals(-1L, event.getHostcpu());
        assertEquals(-1.0, event.getHostmem(), 0.0);
    }

    @Test
    void exceptionsFromOsBeanDoNotPropagate() {
        when(os.getCpuLoad()).thenThrow(new UnsupportedOperationException("boom"));
        when(os.getTotalMemorySize()).thenThrow(new IllegalStateException("boom"));
        when(os.getProcessCpuTime()).thenThrow(new SecurityException("boom"));
        MonitoringEvent event = fetcher("sdc-be", Collections.emptyList()).getMonitoringMetrics();
        assertEquals(-1L, event.getHostcpu());
        assertEquals(-1.0, event.getHostmem(), 0.0);
        assertEquals(-1L, event.getJvmcpu());
        assertEquals(42, event.getJvmtnum());
    }

    @Test
    void missingOsBeanYieldsMinusOne() {
        MonitoringMetricsFetcher fetcher = new MonitoringMetricsFetcher(null, threads, memory, () -> "h", Collections::emptyList,
            name -> null, "sdc-be");
        MonitoringEvent event = fetcher.getMonitoringMetrics();
        assertEquals(-1L, event.getHostcpu());
        assertEquals(-1.0, event.getHostmem(), 0.0);
        assertEquals(-1L, event.getJvmcpu());
    }

    // ---- disk ----

    @Test
    void failingFileStoreIsSkipped() throws Exception {
        FileStore broken = mock(FileStore.class);
        when(broken.toString()).thenReturn("/broken (x)");
        when(broken.getTotalSpace()).thenThrow(new IOException("io"));
        FileStore ok = store("/ok (/dev/x)", 100L, 50L, 50L);
        MonitoringEvent event = fetcher("sdc-be", Arrays.asList(broken, ok)).getMonitoringMetrics();
        assertEquals("{/ok=50.0}", event.getHostdisk());
    }

    @Test
    void failingFileStoreSupplierYieldsEmptyDisk() {
        MonitoringMetricsFetcher fetcher = new MonitoringMetricsFetcher(os, threads, memory, () -> "h",
            () -> { throw new IllegalStateException("fs"); }, name -> null, "sdc-be");
        assertEquals("{}", fetcher.getMonitoringMetrics().getHostdisk());
    }

    @Test
    void storeNameWithoutDeviceSuffixIsKeptAsIs() throws Exception {
        MonitoringEvent event = fetcher("sdc-be", Collections.singletonList(store("C:\\", 100L, 75L, 75L))).getMonitoringMetrics();
        assertEquals("{C:\\=25.0}", event.getHostdisk());
    }

    // ---- host name ----

    @Test
    void hostNameFallsBackToEnvironment() {
        UnaryOperator<String> env = name -> "HOSTNAME".equals(name) ? "env-host" : null;
        MonitoringMetricsFetcher failing = new MonitoringMetricsFetcher(os, threads, memory,
            () -> { throw new java.net.UnknownHostException("x"); }, Collections::emptyList, env, "sdc-be");
        assertEquals("env-host", failing.getMonitoringMetrics().getHostid());

        MonitoringMetricsFetcher empty = new MonitoringMetricsFetcher(os, threads, memory, () -> "", Collections::emptyList,
            name -> "COMPUTERNAME".equals(name) ? "win-host" : null, "sdc-be");
        assertEquals("win-host", empty.getMonitoringMetrics().getHostid());
    }

    @Test
    void hostNameUnknownWhenNothingAvailable() {
        MonitoringMetricsFetcher fetcher = new MonitoringMetricsFetcher(os, threads, memory, () -> null, Collections::emptyList,
            name -> null, "sdc-be");
        assertEquals("unknown", fetcher.getMonitoringMetrics().getHostid());
    }

    // ---- jvm name selection ----

    @Test
    void jvmNameSelection() {
        assertEquals("jetty-fe", fetcher("sdc-fe", Collections.emptyList()).getMonitoringMetrics().getJvmid());
        assertEquals("jetty-be", fetcher("sdc-be", Collections.emptyList()).getMonitoringMetrics().getJvmid());
        assertEquals("Unknown", fetcher("common", Collections.emptyList()).getMonitoringMetrics().getJvmid());
        assertEquals("Unknown", fetcher(null, Collections.emptyList()).getMonitoringMetrics().getJvmid());
    }

    @Test
    void createDefaultUsesPlatformBeans() {
        MonitoringEvent event = MonitoringMetricsFetcher.createDefault("sdc-fe").getMonitoringMetrics();
        assertEquals("jetty-fe", event.getJvmid());
        assertTrue(event.getJvmtnum() <= ManagementFactory.getThreadMXBean().getThreadCount() + 100);
    }
}
