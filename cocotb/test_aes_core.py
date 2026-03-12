"""
Cocotb testbench for aes_core / aes_iterative.

Tests use official NIST FIPS 197 vectors plus round-trip checks.

Run:
    cd cocotb
    python3 test_aes_core.py
"""

import os
from pathlib import Path
from Crypto.Cipher import AES  # pycryptodome

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb_tools.runner import get_runner, Verilog

SIM          = os.getenv("SIM", "icarus")
HDL_TOPLEVEL = "aes_core"
CLK_PERIOD   = 10  # ns  (100 MHz – fast for sim, timing is cycle-count not wall-clock)

# ---------------------------------------------------------------------------
# NIST FIPS 197 test vectors
# ---------------------------------------------------------------------------
FIPS_VECTORS = [
    # (key, plaintext, ciphertext)  – all 128-bit, big-endian hex
    # Appendix B
    (
        0x2b7e151628aed2a6abf7158809cf4f3c,
        0x3243f6a8885a308d313198a2e0370734,
        0x3925841d02dc09fbdc118597196a0b32,
    ),
    # Appendix C.1
    (
        0x000102030405060708090a0b0c0d0e0f,
        0x00112233445566778899aabbccddeeff,
        0x69c4e0d86a7b0430d8cdb78070b4c55a,
    ),
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
CLK_TIMEOUT = 200  # cycles


async def init(dut):
    """Clock, reset."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD, "ns").start())
    dut.rst_n.value    = 0
    dut.start.value    = 0
    dut.mode.value     = 0
    dut.key.value      = 0
    dut.block_in.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_aes(dut, key: int, block_in: int, mode: int) -> int:
    """
    Assert start for one cycle, then wait for done.
    Returns block_out as int.
    """
    dut.key.value      = key
    dut.block_in.value = block_in
    dut.mode.value     = mode
    dut.start.value    = 1
    await RisingEdge(dut.clk)
    dut.start.value    = 0

    for _ in range(CLK_TIMEOUT):
        await RisingEdge(dut.clk)
        if dut.done.value == 1:
            return int(dut.block_out.value)

    raise TimeoutError("AES core did not assert done within timeout")


def py_aes_enc(key: int, block: int) -> int:
    k = key.to_bytes(16, "big")
    b = block.to_bytes(16, "big")
    return int.from_bytes(AES.new(k, AES.MODE_ECB).encrypt(b), "big")


def py_aes_dec(key: int, block: int) -> int:
    k = key.to_bytes(16, "big")
    b = block.to_bytes(16, "big")
    return int.from_bytes(AES.new(k, AES.MODE_ECB).decrypt(b), "big")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_fips_encrypt(dut):
    """NIST FIPS 197 encryption vectors."""
    await init(dut)
    for key, pt, ct_expected in FIPS_VECTORS:
        result = await run_aes(dut, key, pt, mode=0)
        assert result == ct_expected, (
            f"Encrypt mismatch\n"
            f"  key={key:#034x}\n"
            f"  pt ={pt:#034x}\n"
            f"  got={result:#034x}\n"
            f"  exp={ct_expected:#034x}"
        )
        dut._log.info(f"FIPS encrypt OK: {result:#034x}")


@cocotb.test()
async def test_fips_decrypt(dut):
    """NIST FIPS 197 decryption vectors (ciphertext → plaintext)."""
    await init(dut)
    for key, pt_expected, ct in FIPS_VECTORS:
        result = await run_aes(dut, key, ct, mode=1)
        assert result == pt_expected, (
            f"Decrypt mismatch\n"
            f"  key={key:#034x}\n"
            f"  ct ={ct:#034x}\n"
            f"  got={result:#034x}\n"
            f"  exp={pt_expected:#034x}"
        )
        dut._log.info(f"FIPS decrypt OK: {result:#034x}")


@cocotb.test()
async def test_round_trip(dut):
    """Encrypt then decrypt several random-ish blocks must recover original."""
    await init(dut)
    cases = [
        (0xdeadbeefcafebabe0011223344556677, 0x00000000000000000000000000000001),
        (0x00112233445566778899aabbccddeeff, 0xffffffffffffffffffffffffffffffff),
        (0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, 0x55555555555555555555555555555555),
    ]
    for key, pt in cases:
        ct     = await run_aes(dut, key, pt, mode=0)
        pt_rec = await run_aes(dut, key, ct, mode=1)
        assert pt_rec == pt, (
            f"Round-trip failed: key={key:#034x} pt={pt:#034x} "
            f"ct={ct:#034x} recovered={pt_rec:#034x}"
        )
        # Also cross-check against Python reference
        ct_ref = py_aes_enc(key, pt)
        assert ct == ct_ref, f"HW/SW encrypt mismatch for key={key:#034x}"
        dut._log.info(f"Round-trip OK: pt={pt:#034x} ct={ct:#034x}")


@cocotb.test()
async def test_sequential_operations(dut):
    """Back-to-back AES calls without extra idle cycles between them."""
    await init(dut)
    key = 0x2b7e151628aed2a6abf7158809cf4f3c
    blocks = [
        0x3243f6a8885a308d313198a2e0370734,
        0x00000000000000000000000000000000,
        0xffffffffffffffffffffffffffffffff,
    ]
    for pt in blocks:
        ct_hw  = await run_aes(dut, key, pt, mode=0)
        ct_ref = py_aes_enc(key, pt)
        assert ct_hw == ct_ref, (
            f"Sequential encrypt mismatch: pt={pt:#034x} hw={ct_hw:#034x} ref={ct_ref:#034x}"
        )
    dut._log.info("Sequential operations OK")


@cocotb.test()
async def test_layr_protocol_aes_ops(dut):
    """
    Simulate the exact AES operations performed by the LAYR core during
    a normal authentication transaction, using the fixed test PSK and a
    known card nonce, and verify every step matches the Python reference.

    PSK  = 0x00112233445566778899AABBCCDDEEFF  (DEBUG_KEY from EEPROM init)
    r_C  = 0x0102030405060708 (low 8 bytes of card nonce)
    ctr  = 1  (terminal nonce counter, starts at 1 after init)
    """
    await init(dut)

    PSK = 0x00112233445566778899AABBCCDDEEFF
    r_C = 0x0102030405060708

    # Step 1 – Card sends AES_PSK(r_C || 0^64), terminal decrypts
    auth_init_cipher = py_aes_enc(PSK, (r_C << 64))
    rc_recovered_hw  = await run_aes(dut, PSK, auth_init_cipher, mode=1)
    assert rc_recovered_hw >> 64 == r_C, "AUTH_INIT decrypt: r_C mismatch"
    dut._log.info(f"AUTH_INIT decrypt OK: r_C={r_C:#018x}")

    # Step 2 – Terminal derives r_T = AES_PSK(0 || ctr)[63:0]
    CTR = 1
    gen_rt_enc = await run_aes(dut, PSK, CTR, mode=0)
    r_T = gen_rt_enc & 0xFFFFFFFFFFFFFFFF
    r_T_ref = py_aes_enc(PSK, CTR) & 0xFFFFFFFFFFFFFFFF
    assert r_T == r_T_ref, f"r_T mismatch: hw={r_T:#018x} ref={r_T_ref:#018x}"
    dut._log.info(f"r_T generation OK: r_T={r_T:#018x}")

    # Step 3 – Terminal sends AUTH = AES_PSK(r_T || r_C)
    k_eph  = (r_C << 64) | r_T
    auth_block = (r_T << 64) | r_C
    auth_cipher_hw  = await run_aes(dut, PSK, auth_block, mode=0)
    auth_cipher_ref = py_aes_enc(PSK, auth_block)
    assert auth_cipher_hw == auth_cipher_ref, "AUTH encrypt mismatch"
    dut._log.info(f"AUTH encrypt OK: cipher={auth_cipher_hw:#034x}")

    # Step 4 – Terminal decrypts AUTH response (AES_keph(AUTH_SUCCESS))
    AUTH_SUCCESS = 0x415554485F5355434345535300000000
    auth_resp_cipher = py_aes_enc(k_eph, AUTH_SUCCESS)
    resp_hw = await run_aes(dut, k_eph, auth_resp_cipher, mode=1)
    assert resp_hw == AUTH_SUCCESS, f"AUTH response decrypt failed: {resp_hw:#034x}"
    dut._log.info("AUTH response verify OK")

    # Step 5 – GET_ID: decrypt AES_keph(card_id)
    CARD_ID = 0x00000000000000000000000000000001  # ID_1 from whitelist
    id_cipher = py_aes_enc(k_eph, CARD_ID)
    id_hw = await run_aes(dut, k_eph, id_cipher, mode=1)
    assert id_hw == CARD_ID, f"GET_ID decrypt failed: {id_hw:#034x}"
    dut._log.info(f"GET_ID decrypt OK: id={id_hw:#034x}")


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def aes_core_runner():
    proj = Path(__file__).resolve().parent
    rtl  = proj / "../src/user_rtl/rtl"
    ip   = proj / "../src/user_rtl/ip/canright-aes-sboxes/verilog"

    sources = [
        proj / "timescale.v",          # sets 1ns/1ps for icarus
        rtl / "aes_core.v",
        rtl / "aes_small/aes_iterative.v",
        Verilog(ip / "sbox.verilog"),
    ]

    runner = get_runner(SIM)
    runner.build(
        sources=sources,
        hdl_toplevel=HDL_TOPLEVEL,
        always=True,
        waves=True,
    )
    runner.test(
        hdl_toplevel=HDL_TOPLEVEL,
        test_module="test_aes_core,",
        waves=True,
    )


if __name__ == "__main__":
    aes_core_runner()
