# PowerShell script to automate ZK-SNARK compilation, setup, proving, and verification with SnarkJS (Groth16)

$ErrorActionPreference = "Stop"

Write-Host "=== 1. Cleaning up previous build artifacts ===" -ForegroundColor Cyan
$filesToClean = @(
    "circ.r1cs", "circ.sym", "witness.wtns", "pot12_0000.ptau", "pot12_0001.ptau", 
    "pot12_final.ptau", "circ_0000.zkey", "circ_final.zkey", "verification_key.json", 
    "proof.json", "public.json"
)
foreach ($file in $filesToClean) {
    if (Test-Path $file) {
        Remove-Item $file -Force
    }
}
if (Test-Path "circ_js") {
    Remove-Item "circ_js" -Recurse -Force
}

Write-Host "=== 2. Compiling the circuit ===" -ForegroundColor Cyan
# Compiles to generate circ.r1cs, circ.sym and the circ_js directory (containing circ.wasm)
& circom circ.circom --r1cs --wasm --sym
if ($LASTEXITCODE -ne 0) { throw "circom compilation failed!" }

Write-Host "=== 3. Generating the witness ===" -ForegroundColor Cyan
# Uses node and the generated JS/WASM code to compute the witness from input.json
& node circ_js/generate_witness.js circ_js/circ.wasm input.json witness.wtns
if ($LASTEXITCODE -ne 0) { throw "witness generation failed!" }

Write-Host "=== 4. Starting Powers of Tau (Phase 1 Ceremony) ===" -ForegroundColor Cyan
# Create a new powers of tau ceremony
& snarkjs powersoftau new bn128 12 pot12_0000.ptau -v
# Contribute to the ceremony
& snarkjs powersoftau contribute pot12_0000.ptau pot12_0001.ptau --name="Contributor 1" -v -e="some random text"
# Prepare phase 2
& snarkjs powersoftau prepare phase2 pot12_0001.ptau pot12_final.ptau -v

Write-Host "=== 5. Performing Circuit-Specific Setup (Phase 2) ===" -ForegroundColor Cyan
# Setup zkey for Groth16
& snarkjs groth16 setup circ.r1cs pot12_final.ptau circ_0000.zkey
# Contribute to the zkey
& snarkjs zkey contribute circ_0000.zkey circ_final.zkey --name="Contributor 1" -v -e="some random text"
# Export verification key
& snarkjs zkey export verificationkey circ_final.zkey verification_key.json

Write-Host "=== 6. Generating the Proof ===" -ForegroundColor Cyan
# Prove the witness
& snarkjs groth16 prove circ_final.zkey witness.wtns proof.json public.json

Write-Host "=== 7. Verifying the Proof ===" -ForegroundColor Cyan
# Verify the generated proof
& snarkjs groth16 verify verification_key.json public.json proof.json

Write-Host "`nZK-SNARK pipeline completed successfully!" -ForegroundColor Green
