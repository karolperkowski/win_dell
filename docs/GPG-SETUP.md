# GPG Signing Setup

WinDeploy uses GPG asymmetric signing for manifest integrity. The private key signs the manifest in CI; the public key is embedded in `install.ps1` to verify before downloading anything.

---

## Prerequisites

GPG is included with Git for Windows. Verify it is available:

```powershell
gpg --version
```

If missing, install [Gpg4win](https://www.gpg4win.org/).

---

## Step 1 — Generate the key pair

Run on **your own machine** — never generate private keys in CI or in a chat session.

```bash
gpg --full-generate-key
```

At the prompts choose:
- Kind: **RSA and RSA** (option 1)
- Size: **4096**
- Expiry: **2y** (rotate every 2 years)
- Name: `WinDeploy Signing`
- Email: `deploy@yourdomain.com` (does not need to be a real address)
- Comment: `win_dell manifest signing`
- Passphrase: choose a strong passphrase and store it in a password manager

---

## Step 2 — Find your key ID

```bash
gpg --list-secret-keys --keyid-format LONG
```

Output:
```
sec   rsa4096/ABCD1234EFGH5678 2025-01-15 [SC] [expires: 2027-01-15]
                               ^^^^^^^^^^^^^^^^
                               This is your key ID
```

---

## Step 3 — Export the public key

The public key is safe to share and goes into `install.ps1`.

```bash
gpg --armor --export ABCD1234EFGH5678
```

Copy the full output including the `-----BEGIN PGP PUBLIC KEY BLOCK-----` header and footer. Paste it into `install.ps1` at the `$GPG_PUBLIC_KEY` variable.

---

## Step 4 — Export the private key for GitHub Actions

```bash
gpg --armor --export-secret-keys ABCD1234EFGH5678 > windeploy_private.asc
cat windeploy_private.asc
```

Copy the full output. Then **delete the exported file**:

```bash
del windeploy_private.asc   # Windows
rm windeploy_private.asc    # bash
```

---

## Step 5 — Add GitHub Secrets

Go to: `https://github.com/karolperkowski/win_dell/settings/secrets/actions`

Add two secrets:

| Name | Value |
|---|---|
| `GPG_PRIVATE_KEY` | Full `-----BEGIN PGP PRIVATE KEY BLOCK-----` block |
| `GPG_PASSPHRASE` | The passphrase you chose in Step 1 |

Remove the old `MANIFEST_SIGNING_KEY` secret if it exists — it is no longer used.

---

## Step 6 — Update install.ps1

Open `install.ps1` and replace the `$GPG_PUBLIC_KEY` placeholder:

```powershell
$GPG_PUBLIC_KEY = @'
-----BEGIN PGP PUBLIC KEY BLOCK-----

(paste your public key here)
-----END PGP PUBLIC KEY BLOCK-----
'@
```

Commit and push. The next CI run will produce a properly GPG-signed `manifest.sig`.

---

## Key rotation

When your key expires or you need to rotate:

1. Generate a new key pair (Step 1–2 above)
2. Update `GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` in GitHub Secrets
3. Update `$GPG_PUBLIC_KEY` in `install.ps1`
4. Push — CI will use the new key immediately

Old installs using the previous public key will fail verification until they re-run `irm ... | iex` and pick up the new public key embedded in `install.ps1`.

---

## Verifying locally

To verify a manifest signature on your own machine:

```bash
# Import the public key
gpg --import windeploy_public.asc

# Verify
gpg --verify manifest.sig manifest.json
```

Expected output:
```
gpg: Signature made <date>
gpg:                using RSA key ABCD1234EFGH5678
gpg: Good signature from "WinDeploy Signing <deploy@yourdomain.com>"
```
