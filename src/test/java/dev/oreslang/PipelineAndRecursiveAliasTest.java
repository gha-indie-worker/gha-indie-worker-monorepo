package dev.oreslang;

import dev.oreslang.parser.Lexer;
import dev.oreslang.parser.Parser;
import dev.oreslang.parser.Token;
import dev.oreslang.types.TypeChecker;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.Source;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.*;

final class PipelineAndRecursiveAliasTest {
    @Test
    void pipelineHasDedicatedTokenAndRetainsBitwiseOrAndLambdaSyntax() {
        var tokens = new Lexer("x |> twice | mask; val cb = |int x| -> x;").scan();
        assertTrue(tokens.stream().anyMatch(token -> token.type() == Token.Type.PIPE_FORWARD));
        assertEquals(3, tokens.stream().filter(token -> token.type() == Token.Type.PIPE).count());
    }

    @Test
    void pipelineLowersToOrdinaryCallsAndRunsLeftToRight() throws Exception {
        String program = """
                fnc increment(int value): int {
                  return value + 1;
                }

                fnc multiply(int value, int factor): int {
                  return value * factor;
                }

                define module Math as
                  pub fnc twice(int value): int {
                    return value * 2;
                  }
                end

                pub fnc main(): void {
                  val Fnc<int(int)> square = |int value| -> value * value;
                  stdio.println(1 |> increment |> multiply(3));
                  stdio.println((2 + 3) |> Math.twice);
                  stdio.println(4 |> square);
                  return;
                }
                """;
        assertDoesNotThrow(() -> TypeChecker.check(Parser.parse(program)));
        assertEquals("6\n10\n16\n", run(program));
    }

    @Test
    void guardedRecursiveDataAliasesResolveWithFiniteCompilerTypes() {
        assertDoesNotThrow(() -> TypeChecker.check(Parser.parse("""
                type Node<T> = Option<[T, Node<T>]>;
                type IntNode = Node<int>;
                type A = Option<B>;
                type B = Result<int, A>;
                fnc depth(IntNode root): int {
                  return 0;
                }
                fnc use(A a): B {
                  return Ok(1);
                }
                """)));
    }

    @Test
    void transparentAndNonRegularAliasCyclesFailWithoutStackOverflow() {
        for (String bad : new String[] {
                "type Bad = Bad;",
                "type A = B; type B = A;",
                "type Bad = int | Bad;",
                "type Grow<T> = Option<Grow<List<T>>>;"
        }) {
            assertThrows(IllegalArgumentException.class,
                    () -> TypeChecker.check(Parser.parse(bad)), bad);
        }
    }

    @Test
    void modulesAndClassesCannotBeUsedAsRuntimeValues() {
        assertThrows(IllegalArgumentException.class, () -> TypeChecker.check(Parser.parse("""
                define module Maths as
                  pub fnc twice(int x): int { return x * 2; }
                end
                fnc bad(): void {
                  val m = Maths;
                  return;
                }
                """)));
        assertThrows(IllegalArgumentException.class, () -> TypeChecker.check(Parser.parse("""
                define class Helper as
                  pub static fnc twice(int x): int { return x * 2; }
                end
                fnc bad(): void {
                  val c = Helper;
                  return;
                }
                """)));
    }

    private static String run(String program) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Source source = Source.newBuilder(OresLanguage.ID, program, "pipeline-alias.ores")
                .mimeType(OresLanguage.MIME_TYPE)
                .build();
        try (Context context = Context.newBuilder(OresLanguage.ID)
                .allowAllAccess(false)
                .out(output)
                .build()) {
            context.eval(source);
        }
        return output.toString(StandardCharsets.UTF_8);
    }
}
