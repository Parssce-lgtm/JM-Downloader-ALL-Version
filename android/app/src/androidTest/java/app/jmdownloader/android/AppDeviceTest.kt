package app.jmdownloader.android
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.*
import android.graphics.pdf.PdfDocument
import java.io.File
import kotlinx.coroutines.runBlocking

class AppDeviceTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun imageAssemblyPreservesPagesAndMetadata()=runBlocking {
        val store=(compose.activity.application as JMApplication).store;store.ready.await()
        val work=File(compose.activity.cacheDir,"export-device-test").apply{mkdirs()};val output=File(work,"test.pdf")
        try{val bitmap=android.graphics.Bitmap.createBitmap(100,160,android.graphics.Bitmap.Config.ARGB_8888);bitmap.eraseColor(android.graphics.Color.WHITE);(0..2).forEach{n->File(work,"$n.img").outputStream().use{bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}};bitmap.recycle();val pages=(0..2).map{Page("","1","$it.png")};val c=Comic("123","测试漫画",tags=listOf("純愛","彩漫"));var progress=0;assemblePDF(work,c,pages,output){progress=it};assertEquals(3,progress);android.os.ParcelFileDescriptor.open(output,android.os.ParcelFileDescriptor.MODE_READ_ONLY).use{fd->android.graphics.pdf.PdfRenderer(fd).use{pdf->assertEquals(3,pdf.pageCount)}};com.tom_roush.pdfbox.pdmodel.PDDocument.load(output).use{pdf->assertEquals("测试漫画",pdf.documentInformation.title);assertEquals("純愛,彩漫",pdf.documentInformation.keywords)}}finally{work.deleteRecursively()}
    }
    @Test fun nativeNavigationAndDeveloperPreview(){compose.onNodeWithContentDescription("设置").performClick();compose.onNodeWithText("开发者功能").performScrollTo().performClick();compose.onNodeWithText("预览").assertExists();compose.onNode(isToggleable()).performClick();compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("PDF 预览").assertExists().performClick();compose.onNodeWithText("更多").performClick();compose.onNodeWithText("按页数排序").assertExists().performClick()}
    @Test fun androidKeystoreSessionRoundTrip(){val vault=SecureVault(compose.activity);vault.put("test","secret-token");assertEquals("secret-token",vault.get("test"));vault.put("test",null);assertNull(vault.get("test"))}
    @Test fun pdfRoundTripAndJMDescramble(){val store=(compose.activity.application as JMApplication).store;runBlocking{store.ready.await()};val f=File(store.pdfRoot,"JM123-device-test.pdf");try{val pdf=PdfDocument();val p=pdf.startPage(PdfDocument.PageInfo.Builder(200,300,1).create());p.canvas.drawColor(android.graphics.Color.WHITE);pdf.finishPage(p);f.outputStream().use{pdf.writeTo(it)};pdf.close();val local=localPDFs(store).first{it.file==f};assertEquals(1,local.pages);assertEquals("123",local.id);val b=android.graphics.Bitmap.createBitmap(20,103,android.graphics.Bitmap.Config.ARGB_8888);for(y in 0 until 103)for(x in 0 until 20)b.setPixel(x,y,android.graphics.Color.rgb(y,0,0));val image=File(compose.activity.cacheDir,"test.png");image.outputStream().use{b.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};val output=decodePage(image,Page("","200000","x.png",1),Platform.JM);ProtocolCrypto.slices(103,10).forEach{s->assertEquals(b.getPixel(0,s.source),output.getPixel(0,s.destination))};b.recycle();output.recycle();image.delete()}finally{f.delete()}}
}
