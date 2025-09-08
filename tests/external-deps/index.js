#!/usr/bin/env node

import { enc } from "./mybencode.js";

function main() {
  console.log(enc("hello, world"));
}

main();
