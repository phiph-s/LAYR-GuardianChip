package dev.seelos.layrsimulator

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class KeyAdapter(
    private val keys: MutableList<Pair<String, String>>,
    private val onDeleteClicked: (Pair<String, String>) -> Unit
) : RecyclerView.Adapter<KeyAdapter.KeyViewHolder>() {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): KeyViewHolder {
        val view = LayoutInflater.from(parent.context).inflate(R.layout.item_key, parent, false)
        return KeyViewHolder(view)
    }

    override fun onBindViewHolder(holder: KeyViewHolder, position: Int) {
        val key = keys[position]
        holder.bind(key)
    }

    override fun getItemCount(): Int = keys.size

    fun updateKeys(newKeys: List<Pair<String, String>>) {
        keys.clear()
        keys.addAll(newKeys)
        notifyDataSetChanged()
    }

    inner class KeyViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val keyNameTextView: TextView = itemView.findViewById(R.id.text_view_key_name)
        private val keyValueTextView: TextView = itemView.findViewById(R.id.text_view_key_value)
        private val deleteButton: ImageButton = itemView.findViewById(R.id.button_delete_key)

        fun bind(key: Pair<String, String>) {
            keyNameTextView.text = key.first
            keyValueTextView.text = key.second
            deleteButton.setOnClickListener { onDeleteClicked(key) }
        }
    }
}