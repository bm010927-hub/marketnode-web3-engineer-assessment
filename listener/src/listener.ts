import { FakeChain } from "./fakeChain.js";
import { HolderStore } from "./store.js";
import { ZERO_ADDRESS } from "./types.js";

function logKey(blockNumber: bigint, txHash: string, logIndex: number): string {
  return `transfer:${blockNumber.toString()}:${logIndex}:${txHash}`;
}

/** Polls Transfer logs and projects holder balances into the supplied store. */
export class Listener {
  private readonly confirmations: bigint;

  constructor(
    private readonly chain: FakeChain,
    private readonly store: HolderStore,
    confirmations: bigint = 2n,
  ) {
    if (typeof confirmations !== "bigint" || confirmations < 0n) {
      throw new RangeError("confirmations must be a non-negative bigint");
    }
    this.confirmations = confirmations;
  }

  async sync(): Promise<void> {
    const head = await this.chain.getHead();
    const finalized = head - this.confirmations;
    const cursor = await this.store.getCursor();
    if (finalized <= cursor) return; // nothing newly eligible (also covers an empty chain)

    const from = cursor + 1n;
    const logs = await this.chain.getLogs(from, finalized);

    await this.store.transaction(async () => {
      for (const log of logs) {
        // Check the block range is this within eligible
        if (log.blockNumber < from || log.blockNumber > finalized) continue;

        const appliedKey = logKey(log.blockNumber, log.txHash, log.logIndex);
        if (this.store.kv.has(appliedKey)) continue;

        if (log.from !== ZERO_ADDRESS) {
          const balance = await this.store.getBalance(log.from);
          await this.store.setBalance(log.from, balance - log.value);
        }
        if (log.to !== ZERO_ADDRESS) {
          const balance = await this.store.getBalance(log.to);
          await this.store.setBalance(log.to, balance + log.value);
        }

        this.store.kv.set(appliedKey, "1");
      }

      // The cursor is the last eligible block, even when its range held no logs.
      await this.store.setCursor(finalized);
    });
  }
}
