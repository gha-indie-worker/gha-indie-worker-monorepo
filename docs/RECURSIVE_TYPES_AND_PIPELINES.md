# Pipelines, recursive aliases, and static namespaces

## Pipelines

The value-first operator is `|>`. It is left associative and is parsed
between logical-or and the conditional (`?:`) expression.

```oreslang
fnc increment(int value): int {
  return value + 1;
}

fnc scale(int value, int factor): int {
  return value * factor;
}

val int result = 2 |> increment |> scale(10);
```

The compiler lowers this to `scale(increment(2), 10)` before static
analysis. The left side is evaluated once; right-hand side must be a
callable reference, member reference, lambda, or a call expression.
`value |> f(extra)` prepends `value` to the arguments of `f`. Use
parentheses for intentionally mixed operator precedence. Neither bitwise
`|` nor lambda delimiters `|x|` change. Bindings and expression
statements still require their normal terminating semicolon.

## Recursive types

Recursive aliases are permitted only when every cycle crosses a
concrete storage/indirection type: `Option`, `Result`, array/list,
finite tuple, record, borrow, callable, or a known nominal data type.

```oreslang
type Node<T> = Option<[T, Node<T>]>;
type IntNode = Node<int>;

type First = Option<Second>;
type Second = Result<int, First>;
```

The resolver terminates guarded cycles using a compiler-internal
nominal recursion reference. It rejects transparent cycles and
non-regular recursion that changes generic arguments:

```oreslang
type Broken = Broken;                       // error
type Left = Right; type Right = Left;        // error
type BrokenUnion = int | BrokenUnion;        // error
type Growing<T> = Option<Growing<List<T>>>;  // error
```

These are static type-graph rules. They do not themselves add ADT
constructors, automatic cyclic allocation, cycle-aware serialization,
actor sendability, or exhaustive constructor-pattern proofs.
The current checker conservatively refuses unverified cross-actor
transport where a recursive marker cannot be proven data-only.

## Module/class declarations are not values

Modules and classes are compile-time declarations. Use them as qualified
names, not as objects to pass, store, or return.

```oreslang
define module Math as
  pub fnc double(int value): int {
    return value * 2;
  }
end

val int result = 8 |> Math.double;  // valid: static member invocation
val Fnc<int(int)> fn = Math.double;  // valid: static function value
val m = Math;                       // invalid: module declaration as value
```

Likewise a class declaration can be named in a `new` expression or
accessed for static members, but cannot be stored as a runtime value.
A `Module<T>` runtime handle or first-class module/functor feature is
**not** implied by module contracts. Existing contracts remain separate
compile-time conformance checks.

## Future hardening

1. Recursive alias instantiation caching and generics substitution across
   mutually recursive alias families.
2. Nominal tagged algebraic constructors, nested pattern matching, and
   complete exhaustiveness/unreachable-arm analysis.
3. Cycle-aware tracing, ownership, deep-copy/serialization, and explicit
   opt-in to actor transport for recursive data.
4. Cross-file imported static namespace identity and compiler-enforced
   restrictions at every AOT/linked-program boundary.
