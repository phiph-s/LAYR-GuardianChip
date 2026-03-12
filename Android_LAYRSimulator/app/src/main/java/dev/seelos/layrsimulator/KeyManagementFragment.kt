package dev.seelos.layrsimulator

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import android.text.Editable
import android.text.TextWatcher
import java.security.SecureRandom

class KeyManagementFragment : Fragment() {

    private lateinit var cardIdLayout: TextInputLayout
    private lateinit var cardIdEditText: TextInputEditText
    private lateinit var keyNameEditText: TextInputEditText
    private lateinit var keyValueEditText: TextInputEditText
    private lateinit var generateRandomKeyButton: Button
    private lateinit var addKeyButton: Button
    private lateinit var keysRecyclerView: RecyclerView
    private lateinit var keyManager: KeyManager
    private lateinit var cardSettings: CardSettings
    private lateinit var keyAdapter: KeyAdapter

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        val view = inflater.inflate(R.layout.tab_key_management, container, false)

        cardIdLayout = view.findViewById(R.id.layout_card_id)
        cardIdEditText = view.findViewById(R.id.edit_text_card_id)
        keyNameEditText = view.findViewById(R.id.edit_text_key_name)
        keyValueEditText = view.findViewById(R.id.edit_text_key_value)
        generateRandomKeyButton = view.findViewById(R.id.button_generate_random_key)
        addKeyButton = view.findViewById(R.id.button_add_key)
        keysRecyclerView = view.findViewById(R.id.recycler_view_keys)

        keyManager = KeyManager(requireContext())
        cardSettings = CardSettings(requireContext())

        generateRandomKeyButton.setOnClickListener {
            val randomKey = ByteArray(16)
            SecureRandom().nextBytes(randomKey)
            keyValueEditText.setText(randomKey.toHexString())
        }

        addKeyButton.setOnClickListener {
            val keyName = keyNameEditText.text.toString()
            val keyValue = keyValueEditText.text.toString()
            if (keyName.isNotEmpty() && keyValue.isNotEmpty()) {
                keyManager.saveKey(keyName, keyValue)
                updateKeysList()
                keyNameEditText.text?.clear()
                keyValueEditText.text?.clear()
            }
        }

        setupRecyclerView()
        updateKeysList()

        val storedId = cardSettings.getCardIdHex()
        cardIdEditText.setText(storedId)
        CardService.setCardIdHex(storedId)
        cardIdEditText.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) {
                val value = s?.toString() ?: ""
                if (value.isEmpty()) {
                    cardIdLayout.error = null
                    return
                }
                val ok = CardService.setCardIdHex(value)
                if (ok) {
                    cardIdLayout.error = null
                    cardSettings.setCardIdHex(value)
                } else {
                    cardIdLayout.error = "Expected 32 hex chars"
                }
            }

            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        })

        return view
    }

    private fun setupRecyclerView() {
        keyAdapter = KeyAdapter(mutableListOf()) { key ->
            showDeleteConfirmationDialog(key)
        }
        keysRecyclerView.adapter = keyAdapter
    }

    private fun showDeleteConfirmationDialog(key: Pair<String, String>) {
        MaterialAlertDialogBuilder(requireContext())
            .setTitle("Delete Key")
            .setMessage("Are you sure you want to delete the key '${key.first}'?")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Delete") { _, _ ->
                keyManager.deleteKey(key.first)
                updateKeysList()
            }
            .show()
    }

    private fun updateKeysList() {
        val keys = keyManager.getKeys().map { it.key to it.value as String }
        keyAdapter.updateKeys(keys)
    }

    private fun ByteArray.toHexString(): String = joinToString(separator = "") { eachByte -> "%02X".format(eachByte) }
}
