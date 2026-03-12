"""
Cocotb testbench for layr_core.v.

The testbench acts as both the NFC link (driving app_tx_ready /
app_rx_valid / app_rx_byte) and as a software implementation of the
LAYR card side (using Python AES via pycryptodome).

Test cases:
  1. Successful authentication – whitelisted ID, no rollover
  2. Rejected card – ID not in whitelist
  3. Wrong PSK – AUTH step ciphertext cannot be verified by card
  4. Key rollover – card signals SW=0x9001 in GET_ID
  5. Link drop mid-transaction – link_ready de-asserted unexpectedly

Run:
    cd cocotb
    python3 test_layr_core.py

Note: CLK_HZ is overridden to 1_000 in sim so ms-ticks fire quickly.
"""

import os
from pathlib import Path
from Crypto.Cipher import AES as _AES

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
from cocotb_tools.runner import get_runner, Verilog

SIM          = os.getenv("SIM", "icarus")
HDL_TOPLEVEL = "layr_core"

# Use a tiny CLK_HZ so the 1 ms tick fires after 1 clock cycle in simulation.
# The module parameter is overridden via the runner parameters below.
SIM_CLK_HZ   = 1_000      # 1 tick per ms
CLK_PERIOD   = 1_000_000  // SIM_CLK_HZ  # ns

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------
PSK  = 0x00112233445566778899AABBCCDDEEFF   # DEBUG_KEY from EEPROM init
CTR  = 1                                    # initial counter value

# Whitelist: 6 slots.  Slot 0 = ID_1 (whitelisted), rest zeros for simplicity.
ID_WHITELISTED     = 0x00000000000000000000000000000001
ID_NOT_WHITELISTED = 0xDEADBEEFCAFEBABE0011223344556677

ALLOWED_IDS = (ID_WHITELISTED << (5 * 128))  # slot 0 at MSB; slots 1-5 = 0

APDU_TIMEOUT = 4_000  # clock cycles – generous for sim

# ---------------------------------------------------------------------------
# Python-side AES
# ---------------------------------------------------------------------------
def aes_enc(key: int, block: int) -> int:
    return int.from_bytes(
        _AES.new(key.to_bytes(16, "big"), _AES.MODE_ECB)
            .encrypt(block.to_bytes(16, "big")),
        "big"
    )

def aes_dec(key: int, block: int) -> int:
    return int.from_bytes(
        _AES.new(key.to_bytes(16, "big"), _AES.MODE_ECB)
            .decrypt(block.to_bytes(16, "big")),
        "big"
    )

