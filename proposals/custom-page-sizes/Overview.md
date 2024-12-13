# Custom Page Sizes

This proposal allows customizing a memory's page size in its static type
definition.

## Motivation

1. Allow Wasm to better target resource-constrained **embedded environments**,
   including those with less than 64 KiB memory available.

2. Allow Wasm to have **finer-grained control** over its resource consumption,
   e.g. if a Wasm module only requires a small amount of additional working
   memory, it doesn't need to reserve a full 64 KiB. Consider, for example,
   compiling automata and other state machines down into Wasm modules: there
   will be some state tables in memory, but depending on the size and complexity
   of the state machine in question these tables can be quite small and may not
   need a full 64 KiB.

## Proposal

Memory types currently have the following structure:

```ebnf
memtype ::= limits
```

where `limits` is defined in terms of pages, which are always 64 KiB.[^memory64]

[^memory64]: The `memory64` proposal adds an index type to the memory type, and
parameterizes the limits on the index type, but the limits are still defined in
terms of 64 KiB pages. Similarly, the `threads` proposal adds the concept of
shared and unshared memories and stores that information in the `memtype`, but
the memory size is unaffected.

This proposal extends the memory type structure[^structure] with a page size:

```ebnf
memtype ::= limits mempagesize
mempagesize ::= u32
```

[^structure]: Note that this code snipppet is defining *structure* and not
*binary encoding*, which is why the `mempagesize` is always present. Even though
the `mempagesize` would be optional in the *binary encoding*, it would have a
default value of 2<sup>16</sup> if omitted (for backwards compatibility) and is
therefore always present in the *structure*.

There are currently exactly two valid page sizes: 1 byte and 64 KiB. The
encoding and spec are factored such that we can relax this to allow any power of
two between `1` and `65536` (inclusive) in the future, should we choose to do
so.

The memory type's limits are still be defined in terms of pages, however the
final memory's size in bytes is now determined both by the limits and the
configured page size. For example, given a memory type defined with a page size
of `1`, a minimum limit of `4096`, and a maximum limit of `8192`, memory
instances of that type would have a minimum byte size of `4096`, a maximum byte
size of `8192`, and their byte size at any given moment could be any multiple of
the page size (`1`) within those min/max bounds.

[Memory type matching] requires that both memory types define the exact same
page size. We do not define a subtyping relationship between page sizes.

[Memory type matching]: https://webassembly.github.io/spec/core/valid/types.html#memories

The `memory.grow` and `memory.size` instructions continue to give results in
page counts, and can generally remain unmodified.

Customizing a memory's page size does not affect its index type; it has the same
`i32` or `i64`[^i64-index] index it would otherwise have.

[^i64-index]: If the `memory64` proposal is enabled and this memory is a 64-bit
memory.

Finally, extending memory types with a page size has the following desirable
properties:

1. **It is minimally invasive.** This proposal doesn't require any new
   instructions (e.g. a `memory.page_size <memidx> : [] -> [u32]` instruction,
   which would be required if page sizes were not static knowledge, see point 3)
   and only imposes small adjustments to existing instructions. For example, the
   `memory.size` instruction, as mentioned previously, is almost unchanged: its
   result is still defined in terms of numbers of pages, its just that engines
   divide the memory's byte capacity by its defined page size rather than the
   constant 64 Ki.

2. **Page size customization applies to a particular memory.** A module is free
   to, for example, define multiple memories with multiple different page
   sizes. Opting into small page sizes for one memory does not affect any other
   memories in the store.

3. **Page sizes are always known statically.** Every memory instruction has a
   static `<memidx>` immediate, so we statically know the memory it is operating
   upon as well as that memory's type, which means we additionally have static
   knowledge of the memory's page size. This enables constant-propagation and
   -folding optimizations in Wasm producers and engines with ahead-of-time
   compilers.

### Example

Here is a short example:

