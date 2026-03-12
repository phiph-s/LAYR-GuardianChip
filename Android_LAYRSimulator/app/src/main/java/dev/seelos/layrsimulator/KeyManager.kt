package dev.seelos.layrsimulator

import android.content.Context
import android.content.SharedPreferences

class KeyManager(context: Context) {

    private val prefs: SharedPreferences = context.getSharedPreferences("key_storage", Context.MODE_PRIVATE)

    fun saveKey(name: String, key: String) {
        prefs.edit().putString(name, key).apply()
    }

    fun getKeys(): Map<String, *> {
        return prefs.all
    }

    fun deleteKey(name: String) {
        prefs.edit().remove(name).apply()
    }
}