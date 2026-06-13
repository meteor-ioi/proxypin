/*
 * Copyright 2026 Antigravity. All rights reserved.
 */

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/network/mcp/mcp_server.dart';
import 'package:flutter_toastr/flutter_toastr.dart';

class AiSettingDialog extends StatefulWidget {
  const AiSettingDialog({super.key});

  @override
  State<AiSettingDialog> createState() => _AiSettingDialogState();
}

class _AiSettingDialogState extends State<AiSettingDialog> {
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _portController = TextEditingController();
  bool _mcpEnabled = false;
  String _mcpToken = "";
  String _mcpScriptPath = "";

  @override
  void initState() {
    super.initState();
    final config = AppConfiguration.current;
    if (config != null) {
      _apiKeyController.text = config.llmApiKey;
      _baseUrlController.text = config.llmBaseUrl;
      _modelController.text = config.llmModel;
      _portController.text = config.mcpPort.toString();
      _mcpEnabled = config.mcpEnabled;
      _mcpToken = config.mcpToken;
    }
    final userHome = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    if (userHome.isNotEmpty) {
      _mcpScriptPath = '$userHome${Platform.pathSeparator}.proxypin${Platform.pathSeparator}proxypin-mcp.js';
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<String> _deployMcpBridge() async {
    try {
      final userHome = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
      if (userHome.isEmpty) return '';
      final dir = Directory('$userHome${Platform.pathSeparator}.proxypin');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}${Platform.pathSeparator}proxypin-mcp.js');
      await file.writeAsString(_mcpBridgeJsContent);
      return file.path;
    } catch (e) {
      debugPrint("Deploy MCP bridge script error: $e");
      return '';
    }
  }

  String _buildClaudeConfigJson() {
    final port = int.tryParse(_portController.text) ?? 8899;
    
    // 转义 Windows 下的路径反斜杠以确保 JSON 合法
    var escapedPath = _mcpScriptPath;
    if (Platform.isWindows) {
      escapedPath = escapedPath.replaceAll('\\', '\\\\');
    }
    
    final map = {
      "mcpServers": {
        "proxypin": {
          "command": "node",
          "args": [
            escapedPath,
            "--port",
            port.toString(),
            "--token",
            _mcpToken
          ]
        }
      }
    };
    
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  Future<void> _save() async {
    final config = AppConfiguration.current;
    if (config == null) return;

    final port = int.tryParse(_portController.text) ?? 8899;

    final prevEnabled = config.mcpEnabled;
    final prevPort = config.mcpPort;
    final prevToken = config.mcpToken;

    config.llmApiKey = _apiKeyController.text.trim();
    config.llmBaseUrl = _baseUrlController.text.trim();
    config.llmModel = _modelController.text.trim();
    config.mcpEnabled = _mcpEnabled;
    config.mcpPort = port;

    await config.flushConfig();

    if (_mcpEnabled) {
      await _deployMcpBridge();
    }

    // 根据开关状态和端口变化动态控制 MCP Server
    if (_mcpEnabled) {
      if (!prevEnabled || prevPort != port || prevToken != config.mcpToken || !McpServer.instance.isRunning) {
        await McpServer.instance.start(port, config.mcpToken);
      }
    } else {
      if (prevEnabled) {
        await McpServer.instance.stop();
      }
    }

    if (mounted) {
      FlutterToastr.show("AI 与 MCP 配置保存成功", context);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("AI 分析与 MCP 服务配置"),
      content: SizedBox(
        width: 550,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("🤖 LLM 大模型配置", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 10),
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "API Key (如: sk-xxx)",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: "API Base URL",
                  helperText: "例如: https://api.deepseek.com/v1 或 https://api.openai.com/v1",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: "模型名称 (Model Name)",
                  helperText: "如: deepseek-chat 或 gpt-4o-mini",
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const Divider(height: 25),
              const Text("🔌 MCP 服务配置 (外部 AI 桥接)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 5),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text("启用内置 MCP 服务"),
                subtitle: Text(McpServer.instance.isRunning ? "状态: 运行中" : "状态: 未启动", 
                    style: TextStyle(color: McpServer.instance.isRunning ? Colors.green : Colors.grey)),
                value: _mcpEnabled,
                onChanged: (val) {
                  setState(() {
                    _mcpEnabled = val;
                  });
                },
              ),
              if (_mcpEnabled) ...[
                const SizedBox(height: 5),
                TextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "MCP 侦听端口",
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text("安全鉴权 Token:\n$_mcpToken", style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: "复制 Token",
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _mcpToken));
                        FlutterToastr.show("Token 已复制到剪贴板", context);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ExpansionTile(
                  title: const Text("🔌 如何连接外部 AI 客户端 (如 Claude Desktop)？",
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.deepOrangeAccent)),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "1. 确认系统已安装 Node.js 环境 (支持 'node' 终端命令)。\n"
                        "2. 桥接脚本将会自动释放到以下绝对路径：",
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(6),
                      color: Colors.grey.shade100,
                      child: SelectableText(
                        _mcpScriptPath,
                        style: const TextStyle(fontSize: 11, color: Colors.blue, fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "3. 请复制以下配置段，并粘贴配置进您本地 AI 客户端的配置文件 (如 Claude Desktop 的 config.json)：",
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      color: Colors.grey.shade100,
                      child: SelectableText(
                        _buildClaudeConfigJson(),
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text("一键复制 Claude 配置 JSON"),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _buildClaudeConfigJson()));
                        FlutterToastr.show("Claude 配置 JSON 已复制到剪贴板", context);
                      },
                    ),
                    const SizedBox(height: 5),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("取消"),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text("保存"),
        ),
      ],
    );
  }
}

