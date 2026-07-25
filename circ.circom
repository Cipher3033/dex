pragma circom 2.0.0;

include "node_modules/circomlib/circuits/poseidon.circom";
include "node_modules/circomlib/circuits/comparators.circom";
include "node_modules/circomlib/circuits/bitify.circom";
include "node_modules/circomlib/circuits/mux1.circom";

// ─────────────────────────────────────────────────────────────
// UTILITY: RangeCheck
// Proves that `value` fits within `n` bits, i.e. value ∈ [0, 2^n).
// Implicitly rules out negative numbers in the finite field.
// ─────────────────────────────────────────────────────────────
template RangeCheck(n) {
    signal input value;

    component bits = Num2Bits(n);
    bits.in <== value;
    // If decomposition succeeds, the value is in range — no extra output needed.
}

// ─────────────────────────────────────────────────────────────
// UTILITY: PoseidonCommit
// Computes commitment = Poseidon(secret, salt).
// Used to bind a trader to their input amount without revealing it.
// ─────────────────────────────────────────────────────────────
template PoseidonCommit() {
    signal input secret;
    signal input salt;
    signal output commitment;

    component h = Poseidon(2);
    h.inputs[0] <== secret;
    h.inputs[1] <== salt;
    commitment  <== h.out;
}

// ─────────────────────────────────────────────────────────────
// UTILITY: NullifierDerive
// Derives nullifier = Poseidon(secret) to prevent double-spending.
// The nullifier is posted on-chain so the same commitment cannot
// be used twice, without linking it back to the secret.
// ─────────────────────────────────────────────────────────────
template NullifierDerive() {
    signal input secret;
    signal output nullifier;

    component h = Poseidon(1);
    h.inputs[0] <== secret;
    nullifier   <== h.out;
}

