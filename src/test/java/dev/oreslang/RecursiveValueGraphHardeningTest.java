package dev.oreslang;

import dev.oreslang.ast.Ast;
import dev.oreslang.parser.Parser;
import dev.oreslang.runtime.ActorRuntime;
import dev.oreslang.types.TypeChecker;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

final class RecursiveValueGraphHardeningTest {
    @Test
    void recursiveStructTypeUsesCanonicalExplicitSpelling() {
        assertDoesNotThrow(() -> TypeChecker.check(Parser.parse("""
                type Node = struct{
                  value: int,
                  next: Option<Node>
                };

                fnc accept(Node node): void {
                  return;
                }
                """)));
    }

    @Test
    void unguardedAliasAndNonRegularRecursionStillFail() {
        assertThrows(IllegalArgumentException.class, () ->
                TypeChecker.check(Parser.parse("type A = B; type B = A;")));
        assertThrows(IllegalArgumentException.class, () ->
                TypeChecker.check(Parser.parse("type A = A | int;")));
        assertThrows(IllegalArgumentException.class, () ->
                TypeChecker.check(Parser.parse("type Grow<T> = Option<Grow<List<T>>>;")));
    }

    @Test
    void cyclicClassTypeCannotBeMistakenForSendableActorMessage() {
        assertThrows(IllegalArgumentException.class, () ->
                TypeChecker.check(Parser.parse("""
                        type Node = Option<Node>;
                        actor fnc send(Node value): void {
                          return;
                        }
                        """)));
    }

    @Test
    void displayHandlesLocalCyclesAndSharedSubtreesWithoutStackOverflow() throws Exception {
        Class<?> objectType =
                Class.forName("dev.oreslang.nodes.OresEvalRootNode$OresObject");
        Constructor<?> ctor = objectType.getDeclaredConstructors()[0];
        ctor.setAccessible(true);

        Ast.ClassDecl decl = (Ast.ClassDecl) Parser.parse("""
                define class Node as
                end
                """).modules().getFirst().declarations().getFirst();

        Map<String, Object> fields = new LinkedHashMap<>();
        Object node = ctor.newInstance(null, decl, fields);
        fields.put("self", node);
        fields.put("value", 1L);

        String printed = String.valueOf(node);
        assertTrue(printed.contains("<circular>"), printed);
        assertTrue(printed.contains("Node"), printed);

        Class<?> renderer =
                Class.forName("dev.oreslang.nodes.OresEvalRootNode$GraphDisplay");
        Method format = renderer.getDeclaredMethod("format", Object.class);
        format.setAccessible(true);
        List<Object> cyclic = new ArrayList<>();
        cyclic.add(cyclic);
        assertTrue(((String) format.invoke(null, cyclic)).contains("<circular>"));

        List<Object> shared = new ArrayList<>();
        shared.add("x");
        List<Object> acyclicAlias = List.of(shared, shared);
        assertEquals("[[x], [x]]", format.invoke(null, acyclicAlias));
    }

    @Test
    void mutableCyclesStayLocalAndCannotCrossActorOrSharedMutexBoundary() throws Exception {
        List<Object> cycle = new ArrayList<>();
        cycle.add(cycle);
        assertThrows(IllegalArgumentException.class, () -> ActorRuntime.freeze(cycle));

        Class<?> mutexFactory =
                Class.forName("dev.oreslang.nodes.OresEvalRootNode$MutexFactory");
        Method safe = mutexFactory.getDeclaredMethod(
                "runtimeSharedSafe", Object.class, Set.class);
        safe.setAccessible(true);
        Set<Object> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        assertEquals(false, safe.invoke(null, cycle, seen));

        // Reusing an acyclic subtree is aliasing, not a cycle.
        List<Object> shared = new ArrayList<>();
        shared.add("ok");
        List<Object> dag = List.of(shared, shared);
        assertEquals(true, safe.invoke(null, dag,
                Collections.newSetFromMap(new IdentityHashMap<>())));
        assertDoesNotThrow(() -> ActorRuntime.freeze(dag));
    }
}
