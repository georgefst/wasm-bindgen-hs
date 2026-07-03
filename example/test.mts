import { describe, it, before } from "node:test";
import assert from "node:assert/strict";

import {
  init,
  logMessage,
  greetManyPure,
  replicateText,
  greet,
  addByte,
  multiplyDouble,
  negateBool,
  theAnswer,
  addInt,
  getCurrentTimeText,
  primesUpTo,
} from "example";

before(async () => {
  await init();
});

describe("sync exports", () => {
  it("addInt", () => {
    assert.equal(addInt(2, 3), 5);
    assert.equal(addInt(0, 0), 0);
    assert.equal(addInt(-1, 1), 0);
  });

  it("addByte", () => {
    assert.equal(addByte(10, 20), 30);
    assert.equal(addByte(255, 0), 255);
  });

  it("multiplyDouble", () => {
    assert.equal(multiplyDouble(2.5, 4.0), 10.0);
    assert.equal(multiplyDouble(0, 100), 0);
  });

  it("negateBool", () => {
    // GHC Wasm FFI marshals Bool as 0/1, not false/true
    assert.equal(!!negateBool(true), false);
    assert.equal(!!negateBool(false), true);
  });

  it("theAnswer", () => {
    assert.equal(theAnswer(), 4815162342n);
  });

  it("primesUpTo", () => {
    assert.equal(primesUpTo(6), "[2,3,5,7,11,13]");
  });

  it("getCurrentTimeText", () => {
    assert.match(getCurrentTimeText(), /^\d{4}-\d{2}-\d{2}/);
  });
});

describe("async exports", () => {
  it("greetManyPure", async () => {
    assert.equal(
      await greetManyPure("Alice", "Bob", "Charlie"),
      "Hello, Alice, Bob and Charlie!",
    );
  });

  it("replicateText", async () => {
    assert.equal(await replicateText(3, "ha"), "hahaha");
  });

  it("greet", async () => {
    const result = await greet("World");
    assert.match(result, /^Hello, World! The time is: \d{4}-\d{2}-\d{2}/);
  });

  it("logMessage", async () => {
    const result = await logMessage("test message from JS");
    assert.equal(result, undefined);
  });
});
