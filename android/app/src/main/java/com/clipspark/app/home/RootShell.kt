package com.clipspark.app.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipspark.app.designsystem.*
import com.clipspark.app.drafts.DraftStore
import com.clipspark.app.editor.EditorScreen
import com.clipspark.app.editor.EditorViewModel
import com.clipspark.app.templates.ClipTemplate

/** Root shell: Home / Templates / Settings tabs (3 tabs per spec). */

@Composable
fun RootShell() {
    val context = androidx.compose.ui.platform.LocalContext.current
    var tab by remember { mutableStateOf(0) }
    var editing by remember { mutableStateOf(false) }
    var editorModel by remember { mutableStateOf<EditorViewModel?>(null) }
    var pendingTemplate by remember { mutableStateOf<ClipTemplate?>(null) }
    val templates = remember { ClipTemplate.catalog }

    if (editing && editorModel != null) {
        EditorScreen(
            model = editorModel!!,
            onBack = { editing = false; editorModel = null },
        )
        return
    }

    // Drafts list refreshes when you come back from the editor
    var draftsKey by remember { mutableStateOf(0) }
    LaunchedEffect(editing) { if (!editing) draftsKey++ }
    val drafts = remember(draftsKey) { DraftStore.list(context) }

    Column(Modifier.fillMaxSize().background(CS.BG)) {
        when (tab) {
            0 -> HomeScreen(
                onNewProject = { uris ->
                    editorModel = EditorViewModel().also { it.load(context, uris) }
                    editing = true
                },
                onUseTemplate = { template, uris ->
                    editorModel = EditorViewModel().also {
                        it.load(context, uris, speeds = List(uris.size) { i -> template.speedAt(i) },
                            transition = template.transitionIn)
                        template.titleOverlay?.let { t -> it.addText(t) }
                    }
                    editing = true
                },
                templates = templates,
                drafts = drafts,
                onOpenDraft = { name ->
                    DraftStore.restore(context, name)?.let {
                        editorModel = it
                        editing = true
                    }
                },
                onDeleteDraft = { name ->
                    DraftStore.delete(context, name)
                    draftsKey++
                }
            )
            1 -> TemplatesScreen(templates)
            else -> SettingsScreen()
        }
        NavigationBar(containerColor = CS.Surface) {
            listOf("Home" to CSIcons.Home, "Templates" to CSIcons.Templates, "Settings" to CSIcons.Settings)
                .forEachIndexed { index, (label, icon) ->
                    NavigationBarItem(
                        selected = tab == index,
                        onClick = { tab = index },
                        icon = { Icon(icon, label) },
                        label = { Text(label, fontSize = 12.sp) }
                    )
                }
        }
    }
}

@Composable
private fun HomeScreen(
    onNewProject: (List<String>) -> Unit,
    onUseTemplate: (ClipTemplate, List<String>) -> Unit,
    templates: List<ClipTemplate>,
    drafts: List<String>,
    onOpenDraft: (String) -> Unit,
    onDeleteDraft: (String) -> Unit,
) {
    val pickVideos = rememberVideoPicker(
        onPicked = { uris -> onNewProject(uris.map { it.toString() }) }
    )
    val pickForTemplate = rememberVideoPicker(onPicked = { uris ->
        val template = pendingTemplate
        pendingTemplate = null
        if (template != null && uris.isNotEmpty()) {
            editorModel = EditorViewModel().also {
                it.load(context, uris.map { u -> u.toString() },
                    speeds = List(uris.size) { i -> template.speedAt(i) },
                    transition = template.transitionIn)
                template.titleOverlay?.let { t -> it.addText(t) }
            }
            editing = true
        }
    })

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        CSPrimaryButton("New project", CSIcons.NewProject) { pickVideos() }
        Spacer(16.dp)

        Text("Templates", fontSize = 17.sp, color = CS.TextPrimary)
        Spacer(8.dp)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(templates) { template ->
                Column(
                    Modifier.clickable {
                        // Template flow: remember the recipe, then pick clips
                        pendingTemplate = template
                        pickForTemplate()
                    }
                        .background(CS.SurfaceHigh, androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
                        .padding(12.dp)
                ) {
                    Text(template.name, fontSize = 14.sp, color = CS.TextPrimary)
                    Text("${template.uses} uses", fontSize = 11.sp, color = CS.TextSecondary)
                }
            }
        }
        Spacer(16.dp)
        Text("Drafts", fontSize = 17.sp, color = CS.TextPrimary)
        Spacer(8.dp)
        if (drafts.isEmpty()) {
            Text("No drafts yet. Save one from the editor's toolbar.",
                fontSize = 12.sp, color = CS.TextSecondary)
        } else {
            drafts.forEach { name ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        name,
                        fontSize = 14.sp, color = CS.TextPrimary,
                        modifier = Modifier
                            .weight(1f)
                            .clickable { onOpenDraft(name) }
                    )
                    Text("✕", fontSize = 13.sp, color = CS.TextSecondary,
                        modifier = Modifier.clickable { onDeleteDraft(name) })
                }
            }
        }
        Spacer(16.dp)
        Text("Every cut, instantly. 100% offline.", fontSize = 12.sp, color = CS.TextSecondary)
    }
}

@Composable
private fun TemplatesScreen(templates: List<ClipTemplate>) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        Text("Templates", fontSize = 17.sp, color = CS.TextPrimary)
        Spacer(8.dp)
        templates.forEach { template ->
            Column(Modifier.padding(vertical = 8.dp)) {
                Text(template.name, fontSize = 14.sp, color = CS.TextPrimary)
                Text(template.tagline, fontSize = 12.sp, color = CS.TextSecondary)
            }
        }
        Text("All templates are stored on-device — they work without a connection.",
            fontSize = 11.sp, color = CS.TextSecondary)
    }
}

@Composable
private fun SettingsScreen() {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("ClipSpark", fontSize = 17.sp, color = CS.TextPrimary)
        Text("v0.10.0 · 100% offline", fontSize = 12.sp, color = CS.TextSecondary)
    }
}