# ---------------------------------------------------------------------------
# DUT helpers
# ---------------------------------------------------------------------------
async def init_dut(dut):
    """Clock, reset, set static inputs."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD, "ns").start())
    dut.rst.value               = 1
    dut.enable.value            = 0
    dut.busy_in.value           = 0
    dut.psk_key.value           = PSK
    dut.psk_counter.value       = CTR
    dut.psk_counter_valid.value = 0
    dut.allowed_ids.value       = 0
    dut.allowed_ids_valid.value = 0
    dut.link_ready.value        = 0
    dut.app_tx_ready.value      = 0
    dut.app_rx_valid.value      = 0
    dut.app_rx_byte.value       = 0
    dut.app_rx_last.value       = 0
    dut.key_write_done.value    = 0
    dut.counter_write_done.value= 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    dut.enable.value            = 1
    dut.psk_counter_valid.value = 1
    await RisingEdge(dut.clk)


async def bring_link_up(dut):
    """Assert link_ready so the core starts a transaction."""
    dut.link_ready.value = 1


async def wait_tx_byte(dut) -> tuple[int, bool]:
    """
    Wait until the core drives app_tx_valid=1, acknowledge with
    app_tx_ready=1 for one cycle, return (byte, is_last).
    """
    for _ in range(APDU_TIMEOUT):
        await RisingEdge(dut.clk)
        if int(dut.app_tx_valid.value) == 1:
            b    = int(dut.app_tx_byte.value)
            last = bool(int(dut.app_tx_last.value))
            dut.app_tx_ready.value = 1
            await RisingEdge(dut.clk)
            dut.app_tx_ready.value = 0
            return b, last
    raise TimeoutError("Timeout waiting for app_tx_valid")


async def recv_apdu(dut) -> list[int]:
    """Receive a complete APDU from the core (until app_tx_last)."""
    data = []
    while True:
        b, last = await wait_tx_byte(dut)
        data.append(b)
        if last:
            return data


async def send_apdu(dut, payload: list[int]):
    """
    Deliver payload bytes to the core one at a time via app_rx_valid/byte/last.
    """
    for i, b in enumerate(payload):
        dut.app_rx_valid.value = 1
        dut.app_rx_byte.value  = b
        dut.app_rx_last.value  = 1 if i == len(payload) - 1 else 0
        # Wait until core accepts (app_rx_ready)
        for _ in range(APDU_TIMEOUT):
            await RisingEdge(dut.clk)
            if int(dut.app_rx_ready.value) == 1:
                break
        else:
            raise TimeoutError(f"Timeout: core never asserted app_rx_ready for byte {i}")
        dut.app_rx_valid.value = 0
        dut.app_rx_byte.value  = 0
        dut.app_rx_last.value  = 0
        await RisingEdge(dut.clk)


def int_to_bytes(v: int, n: int) -> list[int]:
    return list(v.to_bytes(n, "big"))


async def wait_signal_high(dut, sig, timeout=APDU_TIMEOUT * 10):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(sig.value) == 1:
            return
    raise TimeoutError(f"Timeout waiting for signal to go high")


# ---------------------------------------------------------------------------
# Card-side protocol helpers
# ---------------------------------------------------------------------------
def card_auth_init_response(psk: int, r_C: int) -> list[int]:
    """Return AES_psk(r_C || 0^64) + SW1 SW2."""
    cipher = aes_enc(psk, (r_C << 64))
    return int_to_bytes(cipher, 16) + [0x90, 0x00]


def card_auth_response(psk: int, r_T: int, r_C: int) -> list[int]:
    """
    Verify terminal's AUTH message, compute k_eph, return
    AES_keph(AUTH_SUCCESS) + SW.
    """
    k_eph        = (r_C << 64) | r_T
    AUTH_SUCCESS = 0x415554485F5355434345535300000000
    resp         = aes_enc(k_eph, AUTH_SUCCESS)
    return int_to_bytes(resp, 16) + [0x90, 0x00]


def card_get_id_response(k_eph: int, card_id: int, rollover: bool = False) -> list[int]:
    enc = aes_enc(k_eph, card_id)
    sw2 = 0x01 if rollover else 0x00
    return int_to_bytes(enc, 16) + [0x90, sw2]


def card_get_new_key_response(k_eph: int, new_key: int) -> list[int]:
    enc = aes_enc(k_eph, new_key)
    return int_to_bytes(enc, 16) + [0x90, 0x00]


# ---------------------------------------------------------------------------
# Shared transaction driver
# ---------------------------------------------------------------------------
async def do_full_auth(dut, psk, ctr, card_id, rollover=False, new_key=None):
    """
    Drive one complete LAYR transaction from SELECT to GET_ID (optionally
    including key rollover).  Returns (k_eph, r_C, r_T).
    Raises AssertionError or TimeoutError on failure.
    """
    # SELECT AID
    select_apdu = await recv_apdu(dut)
    assert select_apdu[:5] == [0x00, 0xA4, 0x04, 0x00, 0x06], \
        f"Bad SELECT header: {select_apdu}"
    assert select_apdu[5:11] == [0xF0, 0x00, 0x00, 0x0C, 0xDC, 0x01], \
        f"Bad AID: {select_apdu[5:11]}"
    await send_apdu(dut, [0x90, 0x00])

    # AUTH_INIT
    ai_apdu = await recv_apdu(dut)
    assert ai_apdu == [0x80, 0x10, 0x00, 0x00, 0x10], f"Bad AUTH_INIT: {ai_apdu}"
    r_C = 0x0102030405060708  # fixed card nonce for determinism
    await send_apdu(dut, card_auth_init_response(psk, r_C))

    # AUTH – terminal sends encrypted(r_T || r_C); we extract r_T
    auth_apdu = await recv_apdu(dut)
    assert auth_apdu[:5] == [0x80, 0x11, 0x00, 0x00, 0x10], f"Bad AUTH hdr: {auth_apdu}"
    auth_cipher_bytes = auth_apdu[5:]
    auth_cipher = int.from_bytes(auth_cipher_bytes, "big")
    # Decrypt to get r_T||r_C
    plain = aes_dec(psk, auth_cipher)
    r_T   = (plain >> 64) & 0xFFFFFFFFFFFFFFFF
    r_C_  = plain & 0xFFFFFFFFFFFFFFFF
    # Card verifies r_C matches; we just check it here in the TB
    assert r_C_ == r_C, f"r_C mismatch in AUTH payload: {r_C_:#018x} vs {r_C:#018x}"
    k_eph = (r_C << 64) | r_T
    await send_apdu(dut, card_auth_response(psk, r_T, r_C))

    # GET_ID
    gid_apdu = await recv_apdu(dut)
    assert gid_apdu == [0x80, 0x12, 0x00, 0x00, 0x10], f"Bad GET_ID: {gid_apdu}"
    await send_apdu(dut, card_get_id_response(k_eph, card_id, rollover=rollover))

    if rollover and new_key is not None:
        gnk_apdu = await recv_apdu(dut)
        assert gnk_apdu == [0x80, 0x21, 0x00, 0x00, 0x10], f"Bad GET_NEW_KEY: {gnk_apdu}"
        await send_apdu(dut, card_get_new_key_response(k_eph, new_key))

    return k_eph, r_C, r_T


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_successful_auth(dut):
    """Full transaction with whitelisted ID → unlock asserted."""
    await init_dut(dut)
    dut.allowed_ids.value       = ALLOWED_IDS
    dut.allowed_ids_valid.value = 1
    await bring_link_up(dut)
    await ClockCycles(dut.clk, 2)

    k_eph, r_C, r_T = await do_full_auth(dut, PSK, CTR, ID_WHITELISTED)

    # Core should assert unlock; wait for it
    await wait_signal_high(dut, dut.unlock)
    dut._log.info(f"Unlock asserted! k_eph={k_eph:#034x}")

    # fault must not be set
    assert int(dut.fault.value) == 0, "fault asserted on successful auth"

    # counter_write_req should fire after hold time
    await wait_signal_high(dut, dut.counter_write_req)
    expected_ctr = (CTR + 1).to_bytes(8, "big")
    written_ctr  = int(dut.counter_write_data.value).to_bytes(8, "big")
    assert written_ctr == expected_ctr, \
        f"Counter write: expected {expected_ctr.hex()} got {written_ctr.hex()}"
    dut.counter_write_done.value = 1
    await ClockCycles(dut.clk, 2)
    dut.counter_write_done.value = 0
    dut._log.info("test_successful_auth PASSED")


@cocotb.test()
async def test_id_not_in_whitelist(dut):
    """Card presents a valid auth but its ID is not whitelisted → fault."""
    await init_dut(dut)
    dut.allowed_ids.value       = ALLOWED_IDS
    dut.allowed_ids_valid.value = 1
    await bring_link_up(dut)
    await ClockCycles(dut.clk, 2)

    await do_full_auth(dut, PSK, CTR, ID_NOT_WHITELISTED)

    await wait_signal_high(dut, dut.fault)
    assert int(dut.unlock.value) == 0, "unlock asserted for non-whitelisted ID"
    dut._log.info("test_id_not_in_whitelist PASSED")


@cocotb.test()
async def test_wrong_psk(dut):
    """
    Card uses a different PSK → the AUTH step response fails SW check
    (wrong MAC from card's perspective) → fault.
    We simulate this by sending a random 16-byte payload + SW 0x90 0x00
    in place of the real AUTH_INIT response, so the terminal cannot
    recover a valid r_C and the subsequent AUTH cipher will be rejected.
    """
    await init_dut(dut)
    dut.allowed_ids.value       = ALLOWED_IDS
    dut.allowed_ids_valid.value = 1
    await bring_link_up(dut)
    await ClockCycles(dut.clk, 2)

    WRONG_PSK = 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEF

    # SELECT
    await recv_apdu(dut)
    await send_apdu(dut, [0x90, 0x00])

    # AUTH_INIT – send a response encrypted with wrong PSK
    r_C = 0xCAFEBABEDEADD00D
    await recv_apdu(dut)  # AUTH_INIT command
    await send_apdu(dut, card_auth_init_response(WRONG_PSK, r_C))

    # AUTH – terminal will have derived wrong r_C from the cipher;
    # we reply with a correct-looking (but wrong) AUTH response.
    auth_apdu = await recv_apdu(dut)
    auth_cipher = int.from_bytes(auth_apdu[5:], "big")
    # Attempt to decode with WRONG_PSK (card side uses wrong_psk)
    plain  = aes_dec(WRONG_PSK, auth_cipher)
    r_T_   = (plain >> 64) & 0xFFFFFFFFFFFFFFFF
    r_C_   = plain & 0xFFFFFFFFFFFFFFFF
    k_eph  = (r_C_ << 64) | r_T_
    # Send the correct AUTH_SUCCESS under this (wrong) k_eph
    AUTH_SUCCESS = 0x415554485F5355434345535300000000
    resp = int_to_bytes(aes_enc(k_eph, AUTH_SUCCESS), 16) + [0x90, 0x00]
    await send_apdu(dut, resp)

    # GET_ID response using wrong k_eph → terminal will decrypt to wrong ID
    await recv_apdu(dut)
    enc_id = int_to_bytes(aes_enc(k_eph, ID_NOT_WHITELISTED), 16) + [0x90, 0x00]
    await send_apdu(dut, enc_id)

    # Expect fault (ID not in whitelist because wrong k_eph produced wrong ID)
    await wait_signal_high(dut, dut.fault)
    assert int(dut.unlock.value) == 0
    dut._log.info("test_wrong_psk PASSED")


@cocotb.test()
async def test_key_rollover(dut):
    """
    Card signals SW=0x9001 → core requests GET_NEW_KEY → key_write_req
    fires with the correctly decrypted new key.
    """
    await init_dut(dut)
    dut.allowed_ids.value       = ALLOWED_IDS
    dut.allowed_ids_valid.value = 1
    await bring_link_up(dut)
    await ClockCycles(dut.clk, 2)

    NEW_KEY = 0xAABBCCDDEEFF00112233445566778899

    k_eph, _, _ = await do_full_auth(
        dut, PSK, CTR, ID_WHITELISTED,
        rollover=True, new_key=NEW_KEY
    )

    # key_write_req should fire; check the decrypted key
    await wait_signal_high(dut, dut.key_write_req)
    written_key = int(dut.key_write_data.value)
    assert written_key == NEW_KEY, \
        f"Key rollover: expected {NEW_KEY:#034x} got {written_key:#034x}"
    dut.key_write_done.value = 1
    await ClockCycles(dut.clk, 2)
    dut.key_write_done.value = 0

    await wait_signal_high(dut, dut.unlock)
    assert int(dut.fault.value) == 0
    dut._log.info(f"test_key_rollover PASSED, new_key={written_key:#034x}")


@cocotb.test()
async def test_link_drop_mid_transaction(dut):
    """
    De-assert link_ready in the middle of AUTH_INIT exchange.
    Core must return to IDLE (busy=0, fault=0, unlock=0).
    """
    await init_dut(dut)
    dut.allowed_ids.value       = ALLOWED_IDS
    dut.allowed_ids_valid.value = 1
    await bring_link_up(dut)
    await ClockCycles(dut.clk, 2)

    # Let SELECT go through
    await recv_apdu(dut)
    await send_apdu(dut, [0x90, 0x00])

    # Receive AUTH_INIT command, then drop the link before responding
    await recv_apdu(dut)
    dut.link_ready.value = 0

    # Wait for core to settle back to IDLE
    for _ in range(APDU_TIMEOUT):
        await RisingEdge(dut.clk)
        if (int(dut.busy.value) == 0 and
                int(dut.unlock.value) == 0 and
                int(dut.fault.value) == 0):
            break
    else:
        raise AssertionError("Core did not return to IDLE after link drop")

    assert int(dut.unlock.value) == 0, "unlock should be 0 after link drop"
    assert int(dut.fault.value)  == 0, "fault should be 0 after link drop"
    dut._log.info("test_link_drop_mid_transaction PASSED")


@cocotb.test()
async def test_select_failure(dut):
    """Card returns 0x6A82 (file not found) to SELECT → fault hold."""
    await init_dut(dut)
    dut.allowed_ids.value       = ALLOWED_IDS
    dut.allowed_ids_valid.value = 1
    await bring_link_up(dut)
    await ClockCycles(dut.clk, 2)

    await recv_apdu(dut)
    # Return error status
    await send_apdu(dut, [0x6A, 0x82])

    await wait_signal_high(dut, dut.fault)
    assert int(dut.unlock.value) == 0
    dut._log.info("test_select_failure PASSED")


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def layr_core_runner():
    proj = Path(__file__).resolve().parent
    rtl  = proj / "../src/user_rtl/rtl"
    ip   = proj / "../src/user_rtl/ip/canright-aes-sboxes/verilog"

    sources = [
        proj / "timescale.v",          # sets 1ns/1ps for icarus
        rtl / "layr_core.v",
        rtl / "aes_core.v",
        rtl / "aes_small/aes_iterative.v",
        Verilog(ip / "sbox.verilog"),
    ]

    runner = get_runner(SIM)
    runner.build(
        sources=sources,
        hdl_toplevel=HDL_TOPLEVEL,
        parameters={"CLK_HZ": SIM_CLK_HZ},
        always=True,
        waves=True,
    )
    runner.test(
        hdl_toplevel=HDL_TOPLEVEL,
        test_module="test_layr_core,",
        waves=True,
    )


if __name__ == "__main__":
    layr_core_runner()
