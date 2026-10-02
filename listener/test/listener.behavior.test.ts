import { expect, test } from "vitest";
import { FakeChain } from "../src/fakeChain.js";
import { Listener } from "../src/listener.js";
import { HolderStore } from "../src/store.js";
import type { TransferLog } from "../src/types.js";

const ZERO = "0x0000000000000000000000000000000000000000";
const alice = "0xA11ce0000000000000000000000000000000a11c";
const bob = "0xB0b0000000000000000000000000000000000b0b";
const carol = "0xCa401000000000000000000000000000000ca401";

type Transfers = Array<{ from: string; to: string; value: bigint; txHash?: string }>;

/** Counts getLogs calls so tests can observe "no-op" behaviour through the public chain API. */
class CountingChain extends FakeChain {
  getLogsCalls = 0;
  override async getLogs(fromBlock: bigint, toBlock: bigint): Promise<TransferLog[]> {
    this.getLogsCalls += 1;
    return super.getLogs(fromBlock, toBlock);
  }
}

/** Records the block ranges the listener asks for. */
class RangeChain extends FakeChain {
  ranges: Array<[bigint, bigint]> = [];
  override async getLogs(fromBlock: bigint, toBlock: bigint): Promise<TransferLog[]> {
    this.ranges.push([fromBlock, toBlock]);
    return super.getLogs(fromBlock, toBlock);
  }
}

/** Store whose named operation fails once after `allowBefore` successful calls. */
class FlakyStore extends HolderStore {
  private setBalanceCalls = 0;
  failSetCursorOnce = false;
  failSetBalanceAfter: number | null = null;

  override async setCursor(blockNumber: bigint): Promise<void> {
    if (this.failSetCursorOnce) {
      this.failSetCursorOnce = false;
      throw new Error("simulated setCursor failure");
    }
    return super.setCursor(blockNumber);
  }

  override async setBalance(address: string, value: bigint): Promise<void> {
    if (this.failSetBalanceAfter !== null) {
      if (this.setBalanceCalls >= this.failSetBalanceAfter) {
        this.failSetBalanceAfter = null;
        this.setBalanceCalls = 0;
        throw new Error("simulated setBalance failure");
      }
      this.setBalanceCalls += 1;
    }
    return super.setBalance(address, value);
  }
}

async function state(store: HolderStore) {
  return {
     balances: await store.snapshot(),
     cursor: await store.getCursor(), 
     kv: [...store.kv.keys()].sort()
  };
}

function mine(chain: FakeChain, ...blocks: Transfers[]): void {
  for (const block of blocks) chain.mineBlock(block);
}

// ---------------------------------------------------------------- REG-01
test("REG-01 publishes only logs through head minus confirmations", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(
    chain,
    [{ from: ZERO, to: alice, value: 100n }], // block 0
    [{ from: alice, to: bob, value: 10n }], // block 1
    [{ from: alice, to: carol, value: 20n }], // block 2
    [{ from: alice, to: bob, value: 5n }], // block 3 = head
  );

  await new Listener(chain, store, 2n).sync(); // finalized = 1

  expect(await store.snapshot()).toEqual({ [alice]: "90", [bob]: "10" });
  expect(await store.getCursor()).toBe(1n);
});

test("REG-01 depth zero publishes the current head immediately", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 10n }]);

  await new Listener(chain, store, 0n).sync();

  expect(await store.snapshot()).toEqual({ [alice]: "10" });
});

test("REG-01 publishes nothing while the chain is shorter than the confirmation depth", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const listener = new Listener(chain, store, 3n);

  await listener.sync(); // empty chain
  mine(chain, [{ from: ZERO, to: alice, value: 1n }], [{ from: ZERO, to: bob, value: 1n }]);
  await listener.sync(); // head 1 < depth 3

  expect(await store.snapshot()).toEqual({});
  expect(await store.getCursor()).toBe(-1n);
});

test("REG-01 a sync with no newly eligible block is no-op", async () => {
  const chain = new CountingChain();
  const store = new HolderStore();
  const listener = new Listener(chain, store, 1n);
  mine(chain, [{ from: ZERO, to: alice, value: 10n }], [{ from: alice, to: bob, value: 4n }]);
  await listener.sync(); // finalized = 0
  const before = await state(store);
  const callsBefore = chain.getLogsCalls;

  await listener.sync();
  await listener.sync();

  expect(await state(store)).toEqual(before);
  expect(chain.getLogsCalls).toBe(callsBefore);
});

