#!/usr/bin/env bash

# Bash script to automate ZK-SNARK compilation, setup, proving, and verification with SnarkJS (Groth16)
set -e

echo -e "\e[36m=== 1. Cleaning up previous build artifacts ===\e[0m"
rm -rf circ.r1cs circ.sym witness.wtns pot12_0000.ptau pot12_0001.ptau \
       pot12_final.ptau circ_0000.zkey circ_final.zkey verification_key.json \
       proof.json public.json circ_js

echo -e "\e[36m=== 2. Compiling the circuit ===\e[0m"
# Compiles to generate circ.r1cs, circ.sym and the circ_js directory (containing circ.wasm)
circom circ.circom --r1cs --wasm --sym

echo -e "\e[36m=== 3. Generating the witness ===\e[0m"
# Uses node and the generated JS/WASM code to compute the witness from input.json
node circ_js/generate_witness.js circ_js/circ.wasm input.json witness.wtns

echo -e "\e[36m=== 4. Starting Powers of Tau (Phase 1 Ceremony) ===\e[0m"
# Create a new powers of tau ceremony
snarkjs powersoftau new bn128 12 pot12_0000.ptau -v
# Contribute to the ceremony
snarkjs powersoftau contribute pot12_0000.ptau pot12_0001.ptau --name="Contributor 1" -v -e="some random text"
# Prepare phase 2
snarkjs powersoftau prepare phase2 pot12_0001.ptau pot12_final.ptau -v

echo -e "\e[36m=== 5. Performing Circuit-Specific Setup (Phase 2) ===\e[0m"
# Setup zkey for Groth16
snarkjs groth16 setup circ.r1cs pot12_final.ptau circ_0000.zkey
# Contribute to the zkey
snarkjs zkey contribute circ_0000.zkey circ_final.zkey --name="Contributor 1" -v -e="some random text"
# Export verification key
snarkjs zkey export verificationkey circ_final.zkey verification_key.json

echo -e "\e[36m=== 6. Generating the Proof ===\e[0m"
# Prove the witness
snarkjs groth16 prove circ_final.zkey witness.wtns proof.json public.json

echo -e "\e[36m=== 7. Verifying the Proof ===\e[0m"
# Verify the generated proof
snarkjs groth16 verify verification_key.json public.json proof.json

echo -e "\n\e[32mZK-SNARK pipeline completed successfully!\e[0m"
