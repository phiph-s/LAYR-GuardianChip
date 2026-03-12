package dev.seelos.layrsimulator

import android.graphics.drawable.AnimatedVectorDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.ImageView
import android.widget.TextView
import androidx.fragment.app.Fragment

abstract class BaseFragment : Fragment() {

    private lateinit var statusTextView: TextView
    private lateinit var feedbackImageView: ImageView
    private val handler = Handler(Looper.getMainLooper())
    private var lastStatus = TransactionStatus.IDLE

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        statusTextView = view.findViewById(R.id.status)
        feedbackImageView = view.findViewById(R.id.feedback_image)

        handler.post(object : Runnable {
            override fun run() {
                val currentStatus = CardService.transactionStatus
                statusTextView.text = CardService.lastEvent

                if (currentStatus != lastStatus) {
                    when (currentStatus) {
                        TransactionStatus.COMMUNICATING -> showCommunicating()
                        TransactionStatus.SUCCESS -> showFeedback(true)
                        TransactionStatus.FAILURE -> showFeedback(false)
                        TransactionStatus.IDLE -> hideFeedback()
                    }
                    lastStatus = currentStatus
                }

                handler.postDelayed(this, 200)
            }
        })
    }

    private fun showCommunicating() {
        feedbackImageView.setImageResource(R.drawable.avd_communicating)
        feedbackImageView.visibility = View.VISIBLE
        (feedbackImageView.drawable as? AnimatedVectorDrawable)?.start()
    }

    private fun showFeedback(isSuccess: Boolean) {
        (feedbackImageView.drawable as? AnimatedVectorDrawable)?.stop()
        val drawableId = if (isSuccess) R.drawable.avd_check else R.drawable.avd_cross
        feedbackImageView.setImageResource(drawableId)
        feedbackImageView.visibility = View.VISIBLE
        (feedbackImageView.drawable as? AnimatedVectorDrawable)?.start()

        handler.postDelayed({
            CardService.transactionStatus = TransactionStatus.IDLE
        }, 2000)
    }

    private fun hideFeedback() {
        (feedbackImageView.drawable as? AnimatedVectorDrawable)?.stop()
        feedbackImageView.visibility = View.GONE
    }
}