package dev.oreslang;

import dev.oreslang.runtime.IsolatePolicy;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.PolyglotException;
import org.graalvm.polyglot.Source;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

final class GarbageCollectionLanguageTest {
    @Test
    void processGcIsAFirstClassBuiltin() throws Exception {
        Source source = Source.newBuilder(OresLanguage.ID, """
                pub fnc main() => void {
                  process.gc();
                  return;
                }
                """, "process-gc.ores").mimeType(OresLanguage.MIME_TYPE).build();
        assertDoesNotThrow(() -> {
            try (Context context = Context.newBuilder(OresLanguage.ID).allowAllAccess(false).build()) {
                context.eval(source);
            }
        });
    }

    @Test
    void actorGcRequiresAnActorMailboxTurn() throws Exception {
        Source source = Source.newBuilder(OresLanguage.ID, """
                pub fnc main() => void {
                  actor.gc();
                  return;
                }
                """, "actor-gc-outside-actor.ores").mimeType(OresLanguage.MIME_TYPE).build();
        try (Context context = Context.newBuilder(OresLanguage.ID).allowAllAccess(false).build()) {
            PolyglotException error = assertThrows(PolyglotException.class, () -> context.eval(source));
            assertTrue(error.getMessage().contains("actor.gc() requires execution inside an actor"));
        }
    }

    @Test
    void strictFaasDoesNotGrantProcessWideGcControl() {
        assertFalse(IsolatePolicy.strictFaas().allows(IsolatePolicy.Capability.GC_CONTROL));
        assertTrue(IsolatePolicy.developer().allows(IsolatePolicy.Capability.GC_CONTROL));
    }
}