```wat
(module
  ;; Import a memory with a page size of 1 byte and a minimum size of
  ;; 1024 pages, aka 1024 bytes. No maximum is specified.
  (import "env" "memory" (memory $imported 1024 (pagesize 1)))

  ;; Define a memory with a page size of 64KiB; a minimum size of 2 pages,
  ;; aka 131072 bytes; and a maximum size of 4 pages, aka 262144 bytes.
  (memory $defined 2 4 (pagesize 65536))

  ;; Export a function to get the imported memory's size, in bytes.
  (func (export "get_imported_memory_size_in_bytes") (result i32)
    ;; Get the current size of the imported memory in units of pages.
    memory.size $imported
    ;; In this case, we statically know that the page size is one byte, so we
    ;; can avoid multiplying the size-in-pages by bytes-per-page to get the
    ;; size-in-bytes. This code could also be cleaned up by either the Wasm-
    ;; producing toolchain or the Wasm-consuming engine, if necessary.
    ;;
    ;; i32.const 1
    ;; i32.mul
  )

  ;; And export a similar function for the defined memory. In this case we can
  ;; avoid the multiplication by page size, since we statically know the page
  ;; size is 1.
  (func (export "get_defined_memory_size_in_bytes") (result i32)
    ;; Get the current size of the defined memory in units of pages.
    memory.size $defined
    ;; In this case, since we are using the default page size of 64KiB, we have
    ;; to multiple the size-in-bytes by the bytes-per-page to get the memory's
    ;; byte size.
    i32.const 65536
    i32.mul
  )
)
```

### Spec Changes

#### Structure

The `memtype` structure gains a `mempagesize` field, which is a `u32` denoting
the memory's page size:

```ebnf
memtype ::= idxtype limits share mempagesize
idxtype ::= i32 | i64
share ::= shared | unshared
mempagesize ::= u32
```

#### Binary Encoding

The [`limits`][limits-binary] production is extended such that it returns a
4-tuple -- rather than the 3-tuple it would otherwise return under the threads
and memory64 proposals -- where the fourth value is the page size:

```ebnf
limits ::= 0x00 n:u32              ⇒ i32, {min n, max ϵ}, unshared, 65536
        |  0x01 n:u32 m:u32        ⇒ i32, {min n, max m}, unshared, 65536
        |  0x02 n:u32              ⇒ i32, {min n, max ϵ},   shared, 65536
        |  0x03 n:u32 m:u32        ⇒ i32, {min n, max m},   shared, 65536
        |  0x04 n:u64              ⇒ i64, {min n, max ϵ}, unshared, 65536
        |  0x05 n:u64 m:u64        ⇒ i64, {min n, max m}, unshared, 65536
        |  0x06 n:u64              ⇒ i64, {min n, max ϵ},   shared, 65536
        |  0x07 n:u64 m:u64        ⇒ i64, {min n, max m},   shared, 65536
        |  0x08 n:u32       p:u32  ⇒ i32, {min n, max ϵ}, unshared, 2**p  if p <= 16
        |  0x09 n:u32 m:u32 p:u32  ⇒ i32, {min n, max m}, unshared, 2**p  if p <= 16
        |  0x0a n:u32       p:u32  ⇒ i32, {min n, max ϵ},   shared, 2**p  if p <= 16
        |  0x0b n:u32 m:u32 p:u32  ⇒ i32, {min n, max m},   shared, 2**p  if p <= 16
        |  0x0c n:u64       p:u32  ⇒ i64, {min n, max ϵ}, unshared, 2**p  if p <= 16
        |  0x0d n:u64 m:u64 p:u32  ⇒ i64, {min n, max m}, unshared, 2**p  if p <= 16
        |  0x0e n:u64       p:u32  ⇒ i64, {min n, max ϵ},   shared, 2**p  if p <= 16
        |  0x0f n:u64 m:u64 p:u32  ⇒ i64, {min n, max m},   shared, 2**p  if p <= 16
```

[limits-binary]: https://webassembly.github.io/spec/core/binary/types.html#limits

The bits of the `limits` production's discriminant can be summarized as follows:

* Bit `0`: Whether a maximum bound (`m`) for the limit follows.
* Bit `1`: Whether the memory is `shared` or `unshared`. This was introduced in
  the `threads` proposal.
* Bit `2`: Whether the memory's index type is `i32` or `i64`. This was
  introduced in the `memory64` proposal.
* Bit `3`: Whether the memory defines a custom page size (`p`) or not and
  therefore whether another `u32` follows after the limits. This is newly
  introduced in this proposal.

Finally, the [`memtype`][memtype-binary] production is extended to use the
parsed page size:

```ebnf
memtype ::= (it, lim, shared, pagesize):limits ⇒ it lim shared pagesize
```

[memtype-binary]: https://webassembly.github.io/spec/core/binary/types.html#binary-memtype

#### Text Format

There is a new `mempagesize` production:

```ebnf
mempagesize ::= '(' 'pagesize' u32 ')'
```

The [`memorytype`][memorytype-text] production is extended to allow an optional
`mempagesize`:[^text]

```ebnf
memtype ::= lim:limits                       ⇒ i32 lim unshared 65536
         |  lim:limits pagesize:mempagesize  ⇒ i32 lim unshared pagesize
```

