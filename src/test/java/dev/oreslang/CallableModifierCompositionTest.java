package dev.oreslang;

import dev.oreslang.OresLanguage;
import dev.oreslang.ast.Ast;
import dev.oreslang.compiler.OresCompiler;
import dev.oreslang.parser.Parser;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.Source;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

final class CallableModifierCompositionTest {

    @Test
    void namedEffectModifiersComposeAroundFncInEverySupportedCombinationAndOrder() {
        List<List<String>> effectSets = List.of(
                List.of("pure"),
                List.of("trap"),
                List.of("nlex"),
                List.of("pure", "trap"),
                List.of("pure", "nlex"),
                List.of("trap", "nlex"),
                List.of("pure", "trap", "nlex"));

        int cases = 0;
        for (List<String> effects : effectSets) {
            List<String> tokens = new ArrayList<>(effects);
            tokens.add("fnc");
            for (List<String> order : permutations(tokens.toArray(String[]::new))) {
                cases++;
                String spelling = String.join(" ", order);
                Ast.Program program = Parser.parse("""
                        %s guarded(int value): int {
                          return value + 1;
                        }
                        """.formatted(spelling));

                Ast.FunctionDecl fn =
                        (Ast.FunctionDecl) program.modules().getFirst().declarations().getFirst();
                assertEquals(effects.contains("pure"), fn.pure(), spelling);
                assertEquals(effects.contains("trap"), fn.trapped(), spelling);
                assertEquals(effects.contains("nlex"), fn.nonLexical(), spelling);

                assertDoesNotThrow(() -> OresCompiler.analyze(program), spelling);
            }
        }

        assertEquals(48, cases);
    }

    @Test
    void namedRoutineEffectsUseTheSameModifierAndTrapRules() {
        for (List<String> order : permutations("pure", "trap", "nlex", "routine")) {
            String spelling = String.join(" ", order);
            Ast.Program program = Parser.parse("""
                    %s guarded(int value): int {
                      return value + 1;
                    }
                    """.formatted(spelling));

            Ast.FunctionDecl routine =
                    (Ast.FunctionDecl) program.modules().getFirst().declarations().getFirst();
            assertEquals(Ast.CallableKind.ROUTINE, routine.kind(), spelling);
            assertTrue(routine.pure(), spelling);
            assertTrue(routine.trapped(), spelling);
            assertTrue(routine.nonLexical(), spelling);
            assertDoesNotThrow(() -> OresCompiler.analyze(program), spelling);
        }

        assertDoesNotThrow(() -> OresCompiler.parseAndTypeCheck("""
                trap routine guarded(): int {
                  return 7;
                }

                fnc use(): void {
                  val Option<int> result = guarded();
                  return;
                }
                """));
    }

    @Test
    void memberCallablesFailClosedInsteadOfDiscardingEffectModifiers() {
        for (String modifier : List.of("pure", "trap", "nlex")) {
            assertThrows(IllegalArgumentException.class, () -> Parser.parse("""
                    define class Box as
                      %s get(): int {
                        return 1;
                      }
                    end
                    """.formatted(modifier)));

            assertThrows(IllegalArgumentException.class, () -> Parser.parse("""
                    define class Box as
                      %s static fnc get(): int {
                        return 1;
                      }
                    end
                    """.formatted(modifier)));

            assertThrows(IllegalArgumentException.class, () -> Parser.parse("""
                    actor Worker {
                      %s get(): int {
                        return 1;
                      }
                    }
                    """.formatted(modifier)));
        }
    }

    @Test
    void rhsPureTrapNlexModifiersComposeInEveryOrder() {
        for (List<String> order : permutations("pure", "trap", "nlex")) {
            String modifiers = String.join(" ", order);
            Ast.Program program = Parser.parse("""
                    fnc make(): void {
                      const Fnc<int, Option<int>> guarded = %s |int value| -> int {
                        return value + 1;
                      };
                      val Option<int> answer = guarded(41);
                      return;
                    }
                    """.formatted(modifiers));

            Ast.FunctionDecl fn =
                    (Ast.FunctionDecl) program.modules().getFirst().declarations().getFirst();
            Ast.LambdaExpr lambda =
                    (Ast.LambdaExpr) ((Ast.BindingStmt) fn.body().getFirst()).initializer();
            assertTrue(lambda.pure(), modifiers);
            assertTrue(lambda.trapped(), modifiers);
            assertTrue(lambda.nonLexical(), modifiers);

            assertDoesNotThrow(() -> OresCompiler.analyze(program), modifiers);
        }
    }

    @Test
    void functionExpressionEffectsBelongToTheValueNotItsBindingKind() {
        assertDoesNotThrow(() -> OresCompiler.parseAndTypeCheck("""
                fnc use(): void {
                  const c = pure || -> int { return 1; };
                  val v = trap || -> int { return 2; };
                  let n = nlex || -> int { return 3; };

                  val int a = c();
                  val Option<int> b = v();
                  val int d = n();
                  return;
                }
                """));
    }

