# 第三方许可

## Webamp — MIT
https://github.com/captbaritone/webamp — Copyright (c) 2015 Jordan Eldredge

`Packages/MP9Kit/Sources/MP9Skin/SkinSprites.swift` 中的精灵图坐标、控件位置与字体映射移植自 Webamp。

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## AMSMB2 / libsmb2 — LGPL-2.1
- https://github.com/amosavian/AMSMB2 — Copyright (c) Amir Abbas Mousavian
- https://github.com/sahlberg/libsmb2 — Copyright (c) Ronnie Sahlberg

AMSMB2 的 SwiftPM 产品声明为 `type: .dynamic`，以 `AMSMB2.framework` 动态库形式嵌入 App，用户可以替换该框架，满足 LGPL-2.1 第 6 节的要求。未修改其源码。

## Monkey's Audio SDK 13.43 — BSD-3-Clause
https://monkeysaudio.com — Copyright 2000-2026 Matthew T. Ashland

`Packages/MP9Kit/Sources/MonkeysAudio/vendor/` 是 SDK 中解码所需的源码，未修改；完整许可见该目录下的 `License.txt`。Monkey's Audio 自 10.18 版（2023-08）起改为 3-Clause BSD。

## swift-atomics — Apache-2.0
https://github.com/apple/swift-atomics — Copyright (c) Apple Inc.（AMSMB2 的依赖）

## 默认皮肤与字体
“MP9 Graphite” 默认皮肤与 3x5 像素字体由本项目在 `DefaultSkin.swift` 中用代码原创绘制，未包含 Winamp 的任何素材。
MP9 与 Winamp / Nullsoft / Llama Group 无关；用户导入的 .wsz 皮肤版权归原作者所有。

## 测试素材
`base-2.91.wsz` 等第三方皮肤仅在本地测试时使用（`Fixtures/local/` 或 `MP9_TEST_WSZ`），不入库、不随 App 分发。
