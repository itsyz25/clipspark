package com.clipspark.app.home

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable

/**
 * System Photo Picker (PickMultipleVisualMedia) — no storage permission
 * needed, works fully offline. Mirrors the iOS PHAsset picker role.
 */
@Composable
fun rememberVideoPicker(onPicked: (List<Uri>) -> Unit): () -> Unit {
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(maxItems = 20)
    ) { uris -> if (uris.isNotEmpty()) onPicked(uris) }

    return {
        launcher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly))
    }
}
