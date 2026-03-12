package dev.seelos.layrsimulator

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Spinner

class LegacyFragment : BaseFragment() {

    private lateinit var keysSpinner: Spinner
    private lateinit var keyManager: KeyManager

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        val view = inflater.inflate(R.layout.tab_legacy, container, false)
        keysSpinner = view.findViewById(R.id.spinner_keys_legacy)
        keyManager = KeyManager(requireContext())
        return view
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        val keys = keyManager.getKeys().keys.toList()
        val adapter = ArrayAdapter(requireContext(), android.R.layout.simple_spinner_item, keys)
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        keysSpinner.adapter = adapter

        keysSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>, view: View?, position: Int, id: Long) {
                val keyName = parent.getItemAtPosition(position) as String
                val keyValue = keyManager.getKeys()[keyName] as String
                CardService.setKey(hex(keyValue))
            }

            override fun onNothingSelected(parent: AdapterView<*>) {
                // Another interface callback
            }
        }
    }
}