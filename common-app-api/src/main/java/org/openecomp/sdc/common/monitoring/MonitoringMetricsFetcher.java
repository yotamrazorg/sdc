/*-
 * ============LICENSE_START=======================================================
 * SDC
 * ================================================================================
 * Copyright (C) 2017 AT&T Intellectual Property. All rights reserved.
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

import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.lang.management.ThreadMXBean;
import java.net.InetAddress;
import java.nio.file.FileStore;
import java.nio.file.FileSystems;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.function.Supplier;
import java.util.function.UnaryOperator;
import com.sun.management.OperatingSystemMXBean;
import org.openecomp.sdc.common.impl.ExternalConfiguration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Collects host and JVM metrics using only the JDK ({@code java.lang.management} and
 * {@code com.sun.management.OperatingSystemMXBean}). No native library is required.
 * <p>
 * Units of the reported values:
 * <ul>
 * <li>{@code hostid} - canonical host name (FQDN), falls back to the {@code HOSTNAME}/{@code COMPUTERNAME}
 * environment variable and finally to {@value #UNKNOWN_HOST}.</li>
 * <li>{@code hostcpu} - system-wide CPU utilization as a whole percentage (0..100), from
 * {@link OperatingSystemMXBean#getCpuLoad()} (container aware). This replaces the cumulative CPU time in
 * milliseconds that was reported before; the JDK cannot provide a cumulative host CPU time. {@code -1} when the
 * load is not available.</li>
 * <li>{@code hostmem} - used physical memory as a percentage (0..100):
 * {@code (total - free) / total * 100}, using {@link OperatingSystemMXBean#getTotalMemorySize()} and
 * {@link OperatingSystemMXBean#getFreeMemorySize()} (container aware). {@code -1} when not available.</li>
 * <li>{@code hostdisk} - map of mount point to used percentage (0..100) of every file store with a non-zero size,
 * computed like {@code df}: {@code used / (used + usable) * 100}.</li>
 * <li>{@code jvmcpu} - CPU time used by this JVM process in nanoseconds ({@code getProcessCpuTime()}, unchanged
 * value; {@code -1} when not available).</li>
 * <li>{@code jvmmem} - used heap memory in bytes.</li>
 * <li>{@code jvmtnum} - number of live threads.</li>
 * </ul>
 */
public class MonitoringMetricsFetcher {

    static final String UNKNOWN_HOST = "unknown";
    static final String FE_JVM_NAME = "jetty-fe";
    static final String BE_JVM_NAME = "jetty-be";
    private static final String UNKNOWN_JVM_NAME = "Unknown";
    private static final Logger monitoringLogger = LoggerFactory.getLogger("asdc.fe.monitoring.fetcher");
    private static volatile MonitoringMetricsFetcher instance;

    private final OperatingSystemMXBean osMXBean;
    private final ThreadMXBean threadMXBean;
    private final MemoryMXBean memoryMXBean;
    private final Callable<String> hostNameResolver;
    private final Supplier<Iterable<FileStore>> fileStoreSupplier;
    private final UnaryOperator<String> envLookup;
    private final String appName;
    private final String jvmName;

    MonitoringMetricsFetcher(OperatingSystemMXBean osMXBean, ThreadMXBean threadMXBean, MemoryMXBean memoryMXBean,
                             Callable<String> hostNameResolver, Supplier<Iterable<FileStore>> fileStoreSupplier,
                             UnaryOperator<String> envLookup, String appName) {
        this.osMXBean = osMXBean;
        this.threadMXBean = threadMXBean;
        this.memoryMXBean = memoryMXBean;
        this.hostNameResolver = hostNameResolver;
        this.fileStoreSupplier = fileStoreSupplier;
        this.envLookup = envLookup;
        this.appName = appName;
        this.jvmName = resolveJvmName(appName);
    }

    public static MonitoringMetricsFetcher getInstance() {
        if (instance == null) {
            synchronized (MonitoringMetricsFetcher.class) {
                if (instance == null) {
                    instance = createDefault(ExternalConfiguration.getAppName());
                }
            }
        }
        return instance;
    }

    static MonitoringMetricsFetcher createDefault(String appName) {
        OperatingSystemMXBean os = null;
        try {
            os = ManagementFactory.getPlatformMXBean(OperatingSystemMXBean.class);
        } catch (Exception e) {
            monitoringLogger.error("com.sun.management.OperatingSystemMXBean is not available, host cpu/memory metrics are disabled", e);
        }
        return new MonitoringMetricsFetcher(os, ManagementFactory.getThreadMXBean(), ManagementFactory.getMemoryMXBean(),
            () -> InetAddress.getLocalHost().getCanonicalHostName(), () -> FileSystems.getDefault().getFileStores(), System::getenv, appName);
    }

    public MonitoringEvent getMonitoringMetrics() {
        MonitoringEvent monitoringEvent = new MonitoringEvent();
        monitoringEvent.setHostid(getFQDN());
        monitoringEvent.setHostcpu(getHostCpuLoad());
        monitoringEvent.setHostmem(getHostUsedMemory());
        monitoringEvent.setHostdisk(getHostUsedDisk().toString());
        monitoringEvent.setJvmid(jvmName);
        monitoringEvent.setJvmcpu(getJvmCpuTime());
        monitoringEvent.setJvmmem(getJvmUsedHeapMemory());
        monitoringEvent.setJvmtnum(getJvmThreads());
        monitoringEvent.setAppid(appName);
        // this is probably from healthcheck
        monitoringEvent.setAppstat("appStatus");
        return monitoringEvent;
    }

