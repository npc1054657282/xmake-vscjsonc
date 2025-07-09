# xmake-vscjsonc
可以修改vscode的settings.json风格的jsonc，不破坏注释的配置设置xmake模块。

## 概述

虽然xmake已经提供了json解析工具，但是，由于vscode常用的配置文件并非标准json，而是“Json with comments”。因此，在xmake脚本中如果想要动态修改vscode配置，仍然存在一些不便。

这个小模块是一个比较简要的能够保留原有vscode注释的jsonc编辑器。由于主要目标是为了动态修改vscode配置，所以功能比较简陋，主要侧重于编辑而不是读取。

## 使用方法

将`module/vsjsonc.lua`文件拷贝到工程里的模块目录，这里假定模块目录为`module`。

在xmake脚本域使用：

``` lua
local editor = import("module.vscjsonc")("path/to/jsonc/file")
```

打开并解析一个jsonc文档。如果文件不存在，则将解析为一个空白文档。

对于得到的editor，主要提供`set`与`save`方法。详细的使用方法可以参见`module/vsjsonc.lua`中的`test_jsonc`函数。

### set

- 参数 `path` (`string` | `table`)
  
  描述jsonc文档中一个键的路径。如果为`string`，表示根级别下的单个键。由于vscode的配置往往采用扁平化管理，因此该配置在实践中往往已经足够。如果为`table`，表示一个嵌套的键路径，表中的每个元素对应路径的一层。
  
- 参数 `value` (`string` | `number` | `boolean` | `nil` | `table`)
  
  要设置到指定路径的新值。可以是任何标准的JSON数据类型：字符串、数字、布尔值或`nil`（会被转换成`null`）。
  
  **注意：**如果`value`是一个`table`（用于表示JSON对象或数组），它必须被`vscjsonc.object()`或`vscjsonc.array()`函数包装 。这样做是为了明确区分是创建一个对象还是一个数组，因为在Lua中它们都用`table`表示。直接传入一个未包装的普通`table`会导致错误。
  
- 参数 `options` (`table`, 可选)
  
  一个包含额外配置选项的表 。
  
  - `options.comment` (`string`, 可选)
    
    为新设置的值前方添加一行注释。
    
    示例: `options = { comment = "这是一行注释" }`

  - `options.preserve_comments` (`boolean`, 可选)
    
    当更新一个已存在的值时，决定是否保留其原有的注释。默认为`true`。若设置为`false`，在更新值时，会丢弃该节点上原有的所有注释。

- 返回值 编辑器实例本身，以便进行链式调用

### save

将设置的内容保存到打开的jsonc文档。