package app.jmdownloader.android

import com.ibm.icu.text.Transliterator
import java.text.Normalizer
import java.util.Locale
import java.util.UUID
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import okio.ByteString.Companion.decodeBase64
import org.json.JSONArray
import org.json.JSONObject

enum class Platform(val label: String) { JM("JMComic"), PICA("PicACG") }
enum class Section(val label: String) { PDF("PDF 预览"), DOWNLOADS("下载任务"), FAVORITES("漫画收藏"), RECOMMENDATIONS("漫画推荐") }
enum class Phase(val label: String, val order: Int) { DOWNLOADING("下载中",0), EXPORTING("生成 PDF",1), PREPARING("读取章节",2), QUEUED("等待下载",3), PAUSED("已暂停",4), FAILED("加载失败",5), COMPLETED("已完成",6) }
data class Comic(val id: String, val title: String, val platform: Platform = Platform.JM, val tags: List<String> = emptyList(), val folders: List<String> = emptyList(), val cover: String = "", val verified: Boolean = false, val reason: String = "") {
    val key get() = "${platform.name}:$id"
}
data class Page(val url: String, val chapter: String, val filename: String, val scramble: Int = Int.MAX_VALUE)
data class DownloadTask(val id: String = UUID.randomUUID().toString(), val owner: String, val comic: Comic, val phase: Phase = Phase.QUEUED, val pages: List<Page> = emptyList(), val done: Set<Int> = emptySet(), val rendered: Int = 0, val output: String = "", val created: Long = System.currentTimeMillis(), val error: String = "", val approved: Boolean = false) {
    val fraction get() = if(pages.isEmpty()) 0f else (if(phase==Phase.EXPORTING) rendered else done.size).toFloat()/pages.size
    val label get() = if(phase==Phase.EXPORTING) "${(fraction*100).toInt().coerceIn(0,99)}%" else if(pages.isEmpty()) "${comic.platform.label} ${comic.id}" else "${done.size} / ${pages.size} 张"
}
data class Settings(val platform: Platform = Platform.JM, val jmHosts: String = "www.cdnhjk.net,www.cdngwc.cc,www.cdngwc.net,www.cdngwc.club", val imageHost: String = "cdn-msp.jmapiproxy1.cc", val picaHost: String = "picaapi.picacomic.com", val proxyHost: String = "", val proxyPort: Int = 7890, val concurrency: Int = 6, val remember: Boolean = true, val autoDownload: Boolean = false, val preview: Boolean = false, val appearance: String = "跟随系统", val dynamicColors: Boolean = true, val tagBlacklist: String = "", val titleBlacklist: String = "")
data class Library(val username: String, val platform: Platform, val favorites: List<Comic> = emptyList(), val recommendations: List<Comic> = emptyList(), val excluded: List<Comic> = emptyList(), val hidden: Set<String> = emptySet(), val disliked: Set<String> = emptySet())
data class Feedback(val message: String = "准备就绪", val percent: Int = 0, val busy: Boolean = false, val network: Boolean = false, val failure: Boolean = false)
data class SearchState(val query: String = "", val results: List<Comic> = emptyList(), val page: Int = 0, val more: Boolean = false, val feedback: Feedback = Feedback())
data class AppState(val settings: Settings = Settings(), val owner: String = "", val libraries: Map<String,Library> = emptyMap(), val jobs: List<DownloadTask> = emptyList(), val searches: Map<Section,SearchState> = emptyMap(), val feedback: Map<Section,Feedback> = emptyMap(), val logs: List<String> = emptyList(), val pendingDislikes: Set<String> = emptySet(), val alert: String? = null) {
    val library get() = libraries[owner]
    val visibleJobs get() = jobs.filter { it.comic.platform==settings.platform && it.owner==owner }.sortedWith(compareBy<DownloadTask>{it.phase.order}.thenByDescending{it.created})
}
data class SearchPage(val comics: List<Comic>, val total: Int, val pages: Int, val query: String)
data class SearchBatch(val comics: List<Comic>, val more: Boolean)
class SessionExpired: Exception("登录会话已过期，请重新登录。")
class DetailUnavailable: Exception("漫画详情不可用。")
class NetworkFailure(message: String, cause: Throwable? = null): Exception(message,cause)
data class Session(var host: String = "", var version: String = "2.1.7", var token: String = "", var cookies: MutableMap<String,String> = java.util.concurrent.ConcurrentHashMap())