    private static String resolveJvmName(String appName) {
        monitoringLogger.debug("appName is {}", appName);
        // According to Yaki, there is no "calculated" jvmName like it was in TAS, just "jetty-be" or "jetty-fe"
        if (appName != null && appName.contains("fe")) {
            return FE_JVM_NAME;
        }
        if (appName != null && appName.contains("be")) {
            return BE_JVM_NAME;
        }
        monitoringLogger.warn("Couldn't determine jvmName, appName is expected to contain \"be\" or \"fe\" string");
        return UNKNOWN_JVM_NAME;
    }

    /**
     * Returns the number of live threads for this JVM
     *
     * @return number of live threads
     */
    private Integer getJvmThreads() {
        return threadMXBean.getThreadCount();
    }

    /**
     * Returns the number of used heap memory (bytes)
     *
     * @return the number of used heap memory (bytes)
     */
    private long getJvmUsedHeapMemory() {
        return memoryMXBean.getHeapMemoryUsage().getUsed();
    }

    /**
     * Returns the CPU time used by this JVM process (nanoseconds, same value as the former
     * {@code ProcessCpuTime} attribute).
     *
     * @return the jvm cpu time in nanoseconds or -1 if not available
     */
    private long getJvmCpuTime() {
        long cpuTime = -1;
        try {
            if (osMXBean != null) {
                long processCpuTime = osMXBean.getProcessCpuTime();
                if (processCpuTime >= 0) {
                    cpuTime = processCpuTime;
                } else {
                    monitoringLogger.warn("JVM CPU time is not supported on this platform");
                }
            }
        } catch (Exception e) {
            monitoringLogger.error("Couldn't measure JVM CPU time", e);
        }
        return cpuTime;
    }

    /**
     * Returns the system-wide CPU utilization as a whole percentage (0..100).
     *
     * @return the host CPU load in percent or -1 if not available
     */
    private long getHostCpuLoad() {
        long cpuLoad = -1;
        try {
            if (osMXBean != null) {
                double load = osMXBean.getCpuLoad();
                if (Double.isNaN(load) || load < 0) {
                    monitoringLogger.warn("Host CPU load is not available (value {})", load);
                } else {
                    cpuLoad = Math.round(Math.min(load, 1.0) * 100);
                }
            }
        } catch (Exception e) {
            monitoringLogger.error("Couldn't measure host CPU load", e);
        }
        return cpuLoad;
    }

    /**
     * Returns the host used physical memory as a percentage (0..100).
     *
     * @return the host used memory in percent or -1 if not available
     */
    private Double getHostUsedMemory() {
        double memory = -1.0;
        try {
            if (osMXBean != null) {
                long total = osMXBean.getTotalMemorySize();
                long free = osMXBean.getFreeMemorySize();
                if (total > 0 && free >= 0) {
                    memory = Math.max(0.0, Math.min(100.0, (double) (total - free) / total * 100));
                } else {
                    monitoringLogger.warn("Host memory is not available (total {}, free {})", total, free);
                }
            }
        } catch (Exception e) {
            monitoringLogger.error("Couldn't measure host used memory", e);
        }
        return memory;
    }

    /**
     * Returns the used percentage (0..100) of every file store, keyed by mount point. File stores that cannot be
     * read or have no size are skipped.
     *
     * @return mount point to used percentage
     */
    private Map<String, Double> getHostUsedDisk() {
        Map<String, Double> res = new LinkedHashMap<>();
        try {
            for (FileStore store : fileStoreSupplier.get()) {
                try {
                    long total = store.getTotalSpace();
                    long used = total - store.getUnallocatedSpace();
                    long usable = store.getUsableSpace();
                    long denominator = used + usable;
                    if (total <= 0 || used < 0 || usable < 0 || denominator <= 0) {
                        continue;
                    }
                    res.put(mountName(store), Math.max(0.0, Math.min(100.0, (double) used / denominator * 100)));
                } catch (Exception e) {
                    monitoringLogger.debug("Skipping file store {}: {}", store, e.toString());
                }
            }
        } catch (Exception e) {
            monitoringLogger.error("Couldn't measure host used disk", e);
        }
        return res;
    }

    /**
     * On Linux {@code FileStore.toString()} is {@code "<mount point> (<device>)"}; only the mount point is used.
     */
    private static String mountName(FileStore store) {
        String name = store.toString();
        int idx = name.lastIndexOf(" (");
        return name.endsWith(")") && idx > 0 ? name.substring(0, idx) : name;
    }

    /**
     * Returns the canonical host name (FQDN)
     *
     * @return the FQDN, or the HOSTNAME/COMPUTERNAME environment variable, or "unknown"
     */
    private String getFQDN() {
        try {
            String fqdn = hostNameResolver.call();
            if (fqdn != null && !fqdn.isEmpty()) {
                return fqdn;
            }
        } catch (Exception e) {
            monitoringLogger.error("Couldn't get FQDN", e);
        }
        for (String var : new String[] {"HOSTNAME", "COMPUTERNAME"}) {
            String value = envLookup.apply(var);
            if (value != null && !value.isEmpty()) {
                return value;
            }
        }
        return UNKNOWN_HOST;
    }
}
