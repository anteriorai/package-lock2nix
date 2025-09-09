import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";

import { enc } from "./mybencode.js";

await suite(import.meta.filename, async () => {
  await test("mybencode", async () => {
    strictEqual(enc([50, 77]), "li50ei77ee");
  });
});
