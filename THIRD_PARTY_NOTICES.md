# Protocol reference

JM API authentication, response decoding and strip rearrangement are ported from jmcomic 2.7.7 (https://github.com/hect0x7/JMComic-Crawler-Python). The iOS application does not bundle Python or third-party binaries. The independent Android application uses the libraries listed below.

MIT License

Copyright (c) 2023 hect0x7

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## PicACG protocol interoperability

PicACG request headers, HMAC signing, routes and media URL formats follow the protocol reference in the user-provided Windows adapter and tonquer/picacg-qt (https://github.com/tonquer/picacg-qt). The Swift networking implementation is written for this project using Foundation and CryptoKit. No third-party PicACG runtime or binaries are bundled.

Media route compatibility (tobeimg/tobs and known image CDN names) was checked against https://github.com/tonquer/picacg-qt/blob/main/src/server/req.py on 2026-10-11. These protocol mappings are independently implemented with URLComponents and URLSession; no Python code or third-party media is packaged.

Recommendation scoring and tag filtering are project-specific logic; no personal account data or credentials are bundled.


# Android dependencies

- AndroidX / Jetpack Compose: Apache License 2.0, Google and Android Open Source Project contributors.
- Kotlin / kotlinx.coroutines: Apache License 2.0, JetBrains contributors.
- OkHttp: Apache License 2.0, Square contributors.
- Coil: Apache License 2.0, Coil contributors.
- PDFBox-Android / Apache PDFBox / FontBox: Apache License 2.0, Tom Roush and Apache Software Foundation contributors.
- ICU4J 76.1: Unicode/ICU license, Unicode, Inc. and contributors.
- desugar_jdk_libs: GPLv2 with Classpath Exception, OpenJDK contributors; Android support portions use Apache License 2.0.

The Android APK retains dependency LICENSE / NOTICE resources. Apache License 2.0 is also included in app assets. Dependency versions are pinned in android/app/build.gradle.kts.
