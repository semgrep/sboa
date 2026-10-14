;; Installs the cpython-embed runtime files next to the executables of an
;; install prefix, from dune alone (see gen_runtime_files.py for the why):
;;
;;   Linux / macOS:  <prefix>/bin/libs/libpython3.13.so.1.0 (or .dylib) and
;;                   <prefix>/bin/libs/python3.13/lib-dynload/*.so
;;                   (the binaries are linked with rpath $ORIGIN/libs or
;;                   @loader_path/libs)
;;   Windows:        <prefix>/bin/python313.dll, vcruntime*.dll, *.pyd, ...
;;                   (the loader searches the executable's directory)
;;
;; Which files go where is decided by the installed cpython-embed.config; the
;; two directory-target rules below populate runtime_libs/ (Linux, macOS) or
;; runtime_bin/ (Windows) and leave the other empty.  dune's `install` cannot
;; take external files, `:include`, or a glob over a directory target (it
;; reports a dependency cycle), so the Windows file names are listed here
;; explicitly.
;; COUPLING: the Windows list must match the Windows branch of install.sh
;; (runtime_files in cpython-embed.config).
;;
;; Usage: this file is not a `dune` file on purpose (it needs cpython-embed
;; installed and `(using directory-targets 0.1)` in dune-project, so it must
;; not be picked up by builds that do not want the runtime files).  Create
;; OSS/libs/pyembed/runtime/dune containing `(include runtime_files.dune.inc)`
;; once pyembed's dune-project has `(using directory-targets 0.1)`.

(rule
 (targets
  (dir runtime_libs))
 (deps
  %{lib:cpython-embed:cpython-embed.config}
  ../probe.sh
  gen_runtime_files.py)
 (action
  ; the cpython-embed interpreter: no other Python is needed to build
  (run sh ../probe.sh --exec-python -I gen_runtime_files.py
   %{lib:cpython-embed:cpython-embed.config} --layout libs --out runtime_libs)))

(rule
 (targets
  (dir runtime_bin))
 (deps
  %{lib:cpython-embed:cpython-embed.config}
  ../probe.sh
  gen_runtime_files.py)
 (action
  ; the cpython-embed interpreter: no other Python is needed to build
  (run sh ../probe.sh --exec-python -I gen_runtime_files.py
   %{lib:cpython-embed:cpython-embed.config} --layout bin --out runtime_bin)))

(install
 (enabled_if
  (<> %{os_type} Win32))
 (package pyembed)
 (section bin)
 (dirs
  (runtime_libs as libs)))

(install
 (enabled_if
  (= %{os_type} Win32))
 (package pyembed)
 (section bin)
 (files
  (runtime_bin/python313.dll as python313.dll)
  (runtime_bin/python3.dll as python3.dll)
  (runtime_bin/vcruntime140.dll as vcruntime140.dll)
  (runtime_bin/vcruntime140_1.dll as vcruntime140_1.dll)
  (runtime_bin/_asyncio.pyd as _asyncio.pyd)
  (runtime_bin/_bz2.pyd as _bz2.pyd)
  (runtime_bin/_ctypes.pyd as _ctypes.pyd)
  (runtime_bin/_decimal.pyd as _decimal.pyd)
  (runtime_bin/_elementtree.pyd as _elementtree.pyd)
  (runtime_bin/_hashlib.pyd as _hashlib.pyd)
  (runtime_bin/_lzma.pyd as _lzma.pyd)
  (runtime_bin/_multiprocessing.pyd as _multiprocessing.pyd)
  (runtime_bin/_overlapped.pyd as _overlapped.pyd)
  (runtime_bin/_queue.pyd as _queue.pyd)
  (runtime_bin/_socket.pyd as _socket.pyd)
  (runtime_bin/_sqlite3.pyd as _sqlite3.pyd)
  (runtime_bin/_ssl.pyd as _ssl.pyd)
  (runtime_bin/_uuid.pyd as _uuid.pyd)
  (runtime_bin/_wmi.pyd as _wmi.pyd)
  (runtime_bin/_zoneinfo.pyd as _zoneinfo.pyd)
  (runtime_bin/libcrypto-3-x64.dll as libcrypto-3-x64.dll)
  (runtime_bin/libffi-8.dll as libffi-8.dll)
  (runtime_bin/libssl-3-x64.dll as libssl-3-x64.dll)
  (runtime_bin/pyexpat.pyd as pyexpat.pyd)
  (runtime_bin/select.pyd as select.pyd)
  (runtime_bin/sqlite3.dll as sqlite3.dll)
  (runtime_bin/unicodedata.pyd as unicodedata.pyd)
  (runtime_bin/winsound.pyd as winsound.pyd)
  (runtime_bin/zlib1.dll as zlib1.dll)))