[memorytype-text]: https://webassembly.github.io/spec/core/text/types.html#text-memtype

[^text]: Note that I've opted not to write out all of the combinations with the
`threads` and `memory64` proposals here.

The [memory abbreviation] is extended to allow an optional page size as well:

```ebnf
'(' 'memory' id? mempagesize? '(' 'data' b_n:datastring ')' ')' === ...
```

[memory abbreviation]: https://webassembly.github.io/spec/core/text/modules.html#text-mem-abbrev

#### Validation

* [Memory Types](https://webassembly.github.io/spec/core/valid/types.html#memory-types):

  * Prepend the following bullet points:

    * The `pagesize` must be the value `1` or the value `65536`.

  * Replace

    > The `limits` must be valid within the range `2**16`.

    with the following two bullet points:

    * The `limits` must be valid within the range `2**32` - 1.

    * The `limits` must be valid within the range `2**32 / pagesize`

#### Execution

##### Instructions

* [`memory.size`](https://webassembly.github.io/spec/core/exec/instructions.html#xref-syntax-instructions-syntax-instr-memory-mathsf-memory-size):

  * Replace step 6 with the following steps:

    * Let `pagesize` be `mem.type.pagesize`

    * Assert due to validation that `pagesize` is either the value `1` or the
      value `65536`.

    * Let `sz` be the length of `mem.data` divided by `pagesize`.

* [`memory.grow`](https://webassembly.github.io/spec/core/exec/instructions.html#xref-syntax-instructions-syntax-instr-memory-mathsf-memory-grow):

  * Replace step 6 with the following steps:

    * Let `pagesize` be `mem.type.pagesize`

    * Assert due to validation that `pagesize` is either the value `1` or the
      value `65536`.

    * Let `sz` be the length of `mem.data` divided by `pagesize`.

##### Modules

* [Growing memories](https://webassembly.github.io/spec/core/exec/modules.html#growing-memories):

  * Replace steps 2, 3, and 4 with the following steps:

    * Let `pagesize` be `meminst.type.pagesize`

    * Assert due to validation that `pagesize` is either the value `1` or the
      value `65536`.

    * Let `len` be `n` added to the length of `meminst.data` divided by `pagesize`.

    * If `len` is larger than or equal to `2**32`, then fail.

    * If `len` is larger than `2**32` divided by `pagesize`, then fail.

  * Replace step 8 with the following step:

    * Append `n` times `pagesize` bytes with the value `0x00` to `meminst.data`

#### Appendix

##### Soundness

* [Memory Instances](https://webassembly.github.io/spec/core/appendix/properties.html#memory-instances-xref-exec-runtime-syntax-meminst-mathsf-type-xref-syntax-types-syntax-limits-mathit-limits-xref-exec-runtime-syntax-meminst-mathsf-data-b-ast)

  * Replace `Memory Instances { type limits, data b* }` with `Memory Instances {
    type limits pagesize, data b* }`.

  * Replace

    > The length of `b*` must equal `limits.min` multiplied by the page size 64 Ki.

    with

    > The length of `b*` must equal `limits.min` multiplied by `pagesize`.

### Expected Toolchain Integration

Although toolchains are of course free to take any approach that best suits
their needs, we [imagine] that the ideal integration of custom page sizes into
toolchains would have the following shape:

* Source language frontends (e.g. `rustc` or `clang`) expose a constant
  variable, macro, or similar construct for source languages to get the Wasm
  page size.

* This expands to or is lowered to a call to a builtin function intrinsic:
  `__builtin_wasm_page_size()`.

* The backend (e.g. LLVM) lowers that builtin to an `i32.const` with a new
  relocation type.

* The linker (e.g. `lld`) fills in the constant based on the configured page
  size given in its command-line arguments.

This approach has the following benefits:

* By delaying the configuration of page size to link time, we ensure that we
  cannot get configured-page-size mismatches between objects being linked
  together (which would then require further design decisions surrounding how
  that scenario should be handled, e.g. whether it should result in a link
  error).

* It allows for source language toolchains to ship pre-compiled standard library
  objects such that these objects play nice with custom page sizes and do not
  either assume the wrong page size or constrain the final binary to a
  particular page size.

* It avoids imposing performance overhead or inhibiting compiler optimizations,
  to the best of our abilities.

  This approach doesn't, for example, access static data within the linear
  memory itself to get the page size (which could happen accidentally happen if
  the page size were a symbol rather than a relocated `i32.const`). Accessing
  memory would inhibit compiler optimizations (on both the producer and consumer
  side) since the compiler would have to prove that the memory contents remain
  constant.

  Link-time optimizations could, in theory, further propagate and fold uses of
  the relocated Wasm page size constant. At the very least, it doesn't prevent
  the engine consuming the Wasm from performing such optimizations.

[imagine]: https://github.com/WebAssembly/custom-page-sizes/issues/3

Alternatively, the linker could inject an immutable global defining the page
size and relocate uses of the `__builtin_wasm_page_size()` to `global.get
$injected_page_size_global` instead of `i32.const $page_size`. This is mostly
equivalent, and should not fundamentally have any more or less potential for
optimization by the Wasm consumer, but may allow [dynamic linking] to either
assert an expected page size (to double check against dynamic linking errors at
runtime) or even for a shared library module to be compatibly linked with
modules using any page size.

[dynamic linking]: https://github.com/WebAssembly/tool-conventions/blob/main/DynamicLinking.md

### How This Proposal Satisfies the Motivating Use Cases

1. Does this proposal help Wasm better target resource-constrained environments,
   including those with < 64 KiB RAM?

   **Yes!**

   Wasm can specify any specific maximum memory size to match its target
   environment's constraints. For example, if the target environment only has
   space for 16 KiB of Wasm memory, it can define a memory with a 1-byte page
   size and 16 Ki minimum and maximum page limits:

   ```wat
   (memory 16384 16384 (pagesize 1))
   ```

2. Does this proposal give finer-grained control over resource consumption?

   **Yes!**

   Wasm can take advantage of domain-specific knowledge and specify a page size
   such that memory size exactly fits its workload. Consider again, for example,
   compiling finite state machines down into Wasm modules: there will be some
   state tables that must be stored in memory and, depending on complexity of
   the state machine in question, these tables might be large or quite
   small. With a 1-byte page size, this proposal allows the memory to be sized
   to the exact capacity required for these state tables, without relying on the
   presence of virtual memory or an MMU to avoid paging in regions of unused
   memory.

## Implementation Status

*If you add support for this proposal to a toolchain, engine, or etc... that
isn't listed here, please send a pull request updating this list!*

Tests:

* [x] [Core spec tests](https://github.com/WebAssembly/custom-page-sizes/tree/main/test/core/custom-page-sizes)

Engines:

* [x] [toywasm](https://github.com/yamt/toywasm/pull/181)
* [x] [WABT's interpreter](https://github.com/WebAssembly/wabt/pull/2502)
* [x] [Wasmtime](https://github.com/bytecodealliance/wasmtime/pull/8763)
* [x] [Wasm3](https://github.com/tommie/wasm3/commit/3d2dfb75129802080e8ea6ffe5b8eded651bda68)

Toolchains:

* [ ] [Binaryen and `wasm-opt`](https://github.com/WebAssembly/binaryen/issues/6873)
* [ ] `wasm-ld` in LLVM
* [x] [The Virgil language toolchain](https://github.com/titzer/virgil/pull/272)

Binary decoders:

* [x] [`wasmparser` in `wasm-tools`](https://docs.rs/wasmparser/0.210.0/wasmparser/struct.MemoryType.html#structfield.page_size_log2)
* [x] [WABT's binary reader](https://github.com/WebAssembly/wabt/pull/2502)

Validation:

* [x] [`wasmparser` in `wasm-tools`](https://docs.rs/wasmparser/0.210.0/wasmparser/struct.WasmFeatures.html#associatedconstant.CUSTOM_PAGE_SIZES)
* [x] [WABT's validator](https://github.com/WebAssembly/wabt/pull/2502)

Binary encoders:

* [x] [`wasm-encoder` in `wasm-tools`](https://docs.rs/wasm-encoder/0.210.0/wasm_encoder/struct.MemoryType.html#structfield.page_size_log2)
* [x] [WABT's binary writer](https://github.com/WebAssembly/wabt/pull/2502)

Text parsers:

* [x] [`wat` and `wast` in `wasm-tools`](https://github.com/bytecodealliance/wasm-tools/blob/d6436035fefa4861e64b27d0c416cfe9f309369d/crates/wast/src/core/types.rs#L643)
* [x] [WABT's `.wat` parser](https://github.com/WebAssembly/wabt/pull/2502)

Fuzzing and test-case generation:

* [x] [`wasm-smith` in `wasm-tools`](https://docs.rs/wasm-smith/0.210.0/wasm_smith/struct.Config.html#structfield.custom_page_sizes_enabled)

## Alternative Approaches

This section discusses alternative approaches that were considered and why they
were discarded.

### Let the Engine Choose the Page Size

Instead of defining page sizes statically in the memory type, we could allow
engines to choose page sizes based on the environment they are running in. This
page size could be determined either at a whole-store or per-memory
granularity. Either way, this effectively makes the page size a dynamic
property, which necessitates a `memory.page_size <memidx>: [] -> [u32]`
instruction, so that `malloc` implementations can determine how much additional
memory they have available to parcel out to the application after they execute a
`memory.grow` instruction, for example. Additionally, existing Wasm binaries
assume a 64 KiB page size today; changing that out from under their feet will
result in breakage.

In contrast, by making the page size part of the static memory type, we avoid
the need for a new `memory.page_size` instruction (or similar) and we
additionally avoid breaking existing Wasm binaries, since new Wasm binaries must
opt into alternative page sizes.

### The "`asm.js`-Style" Approach

We could avoid changing Wasm core semantics and instead encourage a
gentleperson's agreement between Wasm engines and toolchains, possibly with the
help of a Wasm-to-Wasm rewriting tool. Toolchains would emit Wasm that
masks/wraps/bounds-checks every single memory access in such a way that the
engine can statically determine that all accesses fit within the desired memory
size of `N` that is less than 64 KiB. Engines could, therefore, avoid allocating
a full 64 KiB page while still fully conforming to standard Wasm semantics.

This approach, however inelegant, *does* address the narrow embedded use case of
smaller-than-64-KiB memories, but not the other two motivating use
cases. Furthermore, it inflates Wasm binary size, as every memory access needs
an extra sequence of instructions to ensure that the access is clamped to at
most address `N`. It additionally requires that the memory is not exported (and
therefore this approach isn't composable and doesn't support merging or
splitting applications across modules). Finally, it also requires full-program
static analysis on the part of the Wasm engine.

### Ignore These Use Cases

We could ignore these use cases; that is always an option (and is the default,
if we fail to do something to address them).

However, if we (the Wasm CG) do nothing, then the Wasm subcommunities with these
use cases (e.g. embedded) are incentivized to satisfy their needs by abandoning
standard Wasm semantics. Instead, they will implement ad-hoc, non-standard,
proprietary support for non-multiples-of-64-KiB memory sizes. This will lead to
non-interoperability, ecosystem splits, and &mdash; eventually &mdash; pressure
on standards-compliant engines and toolchains to support these non-standard
extensions.

Unfortunately, this scenario has already begun: there exist today engines that
have chosen to deviate from the standard and provide non-standard memory
sizes. Furthermore, they do so in a manner such that their deviant behavior is
observable from Wasm (i.e. they are not performing semantics-preserving
optimizations like the "`asm.js`-style" approach). [Here is proof-of-concept
program](https://gist.github.com/fitzgen/a8cc0a9d5c41447416430c1dedc0adf5) whose
execution diverges depending on whether the Wasm engine is standards compliant
or not. To make matters worse, these non-standard extensions are already
shipping on millions of devices.

Therefore, it is both vital and urgent that we (the Wasm CG) create
standards-based solutions to these use cases, and prevent the situation from
worsening.

### Maximum Memory Address Accessed Hint

We could avoid modifying the memory page size and instead provide a hint
(similar to the branch hinting proposal) promising that memory above address `A`
will never be accessed. Then runtimes could allocate linear memory just large
enough for `A`, leaving the rest of the memory unallocated. This would
effectively allow Wasm to define memories that are smaller than 64 KiB or which
are not multiples of 64 KiB.

However, what happens if the Wasm fails to uphold its promise not to access
memory above `A`?

If the answer to that question is deterministically raising a trap, then this
alternative is basically the same as this proposal, except with two additional
and related disadvantages:

1. It fails to reuse existing Wasm concepts, like memory being composed of
   pages, increasing the effort required to spec the feature and imposing
   additional complexity burden on implementations.

2. Simultaneously, it provides less flexibility and generality than this
   proposal: Wasm cannot, for example, rely on `memory.size` to determine the
   "real" maximum addressable memory address.

If the answer to that question is that accesses nondeterministically trap or
succeed, then that opens the door to even more problematic questions, such as:

* Are stores that do not trap visible from subsequent loads that do not trap?
  That is, is it acceptable to simply ignore stores and return 0 for loads?

* How portable is an observed behavior? Can I expect the same behavior across
  runtimes or architectures or devices or on the Web or outside the Web?

* If I observe a certain nondeterministic behavior for a memory access beyond
  the hint's maximum address when running, will all other such accesses during
  this run exhibit the same behavior? Can one access succeed while the next will
  trap?

Finally, keeping Wasm as deterministic as possible (something the CG has tried
to do in general) has advantages for tooling, portability, testing, and
reliability.
