package app.jmdownloader.android

import android.app.*
import android.content.Intent
import android.graphics.*
import android.graphics.pdf.PdfRenderer
import android.os.*
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.io.MemoryUsageSetting

class DownloadService: Service() {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private lateinit var store: AppStore
    private var pump: Job?=null
    companion object {
        private val running=ConcurrentHashMap<String,Job>()
        fun cancel(id: String){running.remove(id)?.cancel()}
    }
    override fun onBind(intent: Intent?)=null
    override fun onCreate(){super.onCreate();store=(application as JMApplication).store;if(Build.VERSION.SDK_INT>=26)getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("downloads","漫画下载",NotificationManager.IMPORTANCE_LOW));startForeground(180,notification("准备下载"))}
    private fun notification(text: String): Notification {
        val intent=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this,"downloads").setSmallIcon(app.jmdownloader.android.R.drawable.ic_app).setContentTitle("JM downloader").setContentText(text).setContentIntent(intent).setOngoing(true).setOnlyAlertOnce(true).build()
    }
    override fun onStartCommand(intent: Intent?,flags: Int,startId: Int): Int {
        if(pump?.isActive!=true)pump=scope.launch {
            store.ready.await()
            while(isActive){
                val queued=store.state.value.jobs.filter{it.phase==Phase.QUEUED && it.owner==store.state.value.owner && it.comic.platform==store.state.value.settings.platform}
                for(task in queued.take((2-running.size).coerceAtLeast(0))){val job=launch(start=CoroutineStart.LAZY){try{download(task)}finally{running.remove(task.id)}};running[task.id]=job;job.start()}
                if(running.isEmpty() && queued.isEmpty())break
                delay(400)
            }
            store.flush();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf(startId)
        }
        return START_NOT_STICKY
    }
    override fun onDestroy(){scope.cancel();super.onDestroy()}
    // Android 15's data-sync budget can stop a long-running service; leave resumable checkpoints.
    override fun onTimeout(startId: Int,fgsType: Int){store.state.value.jobs.filter{running.containsKey(it.id)}.forEach{store.pause(it.id)};stopSelf()}
    private suspend fun download(initial: DownloadTask){
        val id=initial.id;val work=File(filesDir,"downloads/$id").apply{mkdirs()};val p=store.state.value.settings
        try{
            val api=store.api(initial.owner,p);store.updateJob(id){it.copy(phase=Phase.PREPARING,error="")}
            val pages=initial.pages.ifEmpty{api.manifest(initial.comic)}
            // Reconcile disk and checkpoint after an interrupted write before resuming.
            val done=pages.indices.filter{n->val o=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeFile(File(work,"$n.img").path,o);o.outWidth>0&&o.outHeight>0}.toSet()
            store.updateJob(id){it.copy(phase=Phase.DOWNLOADING,pages=pages,done=done,rendered=0)}
            val media=networkClient(p).newBuilder().followRedirects(true).followSslRedirects(false).callTimeout(60,java.util.concurrent.TimeUnit.SECONDS).build();val sem=Semaphore(p.concurrency.coerceIn(1,6))
            coroutineScope{pages.indices.filterNot{it in done}.map{n->launch{sem.withPermit{
                val page=pages[n];var last: Exception=IOException("图片加载失败");var success=false
                for(url in mediaAlternatives(page.url,initial.comic.platform)){
                    try{
                        val b=Request.Builder().url(url).header("Accept","image/*")
                        if(initial.comic.platform==Platform.JM){b.header("X-Requested-With","com.JMComic3.app").header("Referer","https://${api.session.host}")}
                        val tmp=File(work,"$n.part");media.newCall(b.build()).result().use{r->if(!r.isSuccessful)throw IOException("图片 HTTP ${r.code}");val body=r.body?:throw IOException("图片响应为空");body.byteStream().use{input->tmp.outputStream().use{out->val buffer=ByteArray(32768);var bytes=0L;while(true){ensureActive();val length=input.read(buffer);if(length<0)break;bytes+=length;require(bytes<=80L*1024*1024){"单张图片过大"};out.write(buffer,0,length)}}}}
                        val o=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeFile(tmp.path,o);require(o.outWidth>0&&o.outHeight>0){"图片内容无效"};require(tmp.renameTo(File(work,"$n.img"))){"缓存保存失败"};success=true;break
                    }catch(e:CancellationException){throw e}catch(e:Exception){last=e}
                }
                if(!success)throw last
                store.updateJob(id){it.copy(done=it.done+n)}
            }}}.joinAll()}
            currentCoroutineContext().ensureActive();store.updateJob(id){it.copy(phase=Phase.EXPORTING,rendered=0)}
            val part=File(store.pdfRoot,".${id}.part");val metadata=File(store.pdfRoot,".${id}.meta.part")
            try {
                assemblePDF(work,initial.comic,pages,metadata){n->store.updateJob(id){it.copy(rendered=n)}}
                currentCoroutineContext().ensureActive()
                ParcelFileDescriptor.open(metadata,ParcelFileDescriptor.MODE_READ_ONLY).use{fd->PdfRenderer(fd).use{require(it.pageCount==pages.size){"PDF 页数校验失败"}}}
                currentCoroutineContext().ensureActive()
                val stem="${initial.comic.platform.name}-${initial.comic.id}-${ProtocolCrypto.safeName(initial.comic.title)}"
                var target=File(store.pdfRoot,"$stem.pdf");var suffix=1
                while(target.exists())target=File(store.pdfRoot,"$stem (${suffix++}).pdf")
                require(metadata.renameTo(target)){"PDF 保存失败"};val name=target.name
                store.updateJob(id){it.copy(phase=Phase.COMPLETED,rendered=pages.size,output=target.path)};store.feedback(Section.DOWNLOADS,Feedback("${initial.comic.title} · PDF 已保存",100));store.log("PDF 已保存：$name")
                work.deleteRecursively()
            }finally{part.delete();metadata.delete()}
        }catch(e:CancellationException){store.updateJob(id){if(it.phase!=Phase.COMPLETED)it.copy(phase=Phase.PAUSED)else it};throw e}catch(e:Exception){store.updateJob(id){it.copy(phase=Phase.FAILED,error=e.message?:"下载失败")};store.error(Section.DOWNLOADS,e)}
    }
}
fun decodePage(file: File,page: Page,platform: Platform): Bitmap {
    val o=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeFile(file.path,o);require(o.outWidth>0&&o.outHeight>0)
    var sample=1;while(o.outWidth/sample>2400 || o.outHeight/sample>16000 || o.outWidth.toLong()*o.outHeight/(sample*sample)>16_000_000)sample*=2
    // Descramble at original dimensions to keep slice boundaries exact; refuse unbounded allocations.
    val strips=if(platform==Platform.JM)ProtocolCrypto.strips(page.chapter.toIntOrNull()?:0,page.filename.substringBeforeLast('.'),page.scramble)else 0
    if(strips>0)require(o.outWidth.toLong()*o.outHeight<=36_000_000){"原始图片过大，无法安全解码"}
    val b=BitmapFactory.decodeFile(file.path,BitmapFactory.Options().apply{inSampleSize=if(strips>0)1 else sample})?:throw IOException("图片解码失败")
    if(strips==0)return b
    val out=Bitmap.createBitmap(b.width,b.height,Bitmap.Config.ARGB_8888);val canvas=Canvas(out)
    ProtocolCrypto.slices(b.height,strips).forEach{s->canvas.drawBitmap(b,Rect(0,s.source,b.width,s.source+s.height),Rect(0,s.destination,b.width,s.destination+s.height),null)};b.recycle()
    if(sample>1){val scaled=Bitmap.createScaledBitmap(out,out.width/sample,(out.height/sample).coerceAtLeast(1),true);out.recycle();return scaled};return out
}
fun mediaAlternatives(raw: String,platform: Platform): List<String>{
    val u=raw.toHttpUrl();require(u.isHttps&&u.username.isEmpty()&&u.password.isEmpty()){"图片地址无效"};if(platform!=Platform.PICA)return listOf(raw)
    val storage=listOf("storage-b.picacomic.com","s3.picacomic.com","storage1.diwodiwo.xyz","storage.tipatipa.xyz");val image=listOf("img.picacomic.com","img.diwodiwo.xyz","img.tipatipa.xyz")
    val values=mutableListOf(u.newBuilder().encodedPath(u.encodedPath.replace("/static/tobs/","/static/")).build().toString())
    if(u.host in storage){storage.forEach{values+=u.newBuilder().host(it).build().toString()};if(u.encodedPath.startsWith("/static/tobeimg/"))image.forEach{values+=u.newBuilder().host(it).encodedPath("/"+u.encodedPath.removePrefix("/static/tobeimg/")).build().toString()}}
    if(u.host in image)image.forEach{values+=u.newBuilder().host(it).build().toString()};return values.distinct()
}

// Image streams spill to a private temporary file; a long book does not retain every bitmap.
suspend fun assemblePDF(work: File,comic: Comic,pages: List<Page>,target: File,progress: (Int)->Unit){
    PDDocument(MemoryUsageSetting.setupTempFileOnly().setTempDir(work)).use{document->
        document.documentInformation.apply{title=comic.title;subject="${comic.platform.label} ${comic.id}";keywords=comic.tags.joinToString(",")}
        pages.forEachIndexed{index,page->
            currentCoroutineContext().ensureActive()
            val bitmap=decodePage(File(work,"$index.img"),page,comic.platform)
            try{bitmap.setHasAlpha(false);val sheet=PDPage(PDRectangle(bitmap.width.toFloat(),bitmap.height.toFloat()));document.addPage(sheet);val image=JPEGFactory.createFromImage(document,bitmap,0.94f);PDPageContentStream(document,sheet).use{it.drawImage(image,0f,0f,bitmap.width.toFloat(),bitmap.height.toFloat())}}finally{bitmap.recycle()}
            progress(index+1)
        }
        currentCoroutineContext().ensureActive();document.save(target)
    }
}