// ─────────────────────────────────────────────────────────────
// CORE: MerkleProof
// Proves that `leaf` is included in the Merkle tree whose root
// is `root`, using a Poseidon hash function at every level.
// pathIndices[i] == 0 means the sibling is on the right; 1 means left.
// ─────────────────────────────────────────────────────────────
template MerkleProof(levels) {
    signal input leaf;
    signal input pathElements[levels];
    signal input pathIndices[levels];
    signal output root;

    component hashers[levels];
    component mux[levels];
    signal levelHashes[levels + 1];
    levelHashes[0] <== leaf;

    for (var i = 0; i < levels; i++) {
        // pathIndices must be binary
        pathIndices[i] * (1 - pathIndices[i]) === 0;

        mux[i] = MultiMux1(2);
        // sel=0 → (current, sibling); sel=1 → (sibling, current)
        mux[i].c[0][0] <== levelHashes[i];
        mux[i].c[0][1] <== pathElements[i];
        mux[i].c[1][0] <== pathElements[i];
        mux[i].c[1][1] <== levelHashes[i];
        mux[i].s       <== pathIndices[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== mux[i].out[0];
        hashers[i].inputs[1] <== mux[i].out[1];
        levelHashes[i + 1]   <== hashers[i].out;
    }

    root <== levelHashes[levels];
}

// ─────────────────────────────────────────────────────────────
// CORE: AMMInvariantCheck
// Proves the constant-product formula holds after a swap,
// including a trading fee, WITHOUT revealing reserve or delta values.
//
// Standard formula (Uniswap v2 style):
//   (reserve_x + Δx · fee_num / fee_den) · (reserve_y − Δy) ≥ reserve_x · reserve_y
//
// Cross-multiplied to avoid division in-circuit:
//   (reserve_x · fee_den + Δx · fee_num) · (reserve_y − Δy) ≥ reserve_x · reserve_y · fee_den
//
// Constraints proven:
//   1. reserve_y > Δy  (pool cannot be drained)
//   2. AMM invariant holds with fee
// ─────────────────────────────────────────────────────────────
template AMMInvariantCheck(bits) {
    signal input reserve_x;
    signal input reserve_y;
    signal input delta_x;
    signal input delta_y;
    signal input fee_num;   // e.g. 997
    signal input fee_den;   // e.g. 1000

    // Left-hand side factor 1: reserve_x * fee_den + delta_x * fee_num
    signal lhs_a;
    lhs_a <== reserve_x * fee_den + delta_x * fee_num;

    // Pool must not be fully drained: reserve_y > delta_y
    component drain_check = GreaterThan(bits);
    drain_check.in[0] <== reserve_y;
    drain_check.in[1] <== delta_y;
    drain_check.out   === 1;

    // Left-hand side: lhs_a * (reserve_y - delta_y)
    signal net_y;
    net_y <== reserve_y - delta_y;

    signal lhs;
    lhs <== lhs_a * net_y;

    // Right-hand side: reserve_x * reserve_y * fee_den
    signal rhs_a;
    rhs_a <== reserve_x * reserve_y;

    signal rhs;
    rhs <== rhs_a * fee_den;

    // Enforce lhs >= rhs
    component amm_check = GreaterEqThan(bits);
    amm_check.in[0] <== lhs;
    amm_check.in[1] <== rhs;
    amm_check.out   === 1;
}

// ─────────────────────────────────────────────────────────────
// CORE: SlippageGuard
// Proves Δy ≥ min_output without revealing Δy on-chain.
// This is the ZK equivalent of a slippage parameter passed to
// a normal DEX swap — but here the actual output stays private.
// ─────────────────────────────────────────────────────────────
template SlippageGuard(bits) {
    signal input delta_y;
    signal input min_output;

    component gte = GreaterEqThan(bits);
    gte.in[0] <== delta_y;
    gte.in[1] <== min_output;
    gte.out   === 1;
}

// ─────────────────────────────────────────────────────────────
// MAIN: DarkPoolSwap
//
// Proves, in zero knowledge, that:
//   (1) The swap satisfies the AMM constant-product invariant with fee.
//   (2) The received output meets the trader's minimum (slippage protection).
//   (3) All amounts are within a valid bit-width (no overflow / negative).
//   (4) The trader owns a valid input commitment (Pedersen-style via Poseidon).
//   (5) A unique nullifier is produced to prevent double-spending.
//   (6) The pool reserves are genuine — proven via a Merkle inclusion proof
//       against the on-chain committed pool state root.
//
// Public inputs  → posted on-chain, visible to all.
// Private inputs → known only to the prover (trader).
// ─────────────────────────────────────────────────────────────
template DarkPoolSwap(merkle_levels, amount_bits) {

    // ── PUBLIC INPUTS ──────────────────────────────────────────
    signal input pool_state_root;            // Merkle root of pool state (on-chain)
    signal input input_commitment;           // Poseidon(secret, salt) — proves ownership
    signal input nullifier_hash;             // Poseidon(secret) — posted to prevent reuse
    signal input min_output;                 // Minimum Δy trader will accept
    signal input fee_num;                    // Fee numerator  (e.g. 997)
    signal input fee_den;                    // Fee denominator (e.g. 1000)

    // ── PRIVATE INPUTS ─────────────────────────────────────────
    signal input reserve_x;                 // Pool token-X reserve
    signal input reserve_y;                 // Pool token-Y reserve
    signal input delta_x;                   // Amount of token-X sold  (hidden)
    signal input delta_y;                   // Amount of token-Y bought (hidden)
    signal input trader_secret;             // Secret scalar known only to trader
    signal input trader_salt;               // Randomness used in commitment
    signal input merkle_path[merkle_levels];    // Sibling hashes along Merkle path
    signal input merkle_indices[merkle_levels]; // 0/1 direction bits along path

    // ── OUTPUT ─────────────────────────────────────────────────
    signal output out_nullifier;             // Exposed nullifier for on-chain recording

    // ── CONSTRAINT 1: AMM Invariant ────────────────────────────
    component amm = AMMInvariantCheck(amount_bits);
    amm.reserve_x <== reserve_x;
    amm.reserve_y <== reserve_y;
    amm.delta_x   <== delta_x;
    amm.delta_y   <== delta_y;
    amm.fee_num   <== fee_num;
    amm.fee_den   <== fee_den;

    // ── CONSTRAINT 2: Slippage Guard ───────────────────────────
    component slip = SlippageGuard(amount_bits);
    slip.delta_y   <== delta_y;
    slip.min_output <== min_output;

    // ── CONSTRAINT 3: Range Checks (overflow / sign safety) ────
    component r_dx = RangeCheck(amount_bits);
    r_dx.value <== delta_x;

    component r_dy = RangeCheck(amount_bits);
    r_dy.value <== delta_y;

    component r_rx = RangeCheck(amount_bits);
    r_rx.value <== reserve_x;

    component r_ry = RangeCheck(amount_bits);
    r_ry.value <== reserve_y;

    // ── CONSTRAINT 4: Input Commitment Verification ────────────
    // Re-derive commitment from the private secret + salt and
    // enforce it equals the publicly posted commitment.
    component commit = PoseidonCommit();
    commit.secret <== trader_secret;
    commit.salt   <== trader_salt;
    input_commitment === commit.commitment;

    // ── CONSTRAINT 5: Nullifier Derivation ─────────────────────
    // Derive the nullifier from the secret and expose it publicly.
    // The on-chain contract records it to block reuse of the same commitment.
    component nul = NullifierDerive();
    nul.secret    <== trader_secret;
    out_nullifier <== nul.nullifier;
    nullifier_hash === out_nullifier;

    // ── CONSTRAINT 6: Pool State Merkle Inclusion Proof ────────
    // Hash the (reserve_x, reserve_y) pair into a leaf and prove
    // it belongs to the committed pool state Merkle tree root.
    component leaf_hash = Poseidon(2);
    leaf_hash.inputs[0] <== reserve_x;
    leaf_hash.inputs[1] <== reserve_y;

    component merkle = MerkleProof(merkle_levels);
    merkle.leaf <== leaf_hash.out;
    for (var i = 0; i < merkle_levels; i++) {
        merkle.pathElements[i] <== merkle_path[i];
        merkle.pathIndices[i]  <== merkle_indices[i];
    }
    pool_state_root === merkle.root;
}

// ─────────────────────────────────────────────────────────────
// Instantiate: 20-level Merkle tree, 64-bit amount range.
// 20 levels supports up to 2^20 ≈ 1 million pool state leaves.
// 64-bit amounts support values up to ~1.8 × 10^19 (sub-wei precision).
// ─────────────────────────────────────────────────────────────
component main {
    public [
        pool_state_root,
        input_commitment,
        nullifier_hash,
        min_output,
        fee_num,
        fee_den
    ]
} = DarkPoolSwap(20, 64);
