import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";
// Local copy, different version from dependency
import bencode from "bencode";

import { greet } from "./greet.js";

await suite(import.meta.filename, async () => {
  await test("greet", async () => {
    strictEqual(greet("foo"), "Hello, 3:foo");
  });

  await test("local dependency", async () => {
    // Test that this is indeed the old version of bencode by triggering old behavior
    const enc = bencode.encode;
    enc._floatConversionDetected = true;
    const astxt = new TextDecoder("UTF-8").decode(enc(340282366920938463463374607431768211457));
    strictEqual(astxt, "i0e");
  });
});
