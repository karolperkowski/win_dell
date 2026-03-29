# WinDeploy GPG Signing Setup
# Run this on YOUR machine (not in CI, not shared anywhere)
# Requires: gpg (Git for Windows includes it, or install Gpg4win)

# ---------------------------------------------------------------------------
# Step 1: Generate the key (run interactively on your machine)
# ---------------------------------------------------------------------------
# gpg --full-generate-key
# Choose:
#   Kind: RSA and RSA (option 1)
#   Size: 4096
#   Expiry: 2y  (rotate every 2 years)
#   Name: WinDeploy Signing
#   Email: deploy@yourdomain.com (doesn't need to be real)
#   Comment: win_dell manifest signing

# ---------------------------------------------------------------------------
# Step 2: Get your key ID
# ---------------------------------------------------------------------------
# gpg --list-secret-keys --keyid-format LONG

# Output looks like:
# sec   rsa4096/ABCD1234EFGH5678 2024-01-15 [SC] [expires: 2026-01-15]
#                                ^^^^^^^^^^^^^^^^ <- this is your key ID

# ---------------------------------------------------------------------------
# Step 3: Export the PUBLIC key (safe to share / embed in install.ps1)
# ---------------------------------------------------------------------------
# gpg --armor --export ABCD1234EFGH5678 > windeploy_public.asc

# ---------------------------------------------------------------------------
# Step 4: Export the PRIVATE key for GitHub Actions secret
# ---------------------------------------------------------------------------
# gpg --armor --export-secret-keys ABCD1234EFGH5678 > windeploy_private.asc
# cat windeploy_private.asc
# -> Copy this entire output into GitHub secret: GPG_PRIVATE_KEY
# -> Set passphrase in GitHub secret: GPG_PASSPHRASE
# -> Delete windeploy_private.asc afterwards: del windeploy_private.asc

# ---------------------------------------------------------------------------
# Step 5: Add to GitHub Secrets
# ---------------------------------------------------------------------------
# https://github.com/karolperkowski/win_dell/settings/secrets/actions
#
# GPG_PRIVATE_KEY  = (paste full -----BEGIN PGP PRIVATE KEY BLOCK----- output)
# GPG_PASSPHRASE   = (your key passphrase)

# ---------------------------------------------------------------------------
# Step 6: Embed public key in install.ps1
# ---------------------------------------------------------------------------
# Replace the $MANIFEST_SIGNING_KEY HMAC approach with:
# $GPG_PUBLIC_KEY = @"
# -----BEGIN PGP PUBLIC KEY BLOCK-----
# (paste your public key here)
# -----END PGP PUBLIC KEY BLOCK-----
# "@
