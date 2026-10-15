package app.jmdownloader.android
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class ApiTest {
    @Test fun jmLoginFoldersAndManifestPreserveProtocol()=runBlocking {
        val server=MockWebServer();server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
            if(r.requestUrl!!.encodedPath=="/chapter_view_template")return MockResponse().setBody("var scramble_id = 123;")
            val body=when(r.requestUrl!!.encodedPath){
                "/setting"->"{\"jm3_version\":\"2.1.9\"}"
                "/login"->"{\"uid\":\"7\",\"s\":\"session-test\"}"
                "/favorite"->"{\"total\":1,\"list\":[{\"id\":\"123\",\"name\":\"fixture\"}],\"folder_list\":[]}"
                "/album"->"{\"name\":\"fixture\",\"tags\":[\"剧情\"],\"series\":[]}"
                "/chapter"->"{\"images\":[\"a.jpg\",\"b.jpg\"]}"
                else->"{}"
            };return MockResponse().setBody("{\"code\":200,\"data\":$body}")}}
        server.start();try{val api=ComicApi(Platform.JM,Settings(jmHosts="example.com"),testBase=server.url("/").toString().trimEnd('/'));api.login("name","password");val favorites=api.favorites{_,_->};assertEquals(1,favorites.size);val full=api.detail(favorites[0]);assertEquals("123",full.id);assertEquals(listOf("剧情"),full.tags);val pages=api.manifest(full);assertEquals(2,pages.size);assertEquals(123,pages[0].scramble);assertEquals("https://cdn-msp.jmapiproxy1.cc/media/photos/123/a.jpg",pages[0].url);val requests=(0 until server.requestCount).map{server.takeRequest()};assertTrue(requests.filter{it.requestUrl!!.encodedPath=="/favorite"}.all{it.getHeader("Cookie")=="AVS=session-test"});assertTrue(requests.any{it.getHeader("tokenparam")!!.endsWith(",2.1.9")})}finally{server.shutdown()}
    }
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
