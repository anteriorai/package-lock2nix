import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";

import { foo } from "./foo.js";

await suite(import.meta.filename, async () => {
  await test("foo", async () => {
    strictEqual(foo(), "foobar");
  });
});
