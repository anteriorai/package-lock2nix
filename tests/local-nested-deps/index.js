#!/usr/bin/env node

import { foo } from "single-no-deps/foo";

function main() {
  console.log(`hello from local dependency: ${foo()}`);
}

main();
