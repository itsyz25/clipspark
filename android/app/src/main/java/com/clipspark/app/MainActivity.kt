package com.clipspark.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.clipspark.app.designsystem.ClipSparkTheme
import com.clipspark.app.home.RootShell

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            ClipSparkTheme {
                RootShell()
            }
        }
    }
}