    @Test
    void trapAlwaysAddsExactlyOneOptionLayerForNamedCallables() {
        assertDoesNotThrow(() -> OresCompiler.parseAndTypeCheck("""
                trap fnc scalar(): int {
                  return 7;
                }

                trap fnc nested(bool present): Option<int> {
                  if present; then
                    return Some(9);
                  fi
                  return None;
                }

                trap fnc done(): void {
                  return;
                }

                fnc use(): void {
                  val Option<int> one = scalar();
                  val Option<Option<int>> two = nested(true);
                  val Option<void> three = done();
                  return;
                }
                """));

        assertThrows(IllegalArgumentException.class, () -> OresCompiler.parseAndTypeCheck("""
                trap fnc scalar(): int {
                  return 7;
                }

                fnc bad(): void {
                  val int unwrapped = scalar();
                  return;
                }
                """));

        assertThrows(IllegalArgumentException.class, () -> OresCompiler.parseAndTypeCheck("""
                trap fnc nested(): Option<int> {
                  return Some(9);
                }

                fnc bad(): void {
                  val Option<int> flattened = nested();
                  return;
                }
                """));
    }

    @Test
    void trapAlwaysAddsExactlyOneOptionLayerForFunctionExpressions() {
        assertDoesNotThrow(() -> OresCompiler.parseAndTypeCheck("""
                fnc use(): void {
                  const Fnc<Option<int>> scalar = trap || -> int {
                    return 7;
                  };

                  const Fnc<Option<Option<int>>> nested = trap || -> Option<int> {
                    return Some(9);
                  };

                  const Fnc<Option<void>> done = trap || -> void {
                    return;
                  };

                  val Option<int> one = scalar();
                  val Option<Option<int>> two = nested();
                  val Option<void> three = done();
                  return;
                }
                """));

        assertThrows(IllegalArgumentException.class, () -> OresCompiler.parseAndTypeCheck("""
                fnc bad(): void {
                  const Fnc<int> unwrapped = trap || -> int {
                    return 9;
                  };
                  return;
                }
                """));

        assertThrows(IllegalArgumentException.class, () -> OresCompiler.parseAndTypeCheck("""
                fnc bad(): void {
                  const Fnc<Option<int>> flattened = trap || -> Option<int> {
                    return Some(9);
                  };
                  return;
                }
                """));
    }

    @Test
    void duplicateEffectModifiersFailOnDeclarationsAndExpressions() {
        for (String duplicate : List.of("pure", "trap", "nlex")) {
            assertThrows(IllegalArgumentException.class, () -> Parser.parse("""
                    %s fnc bad(): int {
                      return 1;
                    }
                    """.formatted(duplicate + " " + duplicate)));

            assertThrows(IllegalArgumentException.class, () -> Parser.parse("""
                    fnc bad(): void {
                      const f = %s || -> int {
                        return 1;
                      };
                      return;
                    }
                    """.formatted(duplicate + " " + duplicate)));
        }
    }

    @Test
    void pureAndNlexRemainOrthogonalWhenCombinedWithTrap() {
        assertDoesNotThrow(() -> OresCompiler.parseAndTypeCheck("""
                pure trap fnc lexical(int value): int {
                  return value + 1;
                }

                nlex pure trap fnc isolated(int value): int {
                  return value + 2;
                }

                fnc use(): void {
                  val Option<int> a = lexical(1);
                  val Option<int> b = isolated(1);
                  return;
                }
                """));

        assertThrows(IllegalArgumentException.class, () -> OresCompiler.parseAndTypeCheck("""
                fnc outer(): void {
                  let outside = 1;
                  const bad = pure trap || -> int {
                    outside = 2;
                    return outside;
                  };
                  return;
                }
                """));

        assertThrows(IllegalArgumentException.class, () -> OresCompiler.parseAndTypeCheck("""
                fnc outer(): void {
                  const outside = 1;
                  const bad = nlex pure trap || -> int {
                    return outside;
                  };
                  return;
                }
                """));
    }

    @Test
    void trappedFunctionExpressionRuntimeUsesSomeAndNone() throws Exception {
        String program = """
                pub fnc main(): void {
                  const Fnc<Option<int>> good = pure trap nlex || -> int {
                    return 7;
                  };
                  const Fnc<Option<int>> bad = pure trap nlex || -> int {
                    return [1][4];
                  };

                  stdio.stdout.write(good().unwrap());
                  stdio.stdout.write(":");
                  stdio.stdout.write(bad().is_none());
                  return;
                }
                """;

        assertDoesNotThrow(() -> OresCompiler.parseAndTypeCheck(program));
        assertEquals("7:true", run(program));
    }

    private static List<List<String>> permutations(String... values) {
        List<List<String>> out = new ArrayList<>();
        permute(new ArrayList<>(List.of(values)), new ArrayList<>(), out);
        return out;
    }

    private static void permute(
            List<String> remaining,
            List<String> prefix,
            List<List<String>> out) {
        if (remaining.isEmpty()) {
            out.add(List.copyOf(prefix));
            return;
        }
        for (int i = 0; i < remaining.size(); i++) {
            List<String> rest = new ArrayList<>(remaining);
            String value = rest.remove(i);
            List<String> next = new ArrayList<>(prefix);
            next.add(value);
            permute(rest, next, out);
        }
    }

    private static String run(String program) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Source source = Source.newBuilder(OresLanguage.ID, program, "callable-modifiers.ores")
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
