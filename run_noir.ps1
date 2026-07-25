# PowerShell script to automate Noir circuit compilation, witness generation, and verification

$ErrorActionPreference = "Stop"

Write-Host "=== 1. Checking Noir Circuit ===" -ForegroundColor Cyan
& nargo check

Write-Host "=== 2. Compiling Circuit & Generating Witness ===" -ForegroundColor Cyan
& nargo execute witness

Write-Host "=== 3. Exporting Proof & Verification Key with Barretenberg ===" -ForegroundColor Cyan
& bb prove -b ./target/dark_pool.json -w ./target/witness.gz -o ./target/proof
& bb write_vk -b ./target/dark_pool.json -o ./target/vk

Write-Host "=== 4. Verifying Proof ===" -ForegroundColor Cyan
& bb verify -p ./target/proof -k ./target/vk

Write-Host "`nNoir ZK pipeline completed successfully!" -ForegroundColor Green