object TextMatch {
    private val simplifier = object: ThreadLocal<Transliterator>() { override fun initialValue()=Transliterator.getInstance("Traditional-Simplified") }
    private val traditional = object: ThreadLocal<Transliterator>() { override fun initialValue()=Transliterator.getInstance("Simplified-Traditional") }
    fun normalize(s: String): String = simplifier.get().transliterate(Normalizer.normalize(s,Normalizer.Form.NFKC)).trim().lowercase(Locale.ROOT)
    fun variants(s: String): List<String> = listOf(s, simplifier.get().transliterate(s),traditional.get().transliterate(simplifier.get().transliterate(s))).distinct()
    fun hasTag(comic: Comic, tag: String) = normalize(tag).isNotEmpty() && comic.tags.any { normalize(it)==normalize(tag) }
    fun ordinary(comic: Comic, query: String): Boolean { val q=normalize(query); return q.isNotEmpty() && (normalize(comic.title).contains(q) || comic.id==q.removePrefix("jm").trim() || comic.tags.any { normalize(it).contains(q) }) }
    fun tokens(s: String) = s.split(',', '，','\n').map(::normalize).filter(String::isNotEmpty)
    fun blocked(comic: Comic, settings: Settings) = comic.tags.any { tag -> tokens(settings.tagBlacklist).any { normalize(tag).contains(it) } } || tokens(settings.titleBlacklist).any { normalize(comic.title).contains(it) }
}
sealed class Query {
    data class Text(val value: String): Query()
    data class Tags(val values: List<String>): Query()
    companion object {
        fun parse(raw: String): Query {
            val s=raw.trim().replace('＋','+').replace('＃','#')
            if(s.contains('+')) { val tags=s.split('+').map{it.trim().removePrefix("#").trim()}; require(tags.all{it.isNotEmpty()}){"请在 + 两侧输入完整标签。"}; return Tags(tags.distinctBy(TextMatch::normalize)) }
            if(s.startsWith('#')) { val tag=s.drop(1).trim(); require(tag.isNotEmpty()){"请输入 # 后面的标签。"}; return Tags(listOf(tag)) }
            require(s.isNotEmpty()){"请输入搜索内容。"};return Text(s)
        }
    }
}
object ProtocolCrypto {
    const val JM_SECRET = "185Hcomic3PAPP7R"
    const val PICA_KEY = "C69BAF41DA5ABD1FFEDC6D2FEA56B"
    private val picaSecret = "fmR9JFE3JGVJbmk9Vik5XFJLL1AuUk00OzlbN3xAL0NBfWJ+T1chMz9FVmA6PD5NN3BkZFVCTDVufDAvKkNu".decodeBase64()!!.toByteArray()
    fun digest(algorithm: String, bytes: ByteArray) = MessageDigest.getInstance(algorithm).digest(bytes).joinToString(""){"%02x".format(it.toInt() and 255)}
    fun md5(s: String) = digest("MD5",s.toByteArray(Charsets.UTF_8))
    fun decrypt(data: String, time: String): String { val cipher=Cipher.getInstance("AES/ECB/PKCS5Padding");cipher.init(Cipher.DECRYPT_MODE,SecretKeySpec(md5(time+JM_SECRET).toByteArray(Charsets.UTF_8),"AES"));return cipher.doFinal((data.decodeBase64()?:throw IllegalArgumentException("无效的接口编码")).toByteArray()).toString(Charsets.UTF_8) }
    fun picaSignature(route: String, method: String, time: String, nonce: String): String { val mac=Mac.getInstance("HmacSHA256");mac.init(SecretKeySpec(picaSecret,"HmacSHA256"));return mac.doFinal((route+time+nonce+method+PICA_KEY).lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8)).joinToString(""){"%02x".format(it.toInt() and 255)} }
    fun strips(chapter: Int, filename: String, scramble: Int): Int { if(chapter<scramble)return 0;if(chapter<268850)return 10;val mod=if(chapter<421926)10 else 8;return (md5("$chapter$filename").last().code % mod)*2+2 }
    data class Slice(val source: Int,val destination: Int,val height: Int)
    fun slices(height: Int,count: Int): List<Slice> { if(count<=0)return listOf(Slice(0,0,height));val step=height/count;val rem=height%count;return (0 until count).map { Slice(height-step*(it+1)-rem,step*it+if(it==0)0 else rem,step+if(it==0)rem else 0) } }
    fun safeName(s: String) = s.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"),"_").take(120).trim().ifEmpty{"漫画"}
}
fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
fun JSONObject.strings(key: String) = optJSONArray(key)?.strings() ?: emptyList()
fun JSONObject.stringSet(key: String) = strings(key).toSet()
fun comicJson(c: Comic)=JSONObject().put("id",c.id).put("title",c.title).put("platform",c.platform.name).put("tags",JSONArray(c.tags)).put("folders",JSONArray(c.folders)).put("cover",c.cover).put("verified",c.verified).put("reason",c.reason)
fun readComic(o: JSONObject)=Comic(o.getString("id"),o.getString("title"),Platform.valueOf(o.optString("platform","JM")),o.strings("tags"),o.strings("folders"),o.optString("cover"),o.optBoolean("verified"),o.optString("reason"))
fun pageJson(p: Page)=JSONObject().put("url",p.url).put("chapter",p.chapter).put("filename",p.filename).put("scramble",p.scramble)
fun readPage(o: JSONObject)=Page(o.getString("url"),o.getString("chapter"),o.getString("filename"),o.optInt("scramble",Int.MAX_VALUE))
object SnapshotCodec {
    fun encode(s: AppState): JSONObject {
        val p=s.settings;val settings=JSONObject().put("platform",p.platform.name).put("jmHosts",p.jmHosts).put("imageHost",p.imageHost).put("picaHost",p.picaHost).put("proxyHost",p.proxyHost).put("proxyPort",p.proxyPort).put("concurrency",p.concurrency).put("remember",p.remember).put("autoDownload",p.autoDownload).put("preview",p.preview).put("appearance",p.appearance).put("dynamicColors",p.dynamicColors).put("tagBlacklist",p.tagBlacklist).put("titleBlacklist",p.titleBlacklist)
        val libraries=JSONObject();s.libraries.forEach { (key,l) -> libraries.put(key,JSONObject().put("username",l.username).put("platform",l.platform.name).put("favorites",JSONArray(l.favorites.map(::comicJson))).put("recommendations",JSONArray(l.recommendations.map(::comicJson))).put("excluded",JSONArray(l.excluded.map(::comicJson))).put("hidden",JSONArray(l.hidden)).put("disliked",JSONArray(l.disliked))) }
        val jobs=JSONArray(s.jobs.map { j->JSONObject().put("id",j.id).put("owner",j.owner).put("comic",comicJson(j.comic)).put("phase",j.phase.name).put("pages",JSONArray(j.pages.map(::pageJson))).put("done",JSONArray(j.done)).put("rendered",j.rendered).put("output",j.output).put("created",j.created).put("error",j.error).put("approved",j.approved) })
        return JSONObject().put("schema",1).put("owner",s.owner).put("settings",settings).put("libraries",libraries).put("jobs",jobs)
    }
    fun decode(o: JSONObject): AppState {
        val d=Settings();val p=o.optJSONObject("settings")?:JSONObject();val settings=Settings(Platform.valueOf(p.optString("platform",d.platform.name)),p.optString("jmHosts",d.jmHosts),p.optString("imageHost",d.imageHost),p.optString("picaHost",d.picaHost),p.optString("proxyHost",d.proxyHost),p.optInt("proxyPort",d.proxyPort),p.optInt("concurrency",d.concurrency),p.optBoolean("remember",d.remember),p.optBoolean("autoDownload"),p.optBoolean("preview"),p.optString("appearance",d.appearance),p.optBoolean("dynamicColors",true),p.optString("tagBlacklist"),p.optString("titleBlacklist"))
        val libraries=mutableMapOf<String,Library>();val ls=o.optJSONObject("libraries")?:JSONObject();ls.keys().forEach { key -> val l=ls.getJSONObject(key);libraries[key]=Library(l.getString("username"),Platform.valueOf(l.getString("platform")),l.optJSONArray("favorites")?.objects()?.map(::readComic)?:emptyList(),l.optJSONArray("recommendations")?.objects()?.map(::readComic)?:emptyList(),l.optJSONArray("excluded")?.objects()?.map(::readComic)?:emptyList(),l.stringSet("hidden"),l.stringSet("disliked")) }
        val jobs=o.optJSONArray("jobs")?.objects()?.map { j->DownloadTask(j.getString("id"),j.getString("owner"),readComic(j.getJSONObject("comic")),Phase.valueOf(j.getString("phase")),j.optJSONArray("pages")?.objects()?.map(::readPage)?:emptyList(),j.optJSONArray("done")?.let { a->(0 until a.length()).map{a.getInt(it)}.toSet() }?:emptySet(),j.optInt("rendered"),j.optString("output"),j.optLong("created"),j.optString("error"),j.optBoolean("approved")) }?:emptyList()
        return AppState(settings=settings,owner=o.optString("owner"),libraries=libraries,jobs=jobs)
    }
}
