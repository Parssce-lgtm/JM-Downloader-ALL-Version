package app.jmdownloader.android

import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.*
import java.io.File
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.io.MemoryUsageSetting

data class LocalPDF(val file: File,val title: String,val id: String,val tags: List<String>,val pages: Int,val bytes: Long,val date: Long)
fun localPDFs(store: AppStore): List<LocalPDF> = store.pdfRoot.listFiles().orEmpty().filter{it.isFile&&it.extension.equals("pdf",true)&&it.canonicalFile.parentFile==store.pdfRoot.canonicalFile}.mapNotNull{f->try{
    val count=ParcelFileDescriptor.open(f,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->PdfRenderer(fd).use{it.pageCount}}
    val job=store.state.value.jobs.firstOrNull{it.output==f.path};var title=job?.comic?.title?:f.nameWithoutExtension;var tags=job?.comic?.tags.orEmpty();var id=job?.comic?.id.orEmpty()
    PDDocument.load(f,MemoryUsageSetting.setupTempFileOnly()).use{pdf->val info=pdf.documentInformation;title=info.title?.takeIf{it.isNotBlank()}?:title;tags=(tags+info.keywords.orEmpty().split(',','，').map{it.trim()}.filter{it.isNotEmpty()}).distinct();if(id.isEmpty())id=Regex("(?i)(?:JMComic|JM[- _]?)([0-9]+)").find(info.subject.orEmpty()+" "+f.name)?.groupValues?.get(1).orEmpty()}
    LocalPDF(f,title,id,tags,count,f.length(),f.lastModified())
}catch(_:Exception){null}}
fun localMatches(pdf: LocalPDF,query: String): Boolean {val q=query.trim().replace('＃','#');if(q.isEmpty())return true;if(q.startsWith('#'))return pdf.tags.any{TextMatch.normalize(it)==TextMatch.normalize(q.drop(1))};val id=q.replace(Regex("(?i)^jm\\s*"),"");return id==pdf.id&&id.isNotEmpty()||TextMatch.normalize(pdf.title).contains(TextMatch.normalize(q))}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun PDFLibraryScreen(store: AppStore,s: AppState,listState: LazyListState){
    var items by remember{mutableStateOf(emptyList<LocalPDF>())};var loading by remember{mutableStateOf(true)};var query by remember{mutableStateOf("")};var search by remember{mutableStateOf(false)};var sort by remember{mutableStateOf("按时间排序")};var menu by remember{mutableStateOf(false)};var revision by remember{mutableIntStateOf(0)};var reader by remember{mutableStateOf<LocalPDF?>(null)};val scope=rememberCoroutineScope()
    LaunchedEffect(revision,s.jobs.count{it.phase==Phase.COMPLETED}){loading=true;items=withContext(Dispatchers.IO){localPDFs(store)};loading=false}
    val importer=rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()){uris->scope.launch{withContext(Dispatchers.IO){uris.forEach{uri->try{val name=store.context.contentResolver.query(uri,arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),null,null,null)?.use{if(it.moveToFirst())it.getString(0)else null}?:"导入.pdf";val safe=ProtocolCrypto.safeName(name.removeSuffix(".pdf"));var file=File(store.pdfRoot,"$safe.pdf");var n=1;while(file.exists()){file=File(store.pdfRoot,"$safe (${n++}).pdf")};val temp=File(store.pdfRoot,".import-${java.util.UUID.randomUUID()}.part");try{store.context.contentResolver.openInputStream(uri)?.use{input->temp.outputStream().use{output->input.copyTo(output)}}?:error("无法读取文件");ParcelFileDescriptor.open(temp,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->PdfRenderer(fd).use{require(it.pageCount>0)}};require(temp.renameTo(file))}finally{temp.delete()}}catch(e:Exception){store.change{it.copy(alert="导入失败：${e.message}")}}}};revision++}}
    val visible=items.filter{localMatches(it,query)}.sortedWith(when(sort){"按页数排序"->compareByDescending<LocalPDF>{it.pages};"按大小排序"->compareByDescending{it.bytes};else->compareByDescending{it.date}}.thenBy{it.file.name})
    Column{Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){TextButton(onClick={search=true}){Icon(Icons.Outlined.Search,null);Text("搜索")};Spacer(Modifier.weight(1f));Box{TextButton(onClick={menu=true}){Icon(Icons.Outlined.MoreHoriz,null);Text("更多")};DropdownMenu(menu,{menu=false}){listOf("按时间排序","按页数排序","按大小排序").forEach{label->DropdownMenuItem(text={Text(label)},onClick={sort=label;menu=false})};DropdownMenuItem(text={Text("导入 PDF")},onClick={menu=false;importer.launch(arrayOf("application/pdf"))});DropdownMenuItem(text={Text("刷新")},onClick={menu=false;revision++})}}}
        if(query.isNotBlank())TextButton(onClick={query=""}){Text("搜索：$query · 清除")}
        LazyColumn(Modifier.fillMaxSize(),state=listState,contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)){
            if(loading)item{CircularProgressIndicator()}else if(visible.isEmpty())item{Column(Modifier.fillMaxWidth().padding(24.dp)){Text("这里还没有 PDF");Text("将 PDF 放入应用文件根目录，或点击下方按钮导入。");Button(onClick={importer.launch(arrayOf("application/pdf"))}){Text("导入 PDF")}}}
            items(visible,key={it.file.path}){pdf->Card(onClick={reader=pdf},modifier=Modifier.fillMaxWidth()){Row(Modifier.padding(12.dp),verticalAlignment=Alignment.CenterVertically){PDFPageImage(pdf.file,0,Modifier.size(50.dp,76.dp),150);Column(Modifier.padding(start=12.dp).weight(1f)){Text(pdf.title,maxLines=2,overflow=TextOverflow.Ellipsis);Text("${pdf.pages} 页 · ${android.text.format.Formatter.formatFileSize(store.context,pdf.bytes)}",style=MaterialTheme.typography.bodySmall)}}}}
        }
    }
    if(search)AlertDialog(onDismissRequest={search=false},text={OutlinedTextField(query,{query=it},label={Text("漫画名 / JM号 / #精确标签")},singleLine=true)},confirmButton={TextButton(onClick={search=false}){Text("搜索")}})
    reader?.let{pdf->Dialog(onDismissRequest={reader=null},properties=DialogProperties(usePlatformDefaultWidth=false)){Scaffold(topBar={TopAppBar(title={Text(pdf.title,maxLines=1,overflow=TextOverflow.Ellipsis)},navigationIcon={IconButton(onClick={reader=null}){Icon(Icons.Outlined.ArrowBack,"返回")}})}){padding->LazyColumn(Modifier.padding(padding).fillMaxSize(),verticalArrangement=Arrangement.spacedBy(8.dp)){items(pdf.pages){index->Column{Text("${index+1} / ${pdf.pages}",Modifier.padding(8.dp),style=MaterialTheme.typography.labelSmall);PDFPageImage(pdf.file,index,Modifier.fillMaxWidth().heightIn(min=160.dp),1200)}}}}}}
}
@Composable fun PDFPageImage(file: File,index: Int,modifier: Modifier=Modifier,width: Int=1200){
    var bitmap by remember(file.path,index){mutableStateOf<Bitmap?>(null)};var failed by remember{mutableStateOf(false)}
    LaunchedEffect(file.path,index,width){val rendered=withContext(Dispatchers.IO){try{ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->PdfRenderer(fd).use{pdf->pdf.openPage(index).use{page->val h=(width.toLong()*page.height/page.width).coerceIn(1,6000).toInt();Bitmap.createBitmap(width,h,Bitmap.Config.ARGB_8888).also{it.eraseColor(AndroidColor.WHITE);page.render(it,null,null,PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)}}}}}catch(_:Exception){null}};if(isActive){bitmap=rendered;failed=rendered==null}else rendered?.recycle()}
    bitmap?.let{Image(it.asImageBitmap(),"PDF 第 ${index+1} 页",modifier)}?:Box(modifier){if(failed)Text("该页无法预览")else CircularProgressIndicator(Modifier.size(24.dp))}
    // Compose owns the displayed bitmap until this page leaves the lazy list; no document stays open.
}
