// SPDX-License-Identifier: MIT
/**
 * ethers v6 wrapper around CompressedOracleV1.
 *
 * Push path: the contract has NO push function selector — raw calldata is sent to the
 * contract address and lands in its fallback().
 *
 * Wire format: ONE leading zero byte, then N x 32-byte slot
 * words — total length `1 + 32N`, so the payload after the prefix is a non-zero
 * multiple of 32. The prefix exists so a push can never be dispatched as a function
 * call: without it, a slot word whose top 4 bytes happened to equal an exposed
 * selector would be routed into that function and the update SILENTLY LOST while the
 * transaction still succeeded. Do not drop the prefix — an unprefixed push
 * reverts `BadCalldataLength`.
 *
 * The sender pushes into namespaceRemapping[sender], falling back to its own
 * namespace (zero-setup default). Stale words (timestamp not strictly newer) are
 * SILENTLY ignored — verify with readOracleData when it matters.
 *
 * Signature paths mirror the contract exactly:
 *  - allowPushers consent: EIP-191 personal-sign over
 *      keccak256(abi.encode(chainid, oracle, deadline, pusher, creator))     (signed by the PUSHER)
 *  - updateBySignature:    EIP-191 personal-sign over
 *      keccak256(abi.encode(chainid, oracle, creator, slotWord))             (signed by the CREATOR)
 *
 * Purpose: give scripts a typed, ethers-native surface (reads via a
 * `Provider`, writes via a `Wallet`) over the 9 functions of
 * `CompressedOracleV1`'s Solidity ABI, plus the two off-chain digest/signing
 * helpers the delegation and signed-update flows need.
 *
 * What happens inside: `COMPRESSED_ORACLE_ABI` is a plain array of
 * human-readable Solidity signatures — ethers' `Contract`/`Interface` parse
 * these directly (no extra ABI-parsing wrapper needed). Every write path
 * builds a `new Contract(oracle, ABI, wallet)` (or, for the raw calldata
 * push, calls `wallet.sendTransaction` directly since there is no function
 * selector to target) and funnels the result through `sendAndWait`, which
 * awaits the tx then asserts `receipt.status === 1`. Every read path builds
 * `new Contract(oracle, ABI, provider)` — no wallet/signer involved.
 * Struct-typed returns (`getOracleData`) come back as an ethers `Result`
 * with BOTH indexed and named field access; this file destructures by name.
 *
 * NOTE on number vs. bigint: ethers v6 decodes every ABI int/uint width
 * (uint16 included) as `bigint` — there is no automatic narrowing to plain
 * `number` for small widths. `readOracleData` explicitly `Number()`-narrows
 * the two uint16 spread fields so downstream code (scripts, tests) that
 * compares them against plain number literals keeps working unchanged;
 * `price` (uint64) and `min`/`max` (uint128) stay `bigint` since those need
 * full precision and were already treated as `bigint` by callers.
 *
 * Inputs/outputs/env: every exported function takes a `Clients` (see
 * `../common/clients.ts`) plus the oracle address and function-specific
 * arguments; writes additionally require `clients.wallet` to be non-null
 * (`requireWallet` throws a clear error otherwise). No env vars are read
 * directly here.
 *
 * Place in the package: this is the compressed-lane equivalent of
 * `../pyth/oracle.ts`; every `scripts/0x-*.ts` file and
 * `demo/assert-stale-ignored.ts` calls into this module rather than talking
 * to ethers primitives directly.
 */
import {
  AbiCoder,
  Contract,
  concat,
  getBytes,
  keccak256,
  type ContractTransactionReceipt,
  type Provider,
  type TransactionReceipt,
  type Wallet,
} from 'ethers';
import type { Clients } from '../common/clients.js';
import type { Address, Hex } from '../common/types.js';

export const COMPRESSED_ORACLE_ABI = [
  'function feedIdOf(address creator, uint8 slotIndex, uint8 positionIndex) view returns (bytes32)',
  'function getOracleData(bytes32 feedId) view returns ((uint64 price, uint16 spread0, uint16 spread1, uint56 timestampMs))',
  'function priceGuard(bytes32 feedId) view returns (uint128 min, uint128 max)',
  'function namespaceRemapping(address pusher) view returns (address creator)',
  'function allowPushers(uint256 deadline, address[] pushers, bytes[] signatures)',
  'function removePushers(address[] pushers)',
  'function revokePusher()',
  'function setPriceGuard(bytes32 feedId, uint128 minPrice, uint128 maxPrice)',
  'function updateBySignature(address feedCreator, uint256 newSlotValue, bytes signature) returns (bool)',
] as const;

const abiCoder = AbiCoder.defaultAbiCoder();

function requireWallet(clients: Clients): { wallet: Wallet } {
  if (!clients.wallet) throw new Error('a private key is required for this operation');
  return { wallet: clients.wallet };
}

/** Awaits a sent tx, then asserts success — shared by every write path below. */
async function sendAndWait<R extends { status: number | null; hash: string }>(
  tx: Promise<{ hash: string; wait(): Promise<R | null> }>,
): Promise<R> {
  const sent = await tx;
  const receipt = await sent.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`transaction ${sent.hash} reverted`);
  return receipt;
}

