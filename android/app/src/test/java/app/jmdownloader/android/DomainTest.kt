package app.jmdownloader.android
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class DomainTest {
    @Test fun exactTagsAreAndAcrossChineseScripts(){val c=Comic("1","标题",tags=listOf("純愛","彩漫"));val q=Query.parse("#纯爱＋#彩漫") as Query.Tags;assertTrue(q.values.all{TextMatch.hasTag(c,it)});assertFalse(TextMatch.hasTag(c,"爱"));assertFalse(TextMatch.hasTag(c,"彩"));assertEquals(q,Query.parse("纯爱+彩漫"))}
    @Test fun malformedQueriesAreRejected(){listOf("","#","a+","+b","a++b").forEach{try{Query.parse(it);fail(it)}catch(_:IllegalArgumentException){}}}
    @Test fun fuzzyTitleBlacklistNormalizesChinese(){assertTrue(TextMatch.blocked(Comic("1","名偵探"),Settings(titleBlacklist="侦探")));assertTrue(TextMatch.blocked(Comic("1","title",tags=listOf("純愛")),Settings(tagBlacklist="纯爱")))}
    @Test fun everyDescrambleRowIsCoveredExactlyOnce(){for(h in listOf(100,101,1037,2401))for(n in listOf(2,4,6,8,10,16)){val slices=ProtocolCrypto.slices(h,n);assertEquals((0 until h).toList(),slices.flatMap{(it.source until it.source+it.height).toList()}.sorted());assertEquals((0 until h).toList(),slices.flatMap{(it.destination until it.destination+it.height).toList()}.sorted())}}
    @Test fun taskOrderAndAccountIsolation(){val c=Comic("1","x");val jobs=listOf(Phase.COMPLETED,Phase.EXPORTING,Phase.DOWNLOADING,Phase.PAUSED).map{DownloadTask(owner="a",comic=c,phase=it)}+DownloadTask(owner="b",comic=c);assertEquals(listOf(Phase.DOWNLOADING,Phase.EXPORTING,Phase.PAUSED,Phase.COMPLETED),AppState(owner="a",jobs=jobs).visibleJobs.map{it.phase})}
    @Test fun snapshotRoundTripKeepsExclusionsAndCheckpoints(){val c=Comic("12","名字",tags=listOf("剧情"),verified=true);val state=AppState(owner="JM:a",settings=Settings(preview=true),libraries=mapOf("JM:a" to Library("a",Platform.JM,excluded=listOf(c),hidden=setOf(c.key))),jobs=listOf(DownloadTask(owner="JM:a",comic=c,pages=listOf(Page("https://example.com/a","1","a.jpg")),done=setOf(0),phase=Phase.PAUSED)));assertEquals(state,SnapshotCodec.decode(SnapshotCodec.encode(state)));assertFalse(SnapshotCodec.encode(state).toString().contains("password"))}
    @Test fun publicProtocolVectors(){assertEquals("900150983cd24fb0d6963f7d28e17f72",ProtocolCrypto.md5("abc"));assertEquals(64,ProtocolCrypto.picaSignature("comics?page=1","GET","123","nonce").length);assertEquals(0,ProtocolCrypto.strips(1,"a",2));assertEquals(10,ProtocolCrypto.strips(200000,"a",1))}
    @Test fun pdfExactTagDoesNotMatchTitle(){val p=LocalPDF(java.io.File("/tmp/a.pdf"),"纯爱","12",listOf("彩漫"),1,1,1);assertFalse(localMatches(p,"#纯爱"));assertTrue(localMatches(p,"JM12"));assertTrue(localMatches(p,"#彩漫"))}
}
