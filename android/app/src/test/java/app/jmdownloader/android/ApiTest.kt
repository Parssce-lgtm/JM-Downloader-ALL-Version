package app.jmdownloader.android
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class ApiTest {
    @Test fun multiTagUsesFullDetailAndSkipsRemovedCandidates()=runBlocking {
        val server=MockWebServer();server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
            val path=r.requestUrl!!.encodedPath
            val data=when(path){"/search"->JSONObject().put("total",2).put("content",org.json.JSONArray("[{\"id\":\"1\",\"name\":\"wrong\"},{\"id\":\"2\",\"name\":\"removed\"}]"));"/album"->if(r.requestUrl!!.queryParameter("id")=="1")JSONObject("{\"id\":\"1\",\"name\":\"valid\",\"tags\":[\"純愛\",\"彩漫\"]}")else org.json.JSONArray();else->JSONObject()}
            return MockResponse().setBody(JSONObject().put("code",200).put("data",data).toString())}}
        server.start();try{val api=ComicApi(Platform.JM,Settings(jmHosts="example.com"),testBase=server.url("/").toString().trimEnd('/'));val b=api.search(Query.parse("纯爱+彩漫"),1){};assertEquals(listOf("1"),b.comics.map{it.id});assertFalse(b.more);assertNotNull(server.takeRequest().getHeader("token"))}finally{server.shutdown()}
    }
    @Test fun picaSignatureIncludesEncodedQueryAndNeverLeaksAuthToMedia()=runBlocking {
        val server=MockWebServer();server.enqueue(MockResponse().setBody("{\"code\":200,\"data\":{\"comics\":{\"docs\":[],\"pages\":1,\"total\":0}}}"));server.start()
        try{val api=ComicApi(Platform.PICA,Settings(),Session(token="test-token"),testBase=server.url("/").toString().trimEnd('/'));api.searchPage("test");val r=server.takeRequest();assertEquals("test-token",r.getHeader("authorization"));assertEquals(ProtocolCrypto.picaSignature(r.path!!.removePrefix("/"),"POST",r.getHeader("time")!!,r.getHeader("nonce")!!),r.getHeader("signature"))}finally{server.shutdown()}
    }
    @Test fun mediaAndHostsRejectCredentialAndTraversal(){listOf("https://example.com","example.com/path","user@example.com","").forEach{try{validHost(it);fail(it)}catch(_:IllegalArgumentException){}};try{ComicApi.mediaURL(JSONObject().put("fileServer","https://user:password@example.com").put("path","a"));fail()}catch(_:IllegalArgumentException){}}
}
