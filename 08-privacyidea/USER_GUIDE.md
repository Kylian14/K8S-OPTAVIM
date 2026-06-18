# User guide — Enable TOTP MFA for the OPTAVIM VPN

For security reasons, the OPTAVIM VPN now requires **two-factor authentication (MFA)**: your usual AD password **AND** a 6-digit code generated every 30 seconds by a mobile app.

Without enabling this, **you will no longer be able to connect to the VPN** after `<DATE_CUTOVER>`.

Enabling it takes **~5 minutes** and is done **only once**.

---

## Step 1 — Install an authenticator on your phone

Choose **only one** of the following apps (all free, standard TOTP compatible):

| App | iOS | Android | Recommendation |
|---|---|---|---|
| **Microsoft Authenticator** | ✅ | ✅ | Recommended (already used by some for M365 SSO) |
| **Google Authenticator** | ✅ | ✅ | Simple, no cloud |
| **Authy** | ✅ | ✅ | Multi-device sync (useful if you change phones) |
| **Aegis** (Android) | ❌ | ✅ | Open source, local export |

Download the app from the App Store / Play Store and open it.

---

## Step 2 — Enroll your TOTP token on the portal

1. **Connect to the OPTAVIM LAN** (at the office, or via an existing VPN if you still have access)
2. Open in a browser: **https://mfa.optavim.corp/**
3. If you see a certificate warning → "Continue" (the cert is signed by our internal OPTAVIM CA)
4. On the privacyIDEA login page:
   - **Username**: your AD login (e.g. `kylian.nezan`)
   - **Password**: your usual AD password
   - Leave **Realm** empty
   - Click **Login**
5. In the top menu bar, click **`Tokens`**
6. Click **`Enroll a new token`** in the left menu
7. Choose:
   - **Token type**: **`TOTP`** ⚠️ *(important: not HOTP)*
   - **Description**: `My phone` (or whatever you want)
   - Leave the other fields at their defaults (algorithm SHA1, period 30s, length 6)
8. Click **`Enroll a new token`** at the bottom
9. **A page with a QR code appears**:
   - Open your authenticator app on your phone
   - Choose **"Add an account"** → **"Scan a QR code"** (or "+" then camera)
   - Scan the QR code on screen with the camera
   - Your app now shows a 6-digit code that changes every 30 seconds
10. **Mandatory test before closing the window**:
    - On the privacyIDEA web page, at the bottom, find **"Test OTP only"**
    - Type the **6 digits** shown on your phone into this field
    - Click **`Test OTP only`**
    - You must see **`The OTP token is correct`** *(if "wrong otp value" → retry with a fresher code)*

✅ If the test is OK → your token is enrolled and working.

⚠️ If it fails after several attempts → open a helpdesk ticket with the token serial (e.g. `TOTP00007FB4`) shown on the page

---

## Step 3 — Install the VPN client on your computer

### macOS

1. Download **Tunnelblick**: https://tunnelblick.net/downloads.html
2. Install the `.dmg`
3. Request the config file `Optavim.ovpn` from IT (sent by email / internal link)
4. **Double-click** `Optavim.ovpn` → Tunnelblick installs it automatically

### Windows

1. Download **OpenVPN GUI**: https://openvpn.net/community-downloads/
2. Install (option: "OpenVPN" is enough, "VPN" services optional)
3. Request the `Optavim.ovpn` file from IT
4. Copy `Optavim.ovpn` into `C:\Users\<you>\OpenVPN\config\`
5. Launch **OpenVPN GUI** from the Start menu (systray icon)

### Linux

```bash
sudo apt install openvpn network-manager-openvpn-gnome
nmcli connection import type openvpn file Optavim.ovpn
```

### iOS / Android

1. Install **OpenVPN Connect** from the App/Play Store
2. Receive the `.ovpn` by email or AirDrop
3. Open the file with OpenVPN Connect → "Import"

---

## Step 4 — Connect

Whatever the OpenVPN client, you will enter 2 (or 3) pieces of info:

| Field | What to type |
|---|---|
| **Username** | Your AD login (e.g. `kylian.nezan`) |
| **Password** | Your AD password **directly followed by** the 6 TOTP digits from your app, **with no space** |
| **Security code / Token** *(if present)* | Leave **empty** or disable the option |

### Concrete example

If your AD password is `MaSuperSecure!23` and your authenticator shows `849275`, you type into **Password**:

```
MaSuperSecure!23849275
```

→ 22 characters in total. **No space, no `:` or other separator.**

⚠️ **The TOTP code expires every 30 seconds**: type it quickly after reading it, or wait for a new one to start so you have a full 30s.

Click **Connect**.

---

## Step 5 — Verify it works

Once connected (green Tunnelblick icon / "Connected" message):

- Open a browser and go to **https://cloud.optavim.corp/**
- You should see the OPTAVIM Nextcloud page
- No Nextcloud page → contact IT

---

## FAQ

### I lost my phone

Contact IT. They delete your token on the server side and re-invite you to enroll a new phone.

### I am changing phones

Before the change: open `https://mfa.optavim.corp/`, delete your old token, enroll your new phone.

If you no longer have access to the old one: contact IT for a reset.

### The TOTP code is rejected every time

Possible causes:
- Your phone's clock is out of sync → go to Settings → Date & Time → enable "Automatic"
- The token is HOTP instead of TOTP → re-enroll with the correct type
- Failure counter exceeded (10 failed attempts) → contact IT for a reset

### I am locked out and IT is not responding

If you already have an existing VPN that works without MFA, use it to reach `https://mfa.optavim.corp` and enroll. If you are truly outside with no access at all: helpdesk or support phone.

### Do I need to re-enroll my existing Keycloak TOTP?

No. The Keycloak TOTP (for the `auth/cloud/erp/grafana/wazuh.optavim.corp` web apps) stays separate for now. You will have **2 entries in your authenticator** during the transition phase.

A unification is planned for Q3/Q4 (a single TOTP secret for VPN + web apps).

---

## Support

| Topic | Contact |
|---|---|
| Lost token / MFA reset | helpdesk@optavim.corp |
| OpenVPN client install issue | helpdesk@optavim.corp |
| Invalid portal TLS cert | it-network@optavim.corp |
| Cutover cancellation / delay | IT manager |
