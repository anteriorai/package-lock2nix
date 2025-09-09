import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";

import { aaa } from "./aaa.js";

await suite(import.meta.filename, async () => {
  await test("aaa()", async () => {
    strictEqual(aaa(), "I am A");
  });
});
