# Protocol reference

JM API authentication, response decoding and strip rearrangement are ported from jmcomic 2.7.7 (https://github.com/hect0x7/JMComic-Crawler-Python). No Python runtime or third-party binary is bundled.

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
