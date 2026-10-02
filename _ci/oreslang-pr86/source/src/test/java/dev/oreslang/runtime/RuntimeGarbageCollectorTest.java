package dev.oreslang.runtime;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

final class RuntimeGarbageCollectorTest {
    @Test
    void processCollectionRequestsJvmGcAtMostOncePerThrottleWindow() {
        AtomicInteger gcRequests = new AtomicInteger();
        Object owner = new Object();
        try (RuntimeGarbageCollector gc = new RuntimeGarbageCollector(
                gcRequests::incrementAndGet, Duration.ofHours(1), Duration.ofHours(1), 16)) {
            gc.track(owner, () -> fail("live owner must not be cleaned"));
            var first = gc.collectProcess();
            var second = gc.collectProcess();
            assertTrue(first.jvmGcRequested());
            assertFalse(second.jvmGcRequested());
            assertEquals(1, gcRequests.get());
            assertEquals(1, first.trackedAfter());
            assertNotNull(owner);
        }
    }

    @Test
    void cleanupHandleIsDeterministicAndIdempotent() {
        AtomicInteger cleanups = new AtomicInteger();
        try (RuntimeGarbageCollector gc = new RuntimeGarbageCollector(() -> {}, Duration.ofHours(1))) {
            var handle = gc.track(new Object(), cleanups::incrementAndGet);
            handle.close();
            handle.close();
            assertEquals(1, cleanups.get());
        }
    }

    @Test
    void failedCleanupRemainsRetryable() {
        AtomicInteger attempts = new AtomicInteger();
        try (RuntimeGarbageCollector gc = new RuntimeGarbageCollector(() -> {}, Duration.ofHours(1))) {
            var handle = gc.track(new Object(), () -> {
                if (attempts.incrementAndGet() == 1) throw new IllegalStateException("transient");
            });
            assertThrows(IllegalStateException.class, handle::close);
            assertDoesNotThrow(handle::close);
            assertEquals(2, attempts.get());
        }
    }

    @Test
    void registryGrowthIsBounded() {
        try (RuntimeGarbageCollector gc = new RuntimeGarbageCollector(
                () -> {}, Duration.ofHours(1), Duration.ofSeconds(1), 1)) {
            Object owner = new Object();
            gc.track(owner, () -> {});
            assertThrows(IllegalStateException.class, () -> gc.track(new Object(), () -> {}));
            assertNotNull(owner);
        }
    }

    @Test
    void actorCollectionIsDomainLocalAndNeverRequestsJvmGc() throws Exception {
        AtomicInteger gcRequests = new AtomicInteger();
        AtomicReference<RuntimeGarbageCollector.CollectionReport> report = new AtomicReference<>();
        CountDownLatch done = new CountDownLatch(1);
        try (RuntimeGarbageCollector gc = new RuntimeGarbageCollector(gcRequests::incrementAndGet, Duration.ofHours(1));
             ActorRuntime runtime = new ActorRuntime()) {
            var ref = runtime.<String>spawn(() -> (message, context) -> {
                report.set(gc.collectCurrentActor());
                done.countDown();
            });
            ref.send("gc");
            assertTrue(done.await(2, TimeUnit.SECONDS));
            assertEquals("actor", report.get().scope());
            assertFalse(report.get().jvmGcRequested());
            assertEquals(0, gcRequests.get());
        }
    }

    @Test
    void actorCollectionOutsideActorIsRejected() {
        try (RuntimeGarbageCollector gc = new RuntimeGarbageCollector(() -> {}, Duration.ofHours(1))) {
            var error = assertThrows(IllegalStateException.class, gc::collectCurrentActor);
            assertTrue(error.getMessage().contains("actor.gc() requires execution inside an actor"));
        }
    }
}
