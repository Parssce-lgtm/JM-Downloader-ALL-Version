package app.jmdownloader.android

import android.app.Application
import android.content.Context
import android.content.Intent
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import androidx.core.content.ContextCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import org.json.*
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class JMApplication: Application(), coil.ImageLoaderFactory {
    lateinit var store: AppStore
    override fun onCreate(){super.onCreate();com.tom_roush.pdfbox.android.PDFBoxResourceLoader.init(this);store=AppStore(this)}
    override fun newImageLoader()=coil.ImageLoader.Builder(this).okHttpClient{networkClient(store.state.value.settings).newBuilder().followRedirects(true).build()}.build()
}
class SecureVault(context: Context) {
    private val prefs=context.getSharedPreferences("vault",Context.MODE_PRIVATE)
    private fun key(): SecretKey { val ks=KeyStore.getInstance("AndroidKeyStore").apply{load(null)};return (ks.getKey("jm.sessions",null) as? SecretKey)?:KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply{init(KeyGenParameterSpec.Builder("jm.sessions",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())}.generateKey() }
    @Synchronized fun put(id: String,value: String?) {if(value==null){prefs.edit().remove(id).commit();return};val c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.ENCRYPT_MODE,key());prefs.edit().putString(id,Base64.encodeToString(c.iv+c.doFinal(value.toByteArray()),Base64.NO_WRAP)).commit()}
    @Synchronized fun get(id: String): String? = try{prefs.getString(id,null)?.let{val bytes=Base64.decode(it,Base64.NO_WRAP);val c=Cipher.getInstance("AES/GCM/NoPadding");c.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,bytes.copyOfRange(0,12)));c.doFinal(bytes.copyOfRange(12,bytes.size)).toString(Charsets.UTF_8)}}catch(_:Exception){prefs.edit().remove(id).commit();null}
}
class AppStore(val context: Context) {
    val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val snapshot=AtomicFile(File(context.filesDir,"library.json"))
    private val diskLock=Mutex();private val stateLock=Any();private var saveJob: Job?=null
    val vault=SecureVault(context)
    private val mutable=MutableStateFlow(AppState())
    val state: StateFlow<AppState> = mutable.asStateFlow()
    private val apis=java.util.concurrent.ConcurrentHashMap<String,ComicApi>()
    private val operations=java.util.concurrent.ConcurrentHashMap<Section,Job>();private val generations=java.util.concurrent.ConcurrentHashMap<Section,Long>()
    private val cacheLock=Mutex();private val tags=java.util.concurrent.ConcurrentHashMap<String,Comic>()
    private val cacheFile=AtomicFile(File(context.filesDir,"tags.json"));private var cacheSave: Job?=null
    val ready=CompletableDeferred<Unit>()
    val pdfRoot: File get()=(context.getExternalFilesDir(null)?:File(context.filesDir,"pdf")).apply{mkdirs()}
    init {scope.launch {
        try {val loaded=SnapshotCodec.decode(JSONObject(snapshot.openRead().bufferedReader().use{it.readText()}));change{loaded.copy(jobs=loaded.jobs.map{j->if(j.phase in setOf(Phase.DOWNLOADING,Phase.EXPORTING,Phase.PREPARING,Phase.QUEUED))j.copy(phase=Phase.PAUSED)else j})}}catch(_:java.io.FileNotFoundException){}catch(_:Exception){change{it.copy(alert="本地记录无法读取，原文件已保留。")}}
        try{val o=JSONObject(cacheFile.openRead().bufferedReader().use{it.readText()});o.keys().forEach { tags[it]=readComic(o.getJSONObject(it)) }}catch(_:Exception){}
        ready.complete(Unit)
    }}
    fun change(transform: (AppState)->AppState){synchronized(stateLock){mutable.value=transform(mutable.value)}}
    fun persist(){saveJob?.cancel();saveJob=scope.launch{delay(300);flush()}}
    suspend fun flush(){diskLock.withLock { val bytes=SnapshotCodec.encode(state.value).toString().toByteArray();val out=snapshot.startWrite();try{out.write(bytes);snapshot.finishWrite(out)}catch(e:Exception){snapshot.failWrite(out);throw e} }}
    fun feedback(section: Section,f: Feedback){change{it.copy(feedback=it.feedback+(section to f))}}
    fun log(message: String){change{it.copy(logs=(it.logs+message).takeLast(300))}}
    fun error(section: Section,e: Throwable){if(e is CancellationException)return;val network=e is NetworkFailure || e is SessionExpired;feedback(section,Feedback(if(network)"网络已断开" else "加载失败",network=network,failure=!network));log(e.message?:"加载失败");if(e is SessionExpired)change{it.copy(alert=e.message)}}
    fun settings(p: Settings){require(p.concurrency in 1..12);p.jmHosts.split(',').forEach(::validHost);validHost(p.imageHost);validHost(p.picaHost);networkClient(p);val old=state.value.settings;change{it.copy(settings=p,owner=if(old.platform!=p.platform)it.libraries.entries.firstOrNull{e->e.value.platform==p.platform}?.key.orEmpty()else it.owner,searches=if(old.platform!=p.platform)emptyMap()else it.searches)};if(old!=p)apis.clear();persist()}
    private fun storedSession(id: String): Session { val o=vault.get("session:$id")?.let(::JSONObject)?:return Session();val c=o.optJSONObject("cookies")?:JSONObject();return Session(o.optString("host"),o.optString("version","2.1.7"),o.optString("token"),java.util.concurrent.ConcurrentHashMap<String,String>().apply{c.keys().forEach{put(it,c.getString(it))}}) }
    fun api(owner: String=state.value.owner,prefs: Settings=state.value.settings): ComicApi {
        require(owner.isNotEmpty()){"请先登录账号"};val library=state.value.libraries[owner]?:error("账号不存在");return apis.getOrPut(owner){ComicApi(library.platform,prefs,storedSession(owner))}
    }
    private fun saveSession(id: String,a: ComicApi){if(state.value.settings.remember)vault.put("session:$id",JSONObject().put("host",a.session.host).put("version",a.session.version).put("token",a.session.token).put("cookies",JSONObject(a.session.cookies.toMap())).toString())else vault.put("session:$id",null)}
    fun login(user: String,password: String,onDone: (Boolean)->Unit){scope.launch{
        try{require(user.isNotBlank()&&password.isNotEmpty()){"请输入账号和密码"};val p=state.value.settings;val id="${p.platform.name}:${user.trim().lowercase()}";val a=ComicApi(p.platform,p);a.login(user.trim(),password);apis[id]=a;saveSession(id,a);change{s->s.copy(owner=id,libraries=s.libraries+(id to (s.libraries[id]?:Library(user.trim(),p.platform))),searches=emptyMap(),feedback=emptyMap())};persist();withContext(Dispatchers.Main){onDone(true)};refresh(Section.FAVORITES)}catch(e:Exception){change{it.copy(alert=e.message?:"登录失败")};withContext(Dispatchers.Main){onDone(false)}}
    }}
    fun logout(){operations.values.forEach{it.cancel()};val owner=state.value.owner;pauseAll();scope.launch{vault.put("session:$owner",null)};apis.remove(owner);change{it.copy(owner="",searches=emptyMap())};persist()}
    suspend fun cache(owner: String,c: Comic){tags["$owner|${c.key}"]=c;cacheSave?.cancel();cacheSave=scope.launch{delay(500);cacheLock.withLock{val o=JSONObject();tags.forEach{(k,v)->o.put(k,comicJson(v))};val out=cacheFile.startWrite();try{out.write(o.toString().toByteArray());cacheFile.finishWrite(out)}catch(e:Exception){cacheFile.failWrite(out)}}}}
    private fun enriched(owner: String,c: Comic)=tags["$owner|${c.key}"]?.copy(folders=c.folders)?:c
    fun search(section: Section,raw: String,more: Boolean=false){
        operations[section]?.cancel();val owner=state.value.owner;val token=(generations[section]?:0)+1;generations[section]=token
        operations[section]=scope.launch{
            val previous=state.value.searches[section];val batch=if(more && previous?.query==raw)previous.page+1 else 1
            change{it.copy(searches=it.searches+(section to SearchState(raw,if(batch>1)previous?.results.orEmpty()else emptyList(),batch,feedback=Feedback("正在搜索…",busy=true))))};feedback(section,Feedback("正在搜索…",busy=true))
            try{val q=Query.parse(raw);val a=api(owner);val b=a.search(q,batch){cache(owner,it)};ensureActive();if(state.value.owner!=owner||generations[section]!=token)return@launch
                val rows=((if(batch>1)previous?.results.orEmpty()else emptyList())+b.comics).distinctBy{it.key}.filterNot{TextMatch.blocked(it,state.value.settings)};val f=Feedback("搜索完成，共 ${rows.size} 部",100);change{it.copy(searches=it.searches+(section to SearchState(raw,rows,batch,b.more,f)))};feedback(section,f);saveSession(owner,a)
            }catch(e:Exception){if(generations[section]==token && state.value.owner==owner){error(section,e);change{s->s.copy(searches=s.searches+(section to (s.searches[section]?:SearchState(raw)).copy(feedback=s.feedback[section]?:Feedback())))}}}
        }
    }
    fun clearSearch(section: Section){operations[section]?.cancel();generations[section]=(generations[section]?:0)+1;change{it.copy(searches=it.searches-section)}}
    fun refresh(section: Section){
        state.value.searches[section]?.query?.takeIf{it.isNotEmpty()}?.let{search(section,it);return}
        operations[section]?.cancel();val owner=state.value.owner;val token=(generations[section]?:0)+1;generations[section]=token
        operations[section]=scope.launch{
            feedback(section,Feedback(if(section==Section.FAVORITES)"正在加载"else"正在搜索…",busy=true));change{it.copy(pendingDislikes=emptySet())}
            try{val a=api(owner);val favorites=a.favorites { n,total->if(state.value.owner==owner)feedback(section,Feedback("读取收藏分页 · $n/$total · ${n*100/total}%",n*100/total,busy=true)) }.map{enriched(owner,it)}
                ensureActive();if(state.value.owner!=owner||generations[section]!=token)return@launch
                change{s->val l=s.libraries[owner]!!;s.copy(libraries=s.libraries+(owner to l.copy(favorites=favorites)))};persist()
                if(section==Section.RECOMMENDATIONS){
                    val sem=kotlinx.coroutines.sync.Semaphore(if(a.platform==Platform.PICA)3 else 6);var done=0
                    val complete=coroutineScope { favorites.map { c->async { val full=if(c.verified)c else sem.withPermit{try{a.detail(c).also{cache(owner,it)}}catch(_:DetailUnavailable){c}};synchronized(stateLock){done++;if(done%8==0||done==favorites.size)feedback(section,Feedback("读取收藏标签 · $done/${favorites.size}",if(favorites.isEmpty())0 else done*40/favorites.size,busy=true))};full } }.awaitAll() }
                    change{s->val l=s.libraries[owner]!!;s.copy(libraries=s.libraries+(owner to l.copy(favorites=complete)))};persist()
                    val weights=complete.flatMap{it.tags}.groupingBy(TextMatch::normalize).eachCount();val seeds=weights.entries.sortedByDescending{it.value}.take(8).map{it.key};val ids=complete.map{it.key}.toSet();val candidates=linkedMapOf<String,Comic>()
                    for((index,seed) in seeds.withIndex()){a.searchPage(seed,tag=true,likes=true).comics.forEach{if(it.key !in ids)candidates[it.key]=it};feedback(section,Feedback("检索推荐 · ${index+1}/${seeds.size}",40+(index+1)*20/seeds.size,busy=true))}
                    val list=candidates.values.toList();done=0
                    val verified=coroutineScope{list.map{c->async{val full=sem.withPermit{try{enriched(owner,c).let{if(it.verified)it else a.detail(c).also{cache(owner,it)}}}catch(_:DetailUnavailable){null}};synchronized(stateLock){done++;if(done%8==0||done==list.size)feedback(section,Feedback("核验推荐漫画 · $done/${list.size}",60+done*40/list.size.coerceAtLeast(1),busy=true))};full}}.awaitAll().filterNotNull()}
                    val l=state.value.libraries[owner]!!;val excluded=l.excluded.map{it.key}.toSet();val recommendations=verified.filter{c->!TextMatch.blocked(c,state.value.settings)&&c.key !in excluded&&c.tags.any{TextMatch.normalize(it) in weights}}.sortedByDescending{c->c.tags.sumOf{weights[TextMatch.normalize(it)]?:0}}.map{c->c.copy(reason="收藏标签匹配："+c.tags.filter{TextMatch.normalize(it) in weights}.take(3).joinToString("、"))}
                    ensureActive();if(state.value.owner!=owner||generations[section]!=token)return@launch
                    change{s->s.copy(libraries=s.libraries+(owner to s.libraries[owner]!!.copy(recommendations=recommendations)))};feedback(section,Feedback("推荐加载完成，共 ${recommendations.size} 部",100))
                }else feedback(section,Feedback("收藏加载完成，共 ${favorites.size} 部",100))
                saveSession(owner,a);persist()
                if(state.value.settings.autoDownload && section==Section.FAVORITES)favorites.forEach{enqueue(it,false)}
            }catch(e:Exception){if(state.value.owner==owner && generations[section]==token)error(section,e)}
        }
    }
    fun mutateLibrary(f: (Library)->Library){val owner=state.value.owner;change{s->s.libraries[owner]?.let{s.copy(libraries=s.libraries+(owner to f(it)))}?:s};persist()}
    fun exclude(c: Comic){mutateLibrary{l->l.copy(excluded=if(l.excluded.any{it.key==c.key})l.excluded.filterNot{it.key==c.key}else l.excluded+c)}}
    fun dislike(c: Comic){mutateLibrary{it.copy(excluded=(it.excluded+c).distinctBy{v->v.key},disliked=it.disliked+c.key)};change{it.copy(pendingDislikes=it.pendingDislikes+c.key)}}
    fun hide(c: Comic){mutateLibrary{it.copy(hidden=if(c.key in it.hidden)it.hidden-c.key else it.hidden+c.key,excluded=if(c.key in it.hidden)it.excluded.filterNot{v->v.key==c.key}else (it.excluded+c).distinctBy{v->v.key})}}
    fun restore(c: Comic){mutateLibrary{it.copy(excluded=it.excluded.filterNot{v->v.key==c.key},hidden=it.hidden-c.key,disliked=it.disliked-c.key)}}
    fun enqueue(c: Comic,approved: Boolean){val s=state.value;if(s.owner.isEmpty()){change{it.copy(alert="请先登录")};return};if(!approved&&s.library?.excluded?.any{it.key==c.key}==true)return
        val old=s.jobs.firstOrNull{it.owner==s.owner&&it.comic.key==c.key};if(old?.phase==Phase.COMPLETED)return
        change{it.copy(jobs=if(old==null)it.jobs+DownloadTask(owner=s.owner,comic=c,approved=approved)else it.jobs.map{j->if(j.id==old.id)j.copy(phase=Phase.QUEUED,approved=approved,error="")else j})};persist();startService()
    }
    fun updateJob(id: String,f: (DownloadTask)->DownloadTask){change{s->s.copy(jobs=s.jobs.map{if(it.id==id)f(it)else it})};persist()}
    fun pause(id: String){updateJob(id){it.copy(phase=Phase.PAUSED)};DownloadService.cancel(id)}
    fun pauseAll(){state.value.visibleJobs.filter{it.phase !in setOf(Phase.COMPLETED,Phase.PAUSED,Phase.FAILED)}.forEach{pause(it.id)}}
    fun startAll(){val s=state.value;val excluded=s.library?.excluded?.map{it.key}.orEmpty().toSet();s.visibleJobs.filter{it.phase in setOf(Phase.PAUSED,Phase.FAILED,Phase.QUEUED)&&it.comic.key !in excluded}.forEach{enqueue(it.comic,false)}}
    fun delete(id: String){pause(id);val root=File(context.filesDir,"downloads").canonicalFile;scope.launch{File(root,id).canonicalFile.takeIf{it.parentFile==root}?.deleteRecursively();change{it.copy(jobs=it.jobs.filterNot{j->j.id==id})};persist()}}
    private fun startService(){ContextCompat.startForegroundService(context,Intent(context,DownloadService::class.java))}
}
