import bencode from "bencode";

export function enc(x) {
  return new TextDecoder("UTF-8").decode(bencode.encode(x));
}
