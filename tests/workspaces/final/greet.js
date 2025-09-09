import { enc } from "@example/mybencode";

export function greet(name) {
  return `Hello, ${enc(name)}`;
}
