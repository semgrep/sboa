/*
   Copyright (c) 2026 Semgrep Inc.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public License
   version 2.1 as published by the Free Software Foundation.

   This library is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the file
   LICENSE for more details.
*/
/* Embeds bundle_payload.bin with the assembler's .incbin directive and
   exposes it as a zero-copy bigarray: the same shape the bundle generator
   emits for real bundles (one asm block + one primitive per bundle).
   Section directives: ELF .rodata, Mach-O __TEXT,__const (symbols get a
   leading underscore), COFF .rdata. */
#define CAML_NAME_SPACE
#include <caml/bigarray.h>
#include <caml/mlvalues.h>

#if defined(__APPLE__)
#define SBOA_SYM(s) "_" #s
#define SBOA_SECTION ".section __TEXT,__const"
#elif defined(_WIN32)
#define SBOA_SYM(s) #s
#define SBOA_SECTION ".section .rdata,\"dr\""
#else
#define SBOA_SYM(s) #s
#define SBOA_SECTION ".section .rodata"
#endif

#define SBOA_INCBIN(sym, file)                                     \
  __asm__(SBOA_SECTION "\n"                                        \
          ".globl " SBOA_SYM(sym) "\n"                             \
          ".balign 16\n" SBOA_SYM(sym) ":\n"                       \
          ".incbin \"" file "\"\n"                                    \
          ".globl " SBOA_SYM(sym##_end) "\n"                       \
          SBOA_SYM(sym##_end) ":\n"                                \
          ".byte 0\n"                                                 \
          ".text\n");                                                 \
  extern const unsigned char sym[];                                   \
  extern const unsigned char sym##_end[];                             \
  value sym##_blob(value unit) {                                      \
    return caml_ba_alloc_dims(CAML_BA_CHAR | CAML_BA_C_LAYOUT |      \
                                  CAML_BA_EXTERNAL,                   \
                              1, (void *)sym,                         \
                              (intnat)(sym##_end - sym));             \
  }

SBOA_INCBIN(sboa_test_bundle, SBOA_TEST_PAYLOAD)
