package dev.oreslang;

import dev.oreslang.parser.Parser;
import dev.oreslang.types.TypeChecker;
import org.graalvm.polyglot.Context;
import org.graalvm.polyglot.Source;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.*;

final class StaticClassContractTest {

    @Test
    void staticContractRequiresTheClassNamespaceShape() {
        assertDoesNotThrow(() -> TypeChecker.check(Parser.parse("""
                define static contract Factory as
                  String version;
                  fnc create(int id) => int;
                end

                define class Widget implements static Factory as
                  pub static const String version = "1";

                  pub static fnc create(int id): int {
                    return id;
                  }
                end
                """)));
    }

    @Test
    void instanceMembersCannotSatisfyAStaticContract() {
        IllegalArgumentException failure = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define static contract Factory as
                          String version;
                          fnc create(int id) => int;
                        end

                        define class Widget implements static Factory as
                          pub const String version = "1";

                          pub create(int id): int {
                            return id;
                          }
                        end
                        """)));

        assertTrue(failure.getMessage().contains("static contract"));
    }

    @Test
    void staticMembersCannotSatisfyAnInstanceInterface() {
        IllegalArgumentException failure = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define interface Factory as
                          fnc create(int id) => int;
                        end

                        define class Widget implements Factory as
                          pub static fnc create(int id): int {
                            return id;
                          }
                        end
                        """)));

        assertTrue(failure.getMessage().contains("does not implement interface"));
    }

    @Test
    void wrongSideContractSyntaxGetsTargetedDiagnostics() {
        IllegalArgumentException missingStatic = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define static contract Factory as
                          fnc create(): int;
                        end

                        define class Widget implements Factory as
                          pub static fnc create(): int { return 1; }
                        end
                        """)));
        assertTrue(missingStatic.getMessage().contains("implements static Factory"));

        IllegalArgumentException moduleUsesStatic = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define static contract Factory as
                          fnc create(): int;
                        end

                        define module widgets conforms Factory as
                          pub fnc create(): int { return 1; }
                        end
                        """)));
        assertTrue(moduleUsesStatic.getMessage().contains("cannot be used by a module"));

        IllegalArgumentException classUsesModuleContract = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define contract Factory as
                          fnc create(): int;
                        end

                        define class Widget implements static Factory as
                          pub static fnc create(): int { return 1; }
                        end
                        """)));
        assertTrue(classUsesModuleContract.getMessage().contains("module contract"));
    }

    @Test
    void staticContractInheritanceStaysOnTheStaticSide() {
        assertDoesNotThrow(() -> TypeChecker.check(Parser.parse("""
                define static contract Named as
                  String name;
                end

                define static contract Factory extends Named as
                  fnc create(): int;
                end

                define class Widget implements static Factory as
                  pub static const String name = "widget";
                  pub static fnc create(): int { return 1; }
                end
                """)));

        IllegalArgumentException crossCategory = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define contract ModuleApi as
                          fnc ping(): void;
                        end

                        define static contract Bad extends ModuleApi as
                          fnc create(): int;
                        end
                        """)));
        assertTrue(crossCategory.getMessage().contains("declaration categories"));
    }

    @Test
    void unqualifiedFieldMeansReadableButExplicitBindingKindIsExact() {
        assertDoesNotThrow(() -> TypeChecker.check(Parser.parse("""
                define static contract ReadableName as
                  name: String;
                end

                define class A implements static ReadableName as
                  pub static const name: String = "a";
                end

                define class B implements static ReadableName as
                  pub static let name: String = "b";
                end
                """)));

        IllegalArgumentException exactKind = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define static contract MutableName as
                          let name: String;
                        end

                        define class Bad implements static MutableName as
                          pub static const name: String = "fixed";
                        end
                        """)));
        assertTrue(exactKind.getMessage().contains("binding kind"));
    }

    @Test
    void staticFieldsAreRuntimeClassStateAndNotConstructorSlots() throws Exception {
        String output = run("""
                define static contract CounterShape as
                  let count: int;
                  fnc bump(): int;
                end

                define class Counter implements static CounterShape as
                  pub static let count: int = 5;
                  val int value;

                  pub get(): int {
                    return self.value;
                  }

                  pub static fnc bump(): int {
                    Counter.count = Counter.count + 1;
                    return Counter.count;
                  }
                end

                pub routine main(): void {
                  val counter = new Counter(42);
                  stdio.stdout.write(counter.get());
                  stdio.stdout.write("|");
                  stdio.stdout.write(Counter.count);
                  stdio.stdout.write("|");
                  stdio.stdout.write(Counter.bump());
                  stdio.stdout.write("|");
                  stdio.stdout.write(Counter.count);
                  return;
                }
                """);

        assertEquals("42|5|6|6", output);
    }

    @Test
    void immutableStaticFieldsRejectAssignment() {
        IllegalArgumentException failure = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define class Config as
                          pub static const name: String = "fixed";
                        end

                        routine mutate(): void {
                          Config.name = "changed";
                          return;
                        }
                        """)));

        assertTrue(failure.getMessage().contains("immutable"));
    }

    @Test
    void staticFieldsCannotDependOnClassTypeParameters() {
        IllegalArgumentException failure = assertThrows(
                IllegalArgumentException.class,
                () -> TypeChecker.check(Parser.parse("""
                        define class Box<T> as
                          pub static val value: T;
                        end
                        """)));

        assertTrue(failure.getMessage().contains("T")
                || failure.getMessage().contains("unknown type"));
    }

    private static String run(String program) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Source source = Source.newBuilder(
                        OresLanguage.ID,
                        program,
                        "static-class-contracts.ores")
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
