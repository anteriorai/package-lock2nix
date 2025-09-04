import bencode from "bencode";

export function enc(str) {
  return new TextDecoder("UTF-8").decode(bencode.encode(str));
}
