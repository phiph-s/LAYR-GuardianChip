package dev.seelos.layrsimulator

import android.content.Context
import android.content.SharedPreferences

class CardSettings(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("card_settings", Context.MODE_PRIVATE)

    fun getCardIdHex(): String {
        return prefs.getString(KEY_CARD_ID, CardService.DEFAULT_CARD_ID_HEX)
            ?: CardService.DEFAULT_CARD_ID_HEX
    }

    fun setCardIdHex(value: String) {
        prefs.edit().putString(KEY_CARD_ID, value).apply()
    }

    companion object {
        private const val KEY_CARD_ID = "card_id_hex"
    }
}
