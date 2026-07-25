#!/bin/bash
# Script to automate Noir circuit compilation, witness generation, and verification

set -e

echo "=== 1. Checking Noir Circuit ==="
nargo check

echo "=== 2. Compiling Circuit & Generating Witness ==="
nargo execute witness

echo "=== 3. Exporting Proof & Verification Key with Barretenberg ==="
bb prove -b ./target/dark_pool.json -w ./target/witness.gz -o ./target/proof
bb write_vk -b ./target/dark_pool.json -o ./target/vk

echo "=== 4. Verifying Proof ==="
bb verify -p ./target/proof -k ./target/vk

echo ""
echo "Noir ZK pipeline completed successfully!"
