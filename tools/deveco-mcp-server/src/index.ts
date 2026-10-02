#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

const server = new Server(
  {
    name: "deveco-mcp-server",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "run_hvigor_task",
        description: "在指定的 HarmonyOS 工程目录运行 hvigorw 编译或测试任务",
        inputSchema: {
          type: "object",
          properties: {
            projectPath: { type: "string", description: "项目根目录绝对路径" },
            task: { type: "string", description: "hvigor 任务名，如 assembleDebug 或 test" },
          },
          required: ["projectPath", "task"],
        },
      },
      {
        name: "run_hdc_command",
        description: "运行 HarmonyOS Device Connector (hdc) 命令，用于管理设备和模拟器",
        inputSchema: {
          type: "object",
          properties: {
            command: { type: "string", description: "hdc 的具体命令参数，例如 'list targets' 或 'install xxx.hap'" },
          },
          required: ["command"],
        },
      }
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  if (name === "run_hvigor_task") {
    const { projectPath, task } = args as { projectPath: string; task: string };
    try {
      const { stdout, stderr } = await execAsync(`.\\hvigorw.bat ${task}`, { cwd: projectPath });
      return {
        content: [{ type: "text", text: `Stdout:\n${stdout}\nStderr:\n${stderr}` }],
      };
    } catch (error: any) {
      return {
        content: [{ type: "text", text: `Execution failed:\n${error.message}\n${error.stdout || ''}` }],
        isError: true,
      };
    }
  }

  if (name === "run_hdc_command") {
    const { command } = args as { command: string };
    try {
      const { stdout, stderr } = await execAsync(`hdc ${command}`);
      return {
        content: [{ type: "text", text: `Stdout:\n${stdout}\nStderr:\n${stderr}` }],
      };
    } catch (error: any) {
      return {
        content: [{ type: "text", text: `hdc failed:\n${error.message}\n${error.stdout || ''}` }],
        isError: true,
      };
    }
  }

  throw new Error(`未知的工具: ${name}`);
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("DevEco MCP Server running on stdio");
}

main().catch((error) => console.error("Fatal error:", error));
