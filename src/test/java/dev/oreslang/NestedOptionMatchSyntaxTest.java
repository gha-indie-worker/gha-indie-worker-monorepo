package dev.oreslang;

import dev.oreslang.parser.Parser;
import dev.oreslang.types.TypeChecker;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.Source;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.*;

final class NestedOptionMatchSyntaxTest {

    private static void accepts(String program) {
        assertDoesNotThrow(() -> TypeChecker.check(Parser.parse(program)));
    }

    private static IllegalArgumentException rejects(String program) {
        return assertThrows(IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse(program)));
    }

    @Test
    void threeStatesAreExhaustivelyMatchedInOverEndForm() {
        accepts("""
                fnc classify(Option<Option<int>> entry): int {
                  match entry over
                    Some(Some(value)) -> { return value; }
                    Some(None) -> { return -1; }
                    None -> { return -2; }
                  end
                }
                """);
    }

    @Test
    void bracedFormAndExplicitSymbolDefaultAreSupported() {
        accepts("""
                fnc classify(Option<Option<int>> entry): int {
                  match entry {
                    Some(Some(value)) -> { return value; }
                    Symbol.default -> { return -1; }
                  }
                }
                """);
        accepts("""
                fnc classify(Option<int> entry): int {
                  match entry over
                    Some(value) -> { return value; }
                    default -> { return 0; }
                  end
                }
                """);
        accepts("""
                fnc classify(Option<int> entry): int {
                  match entry {
                    Some(value) -> { return value; }
                    _ -> { return 0; }
                  }
                }
                """);
    }

    @Test
    void deeplyNestedConstructorCoverageIsNotInferredFromOuterSome() {
        IllegalArgumentException err = rejects("""
                fnc incomplete(Option<Option<int>> entry): int {
                  match entry over
                    Some(Some(value)) -> { return value; }
                    None -> { return 0; }
                  end
                }
                """);
        assertTrue(err.getMessage().contains("non-exhaustive"), err.getMessage());
    }

    @Test
    void overlappingNestedConstructorsAreRejected() {
        IllegalArgumentException err = rejects("""
                fnc overlap(Option<Option<int>> entry): int {
                  match entry over
                    Some(value) -> { return 1; }
                    Some(None) -> { return 2; }
                    None -> { return 3; }
                  end
                }
                """);
        assertTrue(err.getMessage().contains("overlapping match arms")
                || err.getMessage().contains("unreachable"), err.getMessage());
    }

    @Test
    void unmatchedWildcardFunctionLiteralIsNotAPattern() {
        IllegalArgumentException err = rejects("""
                fnc invalid(Option<int> entry): int {
                  match entry over
                    Some(value) -> { return value; }
                    None -> { return 0; }
                    || -> { return 1; }
                  end
                }
                """);
        assertTrue(err.getMessage().contains("pattern"), err.getMessage());
    }

    @Test
    void fallbacksAfterCompleteSomeNoneCoverageAreUnreachable() {
        for (String fallback : new String[]{"_", "Symbol.default", "default", "else"}) {
            IllegalArgumentException err = rejects("""
                    fnc invalid(Option<int> entry): int {
                      match entry over
                        Some(value) -> { return value; }
                        None -> { return 0; }
                    """ + "    " + fallback + " -> { return 1; }\n" + """
                      end
                    }
                    """);
            assertTrue(err.getMessage().contains("unreachable"), err.getMessage());
        }
    }

    @Test
    void nestedResultAlsoRequiresEveryVariant() {
        accepts("""
                fnc classify(Result<Option<int>, bool> entry): int {
                  match entry over
                    Ok(Some(value)) -> { return value; }
                    Ok(None) -> { return 0; }
                    Err(flag) -> { return -1; }
                  end
                }
                """);
        assertTrue(rejects("""
                fnc incomplete(Result<Option<int>, bool> entry): int {
                  match entry over
                    Ok(Some(value)) -> { return value; }
                    Err(flag) -> { return 0; }
                  end
                }
                """).getMessage().contains("non-exhaustive"));
    }

    @Test
    void runtimeDispatchesAllThreeStates() throws Exception {
        String code = """
                fnc classify(Option<Option<int>> entry): int {
                  match entry over
                    Some(Some(value)) -> { return value; }
                    Some(None) -> { return -1; }
                    None -> { return -2; }
                  end
                }

                pub fnc main(): void {
                  stdio.println(classify(Some(Some(42))));
                  stdio.println(classify(Some(None)));
                  stdio.println(classify(None));
                  return;
                }
                """;

        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Source src = Source.newBuilder(OresLanguage.ID, code, "nested-match.ores")
                .mimeType(OresLanguage.MIME_TYPE).build();
        try (Context context = Context.newBuilder(OresLanguage.ID)
                .allowAllAccess(false).out(output).build()) {
            context.eval(src);
        }
        String text = output.toString(StandardCharsets.UTF_8);
        assertTrue(text.contains("42"), text);
        assertTrue(text.contains("-1"), text);
        assertTrue(text.contains("-2"), text);
    }
}
