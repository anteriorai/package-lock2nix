import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";

import b from "bencode";

await suite(import.meta.filename, async () => {
  await test("decode", async () => {
    strictEqual(b.decode("i3e"), "foo");
  });
});
