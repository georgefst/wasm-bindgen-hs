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
  chunkWords,
  newCounter,
  incrementCounter,
  describeCounter,
  Counter,
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
    assert.equal(negateBool(true), false);
    assert.equal(negateBool(false), true);
  });

  it("theAnswer", () => {
    assert.equal(theAnswer(), 4815162342n);
  });

  it("getCurrentTimeText", () => {
    assert.match(getCurrentTimeText(), /^\d{4}-\d{2}-\d{2}/);
  });
});

describe("lists", () => {
  it("primesUpTo", () => {
    assert.deepEqual(primesUpTo(6), [2, 3, 5, 7, 11, 13]);
    assert.deepEqual(primesUpTo(0), []);
  });

  it("chunkWords (nested lists)", () => {
    assert.deepEqual(chunkWords(2, "the quick brown fox jumps"), [
      ["the", "quick"],
      ["brown", "fox"],
      ["jumps"],
    ]);
    assert.deepEqual(chunkWords(3, ""), []);
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

describe("opaque types", () => {
  it("counters are independent and stateful", async () => {
    const a = await newCounter("a");
    const b = await newCounter("b");
    assert.ok(a instanceof Counter);
    assert.equal(await incrementCounter(a), 1);
    assert.equal(await incrementCounter(a), 2);
    assert.equal(await incrementCounter(b), 1);
    assert.equal(await describeCounter(a), "a: 2");
    assert.equal(await describeCounter(b), "b: 1");
  });

  it("cannot be constructed directly", () => {
    // @ts-expect-error the constructor is declared private
    assert.throws(() => new Counter(42));
  });

  it("explicit free is idempotent, and use after free throws", async () => {
    const c = await newCounter("c");
    assert.equal(await incrementCounter(c), 1);
    c.free();
    c.free();
    await assert.rejects(async () => incrementCounter(c), /freed Counter/);
  });
});