test("REG-01 replacing an unfinalized tip cannot leave a stale balance", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const listener = new Listener(chain, store, 2n);
  mine(
    chain,
    [{ from: ZERO, to: alice, value: 100n }], // 0
    [{ from: alice, to: bob, value: 10n }], // 1
    [{ from: alice, to: bob, value: 40n }], // 2 (replaceable tip)
  );
  await listener.sync(); // finalized = 0
  expect(await store.snapshot()).toEqual({ [alice]: "100" });

  chain.reorg(2, [[{ from: alice, to: carol, value: 7n }]]); // replace block 2 before it is eligible
  mine(chain, [], []); // blocks 3 and 4 make block 2 eligible
  await listener.sync(); // finalized = 2

  expect(await store.snapshot()).toEqual({ [alice]: "83", [bob]: "10", [carol]: "7" });
});

test("REG-01 constructing a listener with a negative confirmation depth is rejected", () => {
  const chain = new FakeChain();
  const store = new HolderStore();

  expect(() => new Listener(chain, store, -1n)).toThrow();
  expect(() => new Listener(chain, store, 0n)).not.toThrow();
});

// ---------------------------------------------------------------- REG-02
test("REG-02 mint credits only the recipient and the zero address never becomes a holder", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 100n }]);

  await new Listener(chain, store, 0n).sync();

  expect(await store.snapshot()).toEqual({ [alice]: "100" });
  expect(await store.getBalance(ZERO)).toBe(0n);
});

test("REG-02 burn debits only the sender", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 100n }], [{ from: alice, to: ZERO, value: 30n }]);

  await new Listener(chain, store, 0n).sync();

  expect(await store.snapshot()).toEqual({ [alice]: "70" });
  expect(Object.keys(await store.snapshot())).not.toContain(ZERO);
});

test("REG-02 a transfer debits the sender and credits the recipient by the same amount", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 100n }], [{ from: alice, to: bob, value: 37n }]);

  await new Listener(chain, store, 0n).sync();

  const balances = await store.snapshot();
  expect(balances).toEqual({ [alice]: "63", [bob]: "37" });
  expect(BigInt(balances[alice]!) + BigInt(balances[bob]!)).toBe(100n);
});

test("REG-02 draining a holder to zero removes it and a self-transfer changes nothing", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(
    chain,
    [{ from: ZERO, to: alice, value: 50n }],
    [{ from: alice, to: alice, value: 20n }],
    [{ from: alice, to: bob, value: 50n }],
  );

  await new Listener(chain, store, 0n).sync();

  expect(await store.snapshot()).toEqual({ [bob]: "50" });
});

test("REG-02 the zero address never appears as a holder", async () => {
    const chain = new FakeChain();
    const store = new HolderStore();;
    chain.mineBlock([{ from: ZERO, to: alice, value: 100n }]);
    chain.mineBlock([{ from: alice, to: bob, value: 25n }]);
    chain.mineBlock([{ from: bob, to: ZERO, value: 25n }]);
    chain.mineBlock([{ from: alice, to: ZERO, value: 75n }]);

    await new Listener(chain, store, 0n).sync();

    expect(await store.snapshot()).toEqual({});
    expect(await store.getBalance(ZERO)).toBe(0n);
    expect(Object.keys(await store.snapshot())).not.toContain(ZERO);
});

// ---------------------------------------------------------------- REG-03

test("REG-03 distinct logs in one transaction are all applied", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(chain, [
    { from: ZERO, to: alice, value: 100n, txHash: "0xtx" },
    { from: alice, to: bob, value: 10n, txHash: "0xtx" },
    { from: alice, to: carol, value: 20n, txHash: "0xtx" },
  ]);

  await new Listener(chain, store, 0n).sync();

  expect(await store.snapshot()).toEqual({ [alice]: "70", [bob]: "10", [carol]: "20" });
});

test("REG-03 a transaction hash shared across blocks does not suppress later logs", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(
    chain,
    [{ from: ZERO, to: alice, value: 100n, txHash: "0xdup" }],
    [{ from: alice, to: bob, value: 25n, txHash: "0xdup" }],
  );

  await new Listener(chain, store, 0n).sync();

  expect(await store.snapshot()).toEqual({ [alice]: "75", [bob]: "25" });
});

test("REG-03 rereading an overlapping range never applies a log twice", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const listener = new Listener(chain, store, 0n);
  mine(chain, [{ from: ZERO, to: alice, value: 100n }], [{ from: alice, to: bob, value: 40n }]);
  await listener.sync();
  const published = await state(store);

  await store.setCursor(-1n); // force the whole range to be read again
  await listener.sync();
  await listener.sync();

  expect(await store.snapshot()).toEqual(published.balances);
  expect(await store.getCursor()).toBe(1n);
});

