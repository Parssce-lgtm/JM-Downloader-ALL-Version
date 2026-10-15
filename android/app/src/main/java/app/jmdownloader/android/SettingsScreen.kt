package app.jmdownloader.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun SettingsScreen(store: AppStore,s: AppState,onBack: ()->Unit){
    var destination by rememberSaveable{mutableStateOf("")};var user by rememberSaveable{mutableStateOf("")};var password by remember{mutableStateOf("")};var busy by remember{mutableStateOf(false)};var p by remember(s.settings){mutableStateOf(s.settings)};var error by remember{mutableStateOf<String?>(null)}
    fun save(value: Settings){try{store.settings(value)}catch(e:Exception){error=e.message}}
    androidx.activity.compose.BackHandler {if(destination.isEmpty())onBack()else destination=""}
    Scaffold(topBar={TopAppBar(title={Text(destination.ifEmpty{"设置"})},navigationIcon={IconButton(onClick={if(destination.isEmpty())onBack()else destination=""}){Icon(Icons.Outlined.ArrowBack,"返回")}})}){padding->LazyColumn(Modifier.padding(padding).fillMaxSize(),contentPadding=PaddingValues(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
        when(destination){
            ""->{
                item{Text("切换平台",style=MaterialTheme.typography.titleMedium);SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()){Platform.entries.forEachIndexed{i,platform->SegmentedButton(selected=s.settings.platform==platform,onClick={save(s.settings.copy(platform=platform))},shape=SegmentedButtonDefaults.itemShape(i,Platform.entries.size)){Text(platform.label)}}}}
                item{HorizontalDivider();Text(s.library?.let{"${it.platform.label} · ${it.username}"}?:"尚未登录",Modifier.padding(top=12.dp));if(s.owner.isNotEmpty())TextButton(onClick={store.logout()}){Text("退出登录")}}
                item{OutlinedTextField(user,{user=it},label={Text(if(s.settings.platform==Platform.JM)"用户名"else"邮箱")},singleLine=true,modifier=Modifier.fillMaxWidth())}
                item{OutlinedTextField(password,{password=it},label={Text("密码")},visualTransformation=PasswordVisualTransformation(),singleLine=true,modifier=Modifier.fillMaxWidth())}
                item{Button(onClick={busy=true;store.login(user,password){success->busy=false;if(success)password=""}},enabled=!busy,modifier=Modifier.fillMaxWidth()){Text(if(busy)"正在登录…"else"登录")}}
                item{SettingSwitch("记住登录会话",s.settings.remember){save(s.settings.copy(remember=it))}}
                item{HorizontalDivider()}
                items(listOf("API 与代理","下载设置","黑名单","已排除/隐藏","主题设置","缓存与文件")){label->FilledTonalButton(onClick={destination=label},modifier=Modifier.fillMaxWidth()){Text(label)}}
                item{Spacer(Modifier.height(12.dp));HorizontalDivider();Spacer(Modifier.height(12.dp));OutlinedButton(onClick={destination="开发者功能"},modifier=Modifier.fillMaxWidth()){Text("开发者功能")}}
                item{TextButton(onClick={destination="关于"},modifier=Modifier.fillMaxWidth()){Text("关于 · 1.8.0")}}
            }
            "API 与代理"->{
                item{Text("仅填写 HTTPS 主机名；多个 JM API 使用英文逗号分隔。")}
                item{OutlinedTextField(p.jmHosts,{p=p.copy(jmHosts=it)},label={Text("JM API 主机")},modifier=Modifier.fillMaxWidth())}
                item{OutlinedTextField(p.imageHost,{p=p.copy(imageHost=it)},label={Text("JM 图片主机")},modifier=Modifier.fillMaxWidth())}
                item{OutlinedTextField(p.picaHost,{p=p.copy(picaHost=it)},label={Text("PicACG API 主机")},modifier=Modifier.fillMaxWidth())}
                item{OutlinedTextField(p.proxyHost,{p=p.copy(proxyHost=it)},label={Text("HTTP CONNECT 代理主机（可选）")},modifier=Modifier.fillMaxWidth())}
                item{OutlinedTextField(p.proxyPort.toString(),{p=p.copy(proxyPort=it.toIntOrNull()?:0)},label={Text("代理端口")},modifier=Modifier.fillMaxWidth())}
                item{Button(onClick={save(p)}){Text("保存")}}
            }
            "下载设置"->{item{Text("图片并发：${s.settings.concurrency}");Slider(value=s.settings.concurrency.toFloat(),onValueChange={save(s.settings.copy(concurrency=it.toInt().coerceIn(1,12)))},valueRange=1f..12f,steps=10)};item{SettingSwitch("自动下载收藏",s.settings.autoDownload){save(s.settings.copy(autoDownload=it))}};item{Text("已排除的漫画不会随全部开始或自动下载启动。点击单独下载时需要确认。\nPDF 保存位置：${store.pdfRoot.path}")}}
            "黑名单"->{item{OutlinedTextField(p.tagBlacklist,{p=p.copy(tagBlacklist=it)},label={Text("标签黑名单（逗号或换行分隔）")},modifier=Modifier.fillMaxWidth())};item{OutlinedTextField(p.titleBlacklist,{p=p.copy(titleBlacklist=it)},label={Text("漫画名黑名单（支持模糊屏蔽）")},modifier=Modifier.fillMaxWidth())};item{Button(onClick={save(p)}){Text("保存")}}}
            "已排除/隐藏"->{items(s.library?.excluded.orEmpty(),key={it.key}){c->Card{Row(Modifier.padding(12.dp),verticalAlignment=Alignment.CenterVertically){coil.compose.AsyncImage(c.cover,"封面",Modifier.size(44.dp,66.dp));Text(c.title,Modifier.weight(1f).padding(12.dp),maxLines=2);Icon(if(c.key in s.library?.hidden.orEmpty())Icons.Outlined.VisibilityOff else if(c.key in s.library?.disliked.orEmpty())Icons.Outlined.ThumbDown else Icons.Outlined.Block,null);TextButton(onClick={store.restore(c)}){Text("取消排除")}}}}}
            "主题设置"->{items(listOf("跟随系统","浅色","深色")){mode->Row(verticalAlignment=Alignment.CenterVertically){RadioButton(s.settings.appearance==mode,{save(s.settings.copy(appearance=mode))});Text(mode)}};item{SettingSwitch("Material You 动态配色",s.settings.dynamicColors){save(s.settings.copy(dynamicColors=it))}}}
            "缓存与文件"->{item{Text("PDF 文件根目录：${store.pdfRoot.path}\n\n使用 PDF 预览页面的“导入 PDF”可以从文件管理器导入，文件直接保存在根目录。")};item{Button(onClick={store.scope.launch{val root=java.io.File(store.context.cacheDir,"image_cache");root.deleteRecursively();withContext(Dispatchers.Main){error="封面缓存已清理"}}}){Text("清理封面缓存")}}}
            "开发者功能"->{item{SettingSwitch("预览",s.settings.preview){save(s.settings.copy(preview=it))}};item{Text("开启后，顶部左侧显示 PDF 预览。读取应用文件根目录中的 PDF，不需要新建文件夹。")}}
            "关于"->{item{Text("JM-Downloader ALL Version",style=MaterialTheme.typography.titleLarge);Text("Android 1.8.0 (1)\n最低 Android 7.0 · 原生 Material 3\nAndroid 12 及以上支持 Material You 动态配色。\n\n源码：github.com/Parssce-lgtm/JM-Downloader-ALL-Version\n\n仅下载你有权访问和保存的内容。",Modifier.padding(top=16.dp))}}
        }
    }}
    val message=error?:s.alert
    if(message!=null)AlertDialog(onDismissRequest={error=null;store.change{it.copy(alert=null)}},text={Text(message)},confirmButton={TextButton(onClick={error=null;store.change{it.copy(alert=null)}}){Text("确认")}})
}
@Composable fun SettingSwitch(label: String,value: Boolean,onChange: (Boolean)->Unit){Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){Text(label,Modifier.weight(1f));Switch(value,onChange)}}
