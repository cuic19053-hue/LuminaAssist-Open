const fs = require(''fs'');
const p = ''d:\\c4.ai.huawei\\LuminaApp\\entry\\src\\main\\ets\\entryability\\EntryAbility.ets'';
let c = fs.readFileSync(p, ''utf8'');
const oldImport = ''import { Agent } from ''''../agent/Agent'''';\nimport { LLMClient } from ''''../services/LLMClient'''';'';
const newImport = ''import { Agent } from ''''../agent/Agent'''';\nimport { VisionService } from ''''../services/VisionService'''';\nimport { LocalImageClassifier, ClassifierConfig } from ''''../services/LocalImageClassifier'''';'';
if (c.includes(oldImport)) { c = c.replace(oldImport, newImport); console.log(''IMPORT_REPLACED''); } else { console.log(''IMPORT_NOT_FOUND''); }
const oldOnCreate = ''    // 初始化端侧 Agent（使用 UIAbility 继承的 context）\n    Agent.getInstance().init(this.context);\n\n    // 动态申请运行时权限'';
const newOnCreate = ''    // 初始化端侧 Agent（使用 UIAbility 继承的 context）\n    Agent.getInstance().init(this.context);\n\n    // 异步初始化端侧图像分类引擎（P0-3 端侧视觉大模型落地，不阻塞主线程）\n    this.initLocalEngines(this.context);\n\n    // 动态申请运行时权限'';
if (c.includes(oldOnCreate)) { c = c.replace(oldOnCreate, newOnCreate); console.log(''ONCREATE_REPLACED''); } else { console.log(''ONCREATE_NOT_FOUND''); }
const oldOnDestroy = ''    Agent.getInstance().destroy();\n  }'';
const newOnDestroy = ''    Agent.getInstance().destroy();\n    LocalImageClassifier.getInstance().destroy();\n  }'';
if (c.includes(oldOnDestroy)) { c = c.replace(oldOnDestroy, newOnDestroy); console.log(''ONDESTROY_REPLACED''); } else { console.log(''ONDESTROY_NOT_FOUND''); }
fs.writeFileSync(p, c, ''utf8'');
console.log(''ENTRY_OK size='' + c.length);
