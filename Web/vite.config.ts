import { defineConfig } from 'vite'

// Code-split on purpose, and **not** a single inlined file.
//
// Shiki ships one grammar per language as its own dynamic import. Inlining them
// produces a 10.7 MB index.html that WKWebView must parse in full every time the
// view is built, to render one diff in one language. Split, the entry is 459 kB
// and the only grammar fetched is the one the open file actually needs.
//
// The cost is that `file://` cannot serve ES modules — its origin is opaque, so
// every dynamic import fails CORS. Grove therefore serves this directory over a
// custom `grove-diff://` scheme from the app bundle (`DiffSchemeHandler`),
// which gives the page a real origin without giving it a network.
export default defineConfig({
  base: './',
  build: {
    // WKWebView on macOS 27 is far newer than this; the floor only keeps the
    // output readable when something needs debugging.
    target: 'safari18',
    outDir: 'DiffRenderer',
    emptyOutDir: true,
    cssCodeSplit: false,
    // Grammar chunks are legitimately large; the warning is pure noise here.
    chunkSizeWarningLimit: 100_000,
  },
})
