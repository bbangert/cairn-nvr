// The project's only door to the vendored MessagePack decoder
// (assets/vendor/msgpack.min.js — @msgpack/msgpack 3.1.3, provenance in app.js).
//
// The vendored file is the UMD bundle, which esbuild reads as CommonJS: some
// interop paths hang the exports off the namespace's `default` and others put
// them directly on it, and which one you get is a property of the bundler, not
// of anything in this repo. That guess lives here and nowhere else, so a
// future esbuild upgrade is one line to re-check rather than a hunt through
// the hooks.
//
// It is also checked here, at load: if neither shape has a `decode`, the
// console says so once with the reason, instead of every caller discovering it
// as an undefined-is-not-a-function inside a promise chain. The check does not
// throw — a broken decoder must not take the rest of app.js (the players, the
// dashboard) down with it.
import * as msgpackModule from "../vendor/msgpack.min.js"

const msgpack = msgpackModule.decode ? msgpackModule : msgpackModule.default
const usable = !!msgpack && typeof msgpack.decode === "function"

if (!usable) {
  console.error(
    "vendor_msgpack: neither the module namespace nor its default export has decode(). " +
      "The esbuild CommonJS interop shape changed — anything decoding MessagePack will fail."
  )
}

// Decodes one MessagePack document from a Uint8Array. Throws on malformed
// input: what a corrupt file means is the caller's decision, not this module's.
export function decode(bytes) {
  if (!usable) throw new Error("vendor_msgpack: no decode() (see the error logged at load)")
  return msgpack.decode(bytes)
}