test("REG-03 overlap with new blocks applies only the new logs", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const listener = new Listener(chain, store, 0n);
  mine(chain, [{ from: ZERO, to: alice, value: 100n }]);
  await listener.sync();
  mine(chain, [{ from: alice, to: bob, value: 10n }]);
  await store.setCursor(-1n); // block 0 is re-read together with the new block 1

  await listener.sync();

  expect(await store.snapshot()).toEqual({ [alice]: "90", [bob]: "10" });
});

// ---------------------------------------------------------------- REG-04

test("REG-04 a new listener on the same store resumes from durable state", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 100n }]);
  await new Listener(chain, store, 0n).sync();
  mine(chain, [{ from: alice, to: bob, value: 25n }]);

  await new Listener(chain, store, 0n).sync();

  expect(await store.snapshot()).toEqual({ [alice]: "75", [bob]: "25" });
  expect(await store.getCursor()).toBe(1n);
});

test("REG-04 catch-up after downtime fills every newly eligible block without gaps", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 100n }]);
  await new Listener(chain, store, 1n).sync(); // head 0 with depth 1: nothing eligible yet
  mine(
    chain,
    [{ from: alice, to: bob, value: 1n }],
    [{ from: alice, to: bob, value: 2n }],
    [{ from: alice, to: carol, value: 3n }],
    [{ from: bob, to: carol, value: 1n }],
    [{ from: alice, to: carol, value: 4n }],
  );

  await new Listener(chain, store, 1n).sync(); // a "restarted" process; head 5, finalized 4

  const fresh = new HolderStore();
  await new Listener(chain, fresh, 1n).sync();
  expect(await store.snapshot()).toEqual(await fresh.snapshot());
  expect(await store.snapshot()).toEqual({ [alice]: "94", [bob]: "2", [carol]: "4" });
  expect(await store.getCursor()).toBe(4n);
});

test("REG-04 restarting with no eligible gap leaves balances, dedup state and cursor untouched", async () => {
  const chain = new CountingChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 100n }], [{ from: alice, to: bob, value: 40n }]);
  await new Listener(chain, store, 0n).sync();
  const before = await state(store);

  await new Listener(chain, store, 0n).sync();
  await new Listener(chain, store, 0n).sync();

  expect(await state(store)).toEqual(before);
});

test("REG-04 a restarted listener requests only the blocks after the durable cursor", async () => {
  const chain = new RangeChain();
  const store = new HolderStore();
  mine(chain, [{ from: ZERO, to: alice, value: 10n }], [{ from: alice, to: bob, value: 1n }]);
  await new Listener(chain, store, 0n).sync();
  mine(chain, [{ from: alice, to: bob, value: 2n }], []);
  chain.ranges = [];

  await new Listener(chain, store, 0n).sync(); // head 3, durable cursor 1

  expect(chain.ranges).toEqual([[2n, 3n]]);
  expect(await store.snapshot()).toEqual({ [alice]: "7", [bob]: "3" });
});

test("REG-04 a restart does not depend on listener instance fields", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const first = new Listener(chain, store, 0n);
  mine(chain, [{ from: ZERO, to: alice, value: 10n }]);
  await first.sync();
  mine(chain, [{ from: alice, to: bob, value: 3n }]);

  // A brand new instance and the old one must converge on the same durable outcome.
  await new Listener(chain, store, 0n).sync();
  await first.sync();

  expect(await store.snapshot()).toEqual({ [alice]: "7", [bob]: "3" });
});

// ---------------------------------------------------------------- REG-05

test("REG-05 a failed cursor write publishes no balances, markers or cursor", async () => {
  const chain = new FakeChain();
  const store = new FlakyStore();
  mine(chain, [{ from: ZERO, to: alice, value: 100n }], [{ from: alice, to: bob, value: 40n }]);
  const listener = new Listener(chain, store, 0n);
  store.failSetCursorOnce = true;

  await expect(listener.sync()).rejects.toThrow();

  expect(await store.snapshot()).toEqual({});
  expect(await store.getCursor()).toBe(-1n);
  expect(store.kv.size).toBe(0);
});

test("REG-05 a failure part-way through the balance updates publishes none of them", async () => {
  const chain = new FakeChain();
  const store = new FlakyStore();
  mine(
    chain,
    [{ from: ZERO, to: alice, value: 100n }],
    [{ from: alice, to: bob, value: 40n }],
    [{ from: alice, to: carol, value: 10n }],
  );
  const listener = new Listener(chain, store, 0n);
  store.failSetBalanceAfter = 2; // two balance writes succeed, the third fails

  await expect(listener.sync()).rejects.toThrow();

  expect(await store.snapshot()).toEqual({});
  expect(await store.getCursor()).toBe(-1n);
  expect(store.kv.size).toBe(0);
});