const String _mcpBridgeJsContent = r'''#!/usr/bin/env node

/*
 * Copyright 2026 Antigravity. All rights reserved.
 * Stdio-to-HTTP Bridge for Proxypin MCP Server.
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const readline = require('readline');

// 默认配置
let port = 8899;
let token = '';

// 尝试自动读取本地 Proxypin 配置文件
try {
  const homeDir = process.env.HOME || process.env.USERPROFILE;
  const configPath = path.join(homeDir, '.proxypin', 'ui_config.json');
  if (fs.existsSync(configPath)) {
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    if (config.mcpPort) port = parseInt(config.mcpPort, 10);
    if (config.mcpToken) token = config.mcpToken;
  }
} catch (e) {
  // 忽略错误，回退到默认
}

// 支持命令行参数覆盖
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    port = parseInt(args[i + 1], 10);
    i++;
  } else if (args[i] === '--token' && args[i + 1]) {
    token = args[i + 1];
    i++;
  }
}

// 启动 Stdio 逐行读取
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on('line', (line) => {
  if (!line.trim()) return;

  const body = Buffer.from(line, 'utf8');

  // 转发 JSON-RPC 请求到本地 HTTP Server
  const options = {
    hostname: '127.0.0.1',
    port: port,
    path: '/mcp',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
      'Content-Length': body.length
    }
  };

  const req = http.request(options, (res) => {
    let responseData = '';
    res.on('data', (chunk) => {
      responseData += chunk;
    });
    res.on('end', () => {
      // 写入到 stdout 给 AI 客户端
      process.stdout.write(responseData + '\n');
    });
  });

  req.on('error', (e) => {
    // 遇到连接错误，回传标准 JSON-RPC 错误以防 AI 客户端 Crash
    try {
      const parsed = JSON.parse(line);
      const errResponse = {
        jsonrpc: '2.0',
        error: { 
          code: -32603, 
          message: `无法连接到 Proxypin 后台服务 (Port ${port})，请确保 Proxypin 客户端已运行且开启了 MCP。错误: ${e.message}` 
        },
        id: parsed.id || null
      };
      process.stdout.write(JSON.stringify(errResponse) + '\n');
    } catch {
      // 忽略无法解析的请求
    }
  });

  req.write(body);
  req.end();
});
''';
