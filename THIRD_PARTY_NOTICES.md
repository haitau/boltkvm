# 第三方代码与许可

本项目在 `Sources/CVirtualDisplay/` 下包含来自 **vdscreen** 的代码，用于创建
macOS 虚拟显示器。

- 上游：https://github.com/lyonDan/vdscreen
- 版本：commit `bfb16fecf039e05120c137ba1a694bd885f503f4`（2026-10-18）
- 许可：MIT
- 取用范围：`CGVirtualDisplayShim.h` 原样引入；`BKVVirtualDisplay.m` 中的创建流程、
  HiDPI 模式核对与回退逻辑改编自上游 `vdscreen.m`；布局恢复、主屏切换、CLI 与
  菜单栏应用未引入。
- 本地改动：私有类接口封装为 C API（`BKVVirtualDisplayCreate` 等）、显示器被系统
  移除时回调宿主而不是打印到 stderr、显示器身份固定为 `io.github.boltkvm.virtualdisplay`。

上游许可全文：

```
MIT License

Copyright (c) 2026 lyonDan

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
```