test("REG-05 a retry after a failed tick converges to the uninterrupted result", async () => {
  const chain = new FakeChain();
  const flaky = new FlakyStore();
  const clean = new HolderStore();
  mine(
    chain,
    [{ from: ZERO, to: alice, value: 100n }],
    [{ from: alice, to: bob, value: 40n }],
    [{ from: bob, to: ZERO, value: 15n }],
  );
  flaky.failSetCursorOnce = true;
  const listener = new Listener(chain, flaky, 0n);

  await expect(listener.sync()).rejects.toThrow();
  await listener.sync(); // retry succeeds
  await new Listener(chain, clean, 0n).sync();

  expect(await state(flaky)).toEqual(await state(clean));
  expect(await flaky.snapshot()).toEqual({ [alice]: "60", [bob]: "25" });
});

test("REG-05 a failed later tick keeps the earlier published state intact", async () => {
  const chain = new FakeChain();
  const store = new FlakyStore();
  const listener = new Listener(chain, store, 0n);
  mine(chain, [{ from: ZERO, to: alice, value: 100n }]);
  await listener.sync();
  const published = await state(store);
  mine(chain, [{ from: alice, to: bob, value: 40n }]);
  store.failSetCursorOnce = true;

  await expect(listener.sync()).rejects.toThrow();

  expect(await state(store)).toEqual(published);
});

// ---------------------------------------------------------------- REG-06 (accounting)

test("REG-06 balances above Number.MAX_SAFE_INTEGER stay exact through accounting", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const big = 9_007_199_254_740_993n; // MAX_SAFE_INTEGER + 2
  mine(
    chain,
    [{ from: ZERO, to: alice, value: big * 1_000n + 7n }],
    [{ from: alice, to: bob, value: big }],
    [{ from: alice, to: bob, value: 1n }],
  );

  await new Listener(chain, store, 0n).sync();

  expect(await store.getBalance(bob)).toBe(big + 1n);
  expect(await store.getBalance(alice)).toBe(big * 999n + 6n);
  expect(await store.getBalance(alice)).not.toBe(BigInt(Number(big * 999n + 6n)));
});

test("REG-06 18-decimal token amounts add up to the base unit", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const one = 10n ** 18n;
  mine(chain, [{ from: ZERO, to: alice, value: 1_000_000n * one + 1n }], [{ from: alice, to: bob, value: 1n }]);

  await new Listener(chain, store, 0n).sync();

  expect(await store.getBalance(alice)).toBe(1_000_000n * one);
  expect(await store.getBalance(bob)).toBe(1n);
});

// ---------------------------------------------------------------- REG-07

test("REG-07 the cursor is the last eligible block, never the observed head", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  mine(
    chain,
    [{ from: ZERO, to: alice, value: 1n }],
    [{ from: ZERO, to: alice, value: 1n }],
    [{ from: ZERO, to: alice, value: 1n }],
    [{ from: ZERO, to: alice, value: 1n }],
    [{ from: ZERO, to: alice, value: 1n }],
  );

  await new Listener(chain, store, 3n).sync(); // head 4, finalized 1

  expect(await store.getCursor()).toBe(1n);
  expect(await store.getBalance(alice)).toBe(2n);
});

test("REG-07 an eligible empty range still advances the cursor", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const listener = new Listener(chain, store, 0n);
  mine(chain, [{ from: ZERO, to: alice, value: 5n }]);
  await listener.sync();
  mine(chain, [], [], []); // three empty blocks

  await listener.sync();

  expect(await store.getCursor()).toBe(3n);
  expect(await store.snapshot()).toEqual({ [alice]: "5" });
});

test("REG-07 a failed tick cannot advance the cursor", async () => {
  const chain = new FakeChain();
  const store = new FlakyStore();
  const listener = new Listener(chain, store, 0n);
  mine(chain, [{ from: ZERO, to: alice, value: 5n }]);
  await listener.sync();
  mine(chain, [], [{ from: alice, to: bob, value: 1n }]);
  store.failSetBalanceAfter = 0;

  await expect(listener.sync()).rejects.toThrow();

  expect(await store.getCursor()).toBe(0n);
  await listener.sync();
  expect(await store.getCursor()).toBe(2n);
});

test("REG-07 the cursor advances stepwise as blocks become eligible", async () => {
  const chain = new FakeChain();
  const store = new HolderStore();
  const listener = new Listener(chain, store, 2n);
  mine(chain, [{ from: ZERO, to: alice, value: 1n }], [], []);
  await listener.sync();
  expect(await store.getCursor()).toBe(0n);

  mine(chain, []);
  await listener.sync();
  expect(await store.getCursor()).toBe(1n);

  mine(chain, [], []);
  await listener.sync();
  expect(await store.getCursor()).toBe(3n);
});