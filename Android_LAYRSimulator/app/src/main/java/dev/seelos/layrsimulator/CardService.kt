package dev.seelos.layrsimulator

import android.nfc.cardemulation.HostApduService
import android.os.Bundle
import android.util.Log
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

fun hex(s: String): ByteArray =
    s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

enum class TransactionStatus {
    IDLE, COMMUNICATING, SUCCESS, FAILURE
}

class CardService : HostApduService() {

    // AID bytes
    private val aid = hex("F000000CDC01")

    // Responses
    private val SW_OK = hex("9000")
    private val SW_NEW_KEY_PENDING = hex("9001")
    private val SW_INS_NOT_SUPPORTED = hex("6D00")
    private val SW_CLA_NOT_SUPPORTED = hex("6E00")

    private val rng = SecureRandom()
    private var rc: ByteArray? = null
    private var rt: ByteArray? = null
    private var kEph: ByteArray? = null
    private var authenticated: Boolean = false
    private val msgSuccess = "AUTH_SUCCESS".toByteArray(Charsets.US_ASCII) + ByteArray(4)
    private val msgFailure = "AUTH_FAILURE".toByteArray(Charsets.US_ASCII) + ByteArray(4)

    // (Optional) simple state for UI
    companion object {
        private const val TAG = "CardService" // Tag für das Logging
        @Volatile var lastEvent: String = "Idle"
        @Volatile var transactionStatus: TransactionStatus = TransactionStatus.IDLE
        const val DEFAULT_CARD_ID_HEX = "00000000000000000000000000000003"
        @Volatile var cardIdPlain: ByteArray = hex(DEFAULT_CARD_ID_HEX)
        var pskKey = hex("00112233445566778899AABBCCDDEEFF")
        var pskKeyNew: ByteArray? = null
        var newKeyPending: Boolean = false
        @Volatile var rolloverMode: Boolean = false

        @OptIn(ExperimentalStdlibApi::class)
        fun setKey(key: ByteArray) {
            pskKey = key
            Log.d(TAG, "setKey: pskKey updated to ${key.toHexString()}")
            if (!rolloverMode) {
                pskKeyNew = null
                newKeyPending = false
                Log.d(TAG, "setKey: rolloverMode=false, cleared pskKeyNew/newKeyPending")
            }
        }

        @OptIn(ExperimentalStdlibApi::class)
        fun setNewKey(key: ByteArray) {
            pskKeyNew = key
            newKeyPending = true
            Log.d(TAG, "setNewKey: pskKeyNew=${key.toHexString()}, newKeyPending=true")
        }

        fun setRolloverEnabled(enabled: Boolean) {
            rolloverMode = enabled
            Log.d(TAG, "setRolloverEnabled: enabled=$enabled")
            if (!enabled) {
                pskKeyNew = null
                newKeyPending = false
                Log.d(TAG, "setRolloverEnabled: disabled, cleared pskKeyNew/newKeyPending")
            }
        }

        fun setCardIdHex(hexString: String): Boolean {
            val normalized = hexString.trim()
            if (normalized.length != 32) return false
            if (!normalized.all { it.isDigit() || (it in 'a'..'f') || (it in 'A'..'F') }) return false
            return try {
                cardIdPlain = hex(normalized)
                Log.d(TAG, "setCardIdHex: updated to $normalized")
                true
            } catch (e: Exception) {
                false
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service created.")
        lastEvent = "Service Created"
    }

    override fun processCommandApdu(apdu: ByteArray, extras: Bundle?): ByteArray {
        Log.d(TAG, "processCommandApdu called. Received APDU: ${apdu.toHexString()}")

        if (isSelectAid(apdu, aid)) {
            Log.d(TAG, "SELECT AID command successful.")
            lastEvent = "SELECT ok"
            authenticated = false
            rc = null
            rt = null
            kEph = null
            transactionStatus = TransactionStatus.COMMUNICATING
            Log.d(TAG, "Responding with SW_OK: ${SW_OK.toHexString()}")
            return SW_OK
        }

        if (transactionStatus == TransactionStatus.IDLE) {
            transactionStatus = TransactionStatus.COMMUNICATING
        }

        if (apdu.size < 4) {
            Log.w(TAG, "APDU too short (< 4 bytes). Responding with SW_INS_NOT_SUPPORTED.")
            transactionStatus = TransactionStatus.FAILURE
            return SW_INS_NOT_SUPPORTED
        }

        val cla = apdu[0]
        val ins = apdu[1]

        Log.d(TAG, "CLA: ${cla.toHexString()}, INS: ${ins.toHexString()}")

        if (cla != 0x80.toByte()) {
            Log.w(TAG, "Unsupported CLA: ${cla.toHexString()}. Responding with SW_CLA_NOT_SUPPORTED.")
            transactionStatus = TransactionStatus.FAILURE
            return SW_CLA_NOT_SUPPORTED
        }

        val response = when (ins) {
            0x10.toByte() -> { // AUTH_INIT
                Log.i(TAG, "Handling AUTH_INIT command.")
                lastEvent = "AUTH_INIT"
                authenticated = false
                rt = null
                kEph = null
                val rcLocal = ByteArray(8)
                rng.nextBytes(rcLocal)
                rc = rcLocal
                val block = rcLocal + ByteArray(8) { 0x00 }
                val cipher = aesEncrypt(pskKey, block)
                val fullResponse = cipher + SW_OK
                Log.d(TAG, "Responding to AUTH_INIT with cipher + SW_OK: ${fullResponse.toHexString()}")
                fullResponse
            }
            0x11.toByte() -> { // AUTH
                Log.i(TAG, "Handling AUTH command.")
                lastEvent = "AUTH"
                val data = getApduData(apdu) ?: return SW_INS_NOT_SUPPORTED.also { transactionStatus = TransactionStatus.FAILURE }
                if (data.size != 16 || rc == null) {
                    Log.w(TAG, "AUTH wrong length or missing rc.")
                    transactionStatus = TransactionStatus.FAILURE
                    return hex("6700")
                }
                val plain = aesDecrypt(pskKey, data)
                val rtLocal = plain.copyOfRange(0, 8)
                val rcLocal = plain.copyOfRange(8, 16)
                val authSuccess = rcLocal.contentEquals(rc)
                if (!authSuccess) {
                    Log.w(TAG, "AUTH rc mismatch.")
                }
                rt = rtLocal
                kEph = rc!! + rtLocal
                authenticated = authSuccess
                transactionStatus = if (authSuccess) TransactionStatus.COMMUNICATING else TransactionStatus.FAILURE
                val responseMessage = if (authSuccess) msgSuccess else msgFailure
                val cipher = aesEncrypt(kEph!!, responseMessage)
                val fullResponse = cipher + SW_OK
                Log.d(TAG, "Responding to AUTH with status message + SW_OK: ${fullResponse.toHexString()}")
                fullResponse
            }
            0x12.toByte() -> { // GET_ID
                Log.i(TAG, "Handling GET_ID command.")
                lastEvent = "GET_ID"
                if (!authenticated || kEph == null) {
                    Log.w(TAG, "GET_ID without authentication.")
                    transactionStatus = TransactionStatus.FAILURE
                    return hex("6982")
                }
                val cipher = aesEncrypt(kEph!!, cardIdPlain)
                val statusWord = if (rolloverMode && newKeyPending) SW_NEW_KEY_PENDING else SW_OK
                transactionStatus = TransactionStatus.SUCCESS
                val fullResponse = cipher + statusWord
                Log.d(TAG, "GET_ID: newKeyPending=$newKeyPending, rolloverMode=$rolloverMode, status=${statusWord.toHexString()}")
                Log.d(TAG, "Responding to GET_ID with cipher + status: ${fullResponse.toHexString()}")
                fullResponse
            }
            0x21.toByte() -> { // GET_NEW_KEY
                Log.i(TAG, "Handling GET_NEW_KEY command.")
                lastEvent = "GET_NEW_KEY"
                if (!authenticated || kEph == null || pskKeyNew == null) {
                    Log.w(TAG, "GET_NEW_KEY without authentication or new key.")
                    transactionStatus = TransactionStatus.FAILURE
                    return hex("6982")
                }
                val cipher = aesEncrypt(kEph!!, pskKeyNew!!)
                Log.d(TAG, "GET_NEW_KEY: rolloverMode=$rolloverMode, pskKeyNew=${pskKeyNew!!.toHexString()}")
                if (!rolloverMode) {
                    pskKey = pskKeyNew!!
                    pskKeyNew = null
                    newKeyPending = false
                    Log.d(TAG, "GET_NEW_KEY: pskKey updated, newKeyPending=false")
                } else {
                    Log.d(TAG, "GET_NEW_KEY: rolloverMode=true, keeping pskKey and newKeyPending")
                }
                transactionStatus = TransactionStatus.SUCCESS
                val fullResponse = cipher + SW_OK
                Log.d(TAG, "Responding to GET_NEW_KEY with cipher + SW_OK: ${fullResponse.toHexString()}")
                fullResponse
            }
            else -> {
                Log.w(TAG, "Unsupported INS: ${ins.toHexString()}. Responding with SW_INS_NOT_SUPPORTED.")
                transactionStatus = TransactionStatus.FAILURE
                SW_INS_NOT_SUPPORTED
            }
        }
        return response
    }

    override fun onDeactivated(reason: Int) {
        val reasonStr = if (reason == DEACTIVATION_LINK_LOSS) "Link Loss" else "Deselected"
        Log.i(TAG, "onDeactivated called. Reason: $reasonStr ($reason)")
        lastEvent = "Deactivated ($reasonStr)"

        if (transactionStatus == TransactionStatus.COMMUNICATING) {
            transactionStatus = TransactionStatus.IDLE
        }

        authenticated = false
        rc = null
        rt = null
        kEph = null
    }

    private fun isSelectAid(apdu: ByteArray, aid: ByteArray): Boolean {
        if (apdu.size < 5) return false
        val selectHeader = byteArrayOf(0x00.toByte(), 0xA4.toByte(), 0x04.toByte(), 0x00.toByte())
        if (!apdu.copyOfRange(0, 4).contentEquals(selectHeader)) return false

        val lc = apdu[4].toInt() and 0xFF
        if (apdu.size < 5 + lc) return false

        val receivedAid = apdu.copyOfRange(5, 5 + lc)
        return receivedAid.contentEquals(aid)
    }

    private fun getApduData(apdu: ByteArray): ByteArray? {
        if (apdu.size < 5) return ByteArray(0)
        val lc = apdu[4].toInt() and 0xFF
        if (lc == 0) return ByteArray(0)
        if (apdu.size < 5 + lc) return null
        return apdu.copyOfRange(5, 5 + lc)
    }

    private fun aesEncrypt(key: ByteArray, data: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        val spec = SecretKeySpec(key, "AES")
        cipher.init(Cipher.ENCRYPT_MODE, spec)
        return cipher.doFinal(data)
    }

    private fun aesDecrypt(key: ByteArray, data: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/ECB/NoPadding")
        val spec = SecretKeySpec(key, "AES")
        cipher.init(Cipher.DECRYPT_MODE, spec)
        return cipher.doFinal(data)
    }

    private fun ByteArray.toHexString(): String = joinToString(separator = "") { byte -> "%02X".format(byte) }
    private fun Byte.toHexString(): String = "%02X".format(this)
}
