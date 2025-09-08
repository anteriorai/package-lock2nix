#!/usr/bin/env node

import { enc } from "external-deps/mybencode";

function main() {
  console.log(enc("hello from transitive external dependency"));
}

main();
