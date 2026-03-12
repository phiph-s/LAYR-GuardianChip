

# Guardian Chip — LAYR NFC Authentication ASIC

AES-128 mutual authentication chip for the [LAYR Open Chip Challenge 25/26](https://github.com/OCDCpro/LAYR).
Taped out in IHP SG13G2 130 nm BiCMOS using the LibreLane open-source ASIC flow.

A full project report is available in [`Paper/main.pdf`](Paper/main.pdf).

**Keywords:** ASIC · NFC · ISO 14443-4 · AES-128 · MFRC522 · APDU · SPI · EEPROM · IHP SG13G2 · LibreLane · SystemVerilog · Verilog

The project contains an Android app, simulating a JavaCard that implements the LAYR-Protocol.
A ready-to-use non-signed APK can be found in `/Android_LAYRSimulator/app/build/outputs/apk/debug/app-debug.apk`

CAD-Files and a ready-to-print 3mf-file for the 3D-printed demonstrator case can be found in `/CAD`

### Key RTL components

| Module | Path | Description |
|--------|------|-------------|
| `mfrc522_apdu_interface.v` | `src/user_rtl/rtl/` | ISO 14443-A/4 card detect + APDU exchange driver for the NXP MFRC522 over SPI |
| `at25010_interface.v` | `src/user_rtl/rtl/` | SPI driver for the Microchip AT25010B 128-byte EEPROM (key + whitelist storage) |
| `aes_iterative.v` | `src/user_rtl/rtl/aes_small/` | Compact iterative AES-128 engine (one round per cycle, Canright S-box) |
| `layr_core.v` | `src/user_rtl/rtl/` | LAYR protocol state machine (AUTH_INIT / AUTH / GET_ID / UNLOCK) |
| `chip_core.sv` | `src/` | Top-level core connecting all modules to the pad ring |

The Canright S-Box was implemented by GitHub-User coruus in [canright-aes-sboxes](https://github.com/coruus/canright-aes-sboxes/) and is included in `/src/user_rtl/ip/canright-aes-sboxes`

---

This repository is based on [Leo's bonus exercises](https://github.com/IHP-GmbH/OCDCPro-padframe/tree/main/24) for the LibreLane
template for SG13G2 process.

# Full chip design using 24 pins padframe

First, install LibreLane by following the Nix-based installation instructions: https://librelane.readthedocs.io/en/latest/installation/nix_installation/index.html

Invoke `nix-shell` the root directory of this repository. That will enable the correct LibreLane version.
Use `make clone-pdk` to clone the required PDK.

Running `make librelane-full-gdsfill-clean` will execute the flow (additional setup needed, see below).

## Metal Density Fill

The default KLayout filler (LibreLane step 63) leaves 13 local density violations (M2Fil.h, M3Fil.h) in high-routing-density areas of M2 and M3. No other metal layers are affected. The PDK filler macro is left at its default parameters.

The following changes resolve all fill-related DRC, density, and Magic DRC violations:

**gdsfill — `gdsfill_config.yaml`**

**gdsfill — changed `venv/.../ihp-sg13g2/prepare.py`**
- Routing keep-out (`MxFil_c`) increased from 0.42 µm to 0.50 µm to account for routing metal straddling tile boundaries

**Violations fixed:**

| Change | Violations resolved |
|--------|-------------------|
| `erase_m2m3_fill.py` + gdsfill | M2Fil.a2 ×74 270, M3Fil.a2 ×59 736 (double-fill) |
| Keep-out 0.42 → 0.50 µm | M2Fil.c ×2 (fill-to-routing spacing) |
| Density target 35 → 45 % | M2Fil.h ×7, M3Fil.h ×6 |




