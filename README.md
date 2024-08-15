# Linux-0.12-code-review

Linux-0.12 code review，大部分参考了《Linux 内核完全注释》

为了更好地在 vscode 上阅读代码，建议安装下面的插件：
| 名称 | 介绍 |
| ----------------------- | ------------------------------------------------------- |
| GNU Assembler Language | 阅读 gas 汇编代码(提供类 AT&T 语法高亮), 也就是`head.s` |
| x86 and x86_64 Assembly | 阅读 as86 汇编代码, 包括`bootsect.S`和`setup.S` |
| clangd | 阅读 C 语言代码 |

如果你使用的是 prettier 来格式化代码的化，建议把在保存时自动格式化关掉，不然会把`.c`代码格式化得很乱，我现还没有找到一个合适的方法来格式化gnu c的代码