/* ── digests & signing ── */

export function pusherConsentDigest(
  chainId: bigint,
  oracle: Address,
  deadline: bigint,
  pusher: Address,
  creator: Address,
): Hex {
  return keccak256(
    abiCoder.encode(
      ['uint256', 'address', 'uint256', 'address', 'address'],
      [chainId, oracle, deadline, pusher, creator],
    ),
  ) as Hex;
}

export function slotUpdateDigest(
  chainId: bigint,
  oracle: Address,
  creator: Address,
  word: bigint,
): Hex {
  return keccak256(
    abiCoder.encode(['uint256', 'address', 'address', 'uint256'], [chainId, oracle, creator, word]),
  ) as Hex;
}

/** EIP-191 personal-sign of a 32-byte digest — matches toEthSignedMessageHash + ECDSA.recover. */
export function signDigest(wallet: Wallet, digest: Hex): Promise<Hex> {
  return wallet.signMessage(getBytes(digest)) as Promise<Hex>;
}

/* ── writes ── */

export function pushSlots(
  clients: Clients,
  oracle: Address,
  words: Hex[],
): Promise<TransactionReceipt> {
  if (words.length === 0) throw new Error('pushSlots: no words');
  const { wallet } = requireWallet(clients);
  // Leading zero byte: the push is the contract's raw-calldata fallback, and a first 4 bytes that
  // happen to match a function selector would dispatch to that function instead. No selector starts
  // with 0x00, so the prefix forces the fallback for any word content. Calldata = 0x00 + N×32 bytes.
  return sendAndWait<TransactionReceipt>(
    wallet.sendTransaction({ to: oracle, data: concat(['0x00', ...words]) }),
  );
}

export function allowPushers(
  clients: Clients,
  oracle: Address,
  deadline: bigint,
  pushers: Address[],
  signatures: Hex[],
): Promise<ContractTransactionReceipt> {
  const { wallet } = requireWallet(clients);
  const contract = new Contract(oracle, COMPRESSED_ORACLE_ABI, wallet);
  return sendAndWait<ContractTransactionReceipt>(
    contract.allowPushers(deadline, pushers, signatures),
  );
}

/** Simulates first (staticCall): a stale word returns { accepted: false } without spending gas. */
export async function updateBySignature(
  clients: Clients,
  oracle: Address,
  creator: Address,
  word: bigint,
  signature: Hex,
): Promise<{ accepted: boolean; receipt: ContractTransactionReceipt | null }> {
  const { wallet } = requireWallet(clients);
  const contract = new Contract(oracle, COMPRESSED_ORACLE_ABI, wallet);
  const result = (await contract.updateBySignature.staticCall(creator, word, signature)) as boolean;
  if (!result) return { accepted: false, receipt: null };
  const receipt = await sendAndWait<ContractTransactionReceipt>(
    contract.updateBySignature(creator, word, signature),
  );
  return { accepted: true, receipt };
}

export function setPriceGuard(
  clients: Clients,
  oracle: Address,
  feedId: Hex,
  min: bigint,
  max: bigint,
): Promise<ContractTransactionReceipt> {
  const { wallet } = requireWallet(clients);
  const contract = new Contract(oracle, COMPRESSED_ORACLE_ABI, wallet);
  return sendAndWait<ContractTransactionReceipt>(contract.setPriceGuard(feedId, min, max));
}

/* ── reads (all open, permissionless views on the compressed oracle) ── */

export async function readOracleData(provider: Provider, oracle: Address, feedId: Hex) {
  const contract = new Contract(oracle, COMPRESSED_ORACLE_ABI, provider);
  const d = await contract.getOracleData(feedId);
  return {
    price: d.price as bigint,
    // uint16 on the wire: ethers decodes as bigint, narrow to number to match
    // the <=48-bit behavior the rest of the package (and its tests) rely on.
    spread0: Number(d.spread0),
    spread1: Number(d.spread1),
    timestampMs: BigInt(d.timestampMs),
  };
}

export async function readPriceGuard(provider: Provider, oracle: Address, feedId: Hex) {
  const contract = new Contract(oracle, COMPRESSED_ORACLE_ABI, provider);
  const g = await contract.priceGuard(feedId);
  return { min: g.min as bigint, max: g.max as bigint };
}

export async function readFeedIdOf(
  provider: Provider,
  oracle: Address,
  creator: Address,
  slotIndex: number,
  positionIndex: number,
): Promise<Hex> {
  const contract = new Contract(oracle, COMPRESSED_ORACLE_ABI, provider);
  return (await contract.feedIdOf(creator, slotIndex, positionIndex)) as Hex;
}

export async function readNamespaceRemapping(
  provider: Provider,
  oracle: Address,
  pusher: Address,
): Promise<Address> {
  const contract = new Contract(oracle, COMPRESSED_ORACLE_ABI, provider);
  return (await contract.namespaceRemapping(pusher)) as Address;
}
