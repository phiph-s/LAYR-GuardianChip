package dev.seelos.layrsimulator

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Spinner

class RolloverFragment : BaseFragment() {

    private lateinit var oldKeysSpinner: Spinner
    private lateinit var newKeysSpinner: Spinner
    private lateinit var keyManager: KeyManager
    private var keys: Map<String, Any?> = emptyMap()

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        val view = inflater.inflate(R.layout.tab_rollover, container, false)
        oldKeysSpinner = view.findViewById(R.id.spinner_keys_rollover_old)
        newKeysSpinner = view.findViewById(R.id.spinner_keys_rollover_new)
        keyManager = KeyManager(requireContext())
        return view
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        keys = keyManager.getKeys()
        val keyNames = keys.keys.toList()
        val adapter = ArrayAdapter(requireContext(), android.R.layout.simple_spinner_item, keyNames)
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        oldKeysSpinner.adapter = adapter
        newKeysSpinner.adapter = adapter

        oldKeysSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>, view: View?, position: Int, id: Long) {
                applyRolloverSelection()
            }

            override fun onNothingSelected(parent: AdapterView<*>) {}
        }

        newKeysSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>, view: View?, position: Int, id: Long) {
                applyRolloverSelection()
            }

            override fun onNothingSelected(parent: AdapterView<*>) {}
        }
    }

    override fun onResume() {
        super.onResume()
        CardService.setRolloverEnabled(true)
        applyRolloverSelection()
    }

    override fun onPause() {
        CardService.setRolloverEnabled(false)
        super.onPause()
    }

    private fun applyRolloverSelection() {
        val oldName = oldKeysSpinner.selectedItem as? String ?: return
        val newName = newKeysSpinner.selectedItem as? String ?: return
        val oldValue = keys[oldName] as? String ?: return
        val newValue = keys[newName] as? String ?: return
        CardService.setKey(hex(oldValue))
        CardService.setNewKey(hex(newValue))
    }
}
