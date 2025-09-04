import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";

import { greet } from "./greet.js";

await suite(import.meta.filename, async () => {
  await test("greet", async () => {
    strictEqual(greet("foo"), "Hello, 3:foo");
  });
});
