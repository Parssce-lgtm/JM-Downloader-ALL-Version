package app.jmdownloader.android

import android.Manifest
import android.os.Build
import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.pager.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.launch
import java.io.File

class MainActivity: ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?){super.onCreate(savedInstanceState);setContent{val store=(application as JMApplication).store;val state by store.state.collectAsStateWithLifecycle();JMTheme(state.settings){MainScreen(store,state)}}}
}
@Composable fun JMTheme(p: Settings,content: @Composable ()->Unit){val dark=when(p.appearance){"深色"->true;"浅色"->false;else->isSystemInDarkTheme()};val context=LocalContext.current;val colors=if(p.dynamicColors&&Build.VERSION.SDK_INT>=31){if(dark)dynamicDarkColorScheme(context)else dynamicLightColorScheme(context)}else if(dark)darkColorScheme()else lightColorScheme();MaterialTheme(colorScheme=colors,content=content)}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun MainScreen(store: AppStore,s: AppState){
    val scope=rememberCoroutineScope();val pages=remember(s.settings.preview){Section.entries.filter{it!=Section.PDF||s.settings.preview}};val pager=rememberPagerState(initialPage=if(s.settings.preview)2 else 1,pageCount={pages.size});var settings by rememberSaveable{mutableStateOf(false)};var logs by remember{mutableStateOf(false)};var cover by remember{mutableStateOf<Comic?>(null)};val listStates=Section.entries.associateWith{rememberLazyListState()}
    val notifications=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){}
    LaunchedEffect(Unit){store.ready.await();if(Build.VERSION.SDK_INT>=33)notifications.launch(Manifest.permission.POST_NOTIFICATIONS)}
    if(settings){SettingsScreen(store,s){settings=false};return}
    val selected=pages.getOrElse(pager.currentPage){Section.FAVORITES};val f=s.feedback[selected]?:Feedback(if(selected==Section.DOWNLOADS)"准备就绪 · 下载文件保存在应用文件根目录"else"准备就绪")
    Scaffold(
        topBar = {
            Column {
                CenterAlignedTopAppBar(
                    title = {
                        TextButton(onClick = { scope.launch { listStates[selected]?.animateScrollToItem(0) } }) {
                            Text("JM downloader", color = MaterialTheme.colorScheme.onSurface, fontWeight = FontWeight.Bold)
                        }
                    },
                    actions = { IconButton(onClick = { settings = true }) { Icon(Icons.Outlined.Settings, "设置") } }
                )
                PrimaryScrollableTabRow(selectedTabIndex = pager.currentPage.coerceAtMost(pages.lastIndex), edgePadding = 0.dp) {
                    pages.forEachIndexed { index, page ->
                        Tab(selected = pager.currentPage == index,
                            onClick = { scope.launch { pager.animateScrollToPage(index) } },
                            text = { Text(page.label, maxLines = 1) })
                    }
                }
            }
        },
        bottomBar = {
            if (selected != Section.PDF) {
                Surface(
                    onClick = { if (selected == Section.DOWNLOADS) logs = true },
                    modifier = Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth(),
                    shape = RoundedCornerShape(32.dp), tonalElevation = 3.dp
                ) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.ChatBubbleOutline, "提示")
                        Text(f.message, Modifier.weight(1f).padding(horizontal = 12.dp), maxLines = 1,
                            overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                        if (f.busy) Text("${f.percent}%", style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    ) { padding ->
        HorizontalPager(pager, Modifier.padding(padding).fillMaxSize(), key = { pages[it].name }) { index ->
            val section = pages[index]
            if (section == Section.PDF) PDFLibraryScreen(store, s, listStates.getValue(section))
            else LibraryScreen(store, s, section, listStates.getValue(section), active = pager.currentPage == index,
                onCover = { cover = it })
        }
    }
    s.alert?.let{AlertDialog(onDismissRequest={store.change{v->v.copy(alert=null)}},confirmButton={TextButton(onClick={store.change{v->v.copy(alert=null)}}){Text("确认")}},text={Text(it)})}
    if(logs)ModalBottomSheet(onDismissRequest={logs=false}){LazyColumn(Modifier.fillMaxWidth().heightIn(max=500.dp).padding(20.dp)){item{Text("提示记录",style=MaterialTheme.typography.titleLarge)};items(s.logs){Text(it,Modifier.padding(vertical=8.dp))}}}
    cover?.let{c->ModalBottomSheet(onDismissRequest={cover=null}){AsyncImage(model=c.cover,contentDescription=c.title,modifier=Modifier.fillMaxWidth().heightIn(max=600.dp).padding(16.dp))}}
}

@OptIn(ExperimentalFoundationApi::class,ExperimentalMaterial3Api::class)
@Composable fun LibraryScreen(store: AppStore,s: AppState,section: Section,listState: LazyListState,active: Boolean,onCover: (Comic)->Unit){
    var searchOpen by rememberSaveable(section){mutableStateOf(false)};var input by rememberSaveable(section){mutableStateOf("")};var menu by remember{mutableStateOf(false)};var filter by rememberSaveable{mutableStateOf("普通")};var folder by rememberSaveable{mutableStateOf("")};var folderMenu by remember{mutableStateOf(false)}
    var confirmation by remember{mutableStateOf<Comic?>(null)};var deleting by remember{mutableStateOf<DownloadTask?>(null)}
    val search=s.searches[section];val feedback=s.feedback[section]?:Feedback();val library=s.library;val downloaded=s.jobs.filter{it.owner==s.owner&&it.phase==Phase.COMPLETED}.map{it.comic.key}.toSet();val excluded=library?.excluded?.map{it.key}.orEmpty().toSet()
    LaunchedEffect(active,s.owner){if(active&&s.owner.isNotEmpty()&&section!=Section.DOWNLOADS&&s.feedback[section]==null&&search==null)store.refresh(section)}
    fun request(c: Comic){if(c.key in excluded)confirmation=c else store.enqueue(c,false)}
    val rows=if(search!=null)search.results else if(section==Section.FAVORITES)library?.favorites.orEmpty().filter{c->when(filter){"已下载"->c.key in downloaded;"已隐藏"->c.key in library?.hidden.orEmpty();else->c.key !in downloaded && c.key !in library?.hidden.orEmpty()}}.filter{folder.isEmpty()||folder in it.folders} else library?.recommendations.orEmpty().filter{it.key !in excluded||it.key in s.pendingDislikes}
    Column {
        Row(Modifier.fillMaxWidth().padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically){
            if(section==Section.DOWNLOADS){Text("漫画下载状态",Modifier.weight(1f),style=MaterialTheme.typography.titleMedium);Text("${s.visibleJobs.size} 个任务",style=MaterialTheme.typography.bodySmall)}
            else{TextButton(onClick={searchOpen=true;input=search?.query.orEmpty()}){Icon(Icons.Outlined.Search,null);Text("搜索")};if(section==Section.FAVORITES)Box{TextButton(onClick={folderMenu=true}){Icon(Icons.Outlined.FolderOpen,null);Text(if(folder.isEmpty())"收藏夹"else folder)};DropdownMenu(folderMenu,{folderMenu=false}){DropdownMenuItem(text={Text("全部收藏夹")},onClick={folder="";folderMenu=false});library?.favorites.orEmpty().flatMap{it.folders}.distinct().forEach{f->DropdownMenuItem(text={Text(f)},onClick={folder=f;folderMenu=false})}}};Spacer(Modifier.weight(1f))}
            Box{IconButton(onClick={menu=true}){Icon(Icons.Outlined.MoreHoriz,"更多")};DropdownMenu(menu,{menu=false}){
                if(section==Section.DOWNLOADS){DropdownMenuItem(text={Text("全部开始")},onClick={menu=false;store.startAll()});DropdownMenuItem(text={Text("全部暂停")},onClick={menu=false;store.pauseAll()})}
                else{DropdownMenuItem(text={Text("刷新")},onClick={menu=false;store.refresh(section)});if(section==Section.FAVORITES){listOf("已下载","已隐藏").forEach{f->DropdownMenuItem(text={Text(if(filter==f)"关闭查看$f"else"查看$f")},onClick={filter=if(filter==f)"普通"else f;menu=false})}}}
            }}
        }
        if(search!=null)Row(Modifier.padding(horizontal=20.dp),verticalAlignment=Alignment.CenterVertically){Text("搜索：${search.query}",Modifier.weight(1f),maxLines=1,overflow=TextOverflow.Ellipsis);TextButton(onClick={store.clearSearch(section)}){Text("返回${if(section==Section.FAVORITES)"收藏"else"推荐"}")}}
        if(section==Section.DOWNLOADS)Row(Modifier.fillMaxWidth().padding(horizontal=12.dp)){TextButton(onClick={store.startAll()}){Icon(Icons.Outlined.PlayArrow,null);Text("全部开始")};Spacer(Modifier.weight(1f));TextButton(onClick={store.pauseAll()}){Icon(Icons.Outlined.Pause,null);Text("全部暂停")}}
        LazyColumn(Modifier.fillMaxSize(),state=listState,contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
            if(section==Section.DOWNLOADS){items(s.visibleJobs,key={it.id}){job->ComicCard(job.comic,job=job,dim=false,onCover={onCover(job.comic)},action={if(job.phase in setOf(Phase.DOWNLOADING,Phase.EXPORTING,Phase.QUEUED,Phase.PREPARING))store.pause(job.id)else if(job.phase==Phase.COMPLETED)openPDF(store,job.output)else request(job.comic)},menuItems=listOf((if(job.comic.key in excluded)"取消排除该漫画"else"排除该漫画") to {store.exclude(job.comic)},"删除任务及下载缓存" to {deleting=job}))}}
            else{items(rows,key={it.key}){c->ComicCard(c,dim=c.key in s.pendingDislikes,onCover={onCover(c)},action={request(c)},menuItems=if(section==Section.RECOMMENDATIONS)listOf("不喜欢该漫画" to {store.dislike(c)})else listOf((if(c.key in library?.hidden.orEmpty())"关闭隐藏漫画"else"隐藏漫画") to {store.hide(c)}))}
                if(rows.isEmpty())item{Column(Modifier.fillMaxWidth().padding(vertical=48.dp),horizontalAlignment=Alignment.CenterHorizontally){if(feedback.busy)CircularProgressIndicator(Modifier.size(56.dp))else Icon(if(feedback.network)Icons.Outlined.WifiOff else if(feedback.failure)Icons.Outlined.ErrorOutline else Icons.Outlined.MenuBook,null,Modifier.size(56.dp));Text(if(feedback.busy||feedback.failure||feedback.network)feedback.message else if(s.owner.isEmpty())"请先在设置中登录"else"这里还没有漫画",Modifier.padding(16.dp));if(s.owner.isNotEmpty()&&!feedback.busy)TextButton(onClick={store.refresh(section)}){Text("刷新")}}}
                if(search?.more==true)item{TextButton(onClick={store.search(section,search.query,true)},modifier=Modifier.fillMaxWidth(),enabled=!feedback.busy){Text("加载更多")}}
            }
        }
    }
    if(searchOpen)AlertDialog(onDismissRequest={searchOpen=false},title={Text("搜索漫画")},text={OutlinedTextField(input,{input=it},label={Text("漫画名 / JM号 / #标签 / 标签+标签")},singleLine=true)},confirmButton={TextButton(onClick={searchOpen=false;store.search(section,input)}){Text("搜索")}},dismissButton={TextButton(onClick={searchOpen=false}){Text("取消")}})
    confirmation?.let{c->AlertDialog(onDismissRequest={confirmation=null},text={Text("是否下载该漫画？（该漫画已被排除）")},confirmButton={TextButton(onClick={confirmation=null;store.enqueue(c,true)}){Text("确认")}})}
    deleting?.let{job->AlertDialog(onDismissRequest={deleting=null},text={Text("删除任务及下载缓存？已保存的 PDF 会保留。")},confirmButton={TextButton(onClick={deleting=null;store.delete(job.id)}){Text("确认",color=MaterialTheme.colorScheme.error)}})}
}

@OptIn(ExperimentalFoundationApi::class)
@Composable fun ComicCard(c: Comic,job: DownloadTask?=null,dim: Boolean=false,onCover: ()->Unit,action: ()->Unit,menuItems: List<Pair<String,()->Unit>>){
    var menu by remember{mutableStateOf(false)};val context=LocalContext.current
    Card(Modifier.fillMaxWidth().alpha(if(dim)0.35f else 1f).combinedClickable(onClick=onCover,onLongClick={menu=true}),shape=RoundedCornerShape(26.dp)){
        Row(Modifier.padding(12.dp).heightIn(min=88.dp),verticalAlignment=Alignment.CenterVertically){AsyncImage(model=ImageRequest.Builder(context).data(c.cover).crossfade(true).build(),contentDescription="封面",modifier=Modifier.size(52.dp,78.dp));Column(Modifier.weight(1f).padding(start=12.dp)){Text(c.title,maxLines=2,overflow=TextOverflow.Ellipsis,fontWeight=FontWeight.SemiBold);if(job!=null){LinearProgressIndicator(progress={if(job.phase==Phase.EXPORTING)1f-job.fraction else job.fraction},modifier=Modifier.fillMaxWidth().padding(top=8.dp));Row(Modifier.fillMaxWidth()){Text(job.phase.label,Modifier.weight(1f),style=MaterialTheme.typography.bodySmall);Text(job.label,style=MaterialTheme.typography.bodySmall)}}else Text(c.reason.ifEmpty{"${c.platform.label} ${c.id}"},maxLines=1,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)};IconButton(onClick=action){Icon(when(job?.phase){Phase.DOWNLOADING,Phase.EXPORTING,Phase.PREPARING,Phase.QUEUED->Icons.Outlined.PauseCircle;Phase.COMPLETED->Icons.Outlined.PictureAsPdf;Phase.PAUSED,Phase.FAILED->Icons.Outlined.PlayCircle;else->Icons.Outlined.Download},"${if(job==null)"下载"else job.phase.label}")}}
        DropdownMenu(menu,{menu=false}){menuItems.forEach{(label,action)->DropdownMenuItem(text={Text(label)},onClick={menu=false;action()})}}
    }
}
fun openPDF(store: AppStore,path: String){try{val file=File(path);require(file.exists());val uri=FileProvider.getUriForFile(store.context,"${BuildConfig.APPLICATION_ID}.files",file);store.context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri,"application/pdf").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))}catch(_:Exception){store.change{it.copy(alert="请启用设置 → 开发者功能 → 预览，在应用内阅读 PDF。")}}}
