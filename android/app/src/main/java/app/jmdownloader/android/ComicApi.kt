package app.jmdownloader.android

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.*

suspend fun Call.result(): Response = suspendCancellableCoroutine { c ->
    c.invokeOnCancellation { cancel() }
    enqueue(object: Callback {
        override fun onFailure(call: Call,e: IOException) { if(c.isActive)c.resumeWithException(NetworkFailure("网络连接失败或超时",e)) }
        override fun onResponse(call: Call,r: Response) { c.resume(r) { _, response, _ -> response.close() } }
    })
}
fun validHost(value: String): String {
    val s=value.trim();require(s.isNotEmpty() && !s.contains(Regex("[/:@?#\\s]"))) { "请填写主机名，不包含协议、路径或账号。" }
    val u="https://$s".toHttpUrl();require(u.host==s.lowercase() && u.port==443);return u.host
}
fun networkClient(p: Settings): OkHttpClient {
    val b=OkHttpClient.Builder().connectTimeout(12,TimeUnit.SECONDS).readTimeout(25,TimeUnit.SECONDS).callTimeout(40,TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false)
    if(p.proxyHost.isNotBlank()) { require(!p.proxyHost.contains(Regex("[/@:]")) && p.proxyPort in 1..65535){"代理主机或端口无效"};b.proxy(Proxy(Proxy.Type.HTTP,InetSocketAddress(p.proxyHost,p.proxyPort))) }
    return b.build()
}
class ComicApi(val platform: Platform, val prefs: Settings, val session: Session=Session(), private val client: OkHttpClient=networkClient(prefs), private val testBase: String?=null) {
    private val permits=Semaphore(if(platform==Platform.PICA)3 else prefs.concurrency.coerceIn(1,6))
    private val failed=java.util.concurrent.ConcurrentHashMap<String,Long>()
    private val hosts=if(platform==Platform.JM)prefs.jmHosts.split(',').map(::validHost).distinct() else listOf(validHost(prefs.picaHost))
    private fun base(host: String)=testBase?:"https://$host"
    private suspend fun request(path: String, params: Map<String,String> = emptyMap(), form: Map<String,String>?=null, json: JSONObject?=null): JSONObject = permits.withPermit {
        if(platform==Platform.PICA)return@withPermit pica(path,params,json)
        var failure: Exception=NetworkFailure("无法连接 JM API")
        val pinned=session.host;val cookies=session.cookies.toMap()
        val routes=(listOf(pinned).filter{it in hosts}+hosts).distinct();val healthy=routes.filter{System.currentTimeMillis()-(failed[it]?:0)>60000}
        for(host in healthy.ifEmpty{routes}) {
            currentCoroutineContext().ensureActive()
            try {
                val time=(System.currentTimeMillis()/1000).toString();val u=(base(host)+path).toHttpUrl().newBuilder();params.forEach{(k,v)->u.addQueryParameter(k,v)}
                val b=Request.Builder().url(u.build()).header("token",ProtocolCrypto.md5(time+if(path=="/chapter_view_template")"18comicAPPContent" else ProtocolCrypto.JM_SECRET)).header("tokenparam","$time,${session.version}").header("User-Agent","Mozilla/5.0 (Linux; Android 9) AppleWebKit/537.36 Chrome/91.0.4472.114 Mobile Safari/537.36")
                if(host==pinned && cookies.isNotEmpty())b.header("Cookie",cookies.entries.joinToString("; "){"${it.key}=${it.value}"})
                if(form!=null)b.post(FormBody.Builder().apply{form.forEach{(k,v)->add(k,v)}}.build())
                client.newCall(b.build()).result().use { r ->
                    if(r.code==401)throw SessionExpired();if(!r.isSuccessful)throw NetworkFailure("JM HTTP ${r.code}")
                    if(host!=pinned && cookies.isNotEmpty()){session.cookies.clear();session.host=host;throw SessionExpired()}
                    Cookie.parseAll(u.build(),r.headers).forEach { session.cookies[it.name]=it.value };session.host=host;failed.remove(host)
                    val raw=r.body?.string()?:throw NetworkFailure("空响应")
                    if(path=="/chapter_view_template")return@withPermit JSONObject().put("html",raw)
                    val envelope=JSONObject(raw);if(envelope.optInt("code") ==401)throw SessionExpired();require(envelope.optInt("code")==200){"JM 拒绝请求（${envelope.optInt("code")}）"}
                    val data=envelope.opt("data");val decoded=if(data is String)JSONTokener(ProtocolCrypto.decrypt(data,time)).nextValue() else data
                    if(decoded is JSONObject)return@withPermit decoded
                    if(path=="/album")throw DetailUnavailable()
                    throw IOException("接口响应不完整，请检查线路")
                }
            } catch(e: CancellationException){throw e} catch(e:SessionExpired){throw e} catch(e:DetailUnavailable){throw e} catch(e:Exception){failure=e;if(e is NetworkFailure)failed[host]=System.currentTimeMillis()}
        }
        throw failure
    }
    private suspend fun pica(path: String,params: Map<String,String>,json: JSONObject?): JSONObject {
        val u=(base(hosts[0])+"/"+path.removePrefix("/")).toHttpUrl().newBuilder();params.forEach{(k,v)->u.addQueryParameter(k,v)};val url=u.build();val route=url.encodedPath.removePrefix("/")+(url.encodedQuery?.let{"?$it"}?:"")
        val time=(System.currentTimeMillis()/1000).toString();val nonce=UUID.randomUUID().toString().replace("-","");val method=if(json==null)"GET" else "POST"
        val b=Request.Builder().url(url).header("api-key",ProtocolCrypto.PICA_KEY).header("accept","application/vnd.picacomic.com.v1+json").header("app-channel","3").header("time",time).header("nonce",nonce).header("signature",ProtocolCrypto.picaSignature(route,method,time,nonce)).header("app-version","2.2.1.3.3.4").header("app-build-version","45").header("app-uuid","defaultUuid").header("app-platform","android").header("image-quality","original").header("User-Agent","okhttp/3.8.1").header("Content-Type","application/json; charset=UTF-8")
        if(session.token.isNotEmpty())b.header("authorization",session.token)
        if(json!=null)b.post(json.toString().toRequestBody("application/json; charset=UTF-8".toMediaType()))
        return client.newCall(b.build()).result().use { r->
            if(r.code==401)throw SessionExpired();if(r.code==404 && path.startsWith("comics/"))throw DetailUnavailable()
            if(r.code==429)throw IOException("线路请求过多，请稍后重试")
            if(!r.isSuccessful)throw NetworkFailure("PicACG HTTP ${r.code}")
            val o=JSONObject(r.body?.string()?:"{}");if(o.optInt("code")==401)throw SessionExpired();require(o.optInt("code")==200){"PicACG 拒绝请求"};o.optJSONObject("data")?:throw IOException("PicACG 响应不完整")
        }
    }
    suspend fun login(user: String,password: String) {
        if(platform==Platform.JM){val setting=request("/setting");setting.optString("jm3_version").takeIf{it.matches(Regex("\\d+\\.\\d+\\.\\d+"))}?.let{session.version=it};val d=request("/login",form=mapOf("username" to user,"password" to password));require(d.optString("uid").isNotEmpty() && d.optString("s").isNotEmpty()){"登录失败，请检查账号密码"};session.cookies["AVS"]=d.getString("s")}
        else{session.token=request("auth/sign-in",json=JSONObject().put("email",user).put("password",password)).getString("token");require(session.token.isNotEmpty())}
    }
    private fun comic(row: JSONObject, folder: String=""): Comic {
        val id=row.optString(if(platform==Platform.JM)"id" else "_id",row.optString("id"));require(if(platform==Platform.JM)id.matches(Regex("[0-9]+")) else id.matches(Regex("[a-fA-F0-9]{24}"))){"无效漫画编号"}
        return Comic(id,row.optString(if(platform==Platform.JM)"name" else "title","未命名漫画"),platform,row.strings("tags"),listOf(folder).filter{it.isNotEmpty()},if(platform==Platform.JM)"https://${validHost(prefs.imageHost)}/media/albums/${id}_3x4.jpg" else row.optJSONObject("thumb")?.let(::mediaURL)?:"",platform==Platform.PICA && row.optJSONArray("tags")!=null)
    }
    suspend fun detail(candidate: Comic): Comic {
        val d=if(platform==Platform.JM)request("/album",mapOf("id" to candidate.id)) else request("comics/${candidate.id}").optJSONObject("comic")?:throw DetailUnavailable()
        if(d.optJSONArray("tags")==null)throw DetailUnavailable()
        if(platform==Platform.JM && d.optString("id").isEmpty())d.put("id",candidate.id)
        val c=comic(d);if(c.id!=candidate.id)throw DetailUnavailable();return c.copy(folders=candidate.folders,verified=true,cover=c.cover.ifEmpty{candidate.cover})
    }
    suspend fun favorites(progress: suspend (Int,Int)->Unit): List<Comic> {
        val result=linkedMapOf<String,Comic>();val folders=ArrayDeque<Pair<String,String>>();folders.add("0" to if(platform==Platform.JM)"默认收藏" else "PicACG 收藏");val visited=mutableSetOf<String>();var count=0;var known=0
        while(folders.isNotEmpty()) {
            val (folder,name)=folders.removeFirst();if(!visited.add(folder))continue
            suspend fun load(page: Int): Triple<List<Comic>,Int,List<Pair<String,String>>> {
                val d=if(platform==Platform.JM)request("/favorite",mapOf("folder_id" to folder,"page" to "$page","o" to "mr")) else request("users/favourite",mapOf("s" to "dd","page" to "$page")).getJSONObject("comics")
                val pages=if(platform==Platform.JM)(d.getInt("total")+19)/20 else d.getInt("pages");require(pages in 0..10000){"收藏分页异常"}
                return Triple(d.getJSONArray(if(platform==Platform.JM)"list" else "docs").objects().map{comic(it,name)},pages.coerceAtLeast(1),d.optJSONArray("folder_list")?.objects()?.map{it.optString("FID") to it.getString("name")}?:emptyList())
            }
            val first=load(1);known+=first.second;val seen=mutableSetOf<String>()
            for(index in 1..first.second){val p=if(index==1)first else load(index);val signature=p.first.joinToString{it.id};require((signature.isEmpty()&&first.second==1)||seen.add(signature)&&signature.isNotEmpty()){"收藏分页重复或缺失"};p.first.forEach { c->val old=result[c.key];result[c.key]=if(old==null)c else old.copy(folders=(old.folders+c.folders).distinct()) };p.third.filter{it.first !in visited}.forEach(folders::add);count++;progress(count,known)}
        }
        return result.values.toList()
    }
    suspend fun searchPage(query: String,page: Int=1,tag: Boolean=false,likes: Boolean=false): SearchPage {
        val numeric=query.trim().replace(Regex("(?i)^jm\\s*"),"")
        if(platform==Platform.JM && numeric.matches(Regex("[0-9]+")) || platform==Platform.PICA && numeric.matches(Regex("[a-fA-F0-9]{24}"))) {
            val c=if(page==1)listOf(detail(Comic(numeric,"",platform))) else emptyList();return SearchPage(c,c.size,1,query)
        }
        val d=if(platform==Platform.JM)request("/search",mapOf("search_query" to query,"page" to "$page","main_tag" to if(tag)"3" else "0","o" to if(likes)"tf" else "mr","t" to "a")) else request("comics/advanced-search",mapOf("page" to "$page"),json=JSONObject().put("categories",JSONArray()).put("keyword",query).put("sort",if(likes)"ld" else "dd")).getJSONObject("comics")
        if(platform==Platform.JM && d.optString("redirect_aid").matches(Regex("[0-9]+"))){val c=detail(Comic(d.getString("redirect_aid"),"",platform));return SearchPage(listOf(c),1,1,query)}
        val rows=d.getJSONArray(if(platform==Platform.JM)"content" else "docs").objects().map{comic(it)};val total=d.optInt("total",rows.size);val pages=if(platform==Platform.JM)(total+rows.size.coerceAtLeast(1)-1)/rows.size.coerceAtLeast(1) else d.optInt("pages",1)
        return SearchPage(rows,total,pages.coerceAtLeast(1),query)
    }
    suspend fun search(query: Query,batch: Int,cache: suspend (Comic)->Unit): SearchBatch = coroutineScope {
        val tags=(query as? Query.Tags)?.values
        val seeds=tags?:listOf((query as Query.Text).value)
        val samples=seeds.map { seed->async { TextMatch.variants(seed).map { v->searchPage(v,1,tags!=null) }.maxBy{it.total} } }.awaitAll()
        val chosen=samples.filter{it.total>0}.minByOrNull{it.total}?:return@coroutineScope SearchBatch(emptyList(),false)
        val start=if(tags!=null)(batch-1)*3+1 else batch;val end=if(tags!=null)minOf(chosen.pages,start+2)else start
        if(start>chosen.pages)return@coroutineScope SearchBatch(emptyList(),false)
        val rows=(start..end).flatMap { n->if(n==1)chosen.comics else searchPage(chosen.query,n,tags!=null).comics }.distinctBy{it.key}
        val full=rows.map { c->async { try{detail(c).also{cache(it)}}catch(e:DetailUnavailable){null} } }.awaitAll().filterNotNull()
        SearchBatch(full.filter { c->if(tags!=null)tags.all{TextMatch.hasTag(c,it)}else TextMatch.ordinary(c,(query as Query.Text).value) },end<chosen.pages)
    }
    private suspend fun paginated(route: String,key: String): List<JSONObject> {
        val all=mutableListOf<JSONObject>();val signatures=mutableSetOf<String>();var n=1;var pages=1
        do{val d=request(route,mapOf("page" to "$n")).getJSONObject(key);pages=d.getInt("pages").coerceAtLeast(1);require(pages<=10000);val rows=d.getJSONArray("docs").objects();val sig=rows.joinToString{it.optString("_id",it.optString("id",it.optString("order")))};require((rows.isEmpty()&&pages==1)||sig.isNotEmpty()&&signatures.add(sig)){"章节分页重复或缺失"};all+=rows;n++}while(n<=pages);return all
    }
    suspend fun manifest(c: Comic): List<Page> {
        val output=mutableListOf<Page>()
        if(platform==Platform.JM){val album=request("/album",mapOf("id" to c.id));val chapters=album.optJSONArray("series")?.objects()?.sortedBy{it.optInt("sort")}?.map{it.optString("id")}.orEmpty().ifEmpty{listOf(c.id)}
            for(id in chapters){val chapter=request("/chapter",mapOf("id" to id));val html=request("/chapter_view_template",mapOf("id" to id,"mode" to "vertical","page" to "0","app_img_shunt" to "1","express" to "off","v" to "${System.currentTimeMillis()/1000}")).getString("html");val scramble=Regex("(?i)(?:scramble[_-]?id)\\s*[\"']?\\s*[:=]\\s*[\"']?(\\d+)").find(html)?.groupValues?.get(1)?.toIntOrNull()?:Int.MAX_VALUE
                chapter.getJSONArray("images").strings().forEach { file->require(!file.contains('/')&&!file.contains(".."));output+=Page("https://${validHost(prefs.imageHost)}/media/photos/$id/$file",id,file,scramble) }}
        }else{for(ep in paginated("comics/${c.id}/eps","eps").sortedBy{it.getInt("order")})for(p in paginated("comics/${c.id}/order/${ep.getInt("order")}/pages","pages")){output+=Page(mediaURL(p.getJSONObject("media")),"${ep.getInt("order")}","${output.size}.jpg")}}
        require(output.isNotEmpty()){"漫画没有可下载页面"};return output
    }
    companion object {
        fun mediaURL(m: JSONObject): String { val root=m.getString("fileServer").trimEnd('/').toHttpUrl();require(root.isHttps && root.username.isEmpty() && root.password.isEmpty() && root.query==null && root.fragment==null);val path=m.getString("path").trimStart('/');require(path.isNotEmpty() && path.split('/').none{it==".."});return (root.toString().trimEnd('/')+if(root.encodedPath.trimEnd('/').endsWith("/static"))"/$path" else "/static/$path").replace("/static/static/","/static/") }
    }
}
