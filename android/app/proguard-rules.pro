-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-keep class com.ibm.icu.impl.** { *; }
-keep class com.ibm.icu.text.Transliterator { *; }
-keep class com.tom_roush.pdfbox.** { *; }
-keep class com.tom_roush.fontbox.** { *; }

-keep class com.ibm.icu.** { *; }

# Optional JPEG 2000 codec is not used: preview uses Android PdfRenderer, export uses JPEG.
-dontwarn com.gemalto.jp2.**
