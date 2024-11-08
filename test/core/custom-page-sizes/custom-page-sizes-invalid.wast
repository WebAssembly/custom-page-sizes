;; Page size that is not a power of two.
(assert_malformed
  (module quote "(memory 0 (pagesize 3))")
  "invalid custom page size"
)

(assert_malformed
  (module quote "(memory 0 (pagesize 0))")
  "invalid custom page size"
)

;; Power-of-two page sizes that are not 1 or 64KiB.
(assert_invalid
  (module (memory 0 (pagesize 2)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 4)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 8)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 16)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 32)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 64)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 128)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 256)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 512)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 1024)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 2048)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 4096)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 8192)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 16384)))
  "invalid custom page size"
)
(assert_invalid
  (module (memory 0 (pagesize 32768)))
  "invalid custom page size"
)

;; Power-of-two page size that is larger than 64KiB.
(assert_invalid
  (module (memory 0 (pagesize 0x20000)))
  "invalid custom page size"
)

;; Power of two page size that cannot fit in a u64 to exercise checks against
;; shift overflow.
(assert_malformed
  (module binary
    "\00asm" "\01\00\00\00"
    "\05\04\01"                ;; Memory section

    ;; memory 0
    "\08"                      ;; flags w/ custom page size
    "\00"                      ;; minimum = 0
    "\41"                      ;; pagesize = 2**65
  )
  "invalid custom page size"
)

;; Importing a memory with the wrong page size.

(module $m
  (memory (export "small-pages-memory") 0 (pagesize 1))
  (memory (export "large-pages-memory") 0 (pagesize 65536))
)
(register "m" $m)

(assert_unlinkable
  (module
    (memory (import "m" "small-pages-memory") 0 (pagesize 65536))
  )
  "memory types incompatible"
)

(assert_unlinkable
  (module
    (memory (import "m" "large-pages-memory") 0 (pagesize 1))
  )
  "memory types incompatible"
)

;; Maximum memory sizes.
;;
;; These modules are valid, but instantiating them is unnecessary
;; and would only allocate very large memories and slow down running
;; the spec tests. Therefore, add a missing import so that it cannot
;; be instantiated and use `assert_unlinkable`. This approach
;; enforces that the module itself is still valid, but that its
;; instantiation fails early (hopefully before any memories are
;; actually allocated).

;; i32 (pagesize 1)
(assert_unlinkable
  (module
    (import "test" "unknown" (func))
    (memory 0xFFFF_FFFF (pagesize 1)))
  "unknown import")

;; i64 (pagesize 1)
(assert_unlinkable
  (module
    (import "test" "import" (func))
    (memory i64 0xFFFF_FFFF_FFFF_FFFF (pagesize 1)))
  "unknown import")

;; i32 (default pagesize)
(assert_unlinkable
  (module
    (import "test" "unknown" (func))
    (memory 65536 (pagesize 65536)))
  "unknown import")

;; i64 (default pagesize)
(assert_unlinkable
  (module
    (import "test" "unknown" (func))
    (memory i64 0x1_0000_0000_0000 (pagesize 65536)))
  "unknown import")

;; Memory size just over the maximum.
;;
;; These are malformed (for pagesize 1)
;; or invalid (for other pagesizes).

;; i32 (pagesize 1)
(assert_malformed
  (module quote "(memory 0x1_0000_0000 (pagesize 1))")
  "constant out of range")

;; i64 (pagesize 1)
(assert_malformed
  (module quote "(memory i64 0x1_0000_0000_0000_0000 (pagesize 1))")
  "constant out of range")

;; i32 (default pagesize)
(assert_invalid
  (module
    (memory 65537 (pagesize 65536)))
  "memory size must be at most")

;; i64 (default pagesize)
(assert_invalid
  (module
    (memory i64 0x1_0000_0000_0001 (pagesize 65536)))
  "memory size must be at most")
