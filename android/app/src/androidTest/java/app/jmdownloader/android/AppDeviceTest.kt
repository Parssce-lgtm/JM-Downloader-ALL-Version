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
    @Test fun nativeNavigationAndDeveloperPreview(){compose.onNodeWithContentDescription("设置").performClick();compose.onNodeWithText("开发者功能").performScrollTo().performClick();compose.onNodeWithText("预览").assertExists();compose.onNode(isToggleable()).performClick();compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithContentDescription("返回").performClick();compose.onNodeWithText("PDF 预览").assertExists().performClick();compose.onNodeWithText("更多").performClick();compose.onNodeWithText("按页数排序").assertExists().performClick()}
    @Test fun androidKeystoreSessionRoundTrip(){val vault=SecureVault(compose.activity);vault.put("test","secret-token");assertEquals("secret-token",vault.get("test"));vault.put("test",null);assertNull(vault.get("test"))}
    @Test fun pdfRoundTripAndJMDescramble(){val store=(compose.activity.application as JMApplication).store;runBlocking{store.ready.await()};val f=File(store.pdfRoot,"JM123-device-test.pdf");try{val pdf=PdfDocument();val p=pdf.startPage(PdfDocument.PageInfo.Builder(200,300,1).create());p.canvas.drawColor(android.graphics.Color.WHITE);pdf.finishPage(p);f.outputStream().use{pdf.writeTo(it)};pdf.close();val local=localPDFs(store).first{it.file==f};assertEquals(1,local.pages);assertEquals("123",local.id);val b=android.graphics.Bitmap.createBitmap(20,103,android.graphics.Bitmap.Config.ARGB_8888);for(y in 0 until 103)for(x in 0 until 20)b.setPixel(x,y,android.graphics.Color.rgb(y,0,0));val image=File(compose.activity.cacheDir,"test.png");image.outputStream().use{b.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};val output=decodePage(image,Page("","200000","x.png",1),Platform.JM);ProtocolCrypto.slices(103,10).forEach{s->assertEquals(b.getPixel(0,s.source),output.getPixel(0,s.destination))};b.recycle();output.recycle();image.delete()}finally{f.delete()}}
}
