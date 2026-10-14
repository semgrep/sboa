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
#define PYEMBED_SYM(s) "_" #s
#define PYEMBED_SECTION ".section __TEXT,__const"
#elif defined(_WIN32)
#define PYEMBED_SYM(s) #s
#define PYEMBED_SECTION ".section .rdata,\"dr\""
#else
#define PYEMBED_SYM(s) #s
#define PYEMBED_SECTION ".section .rodata"
#endif

#define PYEMBED_INCBIN(sym, file)                                     \
  __asm__(PYEMBED_SECTION "\n"                                        \
          ".globl " PYEMBED_SYM(sym) "\n"                             \
          ".balign 16\n" PYEMBED_SYM(sym) ":\n"                       \
          ".incbin \"" file "\"\n"                                    \
          ".globl " PYEMBED_SYM(sym##_end) "\n"                       \
          PYEMBED_SYM(sym##_end) ":\n"                                \
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

PYEMBED_INCBIN(pyembed_test_bundle, PYEMBED_TEST_PAYLOAD)
