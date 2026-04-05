## Example: Runtime TLS backend selection using softlink
##
## Demonstrates how a single binary can work with either mbedTLS or wolfSSL,
## using whichever is available on the system. This is the motivating use case
## for softlink — embedded devices (OpenWrt) where you can't control which TLS
## library is installed and can't afford to install one just for health probes.

import softlink

# --- Opaque types (same as you'd define for {.importc.}) ---

type
  MbedSslContext {.incompleteStruct.} = object
  MbedSslConfig {.incompleteStruct.} = object
  MbedEntropy {.incompleteStruct.} = object
  MbedCtrDrbg {.incompleteStruct.} = object

  WolfSslCtx {.incompleteStruct.} = object
  WolfSslSession {.incompleteStruct.} = object

# --- mbedTLS bindings ---

dynlib "libmbedtls.so(.21|.16|.14|)":
  proc mbedtls_ssl_init(ssl: ptr MbedSslContext) {.cdecl.}
  proc mbedtls_ssl_free(ssl: ptr MbedSslContext) {.cdecl.}
  proc mbedtls_ssl_setup(ssl: ptr MbedSslContext, conf: ptr MbedSslConfig): cint {.cdecl.}
  proc mbedtls_ssl_handshake(ssl: ptr MbedSslContext): cint {.cdecl.}
  proc mbedtls_ssl_write(ssl: ptr MbedSslContext, buf: ptr byte, len: csize_t): cint {.cdecl.}
  proc mbedtls_ssl_read(ssl: ptr MbedSslContext, buf: ptr byte, len: csize_t): cint {.cdecl.}
  proc mbedtls_ssl_close_notify(ssl: ptr MbedSslContext): cint {.cdecl.}

# --- wolfSSL bindings ---

dynlib "libwolfssl.so(.42|.35|)":
  proc wolfSSL_Init(): cint {.cdecl.}
  proc wolfSSL_Cleanup(): cint {.cdecl.}
  proc wolfSSL_CTX_new(meth: pointer): ptr WolfSslCtx {.cdecl.}
  proc wolfSSL_new(ctx: ptr WolfSslCtx): ptr WolfSslSession {.cdecl.}
  proc wolfSSL_connect(ssl: ptr WolfSslSession): cint {.cdecl.}
  proc wolfSSL_write(ssl: ptr WolfSslSession, data: pointer, sz: cint): cint {.cdecl.}
  proc wolfSSL_read(ssl: ptr WolfSslSession, data: pointer, sz: cint): cint {.cdecl.}
  proc wolfSSL_free(ssl: ptr WolfSslSession) {.cdecl.}
  proc wolfSSL_CTX_free(ctx: ptr WolfSslCtx) {.cdecl.}

# --- Runtime backend selection ---

type
  TlsBackend* = enum
    tbNone      ## No TLS library available
    tbMbedTls   ## mbedTLS loaded
    tbWolfSsl   ## wolfSSL loaded

proc detectTlsBackend*(): TlsBackend =
  if loadMbedtls().kind == lrOk:
    return tbMbedTls
  if loadWolfssl().kind == lrOk:
    return tbWolfSsl
  tbNone

# --- Application code ---

when isMainModule:
  let backend = detectTlsBackend()
  case backend
  of tbMbedTls:
    echo "Using mbedTLS for HTTPS probes"
  of tbWolfSsl:
    echo "Using wolfSSL for HTTPS probes"
  of tbNone:
    echo "No TLS library available — HTTPS probes disabled"
