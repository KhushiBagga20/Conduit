package com.khushi.conduit

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.khushi.conduit.ui.ConduitApp
import com.khushi.conduit.ui.theme.ConduitTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ConduitTheme {
                ConduitApp()
            }
        }
    }
}
