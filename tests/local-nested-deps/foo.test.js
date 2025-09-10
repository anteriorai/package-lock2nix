import { suite, test } from "node:test";
import { strictEqual } from "node:assert/strict";

import { foo as foo1 } from "single-no-deps/foo";
import { foo as foo2 } from "local-dep-only/foo";

await suite(import.meta.filename, async () => {
  await test("nested import equality", async () => {
    strictEqual(foo1, foo2);
  });
});
