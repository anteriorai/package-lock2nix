import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";

import bencode from "bencode";

await suite(import.meta.filename, async () => {
  await test("bencode", async () => {
    const buf = bencode.encode([50, 77]);
    const astxt = new TextDecoder("UTF-8").decode(buf);
    strictEqual(astxt, "li50ei77ee");
  });
});
